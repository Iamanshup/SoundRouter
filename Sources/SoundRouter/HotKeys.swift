import AppKit
import Carbon.HIToolbox

/// A key combination: Carbon key code and modifiers, plus how to show it.
struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt32   // Carbon: cmdKey | optionKey | controlKey | shiftKey
    var key: String         // e.g. "S", "↑", "F5"

    var label: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)

    static func from(_ event: NSEvent) -> KeyCombo {
        var m: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return KeyCombo(keyCode: Int(event.keyCode), modifiers: m, key: keyName(Int(event.keyCode), event))
    }

    private static func keyName(_ code: Int, _ event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[code] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    /// Function keys work alone; anything else needs ⌘, ⌥ or ⌃ so normal typing isn't hijacked.
    var isUsable: Bool {
        let fKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        return fKeys.contains(keyCode) || modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }
}

/// System-wide shortcuts via Carbon hot keys (no Accessibility permission needed).
@MainActor
final class HotKeys: ObservableObject {
    static let shared = HotKeys()

    enum Action: UInt32, CaseIterable, Identifiable {
        case switchSpeaker = 1, mute = 2, louder = 3, quieter = 4, openPanel = 5
        var id: UInt32 { rawValue }

        var title: String {
            switch self {
            case .switchSpeaker: return "Switch the Mac default speaker"
            case .mute: return "Mute or unmute an app"
            case .louder: return "Louder (up to 200%)"
            case .quieter: return "Quieter"
            case .openPanel: return "Open the SoundRouter panel"
            }
        }

        var defaultCombo: KeyCombo {
            switch self {
            case .switchSpeaker: return KeyCombo(keyCode: kVK_ANSI_S, modifiers: KeyCombo.defaultModifiers, key: "S")
            case .mute: return KeyCombo(keyCode: kVK_ANSI_M, modifiers: KeyCombo.defaultModifiers, key: "M")
            case .louder: return KeyCombo(keyCode: kVK_UpArrow, modifiers: KeyCombo.defaultModifiers, key: "↑")
            case .quieter: return KeyCombo(keyCode: kVK_DownArrow, modifiers: KeyCombo.defaultModifiers, key: "↓")
            case .openPanel: return KeyCombo(keyCode: kVK_ANSI_0, modifiers: KeyCombo.defaultModifiers, key: "0")
            }
        }
    }

    struct Shortcut {
        let id: UInt32
        let combo: KeyCombo
        let action: @MainActor () -> Void
    }

    static let modifierLabel = "⌃⌥⌘"

    /// User choices; a missing action uses its default, `nil` inside means "no shortcut".
    @Published private(set) var combos: [UInt32: KeyCombo?] = [:]
    /// The action whose shortcut is being recorded in Settings.
    @Published var recording: Action?

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var handler: EventHandlerRef?
    private(set) var registered: [Shortcut] = []
    private var lastShortcuts: [Shortcut] = []
    private var monitor: Any?

    init() {
        if let data = UserDefaults.standard.data(forKey: "hotkeys"),
           let saved = try? JSONDecoder().decode([String: KeyCombo?].self, from: data) {
            for (k, v) in saved { if let id = UInt32(k) { combos[id] = v } }
        }
    }

    func combo(for action: Action) -> KeyCombo? {
        if let choice = combos[action.rawValue] { return choice }
        return action.defaultCombo
    }

    func setCombo(_ combo: KeyCombo?, for action: Action) {
        // One combo, one action: take it away from any other action first.
        if let combo {
            for other in Action.allCases where other != action && self.combo(for: other) == combo { combos[other.rawValue] = .some(nil) }
        }
        combos[action.rawValue] = .some(combo)
        save()
    }

    func resetToDefaults() {
        combos = [:]
        save()
    }

    private func save() {
        let out = Dictionary(uniqueKeysWithValues: combos.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(out) { UserDefaults.standard.set(data, forKey: "hotkeys") }
        register(lastShortcuts.isEmpty ? [] : rebuild())
        onChange?()
    }

    var onChange: (() -> Void)?
    private var builder: (() -> [Shortcut])?

    private func rebuild() -> [Shortcut] { builder?() ?? [] }

    func shortcuts(for model: AudioModel, openPanel: @escaping @MainActor () -> Void) -> [Shortcut] {
        builder = { [unowned self] in self.makeShortcuts(model, openPanel) }
        return makeShortcuts(model, openPanel)
    }

    private func makeShortcuts(_ model: AudioModel, _ openPanel: @escaping @MainActor () -> Void) -> [Shortcut] {
        var list: [Shortcut] = []
        let handlers: [Action: @MainActor () -> Void] = [
            .switchSpeaker: { model.cycleDefaultSpeaker() },
            .mute: { model.toggleMuteFrontmost() },
            .louder: { model.nudgeFrontmostVolume(by: 0.1) },
            .quieter: { model.nudgeFrontmostVolume(by: -0.1) },
            .openPanel: openPanel,
        ]
        for action in Action.allCases {
            if let combo = combo(for: action), let run = handlers[action] { list.append(Shortcut(id: action.rawValue, combo: combo, action: run)) }
        }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, code) in digits.enumerated() {
            list.append(Shortcut(id: UInt32(10 + i), combo: KeyCombo(keyCode: code, modifiers: KeyCombo.defaultModifiers, key: "\(i + 1)")) {
                model.applyPreset(at: i)
            })
        }
        return list
    }

    /// Registers the shortcuts; returns how many macOS accepted.
    @discardableResult
    func register(_ shortcuts: [Shortcut]) -> Int {
        unregisterAll()
        lastShortcuts = shortcuts
        installHandlerIfNeeded()
        for s in shortcuts {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5352_4F55), id: s.id) // 'SROU'
            if RegisterEventHotKey(UInt32(s.combo.keyCode), s.combo.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[s.id] = s.action
                registered.append(s)
            }
        }
        return refs.count
    }

    func unregister() {
        unregisterAll()
        lastShortcuts = []
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        registered = []
    }

    /// Runs a shortcut's action as if it had been pressed (used by tests).
    func trigger(_ id: UInt32) { actions[id]?() }

    // MARK: Recording a new combo in Settings

    func startRecording(_ action: Action) {
        stopRecording()
        recording = action
        let paused = lastShortcuts
        unregisterAll()   // so pressing an existing combo records it instead of firing it
        lastShortcuts = paused
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let action = self.recording else { return event }
                switch Int(event.keyCode) {
                case kVK_Escape:
                    self.stopRecording()
                case kVK_Delete:
                    self.stopRecording()
                    self.setCombo(nil, for: action)
                default:
                    let combo = KeyCombo.from(event)
                    guard combo.isUsable else { NSSound.beep(); return nil }
                    self.stopRecording()
                    self.setCombo(combo, for: action)
                }
                return nil
            }
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil {
            recording = nil
            if !lastShortcuts.isEmpty { register(rebuild()) }
        }
    }

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
