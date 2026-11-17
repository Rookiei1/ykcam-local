import Foundation

/// 和服务器保持一条 WebSocket：收设置（布防、检测区域、灵敏度）、收「有人在看实时」「有人在听声音」和「要一张快照」，
/// 发状态、画面和声音。二进制消息前缀：1 实时画面，2 快照，3 实时声音（16 kHz 单声道 μ-law）。
final class LiveLink {
    struct Settings: Equatable {
        var armed = true
        var roi: [Double] = [0, 0, 1, 1]
        var sensitivity = 5
    }

    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "ykcam.link")
    private var sendingFrame = false
    private var sendingAudio = false
    private var stopped = false

    private(set) var connected = false
    private(set) var live = false
    private(set) var listen = false
    private(set) var settings = Settings()

    var onSettings: ((Settings) -> Void)?
    var onSnapshotRequest: (() -> Void)?
    var onChange: (() -> Void)?
    /// 服务器认不出这台手机（被主力手机移除了）
    var onUnauthorized: (() -> Void)?

    func start() {
        queue.async {
            self.stopped = false
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.connected = false
            self.live = false
            self.listen = false
            self.sendingFrame = false
            self.sendingAudio = false
        }
    }

    private func connect() {
        guard !stopped, let url = ServerAPI.socketURL, let cookie = ServerAPI.cookie else { return }
        var req = URLRequest(url: url)
        req.setValue("ykcam=\(cookie)", forHTTPHeaderField: "Cookie")
        let t = ServerAPI.session.webSocketTask(with: req)
        task = t
        t.resume()
        receive(t)
        schedulePing(t)
    }

    private func schedulePing(_ t: URLSessionWebSocketTask) {
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.task === t else { return }
            t.sendPing { _ in }
            self.schedulePing(t)
        }
    }

    private func reconnectLater(_ t: URLSessionWebSocketTask) {
        guard task === t else { return }
        task = nil
        connected = false
        live = false
        listen = false
        sendingFrame = false
        sendingAudio = false
        onChange?()
        // 401：这台手机已被移除
        if let http = t.response as? HTTPURLResponse, http.statusCode == 401 {
            onUnauthorized?()
            return
        }
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connect() }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.queue.async { self.reconnectLater(t) }
            case .success(let message):
                self.queue.async {
                    if !self.connected {
                        self.connected = true
                        self.onChange?()
                    }
                    if case .string(let text) = message { self.handle(text) }
                    if case .data(let d) = message, let text = String(data: d, encoding: .utf8) { self.handle(text) }
                }
                self.receive(t)
            }
        }
    }

    private func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "config":
            var s = settings
            if let a = obj["armed"] as? Bool { s.armed = a }
            if let r = obj["roi"] as? [Double], r.count == 4 { s.roi = r }
            if let n = obj["sensitivity"] as? Int { s.sensitivity = n }
            settings = s
            onSettings?(s)
        case "live":
            live = obj["on"] as? Bool ?? false
            onChange?()
        case "listen":
            listen = obj["on"] as? Bool ?? false
            onChange?()
        case "snapshot":
            // 发快照要回到 sendFrame，它会 queue.sync 这条队列；在队列里直接调会自己等自己而崩溃。换到别的线程再发。
            let request = onSnapshotRequest
            DispatchQueue.global(qos: .userInitiated).async { request?() }
        default:
            break
        }
    }

    func sendStatus(camera: Bool, fps: Int) {
        let target: URLSessionWebSocketTask? = queue.sync { task }
        guard let target else { return }
        let json: [String: Any] = ["type": "status", "camera": camera, "fps": fps, "version": "ios-0.4.0"]
        guard let d = try? JSONSerialization.data(withJSONObject: json), let s = String(data: d, encoding: .utf8) else { return }
        target.send(.string(s)) { _ in }
    }

    /// 发一张画面。上一张还没发完就丢掉这张（网络慢时不越积越卡）。返回是否真的发了。
    @discardableResult
    func sendFrame(kind: UInt8, jpeg: Data, force: Bool = false) -> Bool {
        var target: URLSessionWebSocketTask?
        queue.sync {
            if let t = task, force || !sendingFrame {
                if !force { sendingFrame = true }
                target = t
            }
        }
        guard let t = target else { return false }
        var d = Data([kind])
        d.append(jpeg)
        t.send(.data(d)) { [weak self] _ in
            guard let self, !force else { return }
            self.queue.async { self.sendingFrame = false }
        }
        return true
    }

    /// 发一段实时声音（16 kHz 单声道 μ-law）。上一块还在发就丢掉，不让声音越拖越晚。
    func sendAudio(_ ulaw: Data) {
        var target: URLSessionWebSocketTask?
        queue.sync {
            if let t = task, !sendingAudio {
                sendingAudio = true
                target = t
            }
        }
        guard let t = target else { return }
        var d = Data([3])
        d.append(ulaw)
        t.send(.data(d)) { [weak self] _ in
            self?.queue.async { self?.sendingAudio = false }
        }
    }
}
