import CoreAudio
import Foundation
import Synchronization

/// Single-producer / single-consumer ring of interleaved stereo frames.
/// The network queue writes, the device's IO thread reads; no locks on either side.
final class StereoRing: @unchecked Sendable {
    let capacity: Int                    // in frames
    private let data: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0) // total frames ever written
    private let read = Atomic<Int>(0)    // total frames ever read

    init(capacity: Int) {
        self.capacity = capacity
        data = .allocate(capacity: capacity * 2)
        data.initialize(repeating: 0, count: capacity * 2)
    }

    deinit { data.deallocate() }

    var available: Int { written.load(ordering: .acquiring) - read.load(ordering: .relaxed) }

    /// Producer. `channels` is 1 or 2; mono is duplicated. Drops the chunk if the reader has stalled.
    func write(_ samples: UnsafeBufferPointer<Float>, channels: Int) {
        let frames = samples.count / channels
        let w = written.load(ordering: .relaxed)
        guard w - read.load(ordering: .acquiring) + frames <= capacity else { return }
        for i in 0..<frames {
            let slot = ((w + i) % capacity) * 2
            let l = samples[i * channels]
            data[slot] = l
            data[slot + 1] = channels > 1 ? samples[i * channels + 1] : l
        }
        written.store(w + frames, ordering: .releasing)
    }

    /// Consumer: copies `frames` frames starting `offset` ahead without consuming them.
    func peek(into: UnsafeMutablePointer<Float>, frames: Int, offset: Int = 0) {
        let r = read.load(ordering: .relaxed) + offset
        for i in 0..<frames {
            let slot = ((r + i) % capacity) * 2
            into[i * 2] = data[slot]
            into[i * 2 + 1] = data[slot + 1]
        }
    }

    /// Consumer: drops `frames` frames.
    func advance(_ frames: Int) {
        read.store(read.load(ordering: .relaxed) + frames, ordering: .releasing)
    }

    /// Consumer: copies `frames` frames into `into` (interleaved stereo), starting `skip` frames ahead.
    func read(into: UnsafeMutablePointer<Float>, frames: Int, skip: Int = 0) {
        let r = read.load(ordering: .relaxed) + skip
        for i in 0..<frames {
            let slot = ((r + i) % capacity) * 2
            into[i * 2] = data[slot]
            into[i * 2 + 1] = data[slot + 1]
        }
        read.store(r + frames, ordering: .releasing)
    }
}

/// Plays audio streamed from a browser tab on one output device.
final class TabPlayer: @unchecked Sendable {
    let deviceUID: String
    /// The device's rate.
    let sampleRate: Double
    /// The rate the browser streams at (the first speaker's rate when a tab plays on several).
    /// When it differs from `sampleRate` the player resamples.
    var streamRate: Double
    let state = IOState()
    let ring: StereoRing

    private let deviceID: AudioObjectID
    private var procID: AudioDeviceIOProcID?
    private let scratch: UnsafeMutablePointer<Float>
    private let source: UnsafeMutablePointer<Float>
    private let scratchFrames = 8192
    private let delayLine: DelayLine
    /// Fractional read position for resampling.
    private var phase: Double = 0
    private let queue = DispatchQueue(label: "SoundRouter.tab", qos: .userInteractive)

    // Jitter buffer, in frames.
    private let prebuffer: Int
    private let maxLatency: Int
    private let targetLatency: Int
    private var primed = false

    // Diagnostics: a rate mismatch between the stream and the device shows up as
    // steady skips (stream faster) or underruns (stream slower).
    private(set) var skips = 0
    private(set) var underruns = 0

    /// Called on the main queue when the device's sample rate changes (e.g. Bluetooth
    /// headphones switching to headset mode because an app opened their mic).
    var onSampleRateChange: (() -> Void)?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var listenedID = AudioObjectID(kAudioObjectUnknown)

    init(device: OutputDevice, gain: Float) throws {
        deviceID = device.id
        deviceUID = device.uid
        sampleRate = CA.get(device.id, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 48000
        streamRate = sampleRate
        prebuffer = Int(sampleRate * 0.04)
        targetLatency = Int(sampleRate * 0.06)
        maxLatency = Int(sampleRate * 0.15)
        ring = StereoRing(capacity: Int(sampleRate))
        scratch = .allocate(capacity: scratchFrames * 2)
        source = .allocate(capacity: (scratchFrames * 4 + 4) * 2)
        delayLine = DelayLine(maxFrames: 96_000)
        state.gain = gain

        let initialRate = sampleRate
        var rateAddress = address(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let rate = CA.get(self.deviceID, address(kAudioDevicePropertyNominalSampleRate), Float64(0)),
                  rate != initialRate else { return }
            self.onSampleRateChange?()
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &rateAddress, DispatchQueue.main, listener) == noErr {
            rateListener = listener
            listenedID = deviceID
        }

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [unowned self] _, _, _, output, _ in
            self.render(output)
        }, "Create tab IO proc")
        do { try check(AudioDeviceStart(deviceID, procID), "Start tab output") } catch { stop(); throw error }
    }

    deinit {
        stop()
        scratch.deallocate()
        source.deallocate()
    }

    func stop() {
        if let rateListener {
            var rateAddress = address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(listenedID, &rateAddress, DispatchQueue.main, rateListener)
            self.rateListener = nil
        }
        guard let procID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
    }

    private func render(_ output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        var frames = 0
        for buf in outs where buf.mNumberChannels > 0 {
            frames = max(frames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * Int(buf.mNumberChannels)))
        }
        frames = min(frames, scratchFrames)

        // How many stream frames this callback consumes.
        let ratio = min(4, max(0.25, streamRate / sampleRate))
        let resampling = abs(ratio - 1) > 1e-6
        let needed = resampling ? Int((phase + Double(frames) * ratio).rounded(.up)) + 1 : frames

        var available = ring.available
        if !primed && available >= prebuffer { primed = true }
        var got = 0
        if primed {
            // Fell too far behind (browser sent a burst): jump forward to keep latency low.
            let skip = available > maxLatency ? available - targetLatency : 0
            if skip > 0 { skips += 1; ring.advance(skip) }
            available -= skip
            if available >= needed {
                if resampling {
                    ring.peek(into: source, frames: needed)
                    for i in 0..<frames {
                        let x = phase + Double(i) * ratio
                        let i0 = Int(x)
                        let t = Float(x - Double(i0))
                        scratch[i * 2] = source[i0 * 2] * (1 - t) + source[(i0 + 1) * 2] * t
                        scratch[i * 2 + 1] = source[i0 * 2 + 1] * (1 - t) + source[(i0 + 1) * 2 + 1] * t
                    }
                    let end = phase + Double(frames) * ratio
                    let consumed = Int(end)
                    phase = end - Double(consumed)
                    ring.advance(consumed)
                } else {
                    ring.read(into: scratch, frames: frames)
                }
                got = frames
            } else {
                primed = false   // underrun: rebuild the cushion
                underruns += 1
            }
        }
        for i in (got * 2)..<(frames * 2) { scratch[i] = 0 }

        state.eq.process(scratch, frames: frames)
        delayLine.process(scratch, frames: frames, delay: state.delayFrames)
        DSP.write(scratch, frames: frames, to: output, state: state)
    }
}
