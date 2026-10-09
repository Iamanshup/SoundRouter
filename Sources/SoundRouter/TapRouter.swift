import CoreAudio
import Foundation

/// State shared with the real-time IO thread. Plain stores of Float/UInt64 are
/// word-sized and tear-free on arm64/x86_64, which is all this needs.
final class IOState: @unchecked Sendable {
    var gain: Float = 1
    var peak: Float = 0
    var callbacks: UInt64 = 0
    /// Callbacks where the tap delivered fewer frames than the device wanted (gaps).
    var shortCallbacks: UInt64 = 0
}

/// Captures the audio of a set of processes with a Core Audio process tap (muting
/// their normal output) and plays it on a chosen output device.
final class TapRouter {
    let processObjects: [AudioObjectID]
    let deviceUID: String
    let state = IOState()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "SoundRouter.io", qos: .userInteractive)

    init(name: String, processObjects: [AudioObjectID], deviceUID: String, gain: Float) throws {
        self.processObjects = processObjects
        self.deviceUID = deviceUID
        state.gain = gain
        do { try start(name: name) } catch { stop(); throw error }
    }

    deinit { stop() }

    private func start(name: String) throws {
        let tap = CATapDescription(stereoMixdownOfProcesses: processObjects)
        tap.uuid = UUID()
        tap.name = "SoundRouter: \(name)"
        tap.isPrivate = true
        // Muted only while we read it: if SoundRouter dies, the app's audio comes back.
        tap.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "Create process tap")

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundRouter-\(name)",
            kAudioAggregateDeviceUIDKey: aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "Create aggregate device")

        let state = self.state
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
            TapRouter.render(input: input, output: output, state: state)
        }, "Create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "Start device")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Real-time: copy the tapped stereo mix into the output device's buffers, applying gain.
    /// Handles interleaved and non-interleaved layouts on both sides, and mono outputs.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               state: IOState) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        let gain = state.gain

        // Locate up to two input channels: (base pointer, stride, frame count).
        var l: (UnsafePointer<Float>, Int, Int)?
        var r: (UnsafePointer<Float>, Int, Int)?
        for buf in ins {
            guard let data = buf.mData, buf.mNumberChannels > 0 else { continue }
            let ch = Int(buf.mNumberChannels)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let p = data.assumingMemoryBound(to: Float.self)
            for c in 0..<min(ch, 2) {
                let entry = (UnsafePointer(p + c), ch, frames)
                if l == nil { l = entry } else if r == nil { r = entry }
            }
            if r != nil { break }
        }
        if r == nil { r = l }

        var totalOutChannels = 0
        for buf in outs { totalOutChannels += Int(buf.mNumberChannels) }

        var peak: Float = 0
        var outChannel = 0
        var short = false
        for buf in outs {
            guard let data = buf.mData, buf.mNumberChannels > 0 else { continue }
            let ch = Int(buf.mNumberChannels)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let p = data.assumingMemoryBound(to: Float.self)
            for c in 0..<ch {
                let g = outChannel + c
                let src: (UnsafePointer<Float>, Int, Int)? = g == 0 ? l : (g == 1 ? r : nil)
                let n = min(frames, src?.2 ?? 0)
                if src != nil && n < frames { short = true }
                if let (sp, ss, _) = src, totalOutChannels == 1, let (rp, rs, _) = r {
                    // Mono device: downmix.
                    for i in 0..<n {
                        let v = (sp[i * ss] + rp[i * rs]) * 0.5 * gain
                        p[i * ch + c] = v
                        peak = max(peak, abs(v))
                    }
                } else if let (sp, ss, _) = src {
                    for i in 0..<n {
                        let v = sp[i * ss] * gain
                        p[i * ch + c] = v
                        peak = max(peak, abs(v))
                    }
                }
                for i in n..<frames { p[i * ch + c] = 0 }
            }
            outChannel += ch
        }
        state.peak = peak
        state.callbacks &+= 1
        if short || l == nil { state.shortCallbacks &+= 1 }
    }
}
