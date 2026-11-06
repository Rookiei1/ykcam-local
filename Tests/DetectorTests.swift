import XCTest
@testable import YKCam

/// 和网页、电脑端的检测测试用同样的场景：静止不报、有人站门前报、门开报、区域外不报、开灯不报、小东西不报
final class DetectorTests: XCTestCase {
    let w = 160, h = 90

    func scene(person: Bool = false, door: Bool = false, shift: Int = 0, dot: Bool = false, seed: UInt64) -> [UInt8] {
        var rng = SplitMix(seed: seed)
        var g = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var v = 200                                           // 墙
                if x >= 50 && x < 102 && y >= 18 { v = 120 }           // 门
                if door && x >= 38 && x < 110 && y >= 28 { v = 35 }     // 门开了，门洞变暗
                if person && x >= 68 && x < 92 && y >= 22 { v = 50 }   // 人
                if dot && abs(x - 80) < 2 && abs(y - 50) < 2 { v = 0 }  // 小东西
                v += Int(rng.next() % 13) - 6 + shift                   // 噪点
                g[y * w + x] = UInt8(max(0, min(255, v)))
            }
        }
        return g
    }

    /// 先喂 40 帧静止画面，再喂 frames；返回报警次数
    func alarms(_ frames: [[UInt8]], roi: [Double] = [0, 0, 1, 1]) -> Int {
        let d = Detector()
        var t = 1000.0
        d.reset(now: t - 100)   // 跳过启动预热
        var count = 0
        for i in 0..<40 { _ = d.feed(gray: scene(seed: UInt64(i)), w: w, h: h, now: t, roi: roi, sensitivity: 5); t += 0.1 }
        for f in frames {
            if case .alarm = d.feed(gray: f, w: w, h: h, now: t, roi: roi, sensitivity: 5) { count += 1 }
            t += 0.1
        }
        return count
    }

    func testStaticSceneNoAlarm() {
        XCTAssertEqual(alarms((0..<40).map { scene(seed: 100 + UInt64($0)) }), 0)
    }

    func testPersonInFrontOfDoorAlarms() {
        XCTAssertEqual(alarms((0..<40).map { scene(person: true, seed: 200 + UInt64($0)) }), 1)
    }

    func testDoorOpeningAlarms() {
        XCTAssertEqual(alarms((0..<40).map { scene(door: true, seed: 300 + UInt64($0)) }), 1)
    }

    func testPersonOutsideRegionNoAlarm() {
        XCTAssertEqual(alarms((0..<40).map { scene(person: true, seed: 400 + UInt64($0)) }, roi: [0, 0, 0.3, 1]), 0)
    }

    func testLightsOnNoAlarm() {
        XCTAssertEqual(alarms((0..<40).map { scene(shift: 45, seed: 500 + UInt64($0)) }), 0)
    }

    func testSmallObjectNoAlarm() {
        XCTAssertEqual(alarms((0..<40).map { scene(dot: true, seed: 600 + UInt64($0)) }), 0)
    }

    func testCooldownThenSecondAlarm() {
        var frames: [[UInt8]] = []
        frames += (0..<10).map { scene(person: true, seed: 700 + UInt64($0)) }
        frames += (0..<250).map { scene(seed: 800 + UInt64($0)) }
        frames += (0..<40).map { scene(person: true, seed: 1100 + UInt64($0)) }
        XCTAssertEqual(alarms(frames), 2)
    }

    func testWarmupBlocksEarlyAlarm() {
        let d = Detector()
        d.reset(now: 1000)
        var got = false
        var t = 1000.0
        for i in 0..<20 { _ = d.feed(gray: scene(seed: UInt64(i)), w: w, h: h, now: t, roi: [0, 0, 1, 1], sensitivity: 5); t += 0.1 }
        for i in 0..<30 {
            if case .alarm = d.feed(gray: scene(person: true, seed: 50 + UInt64(i)), w: w, h: h, now: t, roi: [0, 0, 1, 1], sensitivity: 5) { got = true }
            t += 0.1
        }
        XCTAssertFalse(got, "启动 10 秒内不该报警")
    }

    func testMedianAndThreshold() {
        XCTAssertEqual(Detector.median([1, 2, 3, 4, 5]), 3)
        XCTAssertEqual(Detector.threshold(sensitivity: 1), 0.12, accuracy: 1e-9)
        XCTAssertEqual(Detector.threshold(sensitivity: 5), 0.12 * pow(0.7, 4), accuracy: 1e-9)
    }

    func testEventIDFormat() {
        let id = EventID.make(Date(timeIntervalSince1970: 1_793_707_500))
        XCTAssertTrue(EventID.isValid(id), id)
        XCTAssertFalse(EventID.isValid("2026-11-03"))
    }

    func testMotionAngle() {
        XCTAssertEqual(MotionGuard.angle((0, -1, 0), (0, -1, 0)), 0, accuracy: 1e-6)
        XCTAssertEqual(MotionGuard.angle((0, -1, 0), (0, 0, -1)), 90, accuracy: 1e-6)
    }
}

/// 固定种子的随机数，测试结果每次一样
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
