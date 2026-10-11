import AudioToolbox
import CoreAudio
import Foundation

let aggregateUIDPrefix = "com.soundrouter.aggregate."

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    var isDefault: Bool
    var hasHardwareVolume: Bool
    var volume: Float          // 0...1 (hardware, or software fallback)
    var muted: Bool
    /// Where alert and notification sounds play.
    var isAlertOutput: Bool = false
    /// For aggregate / multi-output devices: the real devices inside.
    var subDeviceUIDs: [String] = []

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "hifispeaker"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual: return "square.stack.3d.up"
        default: return "speaker.wave.2"
        }
    }
}

enum DeviceManager {
    static func defaultOutputID() -> AudioObjectID? {
        CA.get(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0))
    }

    static func setDefaultOutput(_ id: AudioObjectID) {
        _ = CA.set(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    /// The device macOS plays alerts and sound effects on ("Play sound effects through").
    static func systemOutputID() -> AudioObjectID? {
        CA.get(systemObject, address(kAudioHardwarePropertyDefaultSystemOutputDevice), AudioObjectID(0))
    }

    static func setSystemOutput(_ id: AudioObjectID) {
        _ = CA.set(systemObject, address(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
    }



    static func outputDevices(softwareVolumes: [String: Float]) -> [OutputDevice] {
        let defaultID = defaultOutputID()
        let alertID = systemOutputID()
        let ids = CA.array(systemObject, address(kAudioHardwarePropertyDevices), AudioObjectID(0))
        return ids.compactMap { id in
            let streams = CA.array(id, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID(0))
            guard !streams.isEmpty,
                  let uid = CA.string(id, address(kAudioDevicePropertyDeviceUID)),
                  !uid.hasPrefix(aggregateUIDPrefix),
                  !uid.hasPrefix("CADefaultDeviceAggregate"),
                  (CA.get(id, address(kAudioDevicePropertyIsHidden), UInt32(0)) ?? 0) == 0
            else { return nil }
            let name = CA.string(id, address(kAudioObjectPropertyName)) ?? uid
            let transport = CA.get(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
            let hw = volumeElements(id)
            let volume = hw.isEmpty ? (softwareVolumes[uid] ?? 1) : hardwareVolume(id, hw)
            let muted = (CA.get(id, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(0)) ?? 0) != 0
            let subs = transport == kAudioDeviceTransportTypeAggregate
                ? CA.array(id, address(kAudioAggregateDevicePropertyActiveSubDeviceList), AudioObjectID(0))
                    .compactMap { CA.string($0, address(kAudioDevicePropertyDeviceUID)) }
                : []
            return OutputDevice(id: id, uid: uid, name: name, transport: transport,
                                isDefault: id == defaultID, hasHardwareVolume: !hw.isEmpty,
                                volume: volume, muted: muted, isAlertOutput: id == alertID, subDeviceUIDs: subs)
        }
    }

    /// Elements that carry a settable volume: the main element, or the stereo channels.
    static func volumeElements(_ id: AudioObjectID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> [AudioObjectPropertyElement] {
        if CA.settable(id, address(kAudioDevicePropertyVolumeScalar, scope)) {
            return [kAudioObjectPropertyElementMain]
        }
        let pair = CA.array(id, address(kAudioDevicePropertyPreferredChannelsForStereo, scope), UInt32(0))
        let channels = pair.isEmpty ? [1, 2] : pair
        return channels.filter {
            CA.settable(id, address(kAudioDevicePropertyVolumeScalar, scope, $0))
        }
    }

    static func hardwareVolume(_ id: AudioObjectID, _ elements: [AudioObjectPropertyElement],
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Float {
        let values = elements.compactMap {
            CA.get(id, address(kAudioDevicePropertyVolumeScalar, scope, $0), Float32(0))
        }
        return values.isEmpty ? 1 : values.reduce(0, +) / Float(values.count)
    }

    static func setHardwareVolume(_ id: AudioObjectID, _ volume: Float, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) {
        for element in volumeElements(id, scope: scope) {
            _ = CA.set(id, address(kAudioDevicePropertyVolumeScalar, scope, element), Float32(volume))
        }
    }

    static func canMute(_ id: AudioObjectID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Bool {
        CA.settable(id, address(kAudioDevicePropertyMute, scope))
    }

    static func setMuted(_ id: AudioObjectID, _ muted: Bool, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) {
        _ = CA.set(id, address(kAudioDevicePropertyMute, scope), UInt32(muted ? 1 : 0))
    }
}

// MARK: Microphones

struct InputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    var name: String
    let transport: UInt32
    var isDefault: Bool
    var hasVolume: Bool
    var volume: Float
    var canMute: Bool
    var muted: Bool
    /// Bluetooth device that also plays audio: using its mic drops its playback to headset quality.
    var isBluetoothHeadset: Bool

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    var symbol: String {
        if isBluetoothHeadset { return "headphones" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeUSB: return "mic"
        default: return "mic"
        }
    }
}

enum InputManager {
    /// For testing the headset guard without real Bluetooth hardware.
    static let simulatedHeadset = ProcessInfo.processInfo.environment["SR_SIMULATE_BT_HEADSET"]

    static func defaultInputID() -> AudioObjectID? {
        CA.get(systemObject, address(kAudioHardwarePropertyDefaultInputDevice), AudioObjectID(0))
    }

    static func setDefaultInput(_ id: AudioObjectID) {
        _ = CA.set(systemObject, address(kAudioHardwarePropertyDefaultInputDevice), id)
    }

    static func inputDevices() -> [InputDevice] {
        let defaultID = defaultInputID()
        let ids = CA.array(systemObject, address(kAudioHardwarePropertyDevices), AudioObjectID(0))
        let input = kAudioObjectPropertyScopeInput
        let list: [InputDevice] = ids.compactMap { id in
            let streams = CA.array(id, address(kAudioDevicePropertyStreams, input), AudioStreamID(0))
            guard !streams.isEmpty,
                  let uid = CA.string(id, address(kAudioDevicePropertyDeviceUID)),
                  !uid.hasPrefix(aggregateUIDPrefix),
                  !uid.hasPrefix("CADefaultDeviceAggregate"),
                  (CA.get(id, address(kAudioDevicePropertyIsHidden), UInt32(0)) ?? 0) == 0
            else { return nil }
            let name = CA.string(id, address(kAudioObjectPropertyName)) ?? uid
            let transport = CA.get(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
            let hasOutput = !CA.array(id, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID(0)).isEmpty
            let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            let elements = DeviceManager.volumeElements(id, scope: input)
            return InputDevice(
                id: id, uid: uid, name: name, transport: transport,
                isDefault: id == defaultID,
                hasVolume: !elements.isEmpty,
                volume: elements.isEmpty ? 1 : DeviceManager.hardwareVolume(id, elements, scope: input),
                canMute: DeviceManager.canMute(id, scope: input),
                muted: (CA.get(id, address(kAudioDevicePropertyMute, input), UInt32(0)) ?? 0) != 0,
                isBluetoothHeadset: (bluetooth && hasOutput) || (simulatedHeadset.map { name.contains($0) } ?? false))
        }
        // Tell apart devices that share a name ("Light Microphone", "Light Microphone 2").
        var seen: [String: Int] = [:]
        return list.map { device in
            var device = device
            let n = (seen[device.name] ?? 0) + 1
            seen[device.name] = n
            if n > 1 { device.name += " \(n)" }
            return device
        }
    }

    /// The mic to switch to when a Bluetooth headset has become the system mic:
    /// the built-in mic, else any other non-headset mic. nil means leave things alone.
    static func headsetGuardTarget(_ inputs: [InputDevice]) -> InputDevice? {
        guard let current = inputs.first(where: \.isDefault), current.isBluetoothHeadset else { return nil }
        return inputs.first(where: \.isBuiltIn) ?? inputs.first(where: { !$0.isBluetoothHeadset })
    }
}
