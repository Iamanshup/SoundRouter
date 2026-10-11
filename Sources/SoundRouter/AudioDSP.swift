import CoreAudio
import Foundation
import Synchronization

/// State shared with the real-time IO thread. Plain stores of Float/Int/UInt64 are
/// word-sized and tear-free on arm64/x86_64, which is all this needs.
final class IOState: @unchecked Sendable {
    var gain: Float = 1
    /// Gain actually applied last callback; changes ramp from here (no clicks).
    var appliedGain: Float = -1
    /// Soft-limit the output (when boosting volume or EQ).
    var limit = false
    let eq = EQProcessor()
    /// Main-thread only: the EQ chain last installed, to skip redundant updates.
    var eqSignature = ""

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

    /// Real-time: writes interleaved stereo `scratch` into a device's output buffers with
    /// gain and limiting. Gain changes ramp across the buffer so fades (e.g. ducking for a
    /// call) are smooth. Handles mono and multichannel devices.
    static func write(_ scratch: UnsafePointer<Float>, frames: Int,
                      to output: UnsafeMutablePointer<AudioBufferList>, state: IOState) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        let target = state.gain
        if state.appliedGain < 0 { state.appliedGain = target }
        let g0 = state.appliedGain
        let step = (target - g0) / Float(max(frames, 1))
        let limit = state.limit || target > 1 || state.appliedGain > 1

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
                let ch0 = channel + c
                for i in 0..<n {
                    let gi = g0 + step * Float(i)
                    var l = scratch[i * 2] * gi, r = scratch[i * 2 + 1] * gi
                    if limit { l = softLimit(l); r = softLimit(r) }
                    let v: Float
                    if total == 1 { v = (l + r) * 0.5 }
                    else if ch0 == 0 { v = l }
                    else if ch0 == 1 { v = r }
                    else { v = 0 }
                    p[i * ch + c] = v
                    if ch0 == 1 { peakR = max(peakR, abs(v)) } else if ch0 == 0 { peakL = max(peakL, abs(v)) }
                }
                for i in n..<available { p[i * ch + c] = 0 }
            }
            channel += ch
        }
        state.appliedGain = target
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

// MARK: - Equalizer

/// One filter of an EQ, in musical terms.
struct EQBand: Codable, Equatable {
    enum Kind: String, Codable { case peak, lowShelf, highShelf }
    var kind: Kind
    var frequency: Double
    var gain: Double      // dB
    var q: Double
}

/// Biquad coefficients (normalised, a0 = 1). RBJ "Audio EQ Cookbook".
struct Biquad: Equatable {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    init() {}

    init(_ band: EQBand, sampleRate: Double) {
        let f = min(max(band.frequency, 10), sampleRate * 0.45)
        let A = pow(10, band.gain / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * max(band.q, 0.05))
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch band.kind {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cosw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosw; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosw + s); b1 = 2 * A * ((A - 1) - (A + 1) * cosw); b2 = A * ((A + 1) - (A - 1) * cosw - s)
            a0 = (A + 1) + (A - 1) * cosw + s; a1 = -2 * ((A - 1) + (A + 1) * cosw); a2 = (A + 1) + (A - 1) * cosw - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosw + s); b1 = -2 * A * ((A - 1) + (A + 1) * cosw); b2 = A * ((A + 1) + (A - 1) * cosw - s)
            a0 = (A + 1) - (A - 1) * cosw + s; a1 = 2 * ((A - 1) - (A + 1) * cosw); a2 = (A + 1) - (A - 1) * cosw - s
        }
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }
}

/// Stereo chain of biquads for the real-time thread. The main thread publishes new
/// coefficients into a spare bank and flips an index, so the IO thread never waits.
final class EQProcessor: @unchecked Sendable {
    static let maxFilters = 32
    private let banks: UnsafeMutablePointer<Biquad>       // 2 × maxFilters
    private let counts: UnsafeMutablePointer<Int>         // per bank
    private let preamps: UnsafeMutablePointer<Float>      // per bank
    private let active = Atomic<Int>(0)
    private let z: UnsafeMutablePointer<Float>            // maxFilters × 2 channels × 2 states

    init() {
        banks = .allocate(capacity: 2 * Self.maxFilters)
        banks.initialize(repeating: Biquad(), count: 2 * Self.maxFilters)
        counts = .allocate(capacity: 2); counts.initialize(repeating: 0, count: 2)
        preamps = .allocate(capacity: 2); preamps.initialize(repeating: 1, count: 2)
        z = .allocate(capacity: Self.maxFilters * 4); z.initialize(repeating: 0, count: Self.maxFilters * 4)
    }

    deinit { banks.deallocate(); counts.deallocate(); preamps.deallocate(); z.deallocate() }

    var isActive: Bool { counts[active.load(ordering: .acquiring)] > 0 }

    /// Main thread: install a new filter chain (empty = bypass). `preampDB` is applied first.
    func set(_ bands: [EQBand], preampDB: Double, sampleRate: Double) {
        let next = 1 - active.load(ordering: .relaxed)
        let list = bands.filter { abs($0.gain) > 0.01 }.prefix(Self.maxFilters)
        for (i, band) in list.enumerated() { banks[next * Self.maxFilters + i] = Biquad(band, sampleRate: sampleRate) }
        counts[next] = list.count
        preamps[next] = list.isEmpty ? 1 : Float(pow(10, preampDB / 20))
        active.store(next, ordering: .releasing)
    }

    /// Real-time: filter interleaved stereo in place.
    func process(_ x: UnsafeMutablePointer<Float>, frames: Int) {
        let bank = active.load(ordering: .acquiring)
        let n = counts[bank]
        guard n > 0 else { return }
        let pre = preamps[bank]
        let coeffs = banks + bank * Self.maxFilters
        for i in 0..<frames {
            for c in 0..<2 {
                var v = x[i * 2 + c] * pre
                for f in 0..<n {
                    let k = coeffs[f]
                    let s = (f * 2 + c) * 2
                    let y = k.b0 * v + z[s]
                    z[s] = k.b1 * v - k.a1 * y + z[s + 1]
                    z[s + 1] = k.b2 * v - k.a2 * y
                    v = y
                }
                x[i * 2 + c] = v
            }
        }
    }
}

/// 10-band graphic EQ and presets.
enum GraphicEQ {
    static let frequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    static let presets: [(name: String, gains: [Double])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost", [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]),
        ("Bass Reducer", [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]),
        ("Vocal Clarity", [-3, -2, -1, 0, 2, 3.5, 3.5, 2, 0, -1]),
        ("Loudness", [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]),
        ("Small Speakers", [4, 4, 3, 1, 0, 0, 0, 1, 2, 2]),
    ]

    static func bands(_ gains: [Double]) -> [EQBand] {
        frequencies.enumerated().map { i, f in
            let kind: EQBand.Kind = i == 0 ? .lowShelf : (i == frequencies.count - 1 ? .highShelf : .peak)
            return EQBand(kind: kind, frequency: f, gain: i < gains.count ? gains[i] : 0, q: kind == .peak ? 1.41 : 0.71)
        }
    }

    /// Headroom so boosts don't clip before the limiter.
    static func preamp(_ gains: [Double]) -> Double { -max(0, gains.max() ?? 0) * 0.6 }

    static func presetName(_ gains: [Double]) -> String? {
        presets.first { zip($0.gains, gains).allSatisfy { abs($0 - $1) < 0.05 } && gains.count == 10 }?.name
    }
}

/// A headphone/speaker correction curve, e.g. from AutoEQ ("ParametricEQ.txt").
struct CorrectionProfile: Codable, Equatable {
    var name: String
    var preamp: Double
    var bands: [EQBand]

    /// Parses AutoEQ / Equalizer APO parametric format:
    ///   Preamp: -6.2 dB
    ///   Filter 1: ON LSC Fc 105 Hz Gain 5.0 dB Q 0.70
    ///   Filter 2: ON PK Fc 220 Hz Gain -3.1 dB Q 1.20
    static func parse(_ text: String, name: String) -> CorrectionProfile? {
        var preamp = 0.0
        var bands: [EQBand] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let words = line.split(separator: " ").map(String.init)
            func number(after key: String) -> Double? {
                guard let i = words.firstIndex(of: key), words.indices.contains(i + 1) else { return nil }
                return Double(words[i + 1])
            }
            if line.lowercased().hasPrefix("preamp:"), let v = Double(words.dropFirst().first ?? "") {
                preamp = v
            } else if line.hasPrefix("Filter"), words.contains("ON"),
                      let fc = number(after: "Fc"), let gain = number(after: "Gain") {
                let kind: EQBand.Kind
                if words.contains("PK") || words.contains("PEQ") { kind = .peak }
                else if words.contains("LSC") || words.contains("LS") { kind = .lowShelf }
                else if words.contains("HSC") || words.contains("HS") { kind = .highShelf }
                else { continue }
                bands.append(EQBand(kind: kind, frequency: fc, gain: gain, q: number(after: "Q") ?? 0.71))
            }
        }
        return bands.isEmpty ? nil : CorrectionProfile(name: name, preamp: preamp, bands: bands)
    }
}
