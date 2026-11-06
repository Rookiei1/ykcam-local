import Security
import SwiftUI
import UIKit

/// 界面状态和设置。具体干活的是 Pipeline。所有数据都只在这台手机上。
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case ready, running }

    @Published var phase: Phase = .ready
    @Published var statusText = ""
    @Published var errorText = ""
    @Published var alarmOn = false
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

    init() {
        let d = UserDefaults.standard
        lens = CameraEngine.Lens(rawValue: d.string(forKey: "lens") ?? "") ?? .ultra
        sensitivity = d.object(forKey: "sensitivity") as? Int ?? 5
        let savedRoi = d.array(forKey: "roi") as? [Double] ?? []
        roi = savedRoi.count == 4 ? savedRoi : [0, 0, 1, 1]
        keepDays = d.object(forKey: "keepDays") as? Int ?? 15
        saveIntrusion = d.bool(forKey: "saveIntrusion")
        AppModel.removeCloudLeftovers()
        pipe.store.cleanup(keepDays: keepDays)
    }

    /// 0.2 以前连服务器时留下的登录凭证和待上传文件，本地版用不上，清掉
    private static func removeCloudLeftovers() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.rookiei1.ykcam"]
        SecItemDelete(q as CFDictionary)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in ["pending", "theft"] {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
        }
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
        pipe.engine.onVideoSample = { sample in pipe.clip.appendVideo(sample) }
        pipe.engine.onAudio = perms.mic ? { sample in pipe.clip.appendAudio(sample) } : nil
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
        pipe.setDetection(.init(roi: roi, sensitivity: sensitivity))
        pipe.saveIntrusionToPhotos = saveIntrusion
        pipe.onFlash = { [weak self] text in Task { @MainActor in self?.showFlash(text) } }
        pipe.onAlarm = { [weak self] on in Task { @MainActor in self?.setAlarm(on) } }
        pipe.motion.onMoved = { Task { await pipe.handleMoved() } }
        pipe.begin()

        UIApplication.shared.isIdleTimerDisabled = true
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0.05   // 黑屏也调暗，省电、不显眼
        timers = [
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.everySecond() }
            },
            // 被切到后台那一刻来不及现拍，每 2 秒备一张小照片
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tamperShot = self?.pipe.engine.currentJPEG(maxSide: 640, quality: 0.6) }
            },
        ]
        phase = .running
    }

    /// 停止监控：只有机主能停
    func stopWithAuth() async {
        guard await OwnerAuth.check("停止门口监控") else { return }
        timers.forEach { $0.invalidate() }
        timers = []
        await pipe.end()
        alarmOn = false
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

    // MARK: 切到后台 / 锁屏：立刻响警报（引擎一直在静音运行，App 还活着）

    func sceneChanged(_ scene: ScenePhase) {
        guard phase == .running else { return }
        if scene == .background { pipe.tamperAlarm(shot: tamperShot) }
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

    private func everySecond() {
        _ = pipe.takeFrameCount()
        ticks += 1
        if ticks % 600 == 0 { pipe.store.cleanup(keepDays: keepDays, keeping: pipe.currentRecordID) }
        let wait = pipe.secondsUntilArmed
        var t: String
        if Date().timeIntervalSince1970 < flashUntil {
            t = flash
        } else if wait > 0 {
            t = "\(wait) 秒后开始监控，放好手机离开"
        } else if !pipe.cameraOK {
            t = "相机没有画面"
        } else {
            t = "监控中 · \(pipe.engine.lensLabel)"
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
