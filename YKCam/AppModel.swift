import SwiftUI
import UIKit

/// 界面状态和设置。具体干活的是 Pipeline。支持连自建服务器（实时看画面、听声音、推送和云备份），也支持仅本机监控。
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case loading, pair, ready, running }

    @Published var phase: Phase = .loading
    @Published var serverInput: String = ""
    @Published var camName: String = "iPhone 13"
    @Published var isPaired: Bool = false
    @Published var canReturnFromPair: Bool = false

    @Published var statusText = ""
    @Published var errorText = ""
    @Published var alarmOn = false
    @Published var serverArmed = true
    @Published var linkConnected = false
    @Published var linkLive = false
    @Published var linkListen = false
    @Published var pendingUploads = 0

    @Published var showRecords = false
    @Published var records: [Record] = []
    @Published var usedBytes: Int64 = 0

    @Published var lens: CameraEngine.Lens { didSet { defaults.set(lens.rawValue, forKey: "lens") } }
    @Published var sensitivity: Int { didSet { defaults.set(sensitivity, forKey: "sensitivity") } }
    @Published var roi: [Double] { didSet { defaults.set(roi, forKey: "roi") } }
    @Published var keepDays: Int { didSet { defaults.set(keepDays, forKey: "keepDays") } }
    @Published var saveIntrusion: Bool { didSet { defaults.set(saveIntrusion, forKey: "saveIntrusion") } }

    let pipe = Pipeline()
    private let defaults = UserDefaults.standard
    private var tamperShot: Data?
    private var flash = ""
    private var flashUntil: TimeInterval = 0
    private var timers: [Timer] = []
    private var savedBrightness: CGFloat = 0.5
    private var ticks = 0
    private var stoppedOnPurpose = false

    private var localOnly: Bool {
        get { defaults.bool(forKey: "localOnly") }
        set { defaults.set(newValue, forKey: "localOnly") }
    }

    private var lastServerROI: [Double] {
        get {
            let arr = defaults.array(forKey: "lastServerROI") as? [Double] ?? []
            return arr.count == 4 ? arr : [0, 0, 1, 1]
        }
        set { defaults.set(newValue, forKey: "lastServerROI") }
    }

    private var lastServerSensitivity: Int? {
        get { defaults.object(forKey: "lastServerSensitivity") as? Int }
        set {
            if let v = newValue { defaults.set(v, forKey: "lastServerSensitivity") }
            else { defaults.removeObject(forKey: "lastServerSensitivity") }
        }
    }

    init() {
        let d = UserDefaults.standard
        lens = CameraEngine.Lens(rawValue: d.string(forKey: "lens") ?? "") ?? .ultra
        sensitivity = d.object(forKey: "sensitivity") as? Int ?? 5
        let savedRoi = d.array(forKey: "roi") as? [Double] ?? []
        roi = savedRoi.count == 4 ? savedRoi : [0, 0, 1, 1]
        keepDays = d.object(forKey: "keepDays") as? Int ?? 15
        saveIntrusion = d.bool(forKey: "saveIntrusion")
        serverInput = ServerAPI.configuredServerString
        camName = d.string(forKey: "camName") ?? "iPhone 13"
        isPaired = ServerAPI.isPaired
        pipe.store.cleanup(keepDays: keepDays)
    }

    // MARK: 配对与服务器连接

    func checkPairing() async {
        isPaired = ServerAPI.isPaired
        if !ServerAPI.isPaired {
            phase = localOnly ? .ready : .pair
            return
        }
        do {
            if let name = try await ServerAPI.me() {
                camName = name
                defaults.set(name, forKey: "camName")
                localOnly = false
                isPaired = true
                phase = .ready
            } else {
                ServerAPI.clearPairing()
                isPaired = false
                errorText = "这台手机已在主力手机上被移除，请重新配对（也可先仅本机使用）。"
                phase = .pair
            }
        } catch {
            // 连不上服务器时照样进入准备页，拍照录像先存手机，网通后再补传
            camName = defaults.string(forKey: "camName") ?? "iPhone 13"
            isPaired = ServerAPI.isPaired
            phase = .ready
        }
    }

    func pair(server: String, code: String, name: String) async {
        errorText = ""
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "iPhone 13" : trimmedName
        do {
            let acceptedName = try await ServerAPI.pair(
                server: server,
                code: code.trimmingCharacters(in: .whitespacesAndNewlines),
                name: finalName
            )
            camName = acceptedName
            serverInput = ServerAPI.configuredServerString
            defaults.set(acceptedName, forKey: "camName")
            localOnly = false
            isPaired = true
            canReturnFromPair = false
            phase = .ready
        } catch {
            errorText = error.localizedDescription
        }
    }

    func useLocalOnly() {
        errorText = ""
        localOnly = true
        isPaired = ServerAPI.isPaired
        canReturnFromPair = false
        phase = .ready
    }

    func openPairing() {
        errorText = ""
        serverInput = ServerAPI.configuredServerString
        canReturnFromPair = true
        phase = .pair
    }

    func managePairingWithAuth() async {
        guard await OwnerAuth.check("管理服务器配对") else { return }
        openPairing()
    }

    func unpairWithAuth() async {
        guard await OwnerAuth.check("解除服务器配对") else { return }
        ServerAPI.clearPairing()
        lastServerSensitivity = nil
        defaults.removeObject(forKey: "lastServerROI")
        await Uploader.shared.clearAll()
        isPaired = false
        localOnly = true
        canReturnFromPair = false
        errorText = ""
        phase = .ready
    }

    // MARK: 摄像头准备（监控和框检测区域都用）

    private func openCamera() async -> Bool {
        errorText = ""
        let perms = await CameraEngine.requestPermissions()
        guard perms.camera else {
            errorText = "没有相机权限。到 iPhone「设置」→「门口摄像头」打开相机。"
            return false
        }
        let pipe = self.pipe
        pipe.engine.lens = lens
        pipe.engine.onFrame = { buffer, now in pipe.processFrame(buffer, now) }
        pipe.engine.onVideoSample = { sample in
            pipe.clip.appendVideo(sample)
            if pipe.video.recording { pipe.video.appendVideo(sample) }
        }
        pipe.engine.onAudio = perms.mic ? { sample in
            pipe.clip.appendAudio(sample)
            if pipe.video.recording { pipe.video.appendAudio(sample) }
            if pipe.link.listen { pipe.liveAudio.append(sample) }
        } : nil
        do {
            try await pipe.engine.start(withMic: perms.mic)
        } catch {
            errorText = "打不开相机：\(error.localizedDescription)"
            return false
        }
        if !perms.mic { showFlash("没有麦克风权限，录像没有声音") }
        return true
    }

    func openCameraForSetup() async { _ = await openCamera() }
    func closeCameraAfterSetup() { pipe.engine.stop() }

    // MARK: 开始 / 停止

    func start() async {
        guard await openCamera() else { return }
        await PhotoSaver.requestAccess()   // 现在问（机主在场），别等到被拿走时才弹窗
        let pipe = self.pipe
        let cloud = ServerAPI.isPaired
        isPaired = cloud
        pipe.setDetection(.init(roi: roi, sensitivity: sensitivity))
        pipe.saveIntrusionToPhotos = saveIntrusion
        pipe.onFlash = { [weak self] text in Task { @MainActor in self?.showFlash(text) } }
        pipe.onAlarm = { [weak self] on in Task { @MainActor in self?.setAlarm(on) } }
        pipe.motion.onMoved = { Task { await pipe.handleMoved() } }

        if cloud {
            pipe.link.onSettings = { [weak self] s in
                Task { @MainActor in self?.applyServerSettings(s) }
            }
            pipe.link.onSnapshotRequest = { pipe.sendSnapshot() }
            pipe.link.onChange = { [weak self] in
                Task { @MainActor in self?.syncLinkFlags() }
            }
            pipe.link.onUnauthorized = { [weak self] in
                Task { @MainActor in await self?.handleServerRemoved() }
            }
            pipe.link.start()
            Task.detached { await Uploader.shared.run() }
        }

        stoppedOnPurpose = false
        serverArmed = true
        pipe.begin(cloud: cloud)

        UIApplication.shared.isIdleTimerDisabled = true
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0.05   // 黑屏也调暗，省电、不显眼
        timers = [
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.everySecond() }
            },
            // 被切到后台那一刻来不及现拍，每 2 秒备一张小照片
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tamperShot = self?.pipe.engine.currentJPEG(maxSide: 640, quality: 0.6) }
            },
        ]
        phase = .running
    }

    private func applyServerSettings(_ s: LiveLink.Settings) {
        serverArmed = s.armed
        pipe.setArmed(s.armed)

        var changedDetection = false
        if s.roi != lastServerROI || roi == [0, 0, 1, 1] {
            if roi != s.roi { roi = s.roi }
            lastServerROI = s.roi
            changedDetection = true
        }
        if lastServerSensitivity != s.sensitivity {
            if sensitivity != s.sensitivity { sensitivity = s.sensitivity }
            lastServerSensitivity = s.sensitivity
            changedDetection = true
        }
        if changedDetection {
            pipe.setDetection(.init(roi: roi, sensitivity: sensitivity))
        }
    }

    private func syncLinkFlags() {
        let wasListening = linkListen
        linkConnected = pipe.link.connected
        linkLive = pipe.link.live
        linkListen = pipe.link.listen
        if wasListening && !linkListen {
            pipe.liveAudio.reset()
        }
    }

    private func handleServerRemoved() async {
        ServerAPI.clearPairing()
        isPaired = false
        timers.forEach { $0.invalidate() }
        timers = []
        await pipe.end()
        alarmOn = false
        UIApplication.shared.isIdleTimerDisabled = false
        UIScreen.main.brightness = savedBrightness
        errorText = "这台手机已在主力手机上被移除，请重新配对。"
        phase = .pair
    }

    /// 停止监控：只有机主能停
    func stopWithAuth() async {
        guard await OwnerAuth.check("停止门口监控") else { return }
        stoppedOnPurpose = true
        let cloud = isPaired
        timers.forEach { $0.invalidate() }
        timers = []
        await pipe.end()
        if cloud { Task { await ServerAPI.post("api/camera/stop") } }
        alarmOn = false
        linkConnected = false
        linkLive = false
        linkListen = false
        UIApplication.shared.isIdleTimerDisabled = false
        UIScreen.main.brightness = savedBrightness
        phase = .ready
        refreshRecords()
    }

    /// 停警报：只有机主能停，停了之后继续监控
    func stopAlarmWithAuth() async {
        guard await OwnerAuth.check("停止防偷警报") else { return }
        pipe.stopAlarm()
    }

    private func setAlarm(_ on: Bool) {
        alarmOn = on
        UIScreen.main.brightness = on ? 1.0 : 0.05
    }

    // MARK: 切到后台 / 锁屏：立刻响警报，并通知服务器

    func sceneChanged(_ scene: ScenePhase) {
        guard phase == .running else { return }
        if scene == .background, !stoppedOnPurpose {
            pipe.tamperAlarm(shot: tamperShot)
            if isPaired {
                let shot = tamperShot ?? Data()
                var bg = UIBackgroundTaskIdentifier.invalid
                bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
                Task {
                    await ServerAPI.post("api/camera/leaving", body: shot, contentType: "image/jpeg")
                    UIApplication.shared.endBackgroundTask(bg)
                }
            }
        }
        if scene == .active {
            UIApplication.shared.isIdleTimerDisabled = true
            UIScreen.main.brightness = alarmOn ? 1.0 : 0.05
        }
    }

    // MARK: 记录

    func openRecords() async {
        guard await OwnerAuth.check("查看监控记录") else { return }
        Siren.configureSession()   // 静音开关打开时也能听到录像的声音
        refreshRecords()
        showRecords = true
    }

    func refreshRecords() {
        records = pipe.store.all()
        usedBytes = pipe.store.usedBytes()
    }

    func delete(_ record: Record) {
        pipe.store.delete(id: record.id)
        refreshRecords()
    }

    // MARK: 状态字

    private func everySecond() async {
        let fps = pipe.takeFrameCount()
        let cameraOK = pipe.cameraOK
        if isPaired {
            pipe.link.sendStatus(camera: cameraOK, fps: fps)
            pendingUploads = await Uploader.shared.pending
            syncLinkFlags()
        }
        ticks += 1
        if ticks % 600 == 0 { pipe.store.cleanup(keepDays: keepDays, keeping: pipe.currentRecordID) }
        let wait = pipe.secondsUntilArmed
        var t: String
        if Date().timeIntervalSince1970 < flashUntil {
            t = flash
        } else if wait > 0 {
            t = "\(wait) 秒后开始监控，放好手机离开"
        } else if !cameraOK {
            t = "相机没有画面"
        } else {
            t = "监控中 · \(pipe.engine.lensLabel)"
            if isPaired {
                if !linkConnected {
                    t += " · 服务器离线，先存手机"
                } else {
                    if !serverArmed { t += " · 已撤防" }
                    if linkLive { t += " · 有人在看实时" }
                    if linkListen { t += " · 有人在听声音" }
                }
                if pendingUploads > 0 { t += " · \(pendingUploads) 项待传" }
            }
            if pipe.clip.recording { t += " · 正在录像" }
        }
        if !UIAccessibility.isGuidedAccessEnabled { t += " · 还没开引导式访问" }
        statusText = t
    }

    private func showFlash(_ text: String) {
        flash = text
        flashUntil = Date().timeIntervalSince1970 + 10
        statusText = text
    }
}
