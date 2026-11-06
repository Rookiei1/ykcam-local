import AVFoundation

/// 录一段视频（画面 + 声音）到手机文件。每 2 秒落一次盘：App 中途被杀，已录的部分也还能播。
final class ClipRecorder {
    private let queue = DispatchQueue(label: "ykcam.clip")
    private let stateLock = NSLock()
    private var active = false            // 没在录时直接丢帧，不排队、不占摄像头缓冲

    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var target: URL?
    private var waitingFirstFrame = false
    private var startPTS: CMTime?

    var recording: Bool { stateLock.withLock { active } }

    func start(to url: URL) {
        stateLock.withLock { active = true }
        queue.async {
            self.target = url
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
        guard let url = target, let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_500_000,   // 约 11 MB 一分钟
                AVVideoExpectedSourceFrameRateKey: 15,
            ],
        ])
        v.expectsMediaDataInRealTime = true
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
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
        startPTS = start
    }

    /// 停止并写完文件；返回录好的文件（一帧都没录到时返回 nil）
    @discardableResult
    func stop() async -> URL? {
        stateLock.withLock { active = false }
        return await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
            queue.async {
                self.waitingFirstFrame = false
                let url = self.target
                self.target = nil
                self.startPTS = nil
                guard let w = self.writer else { c.resume(returning: nil); return }
                self.videoIn?.markAsFinished()
                self.audioIn?.markAsFinished()
                self.writer = nil
                self.videoIn = nil
                self.audioIn = nil
                w.finishWriting { c.resume(returning: url) }
            }
        }
    }
}
