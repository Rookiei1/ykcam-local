import AVFoundation
import MediaPlayer
import UIKit

/// 防偷警报：尖锐的升降调警笛 + 每 4 秒用中文喊一遍「有人偷手机」。
/// 音频会话是 playAndRecord + 外放：静音开关拨到静音也照样响；一边响一边还能录像。
/// 监控期间引擎一直在静音运行，App 被切到后台 / 锁屏时才能继续活着、马上响。
/// App 不能正规地调系统音量，这里用 MPVolumeView 里的滑块把音量推到最大（尽力而为）。
final class Siren {
    private final class Flag { var on = false }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let voice = AVSpeechSynthesizer()
    private var speakTimer: Timer?
    private let flag = Flag()

    /// 开始监控时就设好：和摄像头共用一个音频会话
    static func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
        try? s.setActive(true)
    }

    /// 让引擎静音运行起来
    func prepare() {
        Siren.configureSession()
        guard source == nil else { startEngine(); return }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = rate > 0 ? rate : 44_100
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let flag = self.flag
        var phase = 0.0
        var t = 0.0
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for frame in 0..<Int(frameCount) {
                var value: Float = 0
                if flag.on {
                    // 0.8 秒一个来回：650 Hz → 1400 Hz → 650 Hz
                    let cycle = t.truncatingRemainder(dividingBy: 0.8) / 0.8
                    let sweep = cycle < 0.5 ? cycle * 2 : (1 - cycle) * 2
                    phase += 2 * .pi * (650 + 750 * sweep) / sampleRate
                    if phase > 2 * .pi { phase -= 2 * .pi }
                    value = sin(phase) > 0 ? 0.85 : -0.85   // 方波，比正弦波刺耳、听得远
                    t += 1 / sampleRate
                }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        startEngine()
    }

    private func startEngine() {
        if !engine.isRunning { try? engine.start() }
    }

    var sounding: Bool { flag.on }

    func sound(_ on: Bool) {
        DispatchQueue.main.async {
            guard on != self.flag.on else { return }
            self.flag.on = on
            self.speakTimer?.invalidate()
            self.speakTimer = nil
            if on {
                Siren.configureSession()
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                self.startEngine()
                VolumeBooster.shared.max()
                self.speak()
                self.speakTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.speak() }
            } else {
                self.voice.stopSpeaking(at: .immediate)
            }
        }
    }

    private func speak() {
        guard flag.on, !voice.isSpeaking else { return }
        let u = AVSpeechUtterance(string: "有人偷手机！有人偷手机！")
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.volume = 1
        u.rate = 0.5
        voice.speak(u)
    }

    /// 停止监控：警报和静音引擎都关掉
    func shutdown() {
        sound(false)
        DispatchQueue.main.async { self.engine.stop() }
    }
}

/// 藏在界面里的系统音量控件。用它的滑块把音量推到最大。
final class VolumeBooster {
    static let shared = VolumeBooster()
    let view: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 10, height: 10))
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        return v
    }()

    func max() {
        DispatchQueue.main.async {
            guard let slider = self.view.subviews.compactMap({ $0 as? UISlider }).first else { return }
            // 滑块刚建好时设值可能不生效，稍等一下再设
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                slider.value = 1
                slider.sendActions(for: .valueChanged)
            }
        }
    }
}
