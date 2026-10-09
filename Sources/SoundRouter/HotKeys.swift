import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts via Carbon hot keys (no Accessibility permission needed).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    struct Shortcut {
        let id: UInt32
        let keyCode: Int
        let keyLabel: String
        let title: String
        let action: @MainActor () -> Void
    }

    /// ⌃⌥⌘ — unlikely to clash with app shortcuts.
    static let modifierLabel = "⌃⌥⌘"
    private let modifiers = UInt32(controlKey | optionKey | cmdKey)
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var handler: EventHandlerRef?
    private(set) var registered: [Shortcut] = []

    func shortcuts(for model: AudioModel, openPanel: @escaping @MainActor () -> Void) -> [Shortcut] {
        var list: [Shortcut] = [
            Shortcut(id: 1, keyCode: kVK_ANSI_S, keyLabel: "S", title: "Switch Mac default speaker") { model.cycleDefaultSpeaker() },
            Shortcut(id: 2, keyCode: kVK_ANSI_M, keyLabel: "M", title: "Mute or unmute the app in front") { model.toggleMuteFrontmost() },
            Shortcut(id: 3, keyCode: kVK_UpArrow, keyLabel: "↑", title: "Louder: app in front") { model.nudgeFrontmostVolume(by: 0.1) },
            Shortcut(id: 4, keyCode: kVK_DownArrow, keyLabel: "↓", title: "Quieter: app in front") { model.nudgeFrontmostVolume(by: -0.1) },
            Shortcut(id: 5, keyCode: kVK_ANSI_0, keyLabel: "0", title: "Open the SoundRouter panel", action: openPanel),
        ]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, code) in digits.enumerated() {
            list.append(Shortcut(id: UInt32(10 + i), keyCode: code, keyLabel: "\(i + 1)", title: "Apply preset \(i + 1)") {
                model.applyPreset(at: i)
            })
        }
        return list
    }

    /// Registers the shortcuts; returns how many macOS accepted.
    @discardableResult
    func register(_ shortcuts: [Shortcut]) -> Int {
        unregister()
        installHandlerIfNeeded()
        for s in shortcuts {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5352_4F55), id: s.id) // 'SROU'
            if RegisterEventHotKey(UInt32(s.keyCode), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[s.id] = s.action
                registered.append(s)
            }
        }
        return refs.count
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        registered = []
    }

    /// Runs a shortcut's action as if it had been pressed (used by tests).
    func trigger(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.trigger(id) } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
