import XCTest
@testable import YKCam

final class RecordStoreTests: XCTestCase {
    private var folder: URL!
    private var store: RecordStore!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = RecordStore(root: folder)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testPhotosFrontFirstAndVideoNames() {
        store.create(id: "a", time: 100, kind: .moved)
        for seq in [0, 5, 6, 1] { store.addPhoto(id: "a", seq: seq, jpeg: Data([1])) }
        let first = store.newVideoURL(id: "a")
        let second = store.newVideoURL(id: "a")
        let r = store.all()[0]
        XCTAssertEqual(r.photos, ["photo-5.jpg", "photo-6.jpg", "photo-0.jpg", "photo-1.jpg"])
        XCTAssertEqual(r.videos, ["video-0.mov", "video-1.mov"])
        XCTAssertEqual(first.lastPathComponent, "video-0.mov")
        XCTAssertEqual(second.lastPathComponent, "video-1.mov")
    }

    func testNewestFirstAndKindChange() {
        store.create(id: "old", time: 100, kind: .intrusion)
        store.create(id: "new", time: 200, kind: .moved)
        store.setKind(id: "new", kind: .theft)
        let all = store.all()
        XCTAssertEqual(all.map(\.id), ["new", "old"])
        XCTAssertEqual(all[0].kind, .theft)
    }

    func testRetentionDeletesOldButKeepsRecording() {
        let now = 100.0 * 86400
        store.create(id: "expired", time: now - 16 * 86400, kind: .intrusion)
        store.create(id: "recording", time: now - 16 * 86400, kind: .intrusion)
        store.create(id: "fresh", time: now - 86400, kind: .intrusion)
        store.cleanup(keepDays: 15, keeping: "recording", now: now, freeSpace: { Int64.max })
        XCTAssertEqual(Set(store.all().map(\.id)), ["recording", "fresh"])
    }

    func testLowSpaceDeletesOldestAndTheftLast() {
        let now = 1000.0
        store.create(id: "theft", time: 100, kind: .theft)
        store.create(id: "older", time: 200, kind: .intrusion)
        store.create(id: "newer", time: 300, kind: .intrusion)
        // 每删一条多出 1 GB，从 1.5 GB 起，要到 3 GB 才停：删两条
        var free: Int64 = 1_610_612_736
        var calls = 0
        let removed = store.cleanup(keepDays: 15, now: now, freeSpace: {
            defer { calls += 1 }
            if calls >= 2 { free += 1_073_741_824 }
            return free
        })
        XCTAssertGreaterThan(removed, 0)
        XCTAssertTrue(store.all().map(\.id).contains("theft"), "被拿走的记录最后才删")
        XCTAssertFalse(store.all().map(\.id).contains("older"))
    }

    func testPlentyOfSpaceDeletesNothing() {
        store.create(id: "x", time: 1000, kind: .intrusion)
        XCTAssertEqual(store.cleanup(keepDays: 15, now: 1000, freeSpace: { Int64.max }), 0)
    }
}
