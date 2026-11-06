import AVFoundation
import CoreImage
import ImageIO
import UIKit

/// 摄像头和麦克风。平时开后置（默认 0.5× 超广角）对着门；手机被动了临时切前置拍人。
/// 视频帧每秒约 10 张交给 onFrame，每一帧原始画面和麦克风的声音交给 onVideoSample、onAudio（录像用）。
final class CameraEngine: NSObject {
    enum Lens: String, CaseIterable { case ultra, wide }
    enum Facing { case back, front }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ykcam.session")
    private let videoQueue = DispatchQueue(label: "ykcam.video")
    private let audioQueue = DispatchQueue(label: "ykcam.audio")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private let ci = CIContext(options: [.useSoftwareRenderer: false])

    var lens: Lens = .ultra
    private(set) var facing: Facing = .back
    private(set) var lensLabel = ""

    /// 收到新画面（已转成竖屏）。在 videoQueue 上调用。
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    /// 麦克风的声音。在 audioQueue 上调用。
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// 每一帧原始画面（不限帧率），录像用。在 videoQueue 上调用。
    var onVideoSample: ((CMSampleBuffer) -> Void)?

    private var lastFrame: TimeInterval = 0
    private let frameInterval: TimeInterval = 0.1
    private var latest: CVPixelBuffer?
    private let latestLock = NSLock()

    // MARK: 权限

    static func requestPermissions() async -> (camera: Bool, mic: Bool) {
        let cam = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return (cam, mic)
    }

    // MARK: 开关

    func start(withMic: Bool) async throws {
        try await onSession {
            self.session.beginConfiguration()
            // 音频会话自己管（playAndRecord + 外放），防偷警报响的时候还能接着录
            self.session.automaticallyConfiguresApplicationAudioSession = false
            Siren.configureSession()
            self.session.sessionPreset = .hd1280x720
            if withMic, let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic), self.session.canAddInput(input) {
                self.session.addInput(input)
                if self.session.canAddOutput(self.audioOutput) {
                    self.session.addOutput(self.audioOutput)
                    self.audioOutput.setSampleBufferDelegate(self, queue: self.audioQueue)
                }
            }
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
            try self.attachCamera(.back)
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// 换前置 / 后置。换完、出新画面后才返回。
    func switchTo(_ facing: Facing) async throws {
        try await onSession {
            self.session.beginConfiguration()
            try self.attachCamera(facing)
            self.session.commitConfiguration()
        }
        latestLock.lock(); latest = nil; latestLock.unlock()
        for _ in 0..<30 {   // 最多等 3 秒出第一帧
            if currentBuffer() != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func onSession(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do { try work(); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    private func pickDevice(_ facing: Facing) -> AVCaptureDevice? {
        if facing == .front {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        if lens == .ultra, let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            return uw
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// 在 sessionQueue 上、beginConfiguration 之后调用
    private func attachCamera(_ facing: Facing) throws {
        guard let device = pickDevice(facing) else { throw NSError(domain: "ykcam", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到摄像头"]) }
        if let old = videoInput { session.removeInput(old) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw NSError(domain: "ykcam", code: 2, userInfo: [NSLocalizedDescriptionKey: "摄像头被占用"]) }
        session.addInput(input)
        videoInput = input
        self.facing = facing
        if facing == .back {
            lensLabel = device.deviceType == .builtInUltraWideCamera ? "超广角 0.5×" : "普通 1×"
        }
        // 每秒最多 15 帧，省电省发热
        if (try? device.lockForConfiguration()) != nil {
            let want = CMTime(value: 1, timescale: 15)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= want && want <= $0.maxFrameDuration }) {
                device.activeVideoMinFrameDuration = want
                device.activeVideoMaxFrameDuration = want
            }
            device.unlockForConfiguration()
        }
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }   // 手机竖着放
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = false }
        }
    }

    // MARK: 取画面

    func currentBuffer() -> CVPixelBuffer? {
        latestLock.lock(); defer { latestLock.unlock() }
        return latest
    }

    /// 把画面编成 JPEG，长边不超过 maxSide
    func jpeg(_ buffer: CVPixelBuffer, maxSide: CGFloat, quality: CGFloat) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        let side = max(image.extent.width, image.extent.height)
        if side > maxSide {
            let k = maxSide / side
            image = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ci.jpegRepresentation(of: image, colorSpace: space, options: [key: quality])
    }

    func currentJPEG(maxSide: CGFloat = 1280, quality: CGFloat = 0.85) -> Data? {
        guard let b = currentBuffer() else { return nil }
        return jpeg(b, maxSide: maxSide, quality: quality)
    }

    /// 从亮度通道缩成宽 targetW 的灰度图，给检测用
    static func grayscale(_ buffer: CVPixelBuffer, targetW: Int = 320) -> (pixels: [UInt8], w: Int, h: Int)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let w = min(targetW, width)
        let h = max(1, height * w / width)
        let src = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let sy = y * height / h
            for x in 0..<w {
                out[y * w + x] = src[sy * row + x * width / w]
            }
        }
        return (out, w, h)
    }
}

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            onAudio?(sampleBuffer)
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestLock.lock(); latest = buffer; latestLock.unlock()
        onVideoSample?(sampleBuffer)
        let now = Date().timeIntervalSince1970
        guard now - lastFrame >= frameInterval else { return }
        lastFrame = now
        onFrame?(buffer, now)
    }
}
