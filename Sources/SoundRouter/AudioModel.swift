import AppKit
import Combine
import CoreAudio
import ServiceManagement
import SwiftUI

/// Per-app setting. `deviceUID == nil` means "follow the Mac default speaker".
/// New fields are optional so rules saved by older versions still decode.
struct AppRule: Codable, Equatable {
    var deviceUID: String?
    var volume: Float = 1
    var muted = false
    var name: String?
    /// Further speakers that play the same audio.
    var extraDeviceUIDs: [String]?
    /// -1 (left) … 0 … +1 (right).
    var balance: Float?

    var extras: [String] { extraDeviceUIDs ?? [] }
    var pan: Float { balance ?? 0 }

    /// Nothing to do: plays on the Mac default, untouched.
    var isNeutral: Bool {
        deviceUID == nil && abs(volume - 1) < 0.001 && !muted && extras.isEmpty && abs(pan) < 0.001
    }
}

/// A browser tab whose audio the extension captures and streams to us.
struct TabRoute: Equatable {
    var deviceUID: String
    var extras: [String] = []
    var volume: Float = 1
    var balance: Float = 0
    var muted = false
}

/// A remembered speaker for a website, applied when the extension is opened on its tabs.
struct SiteRule: Codable, Equatable {
    var deviceUID: String
    var extraDeviceUIDs: [String] = []
    var volume: Float = 1
}

/// A saved setup: every app's speaker and volume, the Mac default and the alerts speaker.
struct Preset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var rules: [String: AppRule]
    var defaultUID: String?
    var alerts: String   // see AudioModel.alertsSetting
}

/// "When <device> connects / disconnects, do <action>".
struct Automation: Codable, Equatable, Identifiable {
    var id = UUID()
    var deviceUID: String
    var deviceName: String
    var onConnect = true
    var makeDefault = false
    var presetID: UUID?
}

@MainActor
final class AudioModel: ObservableObject {
    static let shared = AudioModel()

    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var rules: [String: AppRule] = [:]
    @Published private(set) var routeErrors: [String: String] = [:]
    @Published private(set) var levels: [String: Float] = [:]
    @Published var showBackgroundProcesses = UserDefaults.standard.bool(forKey: "showBackground") {
        didSet { UserDefaults.standard.set(showBackgroundProcesses, forKey: "showBackground") }
    }

    @Published private(set) var inputs: [InputDevice] = []
    /// Latest thing the headset guard did, shown under the Microphones section.
    @Published private(set) var micNotice: String?
    @Published var keepHeadphonesHighQuality = UserDefaults.standard.bool(forKey: "keepHeadphonesHighQuality") {
        didSet {
            UserDefaults.standard.set(keepHeadphonesHighQuality, forKey: "keepHeadphonesHighQuality")
            if keepHeadphonesHighQuality { micNotice = nil; enforceHeadsetGuard() }
        }
    }

    /// "" = leave alerts to macOS, "default" = follow the Mac default, otherwise a speaker uid.
    @Published private(set) var alertsSetting = UserDefaults.standard.string(forKey: "alertsSetting") ?? ""
    /// Per-speaker delay in ms, applied when audio plays on several speakers at once.
    @Published private(set) var speakerDelays: [String: Float] = UserDefaults.standard.dictionary(forKey: "speakerDelays") as? [String: Float] ?? [:]
    @Published private(set) var presets: [Preset] = AudioModel.load("presets") ?? []
    @Published private(set) var automations: [Automation] = AudioModel.load("automations") ?? []
    @Published private(set) var siteRules: [String: SiteRule] = AudioModel.load("siteRules") ?? [:]
    @Published var rememberSites = UserDefaults.standard.object(forKey: "rememberSites") as? Bool ?? true {
        didSet { UserDefaults.standard.set(rememberSites, forKey: "rememberSites") }
    }
    @Published var shortcutsEnabled = UserDefaults.standard.object(forKey: "shortcutsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(shortcutsEnabled, forKey: "shortcutsEnabled")
            onShortcutsChanged?()
        }
    }
    /// Names of every speaker seen, so automations can target ones that aren't connected now.
    @Published private(set) var knownDevices: [String: String] = UserDefaults.standard.dictionary(forKey: "knownDevices") as? [String: String] ?? [:]
    var onShortcutsChanged: (() -> Void)?

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var tabRoutes: [String: TabRoute] = [:]
    @Published private(set) var tabErrors: [String: String] = [:]
    @Published private(set) var browserConnections: [Int: String] = [:]   // connection -> browser name
    @Published var showAllTabs = false

    private let bridge = BrowserBridge()
    /// Keyed "<tab key>|<speaker uid>".
    private var tabPlayers: [String: TabPlayer] = [:]
    private var tabStreamRates: [String: Double] = [:]
    private var routedTabKeys: Set<String> = []
    private var capturedTabs: Set<String> = []
    /// Stopping Core Audio objects can block; never do it on the main thread.
    private let teardown = DispatchQueue(label: "SoundRouter.teardown")
    private var devicesInitialized = false
    private var softwareVolumes: [String: Float] = [:]
    /// Speaker uid -> palette index, persisted so a speaker keeps its colour.
    private var speakerColors: [String: Int] = UserDefaults.standard.dictionary(forKey: "speakerColors") as? [String: Int] ?? [:]
    /// Keyed "<app id>|<speaker uid>".
    private var routers: [String: TapRouter] = [:]
    private var refreshScheduled = false
    private var timer: Timer?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "rules"),
           let saved = try? JSONDecoder().decode([String: AppRule].self, from: data) {
            rules = saved
        }
        softwareVolumes = UserDefaults.standard.dictionary(forKey: "softwareVolumes") as? [String: Float] ?? [:]

        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioHardwarePropertyProcessObjectList] {
            CA.listen(systemObject, address(selector)) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        CA.listen(systemObject, address(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in
            MainActor.assumeIsolated {
                self?.inputs = InputManager.inputDevices()
                self?.enforceHeadsetGuard()
            }
        }
        bridge.onMessage = { [weak self] conn, msg in MainActor.assumeIsolated { self?.handleBridge(conn, msg) } }
        bridge.onDisconnect = { [weak self] conn in MainActor.assumeIsolated { self?.browserDisconnected(conn) } }
        bridge.start()
        refresh()
        // Volumes changed elsewhere (keyboard keys, other apps), "is playing" flags and meters.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Persistence helpers

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: Queries

    func nsColor(for uid: String?) -> NSColor {
        guard let uid, let index = speakerColors[uid] else { return Theme.neutral }
        return Theme.nsPalette[index % Theme.nsPalette.count]
    }

    func color(for uid: String?) -> Color { Color(nsColor: nsColor(for: uid)) }

    private func assignColors(_ list: [OutputDevice]) {
        var changed = false
        for device in list where speakerColors[device.uid] == nil {
            let used = Set(speakerColors.values)
            speakerColors[device.uid] = (0..<Theme.nsPalette.count).first { !used.contains($0) } ?? speakerColors.count
            changed = true
        }
        if changed { UserDefaults.standard.set(speakerColors, forKey: "speakerColors") }
    }

    /// Apps worth showing up front: playing, routed / customised, or with tabs playing or routed.
    var nowPlaying: [AudioApp] {
        visibleApps.filter { app in
            app.isPlaying || rules[app.id] != nil
                || (isBrowser(app) && tabs(for: app).contains { $0.audible || tabRoutes[$0.id] != nil })
        }
    }

    var otherApps: [AudioApp] {
        let shown = Set(nowPlaying.map(\.id))
        return visibleApps.filter { !shown.contains($0.id) }
    }

    var visibleApps: [AudioApp] {
        apps.filter { showBackgroundProcesses || $0.isRegularApp || $0.isPlaying || rules[$0.id] != nil }
    }

    /// Rules for apps that aren't currently running, so they can still be edited / removed.
    var dormantRules: [(String, AppRule)] {
        let running = Set(apps.map(\.id))
        return rules.filter { !running.contains($0.key) }.sorted { $0.key < $1.key }
    }

    func rule(for appID: String) -> AppRule { rules[appID] ?? AppRule() }

    func isRouted(_ appID: String) -> Bool { routers.keys.contains { $0.hasPrefix(appID + "|") } }

    var defaultDevice: OutputDevice? { devices.first(where: \.isDefault) }

    func device(_ uid: String?) -> OutputDevice? { uid.flatMap { u in devices.first { $0.uid == u } } }

    func deviceName(_ uid: String) -> String { device(uid)?.name ?? knownDevices[uid] ?? "Unknown speaker" }

    func delay(for uid: String) -> Float { speakerDelays[uid] ?? 0 }

    // MARK: Per-app actions

    func setDevice(_ uid: String?, for app: AudioApp) {
        updateRule(app.id, name: app.name) { $0.deviceUID = uid }
    }

    func setVolume(_ volume: Float, for app: AudioApp) {
        updateRule(app.id, name: app.name) { $0.volume = volume }
    }

    func toggleMute(for app: AudioApp) {
        updateRule(app.id, name: app.name) { $0.muted.toggle() }
    }

    func setBalance(_ balance: Float, for app: AudioApp) {
        updateRule(app.id, name: app.name) { $0.balance = abs(balance) < 0.04 ? nil : balance }
    }

    /// Adds or removes an extra speaker for an app.
    func toggleExtraDevice(_ uid: String, for app: AudioApp) {
        updateRule(app.id, name: app.name) { rule in
            var extras = rule.extras
            if let i = extras.firstIndex(of: uid) { extras.remove(at: i) } else { extras.append(uid) }
            rule.extraDeviceUIDs = extras.isEmpty ? nil : extras
        }
    }

    func removeRule(_ appID: String) {
        rules[appID] = nil
        saveRules()
        reconcile()
    }

    func resetAll() {
        rules = [:]
        saveRules()
        reconcile()
    }

    private func updateRule(_ id: String, name: String, _ change: (inout AppRule) -> Void) {
        var rule = rules[id] ?? AppRule()
        change(&rule)
        rule.name = name
        rules[id] = rule.isNeutral ? nil : rule
        saveRules()
        reconcile()
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "rules") }
    }

    // MARK: Device actions

    func setVolume(_ volume: Float, for device: OutputDevice) {
        if device.hasHardwareVolume {
            DeviceManager.setHardwareVolume(device.id, volume)
        } else {
            softwareVolumes[device.uid] = volume
            UserDefaults.standard.set(softwareVolumes, forKey: "softwareVolumes")
        }
        if let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i].volume = volume }
        applyGains()
        applyTabGains()
    }

    func toggleMute(for device: OutputDevice) {
        if DeviceManager.canMute(device.id) {
            DeviceManager.setMuted(device.id, !device.muted)
        }
        if let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i].muted.toggle() }
        applyGains()
        applyTabGains()
    }

    func makeDefault(_ device: OutputDevice) {
        DeviceManager.setDefaultOutput(device.id)
        scheduleRefresh()
    }

    func setBalance(_ value: Float, for device: OutputDevice) {
        DeviceManager.setBalance(device.id, value)
        if let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i].balance = value }
    }

    func setDelay(_ ms: Float, for device: OutputDevice) {
        speakerDelays[device.uid] = ms < 1 ? nil : ms
        UserDefaults.standard.set(speakerDelays, forKey: "speakerDelays")
        applyGains()
        applyTabGains()
    }

    // MARK: Alert sounds

    /// The speaker alerts actually play on right now.
    var alertsDevice: OutputDevice? { devices.first(where: \.isAlertOutput) }

    /// nil = follow the Mac default; a uid = that speaker.
    func setAlertsDevice(_ uid: String?) {
        alertsSetting = uid ?? "default"
        UserDefaults.standard.set(alertsSetting, forKey: "alertsSetting")
        enforceAlerts()
    }

    private func enforceAlerts() {
        guard !alertsSetting.isEmpty, let fallback = defaultDevice else { return }
        let target = alertsSetting == "default" ? fallback : (device(alertsSetting) ?? fallback)
        if DeviceManager.systemOutputID() != target.id {
            DeviceManager.setSystemOutput(target.id)
            devices = DeviceManager.outputDevices(softwareVolumes: softwareVolumes)
        }
    }

    // MARK: Presets

    func savePreset(named name: String) {
        presets.append(Preset(name: name, rules: rules, defaultUID: defaultDevice?.uid, alerts: alertsSetting))
        store(presets, "presets")
        onShortcutsChanged?()
    }

    func updatePreset(_ id: UUID) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].rules = rules
        presets[i].defaultUID = defaultDevice?.uid
        presets[i].alerts = alertsSetting
        store(presets, "presets")
    }

    func renamePreset(_ id: UUID, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        presets[i].name = name
        store(presets, "presets")
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        for i in automations.indices where automations[i].presetID == id { automations[i].presetID = nil }
        store(presets, "presets")
        store(automations, "automations")
    }

    func movePreset(_ id: UUID, by offset: Int) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(presets.count - 1, i + offset))
        presets.swapAt(i, j)
        store(presets, "presets")
    }

    func applyPreset(_ id: UUID, announce: Bool = true) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        rules = preset.rules
        saveRules()
        if let uid = preset.defaultUID, let target = device(uid), !target.isDefault {
            DeviceManager.setDefaultOutput(target.id)
            devices = DeviceManager.outputDevices(softwareVolumes: softwareVolumes)
        }
        alertsSetting = preset.alerts
        UserDefaults.standard.set(alertsSetting, forKey: "alertsSetting")
        enforceAlerts()
        reconcile()
        if announce { HUD.show("Preset: \(preset.name)", symbol: "square.stack.3d.up.fill") }
    }

    func applyPreset(at index: Int) {
        guard presets.indices.contains(index) else {
            HUD.show("No preset \(index + 1)", symbol: "square.stack.3d.up.slash")
            return
        }
        applyPreset(presets[index].id)
    }

    /// The preset matching the current setup, if any.
    var activePresetID: UUID? {
        presets.first { $0.rules == rules && ($0.defaultUID == nil || $0.defaultUID == defaultDevice?.uid) }?.id
    }

    // MARK: Automations

    func addAutomation(_ automation: Automation) {
        automations.append(automation)
        store(automations, "automations")
    }

    func updateAutomation(_ automation: Automation) {
        guard let i = automations.firstIndex(where: { $0.id == automation.id }) else { return }
        automations[i] = automation
        store(automations, "automations")
    }

    func deleteAutomation(_ id: UUID) {
        automations.removeAll { $0.id == id }
        store(automations, "automations")
    }

    private func runAutomations(connected: Set<String>, disconnected: Set<String>) {
        for automation in automations {
            let fired = automation.onConnect ? connected.contains(automation.deviceUID) : disconnected.contains(automation.deviceUID)
            guard fired else { continue }
            var did: [String] = []
            // Preset first, so the automation's own "make default" wins over the preset's saved default.
            if let presetID = automation.presetID, let preset = presets.first(where: { $0.id == presetID }) {
                applyPreset(presetID, announce: false)
                did.append("applied \(preset.name)")
            }
            if automation.makeDefault, automation.onConnect, let target = device(automation.deviceUID) {
                DeviceManager.setDefaultOutput(target.id)
                devices = DeviceManager.outputDevices(softwareVolumes: softwareVolumes)
                enforceAlerts()
                reconcile()
                did.insert("made it the Mac default", at: 0)
            }
            if !did.isEmpty {
                HUD.show("\(automation.deviceName) \(automation.onConnect ? "connected" : "disconnected"): \(did.joined(separator: ", "))",
                         symbol: automation.onConnect ? "link" : "link.badge.plus")
            }
        }
    }

    // MARK: Shortcut actions

    func cycleDefaultSpeaker() {
        guard !devices.isEmpty else { return }
        let i = devices.firstIndex(where: \.isDefault) ?? -1
        let next = devices[(i + 1) % devices.count]
        DeviceManager.setDefaultOutput(next.id)
        devices = DeviceManager.outputDevices(softwareVolumes: softwareVolumes)
        enforceAlerts()
        reconcile()
        reconcileTabs()
        HUD.show("Mac default: \(next.name)", symbol: next.symbol)
    }

    /// The app in front, as a rule key and display name.
    private func frontmostApp() -> (id: String, name: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let id = app.bundleIdentifier else { return nil }
        return (id, app.localizedName ?? id)
    }

    func toggleMuteFrontmost() {
        guard let (id, name) = frontmostApp() else { return }
        updateRule(id, name: name) { $0.muted.toggle() }
        let muted = rules[id]?.muted ?? false
        HUD.show("\(name) \(muted ? "muted" : "unmuted")", symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }

    func nudgeFrontmostVolume(by delta: Float) {
        guard let (id, name) = frontmostApp() else { return }
        updateRule(id, name: name) { rule in
            rule.volume = max(0, min(2, ((rule.volume + delta) * 10).rounded() / 10))
            rule.muted = false
        }
        let volume = rules[id]?.volume ?? 1
        HUD.show("\(name) \(Int((volume * 100).rounded()))%", symbol: volume > 1 ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
    }

    // MARK: Microphones

    func makeDefault(_ input: InputDevice) {
        if input.isBluetoothHeadset && keepHeadphonesHighQuality {
            // An explicit choice wins over the automatic guard.
            keepHeadphonesHighQuality = false
            micNotice = "Turned off “Keep headphones in high quality” because you chose \(input.name)’s mic."
        }
        InputManager.setDefaultInput(input.id)
        inputs = InputManager.inputDevices()
    }

    func setVolume(_ volume: Float, for input: InputDevice) {
        DeviceManager.setHardwareVolume(input.id, volume, scope: kAudioObjectPropertyScopeInput)
        if let i = inputs.firstIndex(where: { $0.id == input.id }) { inputs[i].volume = volume }
    }

    func toggleMute(for input: InputDevice) {
        DeviceManager.setMuted(input.id, !input.muted, scope: kAudioObjectPropertyScopeInput)
        if let i = inputs.firstIndex(where: { $0.id == input.id }) { inputs[i].muted.toggle() }
    }

    /// If macOS (or another app) made a Bluetooth headset the system mic, move it back to
    /// the Mac's own mic so the headset keeps playing in high quality.
    private func enforceHeadsetGuard() {
        guard keepHeadphonesHighQuality,
              let headset = inputs.first(where: \.isDefault),
              let target = InputManager.headsetGuardTarget(inputs) else { return }
        InputManager.setDefaultInput(target.id)
        inputs = InputManager.inputDevices()
        let time = Date().formatted(date: .omitted, time: .shortened)
        micNotice = "\(time): switched mic from \(headset.name) to \(target.name) to keep your headphones in high quality."
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    // MARK: Refresh / routing

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        inputs = InputManager.inputDevices()
        enforceHeadsetGuard()
        updateDevices(DeviceManager.outputDevices(softwareVolumes: softwareVolumes))
        enforceAlerts()
        apps = ProcessManager.audioApps()
        reconcile()
        reconcileTabs()
    }

    /// Records names and colours, and fires connect/disconnect automations.
    private func updateDevices(_ fresh: [OutputDevice]) {
        assignColors(fresh)
        var namesChanged = false
        for d in fresh where knownDevices[d.uid] != d.name {
            knownDevices[d.uid] = d.name
            namesChanged = true
        }
        if namesChanged { UserDefaults.standard.set(knownDevices, forKey: "knownDevices") }
        let old = Set(devices.map(\.uid)), new = Set(fresh.map(\.uid))
        devices = fresh
        if devicesInitialized && old != new {
            runAutomations(connected: new.subtracting(old), disconnected: old.subtracting(new))
        }
        devicesInitialized = true
    }

    private func tick() {
        let freshInputs = InputManager.inputDevices()
        if freshInputs != inputs { inputs = freshInputs }
        let fresh = DeviceManager.outputDevices(softwareVolumes: softwareVolumes)
        if fresh != devices {
            let deviceSetChanged = fresh.map(\.uid) != devices.map(\.uid)
            updateDevices(fresh)
            if deviceSetChanged { enforceAlerts(); reconcile(); reconcileTabs() } else { applyGains(); applyTabGains() }
        }
        let freshApps = ProcessManager.audioApps()
        if freshApps != apps {
            apps = freshApps
            reconcile()
        }
        var newLevels: [String: Float] = [:]
        for (key, router) in routers {
            let id = String(key[..<key.lastIndex(of: "|")!])
            newLevels[id] = max(newLevels[id] ?? 0, router.state.peak)
        }
        for (key, player) in tabPlayers {
            let id = "tab:" + key[..<key.lastIndex(of: "|")!]
            newLevels[id] = max(newLevels[id] ?? 0, player.state.peak)
        }
        if newLevels != levels { levels = newLevels }
    }

    /// The speakers SoundRouter should play an app on; empty to leave the app alone.
    private func targets(for rule: AppRule) -> [OutputDevice] {
        let base = device(rule.deviceUID) ?? defaultDevice
        let extras = rule.extras.compactMap(device).filter { $0.uid != base?.uid }
        guard let base else { return [] }
        if !extras.isEmpty { return physical([base] + extras) }
        if !base.isDefault { return physical([base]) }
        // On the Mac default: only intercept to apply volume, mute or balance.
        let needsProcessing = abs(rule.volume - 1) > 0.001 || rule.muted || abs(rule.pan) > 0.001
        return needsProcessing ? physical([base]) : []
    }

    /// Multi-output / aggregate devices can't be nested inside our routing device, so play on
    /// the real speakers they contain instead (each once).
    private func physical(_ list: [OutputDevice]) -> [OutputDevice] {
        var seen: Set<String> = []
        var out: [OutputDevice] = []
        for d in list {
            let parts = d.subDeviceUIDs.compactMap(device)
            for p in parts.isEmpty ? [d] : parts where seen.insert(p.uid).inserted { out.append(p) }
        }
        return out
    }

    private func gain(volume: Float, muted: Bool, on device: OutputDevice) -> Float {
        if muted { return 0 }
        var g = volume
        // Devices without a hardware volume control get a software one.
        if !device.hasHardwareVolume { g *= device.muted ? 0 : device.volume }
        return g
    }

    private func configure(_ state: IOState, volume: Float, muted: Bool, balance: Float, on device: OutputDevice, multi: Bool) {
        state.gain = gain(volume: volume, muted: muted, on: device)
        state.balance = balance
        let rate = CA.get(device.id, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 48000
        state.delayFrames = multi ? Int(Double(delay(for: device.uid)) / 1000 * rate) : 0
    }

    private func retire(_ router: TapRouter?) {
        guard let router else { return }
        teardown.async { router.stop() }
    }

    private func retire(_ player: TabPlayer?) {
        guard let player else { return }
        teardown.async { player.stop() }
    }

    private func reconcile() {
        var wanted: Set<String> = []
        var errors: [String: String] = [:]
        for app in apps {
            guard let rule = rules[app.id] else { continue }
            let targets = targets(for: rule)
            let objects = app.processObjects.sorted()
            for device in targets {
                let key = app.id + "|" + device.uid
                wanted.insert(key)
                if let existing = routers[key], existing.processObjects == objects {
                    configure(existing.state, volume: rule.volume, muted: rule.muted, balance: rule.pan, on: device, multi: targets.count > 1)
                    continue
                }
                retire(routers.removeValue(forKey: key))
                do {
                    let router = try TapRouter(name: app.name, processObjects: objects, deviceUID: device.uid, gain: 0)
                    configure(router.state, volume: rule.volume, muted: rule.muted, balance: rule.pan, on: device, multi: targets.count > 1)
                    routers[key] = router
                } catch {
                    errors[app.id] = "\(error)"
                    NSLog("SoundRouter: routing \(app.name) to \(device.name) failed: \(error)")
                }
            }
        }
        for key in routers.keys where !wanted.contains(key) {
            retire(routers.removeValue(forKey: key))
        }
        if errors != routeErrors { routeErrors = errors }
    }

    private func applyGains() {
        for app in apps {
            guard let rule = rules[app.id] else { continue }
            let targets = targets(for: rule)
            for device in targets {
                guard let router = routers[app.id + "|" + device.uid] else { continue }
                configure(router.state, volume: rule.volume, muted: rule.muted, balance: rule.pan, on: device, multi: targets.count > 1)
            }
        }
    }

    func shutdown() {
        // Taps and aggregate devices die with the process anyway; don't hang quitting.
        let done = DispatchGroup()
        for router in routers.values { done.enter(); teardown.async { router.stop(); done.leave() } }
        for player in tabPlayers.values { done.enter(); teardown.async { player.stop(); done.leave() } }
        routers = [:]
        tabPlayers = [:]
        _ = done.wait(timeout: .now() + 2)
    }

    // MARK: Browser tabs

    /// Tabs belonging to a browser app row, matched by name ("Google Chrome", "Brave Browser"...).
    func tabs(for app: AudioApp) -> [BrowserTab] {
        let conns = Set(browserConnections.filter { Self.browser($0.value, matches: app.name) }.keys)
        return visible(tabs.filter { conns.contains($0.connection) })
    }

    /// Browsers with the extension connected but no matching app row.
    var unmatchedBrowsers: [(name: String, tabs: [BrowserTab])] {
        let shown = Set(visibleApps.map(\.name))
        return browserConnections.sorted { $0.key < $1.key }.compactMap { conn, name in
            guard !shown.contains(where: { Self.browser(name, matches: $0) }) else { return nil }
            return (name, visible(tabs.filter { $0.connection == conn }))
        }
    }

    func isBrowser(_ app: AudioApp) -> Bool {
        browserConnections.values.contains { Self.browser($0, matches: app.name) }
    }

    private static func browser(_ brand: String, matches appName: String) -> Bool {
        let a = brand.lowercased(), b = appName.lowercased()
        return a == b || a.contains(b) || b.contains(a)
    }

    private func visible(_ tabs: [BrowserTab]) -> [BrowserTab] {
        showAllTabs ? tabs : tabs.filter { $0.audible || tabRoutes[$0.id] != nil || tabErrors[$0.id] != nil }
    }

    func setDevice(_ uid: String?, forTab tab: BrowserTab) {
        tabErrors[tab.id] = nil
        if let uid {
            var route = tabRoutes[tab.id] ?? TabRoute(deviceUID: uid)
            route.deviceUID = uid
            route.extras.removeAll { $0 == uid }
            tabRoutes[tab.id] = route
        } else {
            tabRoutes[tab.id] = nil
        }
        rememberSite(for: tab)
        reconcileTabs()
    }

    func setVolume(_ volume: Float, forTab tab: BrowserTab) {
        tabRoutes[tab.id]?.volume = volume
        rememberSite(for: tab)
        applyTabGains()
        broadcastState()
    }

    func setBalance(_ balance: Float, forTab tab: BrowserTab) {
        tabRoutes[tab.id]?.balance = abs(balance) < 0.04 ? 0 : balance
        applyTabGains()
    }

    func toggleMute(forTab tab: BrowserTab) {
        tabRoutes[tab.id]?.muted.toggle()
        applyTabGains()
        broadcastState()
    }

    func toggleExtraDevice(_ uid: String, forTab tab: BrowserTab) {
        guard var route = tabRoutes[tab.id] else { return }
        if let i = route.extras.firstIndex(of: uid) { route.extras.remove(at: i) } else if uid != route.deviceUID { route.extras.append(uid) }
        tabRoutes[tab.id] = route
        rememberSite(for: tab)
        reconcileTabs()
    }

    static func host(of url: String) -> String? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Remembered speaker for a tab's website, if any.
    func siteRule(for tab: BrowserTab) -> (host: String, rule: SiteRule)? {
        guard let host = Self.host(of: tab.url), let rule = siteRules[host] else { return nil }
        return (host, rule)
    }

    private func rememberSite(for tab: BrowserTab) {
        guard rememberSites, let host = Self.host(of: tab.url) else { return }
        if let route = tabRoutes[tab.id] {
            siteRules[host] = SiteRule(deviceUID: route.deviceUID, extraDeviceUIDs: route.extras, volume: route.volume)
        } else {
            siteRules[host] = nil
        }
        store(siteRules, "siteRules")
    }

    func forgetSite(_ host: String) {
        siteRules[host] = nil
        store(siteRules, "siteRules")
        broadcastState()
    }

    func setSiteDevice(_ uid: String, for host: String) {
        siteRules[host]?.deviceUID = uid
        store(siteRules, "siteRules")
        broadcastState()
    }

    private func handleBridge(_ conn: Int, _ msg: [String: Any]) {
        let tabID = (msg["tabId"] as? NSNumber)?.intValue
        let key = tabID.map { "\(conn)/\($0)" }
        switch msg["type"] as? String {
        case "hello":
            browserConnections[conn] = msg["browser"] as? String ?? "Browser"
            sendState(conn)
        case "tabs":
            let browser = browserConnections[conn] ?? "Browser"
            let incoming = (msg["tabs"] as? [[String: Any]] ?? []).compactMap { t -> BrowserTab? in
                guard let id = (t["id"] as? NSNumber)?.intValue else { return nil }
                return BrowserTab(connection: conn, tabID: id, browser: browser,
                                  title: t["title"] as? String ?? "Tab", url: t["url"] as? String ?? "",
                                  audible: t["audible"] as? Bool ?? false,
                                  favIconURL: t["favIconUrl"] as? String)
            }
            tabs = tabs.filter { $0.connection != conn } + incoming
            reconcileTabs()
        case "setRoute":   // chosen in the extension popup
            guard let key, let tab = tabs.first(where: { $0.id == key }) else { return }
            if let volume = (msg["volume"] as? NSNumber)?.floatValue {
                setVolume(volume, forTab: tab)
            } else if msg["fromSite"] as? Bool == true, let (_, site) = siteRule(for: tab) {
                // Re-applying a remembered website speaker, with its extras and volume.
                tabErrors[key] = nil
                tabRoutes[key] = TabRoute(deviceUID: site.deviceUID, extras: site.extraDeviceUIDs, volume: site.volume)
                reconcileTabs()
            } else {
                setDevice(msg["deviceUID"] as? String, forTab: tab)
            }
        case "forgetSite":
            if let host = msg["host"] as? String { forgetSite(host) }
        case "captured":
            if let key { capturedTabs.insert(key); tabErrors[key] = nil }
        case "captureFailed":
            guard let key else { return }
            capturedTabs.remove(key)
            tabRoutes[key] = nil
            let reason = msg["reason"] as? String ?? "unknown error"
            tabErrors[key] = reason.localizedCaseInsensitiveContains("invoked") || reason.localizedCaseInsensitiveContains("activeTab")
                ? "Click the SoundRouter extension button while this tab is open (once per tab), then choose again."
                : "Couldn't capture tab: \(reason)"
            reconcileTabs()
        case "debugStats":   // used by the bridge test script
            guard let key, let tab = tabs.first(where: { $0.id == key }) else { return }
            let stats = tabPlayerStats(key)
            let players = tabPlayers.filter { $0.key.hasPrefix(key + "|") }.map(\.value)
            let primary = tabRoutes[key].flatMap { tabPlayers[key + "|" + $0.deviceUID] } ?? players.first
            bridge.send(tab.connection, ["type": "debugStats", "tabId": tab.tabID,
                                         "callbacks": stats?.callbacks ?? 0, "peak": stats?.peak ?? 0,
                                         "device": primary?.deviceUID ?? "",
                                         "sampleRate": primary?.sampleRate ?? 0,
                                         "skips": primary?.skips ?? 0,
                                         "underruns": primary?.underruns ?? 0,
                                         "players": players.map { ["device": $0.deviceUID, "peak": $0.state.peak,
                                                                   "peakLeft": $0.state.peakLeft, "peakRight": $0.state.peakRight,
                                                                   "callbacks": $0.state.callbacks, "sampleRate": $0.sampleRate,
                                                                   "streamRate": $0.streamRate, "underruns": $0.underruns] }])
        case "captureEnded":
            guard let key else { return }
            capturedTabs.remove(key)
            tabRoutes[key] = nil
            reconcileTabs()
        default:
            break
        }
    }

    private func browserDisconnected(_ conn: Int) {
        browserConnections[conn] = nil
        tabs.removeAll { $0.connection == conn }
        let prefix = "\(conn)/"
        for key in tabRoutes.keys where key.hasPrefix(prefix) { tabRoutes[key] = nil }
        capturedTabs = capturedTabs.filter { !$0.hasPrefix(prefix) }
        tabErrors = tabErrors.filter { !$0.key.hasPrefix(prefix) }
        reconcileTabs()
    }

    private func tabTargets(_ route: TabRoute) -> [OutputDevice] {
        guard let base = device(route.deviceUID) ?? defaultDevice else { return [] }
        return physical([base] + route.extras.compactMap(device).filter { $0.uid != base.uid })
    }

    private func reconcileTabs() {
        let liveTabs = Set(tabs.map(\.id))
        for key in tabRoutes.keys where !liveTabs.contains(key) { tabRoutes[key] = nil }

        var wantedPlayers: Set<String> = []
        for (key, route) in tabRoutes {
            guard let tab = tabs.first(where: { $0.id == key }) else { continue }
            let targets = tabTargets(route)
            var players: [TabPlayer] = []
            for device in targets {
                let pkey = key + "|" + device.uid
                wantedPlayers.insert(pkey)
                let rate = CA.get(device.id, address(kAudioDevicePropertyNominalSampleRate), Float64(0))
                if let existing = tabPlayers[pkey], rate == nil || rate == existing.sampleRate {
                    configure(existing.state, volume: route.volume, muted: route.muted, balance: route.balance, on: device, multi: targets.count > 1)
                    players.append(existing)
                    continue
                }
                retire(tabPlayers.removeValue(forKey: pkey))
                do {
                    let player = try TabPlayer(device: device, gain: 0)
                    configure(player.state, volume: route.volume, muted: route.muted, balance: route.balance, on: device, multi: targets.count > 1)
                    // Rebuild at the new rate; the extension re-renders the same tab stream to match.
                    player.onSampleRateChange = { [weak self] in MainActor.assumeIsolated { self?.reconcileTabs() } }
                    tabPlayers[pkey] = player
                    players.append(player)
                } catch {
                    tabErrors[key] = "\(error)"
                }
            }
            guard let primary = players.first else { continue }
            // One stream from the browser, at the first speaker's rate; others resample.
            players.forEach { $0.streamRate = primary.sampleRate }
            bridge.setPlayers(players, for: key)
            if !capturedTabs.contains(key) || tabStreamRates[key] != primary.sampleRate {
                tabStreamRates[key] = primary.sampleRate
                bridge.send(tab.connection, ["type": "route", "tabId": tab.tabID, "sampleRate": primary.sampleRate])
            }
        }
        for pkey in tabPlayers.keys where !wantedPlayers.contains(pkey) {
            retire(tabPlayers.removeValue(forKey: pkey))
        }
        // Tabs no longer routed: release the capture so they play normally again.
        for key in routedTabKeys where tabRoutes[key] == nil {
            bridge.setPlayers([], for: key)
            tabStreamRates[key] = nil
            capturedTabs.remove(key)
            let parts = key.split(separator: "/").compactMap { Int($0) }
            if parts.count == 2, browserConnections[parts[0]] != nil {
                bridge.send(parts[0], ["type": "unroute", "tabId": parts[1]])
            }
        }
        routedTabKeys = Set(tabRoutes.keys)
        broadcastState()
    }

    private func applyTabGains() {
        for (key, route) in tabRoutes {
            let targets = tabTargets(route)
            for device in targets {
                guard let player = tabPlayers[key + "|" + device.uid] else { continue }
                configure(player.state, volume: route.volume, muted: route.muted, balance: route.balance, on: device, multi: targets.count > 1)
            }
        }
    }

    /// Devices and current tab routes, for the extension's popup.
    private func sendState(_ conn: Int) {
        let prefix = "\(conn)/"
        var routes: [String: Any] = [:]
        for (key, route) in tabRoutes where key.hasPrefix(prefix) {
            routes[String(key.dropFirst(prefix.count))] = ["deviceUID": route.deviceUID, "volume": route.volume, "muted": route.muted,
                                                           "extras": route.extras]
        }
        var errors: [String: String] = [:]
        for (key, error) in tabErrors where key.hasPrefix(prefix) { errors[String(key.dropFirst(prefix.count))] = error }
        bridge.send(conn, [
            "type": "state",
            "devices": devices.map { ["uid": $0.uid, "name": $0.name, "isDefault": $0.isDefault, "color": hex(nsColor(for: $0.uid))] },
            "routes": routes,
            "errors": errors,
            "sites": siteRules.mapValues { ["deviceUID": $0.deviceUID, "volume": $0.volume] },
            "rememberSites": rememberSites,
        ])
    }

    private func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private func broadcastState() {
        browserConnections.keys.forEach(sendState)
    }

    // MARK: Diagnostics (used by --selftest)

    /// Per-speaker stats for an app's routers (used by tests).
    func routerStats(_ appID: String) -> [String: IOState] {
        var out: [String: IOState] = [:]
        for (key, router) in routers where key.hasPrefix(appID + "|") { out[router.deviceUID] = router.state }
        return out
    }

    func tabPlayerStats(_ key: String) -> (callbacks: UInt64, peak: Float)? {
        let primary = tabRoutes[key].flatMap { tabPlayers[key + "|" + $0.deviceUID] }
        return primary.map { ($0.state.callbacks, $0.state.peak) }
    }

    /// For tests: set a rule directly by app id.
    func setRule(_ rule: AppRule?, forAppID id: String) {
        rules[id] = rule
        saveRules()
        reconcile()
    }
}
