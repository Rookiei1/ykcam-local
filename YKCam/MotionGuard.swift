import CoreMotion
import Foundation

/// 手机被拿起、碰歪、转向就报警。放稳 10 秒后记下重力方向，之后朝向变超过 20°
/// 或突然加速度超过 3 m/s² 就触发；60 秒内只报一次，触发后重新放稳 10 秒再以新朝向为准。
final class MotionGuard {
    static let moveAngle = 20.0
    static let moveShake = 3.0 / 9.81    // CoreMotion 的单位是 g
    static let settle: TimeInterval = 10
    static let cooldown: TimeInterval = 60

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private var base: (Double, Double, Double)?
    private var baseAt: TimeInterval = 0
    private var lastAlarm: TimeInterval = 0
    /// 被动之前手机放着时的朝向，判断「有没有放回去」用
    private(set) var restBase: (Double, Double, Double)?
    var paused = false

    /// 每次传感器更新都报一次：去掉重力的晃动（g）、和放着时的朝向差（度）。防偷判断时用。
    var onSample: ((Double, Double) -> Void)?

    /// 被动了，在后台线程调用
    var onMoved: (() -> Void)?

    var available: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 30
        baseAt = Date().timeIntervalSince1970 + MotionGuard.settle
        base = nil
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            self.handle(gravity: (m.gravity.x, m.gravity.y, m.gravity.z),
                        user: (m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z))
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    static func angle(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let dot = a.0 * b.0 + a.1 * b.1 + a.2 * b.2
        let la = (a.0 * a.0 + a.1 * a.1 + a.2 * a.2).squareRoot()
        let lb = (b.0 * b.0 + b.1 * b.1 + b.2 * b.2).squareRoot()
        guard la > 0, lb > 0 else { return 0 }
        return acos(max(-1, min(1, dot / (la * lb)))) * 180 / .pi
    }

    private func handle(gravity g: (Double, Double, Double), user u: (Double, Double, Double)) {
        let now = Date().timeIntervalSince1970
        if let sample = onSample {
            let rest = restBase ?? base ?? g
            sample((u.0 * u.0 + u.1 * u.1 + u.2 * u.2).squareRoot(), MotionGuard.angle(g, rest))
        }
        guard let b = base else {
            if now >= baseAt { base = g }
            return
        }
        let shake = (u.0 * u.0 + u.1 * u.1 + u.2 * u.2).squareRoot()
        let tilt = MotionGuard.angle(g, b)
        guard !paused, tilt > MotionGuard.moveAngle || shake > MotionGuard.moveShake,
              now - lastAlarm > MotionGuard.cooldown else { return }
        lastAlarm = now
        restBase = b
        base = nil
        baseAt = now + MotionGuard.settle
        onMoved?()
    }
}
