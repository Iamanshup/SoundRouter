import CoreAudio
import Foundation

struct CAError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed (OSStatus \(status))" }
}

@inline(__always)
func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CAError(what: what, status: status) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

enum CA {
    static func has(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var addr = addr
        return AudioObjectHasProperty(obj, &addr)
    }

    static func settable(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var addr = addr
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(obj, &addr),
              AudioObjectIsPropertySettable(obj, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func get<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var addr = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func set<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var addr = addr
        var value = value
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(obj, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }

    static func array<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ zero: T) -> [T] {
        var addr = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        var values = [T](repeating: zero, count: count)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var addr = addr
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Registers a block listener on the main queue. Returns a token to remove it.
    @discardableResult
    static func listen(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress,
                       _ handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock? {
        var addr = addr
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(obj, &addr, DispatchQueue.main, block)
        return status == noErr ? block : nil
    }
}
