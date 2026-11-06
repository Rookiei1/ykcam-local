import Foundation

/// 检测门的位置有没有变化。和电脑端 agent.py、网页 camera.js 用同一套方法：
/// 和慢慢更新的背景比，检测区域里变化的像素超过门槛并持续 3 帧就报警。
final class Detector {
    enum Result: Equatable {
        case quiet
        case firstHit          // 刚开始变化：先留一张照片，真报警时用它当第一张
        case motion            // 在动，但还没到报警（还没满 3 帧，或在冷却中）
        case alarm(ratio: Double)
    }

    static let pixelDiff = 25
    static let holdFrames = 3
    static let warmup: TimeInterval = 10      // 刚启动 10 秒不报警，等曝光和背景稳定
    static let lightShift = 25                // 整体亮度（中位数）一下变这么多，当作开关灯
    static let cooldown: TimeInterval = 20

    private var bg: [Float]?
    private var hits = 0
    private(set) var started = Date().timeIntervalSince1970
    private var lastEvent: TimeInterval = 0
    private(set) var lastMotion: TimeInterval = 0

    static func threshold(sensitivity: Int) -> Double {
        0.12 * pow(0.7, Double(sensitivity - 1))   // 1 → 12%，5 → 2.9%，10 → 0.5%
    }

    /// 换了摄像头或刚开始：背景重学，10 秒内不报警
    func reset(now: TimeInterval) {
        bg = nil
        hits = 0
        started = now
    }

    static func median(_ values: [UInt8]) -> Int {
        var hist = [Int](repeating: 0, count: 256)
        for v in values { hist[Int(v)] += 1 }
        var acc = 0
        let half = Double(values.count) / 2
        for v in 0..<256 {
            acc += hist[v]
            if Double(acc) >= half { return v }
        }
        return 255
    }

    /// 3x3 均值模糊，去掉噪点
    static func blur(_ g: [UInt8], w: Int, h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: g.count)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0, n = 0
                for dy in -1...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx < 0 || xx >= w { continue }
                        sum += Int(g[yy * w + xx]); n += 1
                    }
                }
                out[y * w + x] = UInt8(sum / n)
            }
        }
        return out
    }

    /// gray：已缩小的灰度图（宽 w、高 h）。roi：[x, y, 宽, 高]，都是 0~1。
    func feed(gray raw: [UInt8], w: Int, h: Int, now: TimeInterval, roi: [Double], sensitivity: Int) -> Result {
        let g = Detector.blur(raw, w: w, h: h)
        guard let background = bg, background.count == g.count else {
            bg = g.map { Float($0) }
            return .quiet
        }
        let bg8 = background.map { UInt8(max(0, min(255, $0.rounded()))) }
        let shift = Detector.median(g) - Detector.median(bg8)
        if abs(shift) > Detector.lightShift {
            bg = g.map { Float($0) }
            hits = 0
            return .quiet
        }
        var changed = [Bool](repeating: false, count: g.count)
        var all = 0
        for i in 0..<g.count {
            let a = max(0, min(255, Int(g[i]) - shift))
            if abs(a - Int(bg8[i])) > Detector.pixelDiff { changed[i] = true; all += 1 }
        }
        if Double(all) / Double(g.count) > 0.85 {   // 自动曝光一下全变，不算
            hits = 0
            bg = zip(background, g).map { $0 * 0.7 + Float($1) * 0.3 }
            return .quiet
        }
        let r = roi.count == 4 ? roi : [0, 0, 1, 1]
        let x0 = max(0, min(w - 1, Int(r[0] * Double(w))))
        let y0 = max(0, min(h - 1, Int(r[1] * Double(h))))
        let x1 = max(x0 + 1, min(w, Int((r[0] + r[2]) * Double(w))))
        let y1 = max(y0 + 1, min(h, Int((r[1] + r[3]) * Double(h))))
        var inRoi = 0
        for y in y0..<y1 { for x in x0..<x1 where changed[y * w + x] { inRoi += 1 } }
        let ratio = Double(inRoi) / Double((x1 - x0) * (y1 - y0))
        bg = zip(background, g).map { $0 * 0.97 + Float($1) * 0.03 }

        guard ratio > Detector.threshold(sensitivity: sensitivity) else {
            hits = 0
            return .quiet
        }
        hits += 1
        if hits == 1 { return .firstHit }
        if hits < Detector.holdFrames || now - started < Detector.warmup { return .motion }
        lastMotion = now
        if now - lastEvent < Detector.cooldown { return .motion }
        lastEvent = now
        return .alarm(ratio: ratio)
    }
}

/// 报警编号：本机时间 + 4 位随机，和网页、电脑端格式一样（20261103-210000-ab12）
enum EventID {
    static func make(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let rand = String((0..<4).map { _ in chars.randomElement()! })
        return "\(f.string(from: date))-\(rand)"
    }

    static func isValid(_ id: String) -> Bool {
        id.range(of: #"^\d{8}-\d{6}-[a-z0-9]{4}$"#, options: .regularExpression) != nil
    }
}
