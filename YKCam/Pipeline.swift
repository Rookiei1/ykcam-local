import AVFoundation
import Foundation

/// 监控的整条流水线，全部在手机本地运行，不连任何服务器：
/// 画面有变化 → 拍照 + 录像；手机被动了 → 前后摄像头拍照，马上开始前置录像；
/// 一直被拿着走 → 警报 + 喊话 + 继续录像，每 30 秒存一段进相册。
/// 不绑主线程，画面在 CameraEngine 的 videoQueue 上进来。界面通过 onFlash / onAlarm 收通知。
final class Pipeline {
    struct Detection {
        var roi: [Double] = [0, 0, 1, 1]
        var sensitivity = 5
    }

    /// 点开始后留 20 秒让人走开，再加检测本身 10 秒预热，一共 30 秒后生效
    static let leaveDelay: TimeInterval = 20
    static let minClip: TimeInterval = 60      // 闯入录像至少录这么久
    static let quietStop: TimeInterval = 30    // 没动静这么久就停
    static let maxClip: TimeInterval = 600     // 一段最长 10 分钟
    static let carryWatch: TimeInterval = 30   // 手机被动后，前置录这么久并看是不是被拿着走
    static let theftChunk: TimeInterval = 30   // 被拿走时每段这么长，一段录完马上存相册
    static let theftLimit: TimeInterval = 600

    let engine = CameraEngine()
    let motion = MotionGuard()
    let siren = Siren()
    let clip = ClipRecorder()
    let store: RecordStore

    private let detector = Detector()
    private let lock = NSLock()

    // 下面这些都在 lock 里读写
    private var detection = Detection()
    private var shots: [(due: TimeInterval, seq: Int, id: String)] = []
    private var firstHitJPEG: Data?
    private var switching = false
    private var armedAt: TimeInterval = .infinity
    private var lastFrame: TimeInterval = 0
    private var frameCount = 0
    private var intrusionID: String?
    private var clipStarted: TimeInterval = 0
    private var theftStopRequested = false

    var saveIntrusionToPhotos = false

    /// 提示文字（任意线程调用）
    var onFlash: ((String) -> Void)?
    /// 警报开始 / 结束（任意线程调用）
    var onAlarm: ((Bool) -> Void)?

    init(store: RecordStore = .shared) {
        self.store = store
    }

    static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    func setDetection(_ d: Detection) { lock.withLock { detection = d } }

    /// 还要多少秒才开始监控；已经开始了返回 0
    var secondsUntilArmed: Int {
        let at = lock.withLock { armedAt }
        guard at != .infinity else { return 0 }
        return max(0, Int((at + Detector.warmup - Date().timeIntervalSince1970).rounded(.up)))
    }

    var cameraOK: Bool { Date().timeIntervalSince1970 - lock.withLock { lastFrame } < 3 }
    var currentRecordID: String? { lock.withLock { intrusionID } }

    func takeFrameCount() -> Int {
        lock.withLock {
            let n = frameCount
            frameCount = 0
            return n
        }
    }

    // MARK: 开始 / 结束

    func begin() {
        let now = Date().timeIntervalSince1970
        lock.withLock {
            armedAt = now + Pipeline.leaveDelay
            switching = false
            shots = []
            intrusionID = nil
        }
        siren.prepare()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Pipeline.leaveDelay * 1e9))
            guard let self, self.lock.withLock({ self.armedAt }) != .infinity else { return }
            self.resetDetector()
            self.motion.start()   // MotionGuard 自己还会等手机放稳 10 秒
        }
    }

    func end() async {
        lock.withLock {
            armedAt = .infinity
            theftStopRequested = true
            intrusionID = nil
        }
        motion.stop()
        siren.shutdown()
        await clip.stop()
        engine.stop()
    }

    func resetDetector() {
        lock.withLock { detector.reset(now: Date().timeIntervalSince1970) }
    }

    // MARK: 每帧（videoQueue 上）

    func processFrame(_ buffer: CVPixelBuffer, _ now: TimeInterval) {
        let (paused, armed, d) = lock.withLock { () -> (Bool, Bool, Detection) in
            lastFrame = now
            frameCount += 1
            return (switching, now >= armedAt, detection)
        }
        guard !paused, armed else { return }
        takeDueShots(buffer, now)

        guard let gray = CameraEngine.grayscale(buffer) else { return }
        let result = lock.withLock {
            detector.feed(gray: gray.pixels, w: gray.w, h: gray.h, now: now, roi: d.roi, sensitivity: d.sensitivity)
        }
        switch result {
        case .firstHit:
            let jpeg = engine.jpeg(buffer, maxSide: 1280, quality: 0.85)
            lock.withLock { firstHitJPEG = jpeg }
        case .alarm:
            startIntrusion(buffer, now)
        default:
            break
        }
        finishIntrusionIfQuiet(now)
    }

    private func startIntrusion(_ buffer: CVPixelBuffer, _ now: TimeInterval) {
        let already = lock.withLock { intrusionID != nil }
        if already { return }   // 正在录，靠 lastMotion 延长
        let id = EventID.make(Date(timeIntervalSince1970: now))
        store.create(id: id, time: now, kind: .intrusion)
        let first = lock.withLock { firstHitJPEG }
        if let jpeg = first ?? engine.jpeg(buffer, maxSide: 1280, quality: 0.85) {
            store.addPhoto(id: id, seq: 0, jpeg: jpeg)
        }
        clip.start(to: store.newVideoURL(id: id))
        lock.withLock {
            intrusionID = id
            clipStarted = now
            shots.append((now + 1, 1, id))
            shots.append((now + 2.5, 2, id))
        }
        onFlash?("\(Pipeline.clock()) 有人闯入，正在录像")
    }

    private func finishIntrusionIfQuiet(_ now: TimeInterval) {
        let stop = lock.withLock { () -> Bool in
            guard intrusionID != nil else { return false }
            let age = now - clipStarted
            let quiet = now - detector.lastMotion
            guard age >= Pipeline.maxClip || (age >= Pipeline.minClip && quiet > Pipeline.quietStop) else { return false }
            intrusionID = nil
            return true
        }
        if stop { Task { await self.closeClip(saveToPhotos: self.saveIntrusionToPhotos) } }
    }

    private func closeClip(saveToPhotos: Bool) async {
        if let url = await clip.stop(), saveToPhotos { PhotoSaver.save(video: url) }
    }

    private func takeDueShots(_ buffer: CVPixelBuffer, _ now: TimeInterval) {
        let due = lock.withLock { () -> [(due: TimeInterval, seq: Int, id: String)] in
            let ready = shots.filter { $0.due <= now }
            shots.removeAll { $0.due <= now }
            return ready
        }
        for s in due {
            if let jpeg = engine.jpeg(buffer, maxSide: 1280, quality: 0.85) {
                store.addPhoto(id: s.id, seq: s.seq, jpeg: jpeg)
            }
        }
    }

    // MARK: 手机被动了：后置拍一张 → 切前置拍人并马上开始录像 → 一直被拿着走就报警
    // 照片序号 0、1 后置，5、6 前置。摄像头不会被占去做别的，从拿起开始一直有录像。

    func handleMoved() async {
        let busy = lock.withLock { () -> Bool in
            if switching { return true }
            switching = true
            intrusionID = nil
            return false
        }
        if busy { return }
        motion.paused = true
        await closeClip(saveToPhotos: saveIntrusionToPhotos)

        let id = EventID.make()
        store.create(id: id, time: Date().timeIntervalSince1970, kind: .moved)
        onFlash?("\(Pipeline.clock()) 手机被动了，正在拍照录像")
        if let j = engine.currentJPEG() { store.addPhoto(id: id, seq: 0, jpeg: j) }

        do {
            try await engine.switchTo(.front)
            clip.start(to: store.newVideoURL(id: id))
            try await Task.sleep(nanoseconds: 400_000_000)   // 等前置曝光稳定
            saveFrontPhoto(id: id, seq: 5)
            try await Task.sleep(nanoseconds: 800_000_000)
            saveFrontPhoto(id: id, seq: 6)
        } catch {
            onFlash?("前置摄像头没拍成：\(error.localizedDescription)")
        }
        let carried = await watchForCarry()
        await closeClip(saveToPhotos: carried || saveIntrusionToPhotos)
        if carried {
            store.setKind(id: id, kind: .theft)
            await theftMode(id: id)
        }
        do {
            try await engine.switchTo(.back)
            try await Task.sleep(nanoseconds: 400_000_000)
            if let j = engine.currentJPEG() { store.addPhoto(id: id, seq: 1, jpeg: j) }
        } catch {
            onFlash?("切回后置摄像头失败：\(error.localizedDescription)")
        }
        resetDetector()   // 换过摄像头，背景重学，10 秒内不按画面报警
        lock.withLock { switching = false }
        motion.paused = false
    }

    /// 拍到拿手机的人：存手机，也马上存相册（开了 iCloud 照片就会同步走）
    private func saveFrontPhoto(id: String, seq: Int) {
        guard let j = engine.currentJPEG() else { return }
        store.addPhoto(id: id, seq: seq, jpeg: j)
        PhotoSaver.save(image: store.url(id: id, name: "photo-\(seq).jpg"))
    }

    /// 动作传感器看 30 秒：一直在晃，而且没放回原来的朝向，就当作被拿着走了
    private func watchForCarry() async -> Bool {
        var judge = CarryJudge()
        let judgeLock = NSLock()
        var carried = false
        motion.onSample = { shake, tilt in
            judgeLock.withLock {
                if judge.feed(now: Date().timeIntervalSince1970, shake: shake, tilt: tilt) { carried = true }
            }
        }
        defer { motion.onSample = nil }
        let deadline = Date().timeIntervalSince1970 + Pipeline.carryWatch
        while Date().timeIntervalSince1970 < deadline, lock.withLock({ armedAt }) != .infinity {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if judgeLock.withLock({ carried }) { return true }
        }
        return false
    }

    // MARK: 被拿着走：警报 + 喊话 + 前置继续录像，每 30 秒存一段进相册（开了 iCloud 照片就会同步走）

    private func theftMode(id: String) async {
        lock.withLock { theftStopRequested = false }
        onAlarm?(true)
        onFlash?("\(Pipeline.clock()) 手机被拿走！正在报警、录像")
        siren.sound(true)

        let started = Date().timeIntervalSince1970
        var finished = false
        while !finished {
            clip.start(to: store.newVideoURL(id: id))
            let chunkStart = Date().timeIntervalSince1970
            while Date().timeIntervalSince1970 - chunkStart < Pipeline.theftChunk {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let stop = lock.withLock { theftStopRequested }
                if stop || Date().timeIntervalSince1970 - started > Pipeline.theftLimit {
                    finished = true
                    break
                }
            }
            await closeClip(saveToPhotos: true)
        }
        siren.sound(false)
        onAlarm?(false)
    }

    // MARK: 监控被切走、锁屏：马上响。回来后要机主验证才停

    func tamperAlarm(shot: Data?) {
        // armedAt 没到（还在倒计时）不算；没开始监控时 armedAt 是无穷大，也不算
        guard lock.withLock({ Date().timeIntervalSince1970 >= armedAt }), !siren.sounding else { return }
        let id = EventID.make()
        store.create(id: id, time: Date().timeIntervalSince1970, kind: .left)
        if let shot { store.addPhoto(id: id, seq: 0, jpeg: shot) }
        siren.sound(true)
        onAlarm?(true)
    }

    /// 机主验证通过后调用：停警报，回到监控
    func stopAlarm() {
        lock.withLock { theftStopRequested = true }
        siren.sound(false)
        onAlarm?(false)
    }
}
