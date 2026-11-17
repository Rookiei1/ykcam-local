import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// 传服务器用的流式录像：H.264 + AAC 用 HLS 分段每 4 秒出一段，一出来就交给 Uploader 传服务器。
/// 即使手机刚被拿走就被关机，前面几秒的画面和声音也已经传到服务器。
final class VideoRecorder {
    private let queue = DispatchQueue(label: "ykcam.video-recorder")
    private let stateLock = NSLock()
    private var active = false

    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var sink: VideoSegmentSink?
    private var eventID = ""
    private var waitingFirstFrame = false
    private var startPTS: CMTime?

    var recording: Bool { stateLock.withLock { active } }

    func start(eventID id: String) {
        stateLock.withLock { active = true }
        queue.async {
            guard self.writer == nil, !self.waitingFirstFrame else { return }
            self.eventID = id
            self.waitingFirstFrame = true
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        guard recording else { return }
        queue.async {
            if self.waitingFirstFrame, let px = CMSampleBufferGetImageBuffer(sample) {
                self.waitingFirstFrame = false
                self.open(at: CMSampleBufferGetPresentationTimeStamp(sample),
                          width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
            }
            guard let w = self.writer, w.status == .writing, let v = self.videoIn, v.isReadyForMoreMediaData else { return }
            v.append(sample)
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard recording else { return }
        queue.async {
            guard let w = self.writer, w.status == .writing, let a = self.audioIn, a.isReadyForMoreMediaData,
                  let start = self.startPTS, CMSampleBufferGetPresentationTimeStamp(sample) >= start else { return }
            a.append(sample)
        }
    }

    private func open(at start: CMTime, width: Int, height: Int) {
        let w = AVAssetWriter(contentType: UTType.mpeg4Movie)
        w.outputFileTypeProfile = .mpeg4AppleHLS
        w.preferredOutputSegmentInterval = CMTime(seconds: 4, preferredTimescale: 1)
        w.initialSegmentStartTime = start
        let s = VideoSegmentSink(eventID: eventID)
        w.delegate = s
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_000_000,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoExpectedSourceFrameRateKey: 15,
            ],
        ])
        v.expectsMediaDataInRealTime = true
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ])
        a.expectsMediaDataInRealTime = true
        guard w.canAdd(v), w.canAdd(a) else { return }
        w.add(v)
        w.add(a)
        guard w.startWriting() else { return }
        w.startSession(atSourceTime: start)
        writer = w
        videoIn = v
        audioIn = a
        sink = s
        startPTS = start
    }

    /// 停止流式录像并等待最后一段写入队列；如果传了 clipSeconds，会补发一个结束标记给服务器标时长
    func stop(clipSeconds: Int? = nil) async {
        stateLock.withLock { active = false }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.waitingFirstFrame = false
                guard let w = self.writer else {
                    c.resume()
                    return
                }
                let s = self.sink
                let id = self.eventID
                self.videoIn?.markAsFinished()
                self.audioIn?.markAsFinished()
                self.writer = nil
                self.videoIn = nil
                self.audioIn = nil
                self.sink = nil
                self.startPTS = nil
                w.finishWriting {
                    if let clipSeconds, let s, s.partCount > 0 {
                        Uploader.shared.saveClipEnd(id: id, part: s.partCount, seconds: clipSeconds)
                    }
                    c.resume()
                }
            }
        }
    }
}

/// 一次录像一个：每段交给 Uploader（段号从 0 开始，0 是初始化段）
final class VideoSegmentSink: NSObject, AVAssetWriterDelegate {
    let eventID: String
    private var part = 0
    private let lock = NSLock()

    init(eventID: String) {
        self.eventID = eventID
    }

    var partCount: Int { lock.withLock { part } }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        let n = lock.withLock { () -> Int in
            let current = part
            part += 1
            return current
        }
        Uploader.shared.saveVideo(id: eventID, part: n, data: segmentData)
    }
}
