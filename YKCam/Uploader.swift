import Foundation

/// 照片和录像分段先写进手机里的「待上传」文件夹，再按顺序传到服务器，成功才删。
/// 断网、服务器坏了、App 被关掉重开，都不丢。
///
/// 文件名：
///   p_<报警编号>_<序号>_<时间毫秒>_<种类>.jpg     照片（种类 motion 门口有动静 / moved 手机被动了）
///   v_<报警编号>_<段号四位>.mp4                    录像分段（前置防偷或闯入录像，服务器按段号接成一个文件）
///   c_<报警编号>_<段号四位>_<秒数>.txt             闯入录像结束标记（给服务器标上 clipSeconds）
actor Uploader {
    static let shared = Uploader()

    let folder: URL
    private var running = false
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private(set) var pending = 0

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    nonisolated func savePhoto(id: String, seq: Int, time: TimeInterval, kind: String, jpeg: Data) {
        let name = "p_\(id)_\(seq)_\(Int64(time * 1000))_\(kind).jpg"
        try? jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)
        Task { await wake() }
    }

    nonisolated func saveVideo(id: String, part: Int, data: Data) {
        let name = String(format: "v_%@_%04d.mp4", id, part)
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
        Task { await wake() }
    }

    nonisolated func saveClipEnd(id: String, part: Int, seconds: Int) {
        let sec = max(1, min(600, seconds))
        let name = String(format: "c_%@_%04d_%d.txt", id, part, sec)
        try? Data().write(to: folder.appendingPathComponent(name), options: .atomic)
        Task { await wake() }
    }

    func clearAll() {
        for file in files() {
            try? FileManager.default.removeItem(at: file)
        }
        pending = 0
    }

    func wake() {
        if let c = wakeContinuation { wakeContinuation = nil; c.resume() }
    }

    private func sleep(seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wakeContinuation = c
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                await self.wake()
            }
        }
    }

    private func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        // 照片最先（服务器收到第一张照片才建报警记录、才推送），其次录像分段，最后录像结束标记；各自按名字排序
        func rank(_ u: URL) -> Int {
            switch u.lastPathComponent.prefix(2) {
            case "p_": return 0
            case "v_": return 1
            case "c_": return 2
            default: return 3
            }
        }
        return all.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.lastPathComponent < b.lastPathComponent
        }
    }

    /// 一直跑：有东西就传，失败就等一会儿（2 秒起，每次翻倍，最多 60 秒）
    func run() async {
        guard !running else { return }
        running = true
        var delay = 2.0
        while true {
            var failed = false
            if ServerAPI.isPaired {
                for file in files() {
                    let ok = await send(file)
                    if ok == nil || ok == false { failed = true; break }
                    try? FileManager.default.removeItem(at: file)
                }
            }
            pending = files().count
            delay = failed ? min(delay * 2, 60) : 2
            await sleep(seconds: failed ? delay : (pending > 0 ? 1 : 300))
        }
    }

    private func send(_ file: URL) async -> Bool? {
        let name = file.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_").map(String.init)
        guard let data = try? Data(contentsOf: file) else { return true }
        if parts.first == "p", parts.count == 5 {
            return await ServerAPI.upload("api/agent/event",
                                          query: ["id": parts[1], "seq": parts[2], "t": parts[3], "kind": parts[4]],
                                          body: data, contentType: "image/jpeg")
        }
        if parts.first == "v", parts.count == 3, let part = Int(parts[2]) {
            return await ServerAPI.upload("api/agent/audio",
                                          query: ["id": parts[1], "part": String(part), "mime": "video/mp4"],
                                          body: data, contentType: "application/octet-stream")
        }
        if parts.first == "c", parts.count == 4, let part = Int(parts[2]), let sec = Int(parts[3]) {
            return await ServerAPI.upload("api/agent/audio",
                                          query: ["id": parts[1], "part": String(part), "mime": "video/mp4", "clip": String(sec)],
                                          body: Data(), contentType: "application/octet-stream")
        }
        return true   // 认不出的文件直接丢掉
    }
}
