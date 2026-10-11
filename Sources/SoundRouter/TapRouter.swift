import CoreAudio
import Foundation

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
    private let scratchFrames = 8192
    private let scratch: UnsafeMutablePointer<Float>
    private let delayLine: DelayLine

    init(name: String, processObjects: [AudioObjectID], deviceUID: String, gain: Float) throws {
        self.processObjects = processObjects
        self.deviceUID = deviceUID
        scratch = .allocate(capacity: scratchFrames * 2)
        delayLine = DelayLine(maxFrames: 96_000)   // 0.5 s at up to 192 kHz
        state.gain = gain
        do { try start(name: name) } catch { stop(); throw error }
    }

    deinit {
        stop()
        scratch.deallocate()
    }

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

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [unowned self] _, input, _, output, _ in
            self.render(input: input, output: output)
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

    /// Real-time: gather the tapped stereo mix, delay it if asked, then write it out
    /// with gain and limiting. Handles interleaved and non-interleaved input.
    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        var frames = 0
        for buf in outs where buf.mNumberChannels > 0 {
            frames = max(frames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * Int(buf.mNumberChannels)))
        }
        frames = min(frames, scratchFrames)

        // Locate up to two input channels: (base pointer, stride, frame count).
        var l: (UnsafePointer<Float>, Int, Int)?
        var r: (UnsafePointer<Float>, Int, Int)?
        for buf in ins {
            guard let data = buf.mData, buf.mNumberChannels > 0 else { continue }
            let ch = Int(buf.mNumberChannels)
            let count = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let p = data.assumingMemoryBound(to: Float.self)
            for c in 0..<min(ch, 2) {
                let entry = (UnsafePointer(p + c), ch, count)
                if l == nil { l = entry } else if r == nil { r = entry }
            }
            if r != nil { break }
        }
        if r == nil { r = l }

        var got = 0
        if let (lp, ls, ln) = l, let (rp, rs, rn) = r {
            got = min(frames, ln, rn)
            for i in 0..<got {
                scratch[i * 2] = lp[i * ls]
                scratch[i * 2 + 1] = rp[i * rs]
            }
        }
        for i in (got * 2)..<(frames * 2) { scratch[i] = 0 }
        if got < frames { state.shortCallbacks &+= 1 }

        state.eq.process(scratch, frames: frames)
        delayLine.process(scratch, frames: frames, delay: state.delayFrames)
        DSP.write(scratch, frames: frames, to: output, state: state)
        _ = outs
    }
}
