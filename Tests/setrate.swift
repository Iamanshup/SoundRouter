// Usage: setrate <device name substring> [rate]   — prints the device's nominal rate, optionally setting it first.
import CoreAudio
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
let want = CommandLine.arguments[1]
for id in ids {
    var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &n, &name) == noErr, let str = name?.takeRetainedValue() as String?, str.contains(want) else { continue }
    var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    if CommandLine.arguments.count > 2 {
        var r = Float64(CommandLine.arguments[2])!
        AudioObjectSetPropertyData(id, &rateAddr, 0, nil, 8, &r)
        usleep(300_000)
    }
    var rate: Float64 = 0
    var rs = UInt32(8)
    AudioObjectGetPropertyData(id, &rateAddr, 0, nil, &rs, &rate)
    print(Int(rate))
    exit(0)
}
print("not found"); exit(1)
