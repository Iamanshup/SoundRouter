import AppKit
import Combine
import CoreAudio
import ServiceManagement
import SwiftUI

/// Per-app setting. `deviceUID == nil` means "follow the system output".
struct AppRule: Codable, Equatable {
    var deviceUID: String?
    var volume: Float = 1
    var muted = false
    var name: String?
}

/// A browser tab whose audio the extension captures and streams to us.
struct TabRoute: Equatable {
    var deviceUID: String
    var volume: Float = 1
    var muted = false
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

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var tabRoutes: [String: TabRoute] = [:]
    @Published private(set) var tabErrors: [String: String] = [:]
    @Published private(set) var browserConnections: [Int: String] = [:]   // connection -> browser name
    @Published var showAllTabs = false

    private let bridge = BrowserBridge()
    private var tabPlayers: [String: TabPlayer] = [:]
    private var capturedTabs: Set<String> = []
    private var softwareVolumes: [String: Float] = [:]
    /// Speaker uid -> palette index, persisted so a speaker keeps its colour.
    private var speakerColors: [String: Int] = UserDefaults.standard.dictionary(forKey: "speakerColors") as? [String: Int] ?? [:]
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
                         kAudioHardwarePropertyProcessObjectList] {
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

    func isRouted(_ appID: String) -> Bool { routers[appID] != nil }

    var defaultDevice: OutputDevice? { devices.first(where: \.isDefault) }

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
        rules[id] = rule == AppRule(name: name) ? nil : rule
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
        assignColors(DeviceManager.outputDevices(softwareVolumes: softwareVolumes))
        inputs = InputManager.inputDevices()
        enforceHeadsetGuard()
        devices = DeviceManager.outputDevices(softwareVolumes: softwareVolumes)
        apps = ProcessManager.audioApps()
        reconcile()
        reconcileTabs()
    }

    private func tick() {
        let freshInputs = InputManager.inputDevices()
        if freshInputs != inputs { inputs = freshInputs }
        let fresh = DeviceManager.outputDevices(softwareVolumes: softwareVolumes)
        if fresh != devices {
            assignColors(fresh)
            let deviceSetChanged = fresh.map(\.uid) != devices.map(\.uid)
            devices = fresh
            if deviceSetChanged { reconcileTabs() } else { applyTabGains() }
        }
        let freshApps = ProcessManager.audioApps()
        if freshApps != apps {
            apps = freshApps
            reconcile()
        }
        var newLevels: [String: Float] = [:]
        for (id, router) in routers { newLevels[id] = router.state.peak }
        for (key, player) in tabPlayers { newLevels["tab:" + key] = player.state.peak }
        if newLevels != levels { levels = newLevels }
    }

    /// Which device an app's audio should be sent to by us, or nil to leave it alone.
    private func target(for rule: AppRule) -> OutputDevice? {
        let chosen = rule.deviceUID.flatMap { uid in devices.first { $0.uid == uid } }
        if let chosen, !chosen.isDefault { return chosen }
        // Following the system output: only intercept when we must apply a volume/mute.
        let needsGain = rule.volume < 0.999 || rule.muted
        return needsGain ? (chosen ?? defaultDevice) : nil
    }

    private func gain(for rule: AppRule, on device: OutputDevice) -> Float {
        if rule.muted { return 0 }
        var g = rule.volume
        // Devices without a hardware volume control get a software one.
        if !device.hasHardwareVolume { g *= device.muted ? 0 : device.volume }
        return g
    }

    private func reconcile() {
        var wanted: Set<String> = []
        var errors: [String: String] = [:]
        for app in apps {
            guard let rule = rules[app.id], let device = target(for: rule) else { continue }
            wanted.insert(app.id)
            let objects = app.processObjects.sorted()
            if let existing = routers[app.id], existing.deviceUID == device.uid, existing.processObjects == objects {
                existing.state.gain = gain(for: rule, on: device)
                continue
            }
            routers[app.id]?.stop()
            routers[app.id] = nil
            do {
                routers[app.id] = try TapRouter(name: app.name, processObjects: objects,
                                                deviceUID: device.uid, gain: gain(for: rule, on: device))
            } catch {
                errors[app.id] = "\(error)"
                NSLog("SoundRouter: routing \(app.name) failed: \(error)")
            }
        }
        for id in routers.keys where !wanted.contains(id) {
            routers[id]?.stop()
            routers[id] = nil
        }
        if errors != routeErrors { routeErrors = errors }
    }

    private func applyGains() {
        for app in apps {
            guard let router = routers[app.id], let rule = rules[app.id],
                  let device = devices.first(where: { $0.uid == router.deviceUID }) else { continue }
            router.state.gain = gain(for: rule, on: device)
        }
    }

    func shutdown() {
        routers.values.forEach { $0.stop() }
        routers = [:]
        tabPlayers.values.forEach { $0.stop() }
        tabPlayers = [:]
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
            tabRoutes[tab.id] = route
        } else {
            tabRoutes[tab.id] = nil
        }
        reconcileTabs()
    }

    func setVolume(_ volume: Float, forTab tab: BrowserTab) {
        tabRoutes[tab.id]?.volume = volume
        applyTabGains()
        broadcastState()
    }

    func toggleMute(forTab tab: BrowserTab) {
        tabRoutes[tab.id]?.muted.toggle()
        applyTabGains()
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
            } else {
                setDevice(msg["deviceUID"] as? String, forTab: tab)
            }
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
            bridge.send(tab.connection, ["type": "debugStats", "tabId": tab.tabID,
                                         "callbacks": stats?.callbacks ?? 0, "peak": stats?.peak ?? 0,
                                         "device": tabPlayers[key]?.deviceUID ?? "",
                                         "sampleRate": tabPlayers[key]?.sampleRate ?? 0,
                                         "skips": tabPlayers[key]?.skips ?? 0,
                                         "underruns": tabPlayers[key]?.underruns ?? 0])
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

    private func tabGain(_ route: TabRoute, on device: OutputDevice) -> Float {
        if route.muted { return 0 }
        var g = route.volume
        if !device.hasHardwareVolume { g *= device.muted ? 0 : device.volume }
        return g
    }

    private func reconcileTabs() {
        let liveTabs = Set(tabs.map(\.id))
        for key in tabRoutes.keys where !liveTabs.contains(key) { tabRoutes[key] = nil }

        for (key, route) in tabRoutes {
            guard let tab = tabs.first(where: { $0.id == key }),
                  let device = devices.first(where: { $0.uid == route.deviceUID }) ?? defaultDevice else { continue }
            let deviceRate = CA.get(device.id, address(kAudioDevicePropertyNominalSampleRate), Float64(0))
            if let player = tabPlayers[key], player.deviceUID == device.uid, deviceRate == nil || deviceRate == player.sampleRate {
                player.state.gain = tabGain(route, on: device)
                continue
            }
            let previousRate = tabPlayers[key]?.sampleRate
            tabPlayers[key]?.stop()
            do {
                let player = try TabPlayer(device: device, gain: tabGain(route, on: device))
                // Rebuild at the new rate; the extension re-renders the same tab stream to match.
                player.onSampleRateChange = { [weak self] in MainActor.assumeIsolated { self?.reconcileTabs() } }
                tabPlayers[key] = player
                bridge.setPlayer(player, for: key)
                if !capturedTabs.contains(key) || previousRate != player.sampleRate {
                    bridge.send(tab.connection, ["type": "route", "tabId": tab.tabID, "sampleRate": player.sampleRate])
                }
            } catch {
                tabPlayers[key] = nil
                bridge.setPlayer(nil, for: key)
                tabErrors[key] = "\(error)"
            }
        }
        for (key, player) in tabPlayers where tabRoutes[key] == nil {
            player.stop()
            tabPlayers[key] = nil
            bridge.setPlayer(nil, for: key)
            let parts = key.split(separator: "/").compactMap { Int($0) }
            if parts.count == 2, browserConnections[parts[0]] != nil {
                bridge.send(parts[0], ["type": "unroute", "tabId": parts[1]])
            }
            capturedTabs.remove(key)
        }
        broadcastState()
    }

    private func applyTabGains() {
        for (key, player) in tabPlayers {
            guard let route = tabRoutes[key], let device = devices.first(where: { $0.uid == player.deviceUID }) else { continue }
            player.state.gain = tabGain(route, on: device)
        }
    }

    /// Devices and current tab routes, for the extension's popup.
    private func sendState(_ conn: Int) {
        let prefix = "\(conn)/"
        var routes: [String: Any] = [:]
        for (key, route) in tabRoutes where key.hasPrefix(prefix) {
            routes[String(key.dropFirst(prefix.count))] = ["deviceUID": route.deviceUID, "volume": route.volume, "muted": route.muted]
        }
        var errors: [String: String] = [:]
        for (key, error) in tabErrors where key.hasPrefix(prefix) { errors[String(key.dropFirst(prefix.count))] = error }
        bridge.send(conn, [
            "type": "state",
            "devices": devices.map { ["uid": $0.uid, "name": $0.name, "isDefault": $0.isDefault, "color": hex(nsColor(for: $0.uid))] },
            "routes": routes,
            "errors": errors,
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

    func routerStats(_ appID: String) -> (callbacks: UInt64, peak: Float)? {
        routers[appID].map { ($0.state.callbacks, $0.state.peak) }
    }

    func tabPlayerStats(_ key: String) -> (callbacks: UInt64, peak: Float)? {
        tabPlayers[key].map { ($0.state.callbacks, $0.state.peak) }
    }
}
