import CoreAudio
import Foundation

/// State shared with the real-time IO thread. Plain stores of Float/Int/UInt64 are
/// word-sized and tear-free on arm64/x86_64, which is all this needs.
final class IOState: @unchecked Sendable {
    var gain: Float = 1
    /// -1 (left only) … 0 (centre) … +1 (right only).
    var balance: Float = 0
    /// Extra delay, used to line up speakers with different latencies (e.g. Bluetooth).
    var delayFrames = 0
    var peak: Float = 0
    var peakLeft: Float = 0
    var peakRight: Float = 0
    var callbacks: UInt64 = 0
    /// Callbacks where the source delivered fewer frames than the device wanted (gaps).
    var shortCallbacks: UInt64 = 0
}

enum DSP {
    /// Gains above 100% can push samples past full scale. Below 0.8 this is transparent;
    /// above, it bends smoothly towards ±1 instead of hard clipping.
    @inline(__always)
    static func softLimit(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.8 { return x }
        let y = 0.8 + 0.2 * tanh((a - 0.8) / 0.2)
        return x < 0 ? -y : y
    }

    /// Per-channel gains for a volume and balance.
    @inline(__always)
    static func channelGains(gain: Float, balance: Float) -> (Float, Float) {
        let b = max(-1, min(1, balance))
        return (gain * (b > 0 ? 1 - b : 1), gain * (b < 0 ? 1 + b : 1))
    }

    /// Real-time: writes interleaved stereo `scratch` into a device's output buffers with
    /// gain, balance and (when boosting) limiting. Handles mono and multichannel devices.
    static func write(_ scratch: UnsafePointer<Float>, frames: Int,
                      to output: UnsafeMutablePointer<AudioBufferList>, state: IOState) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        let (gl, gr) = channelGains(gain: state.gain, balance: state.balance)
        let limit = state.gain > 1

        var total = 0
        for buf in outs { total += Int(buf.mNumberChannels) }
        var peakL: Float = 0, peakR: Float = 0
        var channel = 0
        for buf in outs {
            guard let raw = buf.mData, buf.mNumberChannels > 0 else { continue }
            let ch = Int(buf.mNumberChannels)
            let available = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let n = min(frames, available)
            let p = raw.assumingMemoryBound(to: Float.self)
            for c in 0..<ch {
                let g = channel + c
                for i in 0..<n {
                    var l = scratch[i * 2] * gl, r = scratch[i * 2 + 1] * gr
                    if limit { l = softLimit(l); r = softLimit(r) }
                    let v: Float
                    if total == 1 { v = (l + r) * 0.5 }
                    else if g == 0 { v = l }
                    else if g == 1 { v = r }
                    else { v = 0 }
                    p[i * ch + c] = v
                    if g == 1 { peakR = max(peakR, abs(v)) } else if g == 0 { peakL = max(peakL, abs(v)) }
                }
                for i in n..<available { p[i * ch + c] = 0 }
            }
            channel += ch
        }
        if total == 1 { peakR = peakL }
        state.peakLeft = peakL
        state.peakRight = peakR
        state.peak = max(peakL, peakR)
        state.callbacks &+= 1
    }
}

/// Stereo delay line for the real-time thread (single-threaded use).
final class DelayLine: @unchecked Sendable {
    let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var writeIndex = 0

    init(maxFrames: Int) {
        capacity = maxFrames + 1
        buffer = .allocate(capacity: capacity * 2)
        buffer.initialize(repeating: 0, count: capacity * 2)
    }

    deinit { buffer.deallocate() }

    /// Replaces `scratch` (interleaved stereo) with the signal from `delay` frames ago.
    func process(_ scratch: UnsafeMutablePointer<Float>, frames: Int, delay: Int) {
        let d = max(0, min(delay, capacity - 1))
        for i in 0..<frames {
            let w = writeIndex * 2
            buffer[w] = scratch[i * 2]
            buffer[w + 1] = scratch[i * 2 + 1]
            let r = ((writeIndex - d) % capacity + capacity) % capacity * 2
            scratch[i * 2] = buffer[r]
            scratch[i * 2 + 1] = buffer[r + 1]
            writeIndex = (writeIndex + 1) % capacity
        }
    }
}
