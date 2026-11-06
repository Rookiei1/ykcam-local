import LocalAuthentication

/// 只有机主能停警报、停监控、看记录：面容 ID，不行就输手机锁屏密码。
enum OwnerAuth {
    /// 这台手机设了锁屏密码吗？没设的话谁都能停，界面上要提醒
    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static func check(_ reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
