import AppKit

/// `soundrouter://` links, for Shortcuts ("Open URLs"), Focus modes, scripts and launchers.
///
///   soundrouter://preset/Work              apply a preset (by name or number)
///   soundrouter://speaker/AirPods          make a speaker the Mac default
///   soundrouter://alerts/MacBook           alerts speaker ("default" = follow the Mac default)
///   soundrouter://app/Spotify?speaker=WH-1000XM5&volume=80&mute=0
///                                          an app's speaker ("default" too), volume (0–200) and mute (0, 1, toggle)
///   soundrouter://ducking/on               lower other apps during calls: on, off or toggle
///   soundrouter://panel                    open the menu bar panel
///   soundrouter://window                   open the SoundRouter window
@MainActor
extension AudioModel {
    /// Runs a link; returns a short description of what happened (or what went wrong).
    @discardableResult
    func handle(_ url: URL, openPanel: () -> Void = {}, openWindow: () -> Void = {}) -> String {
        guard url.scheme?.lowercased() == "soundrouter" else { return "Not a SoundRouter link" }
        let command = (url.host ?? "").lowercased()
        let argument = url.pathComponents.dropFirst().joined(separator: "/").removingPercentEncoding ?? ""
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name.lowercased(), $0.value ?? "") })

        func speaker(_ name: String) -> OutputDevice? {
            let n = name.lowercased()
            return devices.first { $0.name.lowercased() == n } ?? devices.first { $0.name.lowercased().contains(n) }
        }

        switch command {
        case "preset":
            if let number = Int(argument), presets.indices.contains(number - 1) {
                applyPreset(presets[number - 1].id)
                return "Applied preset \(presets[number - 1].name)"
            }
            guard let preset = presets.first(where: { $0.name.lowercased() == argument.lowercased() }) else {
                return report("No preset named “\(argument)”")
            }
            applyPreset(preset.id)
            return "Applied preset \(preset.name)"

        case "speaker", "default":
            guard let target = speaker(argument) else { return report("No speaker matching “\(argument)”") }
            makeDefault(target)
            HUD.show("Mac default: \(target.name)", symbol: target.symbol)
            return "Mac default: \(target.name)"

        case "alerts":
            if ["default", "mac default", ""].contains(argument.lowercased()) {
                setAlertsDevice(nil)
                HUD.show("Alerts follow the Mac default", symbol: "bell.fill")
                return "Alerts follow the Mac default"
            }
            guard let target = speaker(argument) else { return report("No speaker matching “\(argument)”") }
            setAlertsDevice(target.uid)
            HUD.show("Alerts: \(target.name)", symbol: "bell.fill")
            return "Alerts: \(target.name)"

        case "app":
            let n = argument.lowercased()
            let known = apps.map { ($0.id, $0.name) } + pinnedApps.map { ($0.key, $0.value) } + rules.compactMap { k, v in v.name.map { (k, $0) } }
            let match = known.first { $0.0.lowercased() == n || $0.1.lowercased() == n } ?? known.first { $0.1.lowercased().contains(n) }
            guard let (id, name) = match else { return report("No app matching “\(argument)”") }
            let app = apps.first { $0.id == id } ?? AudioApp(id: id, name: name, pid: 0, processObjects: [], isPlaying: false, isRegularApp: true)
            var done: [String] = []
            if let s = query["speaker"] {
                if ["default", "mac default"].contains(s.lowercased()) { setDevice(nil, for: app); done.append("Mac default") }
                else if let target = speaker(s) { setDevice(target.uid, for: app); done.append(target.name) }
                else { return report("No speaker matching “\(s)”") }
            }
            if let v = query["volume"], let percent = Float(v) {
                setVolume(max(0, min(200, percent)) / 100, for: app)
                done.append("\(Int(max(0, min(200, percent))))%")
            }
            if let m = query["mute"] {
                let current = rule(for: id).muted
                let want = m == "toggle" ? !current : (m == "1" || m.lowercased() == "true")
                if want != current { toggleMute(for: app) }
                done.append(want ? "muted" : "unmuted")
            }
            let text = "\(name): " + (done.isEmpty ? "nothing to change" : done.joined(separator: ", "))
            HUD.show(text)
            return text

        case "ducking":
            switch argument.lowercased() {
            case "on": duckingEnabled = true
            case "off": duckingEnabled = false
            default: duckingEnabled.toggle()
            }
            let text = "Lower apps during calls: \(duckingEnabled ? "on" : "off")"
            HUD.show(text, symbol: "phone.fill")
            return text

        case "panel":
            openPanel()
            return "Opened the panel"

        case "window":
            openWindow()
            return "Opened the window"

        default:
            return report("Unknown SoundRouter link: \(url.absoluteString)")
        }
    }

    private func report(_ message: String) -> String {
        HUD.show(message, symbol: "exclamationmark.triangle.fill")
        NSLog("SoundRouter: \(message)")
        return message
    }
}
