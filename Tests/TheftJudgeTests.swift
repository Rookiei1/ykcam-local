import XCTest
@testable import YKCam

/// 防偷判断：放回去不算，一直拿着走算
final class TheftJudgeTests: XCTestCase {
    func testCarryNeedsShakingAndTilt() {
        var c = CarryJudge()
        var hit = false
        var t = 0.0
        // 拿起来晃了几秒但放回原来的朝向：不算
        for i in 0..<180 { hit = c.feed(now: t, shake: i % 2 == 0 ? 0.2 : 0.01, tilt: 5) || hit; t += 1.0 / 30 }
        XCTAssertFalse(hit)
        // 朝向变了，但完全不晃（放到别处静止）：不算
        var still = CarryJudge()
        hit = false
        t = 0
        for _ in 0..<180 { hit = still.feed(now: t, shake: 0.01, tilt: 60) || hit; t += 1.0 / 30 }
        XCTAssertFalse(hit)
    }

    func testCarriedAwayByMotion() {
        var c = CarryJudge()
        var hitAt: Double?
        var t = 0.0
        // 拿着走：一直在晃、朝向和放着时差很多
        for i in 0..<300 {
            if c.feed(now: t, shake: i % 3 == 0 ? 0.01 : 0.15, tilt: 50), hitAt == nil { hitAt = t }
            t += 1.0 / 30
        }
        XCTAssertNotNil(hitAt)
        XCTAssertGreaterThanOrEqual(hitAt ?? 0, CarryJudge.minWatch - 0.05, "前 4 秒不下结论")
    }
}
