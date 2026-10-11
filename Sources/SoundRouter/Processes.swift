import AppKit
import CoreAudio
import Darwin

/// An application (with all of its helper processes) known to the audio server.
struct AudioApp: Identifiable, Hashable {
    let id: String              // bundle identifier, or "pid:<n>"
    let name: String
    let pid: pid_t
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
    var isRegularApp: Bool
    /// Using a microphone (or other input) right now, e.g. in a call.
    var isRecording = false

    var icon: NSImage? {
        if pid > 0, let icon = NSRunningApplication(processIdentifier: pid)?.icon { return icon }
        // Pinned apps that aren't running.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsibleFn: ResponsibleFn? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

/// Browsers play audio from helper / XPC processes (Chrome Helper, WebKit GPU process...).
/// The "responsible" pid maps those back to the app the user actually sees.
func responsiblePID(_ pid: pid_t) -> pid_t {
    guard let fn = responsibleFn else { return pid }
    let r = fn(pid)
    return r > 0 ? r : pid
}

func processName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    proc_name(pid, &buf, UInt32(buf.count))
    return String(cString: buf)
}

enum ProcessManager {
    static func audioApps() -> [AudioApp] {
        let me = getpid()
        let objects = CA.array(systemObject, address(kAudioHardwarePropertyProcessObjectList), AudioObjectID(0))
        var apps: [String: AudioApp] = [:]
        for obj in objects {
            guard let pid = CA.get(obj, address(kAudioProcessPropertyPID), pid_t(0)), pid > 0, pid != me else { continue }
            let playing = (CA.get(obj, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0
            let recording = (CA.get(obj, address(kAudioProcessPropertyIsRunningInput), UInt32(0)) ?? 0) != 0
            let ownerPID = responsiblePID(pid)
            guard ownerPID != me else { continue }
            let owner = NSRunningApplication(processIdentifier: ownerPID) ?? NSRunningApplication(processIdentifier: pid)
            let bundleID = owner?.bundleIdentifier ?? CA.string(obj, address(kAudioProcessPropertyBundleID))
            let key = (bundleID?.isEmpty == false) ? bundleID! : "pid:\(ownerPID)"
            guard key != Bundle.main.bundleIdentifier else { continue }
            let name = owner?.localizedName ?? processName(ownerPID)
            if var existing = apps[key] {
                existing.processObjects.append(obj)
                existing.isPlaying = existing.isPlaying || playing
                existing.isRecording = existing.isRecording || recording
                apps[key] = existing
            } else {
                apps[key] = AudioApp(id: key, name: name.isEmpty ? key : name, pid: owner?.processIdentifier ?? ownerPID,
                                     processObjects: [obj], isPlaying: playing,
                                     isRegularApp: owner?.activationPolicy == .regular, isRecording: recording)
            }
        }
        return apps.values.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
