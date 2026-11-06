import Foundation

/// 判断手机是不是被拿着走了。纯计算，方便单元测试。
/// 只用动作传感器：被拿起后一直在晃（像被拿着走），而且朝向没放回原来的样子。
struct CarryJudge {
    static let shakeG = 0.08        // 手拿着走路时的晃动（单位 g）
    static let busyShare = 0.3      // 最近 3 秒里至少 30% 的时候在晃
    static let tiltDegrees = 25.0   // 朝向和放着时差这么多算没放回
    static let minWatch: TimeInterval = 4

    private var samples: [(t: TimeInterval, shaking: Bool)] = []
    private var started: TimeInterval?
    private(set) var lastTilt = 0.0

    /// shake：去掉重力后的加速度（g）；tilt：和原来放着时的朝向差（度）
    mutating func feed(now: TimeInterval, shake: Double, tilt: Double) -> Bool {
        if started == nil { started = now }
        lastTilt = tilt
        samples.append((now, shake > CarryJudge.shakeG))
        samples.removeAll { now - $0.t > 3 }
        guard now - started! >= CarryJudge.minWatch, !samples.isEmpty else { return false }
        let share = Double(samples.filter(\.shaking).count) / Double(samples.count)
        return share >= CarryJudge.busyShare && tilt > CarryJudge.tiltDegrees
    }
}
