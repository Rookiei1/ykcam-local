import AVFoundation
import Foundation

/// 把麦克风的实时声音重采样为 16 kHz 单声道 8 位 μ-law，每 0.1 秒（1600 字节）吐出一次。
/// 网页端「听声音」直接按 16 kHz μ-law 解码播放。
final class LiveAudio {
    static let targetRate: Double = 16_000
    static let chunkSamples = 1600   // 0.1 秒

    private let queue = DispatchQueue(label: "ykcam.liveaudio")
    private var buffer: [UInt8] = []
    private var phase: Double = 0

    var onChunk: ((Data) -> Void)?

    func reset() {
        queue.async {
            self.buffer.removeAll(keepingCapacity: true)
            self.phase = 0
        }
    }

    func append(_ sample: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let asbd = asbdPtr.pointee
        let inRate = asbd.mSampleRate
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bits = Int(asbd.mBitsPerChannel)
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard inRate > 0, (bits == 16 && !isFloat) || (bits == 32 && isFloat) else { return }

        var blockBuffer: CMBlockBuffer?
        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &listSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, audioBufferListOut: nil
        )
        guard listSize > 0 else { return }
        let rawList = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawList.deallocate() }
        let listPtr = rawList.assumingMemoryBound(to: AudioBufferList.self)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: listPtr,
            bufferListSize: listSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        guard let first = buffers.first, let mData = first.mData, first.mDataByteSize > 0 else { return }

        let stride = isNonInterleaved ? 1 : channels
        let bytesPerSample = bits / 8
        let frameCount = Int(first.mDataByteSize) / (bytesPerSample * stride)
        guard frameCount > 0 else { return }

        var mono = [Int16](repeating: 0, count: frameCount)
        if isFloat {
            let ptr = mData.assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount {
                let s = max(-1.0, min(1.0, ptr[i * stride]))
                mono[i] = Int16((s * 32767.0).rounded())
            }
        } else {
            let ptr = mData.assumingMemoryBound(to: Int16.self)
            for i in 0..<frameCount {
                mono[i] = ptr[i * stride]
            }
        }

        queue.async { [weak self] in
            self?.processMono(mono, inRate: inRate)
        }
    }

    private func processMono(_ mono: [Int16], inRate: Double) {
        let step = inRate / Self.targetRate
        var pos = phase
        while Int(pos) < mono.count {
            let idx = Int(pos)
            let frac = pos - Double(idx)
            let a = Double(mono[idx])
            let b = idx + 1 < mono.count ? Double(mono[idx + 1]) : a
            let v = Int16((a + (b - a) * frac).rounded())
            buffer.append(Self.ulaw(v))
            pos += step
            if buffer.count >= Self.chunkSamples {
                let out = Data(buffer.prefix(Self.chunkSamples))
                buffer.removeFirst(Self.chunkSamples)
                onChunk?(out)
            }
        }
        phase = pos - Double(mono.count)
    }

    /// 16 位线性 PCM 压成 8 位 G.711 μ-law，和电脑端 agent.py、网页 app.js 完全一致。
    static func ulaw(_ sample: Int16) -> UInt8 {
        let s = Int(sample)
        let sign = s < 0 ? 1 : 0
        let absVal = s == Int(Int16.min) ? 32767 : abs(s)
        let mag = UInt32(min(absVal, 32635) + 132)
        let exp = (31 - mag.leadingZeroBitCount) - 7
        let mantissa = Int((mag >> (exp + 3)) & 0x0F)
        return UInt8(~((sign << 7) | (exp << 4) | mantissa) & 0xFF)
    }
}
