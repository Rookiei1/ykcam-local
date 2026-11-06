import Foundation
import Photos

/// 一条记录：一次闯入、手机被动、被拿走，或监控被切走。
struct Record: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case intrusion, moved, theft, left

        var title: String {
            switch self {
            case .intrusion: return "有人闯入"
            case .moved: return "手机被动了"
            case .theft: return "手机被拿走"
            case .left: return "监控被切走"
            }
        }
    }

    let id: String
    let time: TimeInterval
    var kind: Kind
    var photos: [String] = []
    var videos: [String] = []
}

/// 所有照片和录像只存在这台手机里：Documents/records/<报警编号>/。
/// 每条记录一个文件夹，配一个 record.json；不进 iCloud 备份。
final class RecordStore {
    static let shared = RecordStore()

    /// 剩余空间低于 minFree 就从最早的记录删起，删到 goalFree
    static let minFree: Int64 = 2 * 1024 * 1024 * 1024
    static let goalFree: Int64 = 3 * 1024 * 1024 * 1024

    let root: URL
    private let lock = NSLock()

    init(root: URL? = nil) {
        var folder = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("records", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        self.root = folder
    }

    private func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private func index(_ id: String) -> URL { folder(id).appendingPathComponent("record.json") }

    func url(id: String, name: String) -> URL { folder(id).appendingPathComponent(name) }

    private func read(_ id: String) -> Record? {
        guard let data = try? Data(contentsOf: index(id)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func write(_ record: Record) {
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: index(record.id), options: .atomic)
        }
    }

    private func update(_ id: String, _ change: (inout Record) -> Void) {
        lock.withLock {
            guard var r = read(id) else { return }
            change(&r)
            write(r)
        }
    }

    func create(id: String, time: TimeInterval, kind: Record.Kind) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
            write(Record(id: id, time: time, kind: kind))
        }
    }

    func setKind(id: String, kind: Record.Kind) {
        update(id) { $0.kind = kind }
    }

    func addPhoto(id: String, seq: Int, jpeg: Data) {
        let name = "photo-\(seq).jpg"
        try? jpeg.write(to: url(id: id, name: name), options: .atomic)
        update(id) { r in
            if !r.photos.contains(name) { r.photos.append(name) }
            // 序号 5、6 是前置（拍拿手机的人），排在最前面
            r.photos.sort { a, b in
                let fa = RecordStore.isFront(a), fb = RecordStore.isFront(b)
                return fa != fb ? fa : a < b
            }
        }
    }

    static func isFront(_ photo: String) -> Bool { photo == "photo-5.jpg" || photo == "photo-6.jpg" }

    /// 开始录之前就登记：即使 App 中途被杀，这段录像也找得到
    func newVideoURL(id: String) -> URL {
        var name = ""
        update(id) { r in
            name = "video-\(r.videos.count).mov"
            r.videos.append(name)
        }
        return url(id: id, name: name.isEmpty ? "video-0.mov" : name)
    }

    func all() -> [Record] {
        lock.withLock {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return names.compactMap { read($0) }.sorted { $0.time > $1.time }
        }
    }

    func delete(id: String) {
        lock.withLock { try? FileManager.default.removeItem(at: folder(id)) }
    }

    func usedBytes() -> Int64 { Self.size(of: root) }

    static func size(of folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func freeBytes() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
    }

    /// 删掉超过保留天数的记录；空间不够时再从最早的删起（被拿走的记录留到最后）。keeping：正在录的不删。
    @discardableResult
    func cleanup(keepDays: Int, keeping: String? = nil, now: TimeInterval = Date().timeIntervalSince1970,
                 freeSpace: () -> Int64 = RecordStore.freeBytes) -> Int {
        var removed = 0
        let cutoff = now - Double(keepDays) * 86400
        for r in all() where r.time < cutoff && r.id != keeping {
            delete(id: r.id)
            removed += 1
        }
        guard freeSpace() < RecordStore.minFree else { return removed }
        let oldestFirst = all().sorted { a, b in
            let ta = a.kind == .theft, tb = b.kind == .theft
            return ta != tb ? tb : a.time < b.time
        }
        for r in oldestFirst where r.id != keeping {
            if freeSpace() >= RecordStore.goalFree { break }
            delete(id: r.id)
            removed += 1
        }
        return removed
    }
}

/// 存进系统相册。如果这台手机开了 iCloud 照片，存进去的录像会自动同步走，手机被拿走也还在。
enum PhotoSaver {
    static func requestAccess() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    static func save(video: URL) { save { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: video) } }
    static func save(image: URL) { save { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: image) } }

    private static func save(_ change: @escaping () -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        PHPhotoLibrary.shared().performChanges(change, completionHandler: nil)
    }
}
