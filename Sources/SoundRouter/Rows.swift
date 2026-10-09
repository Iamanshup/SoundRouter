import AppKit
import SwiftUI

// MARK: - Speaker menus

extension AudioModel {
    /// Menu for an app's or tab's speaker chip: one main speaker, plus "Also play on".
    func speakerMenu(selected: String?, extras: [String] = [], followTitle: String,
                     onSelect: @escaping (String?) -> Void,
                     onToggleExtra: ((String) -> Void)? = nil) -> [NSMenuItem] {
        var items: [NSMenuItem] = [
            ClosureMenuItem(followTitle, image: Theme.dot(Theme.neutral), checked: selected == nil) { onSelect(nil) },
            .separator(),
        ]
        for device in devices {
            let title = device.isDefault ? "\(device.name)  (Mac default)" : device.name
            items.append(ClosureMenuItem(title, image: Theme.dot(nsColor(for: device.uid)), checked: selected == device.uid) {
                onSelect(device.uid)
            })
        }
        if let onToggleExtra, devices.count > 1 {
            let main = selected ?? defaultDevice?.uid
            let submenu = NSMenu()
            for device in devices where device.uid != main {
                submenu.addItem(ClosureMenuItem(device.name, image: Theme.dot(nsColor(for: device.uid)),
                                                checked: extras.contains(device.uid)) { onToggleExtra(device.uid) })
            }
            let parent = NSMenuItem(title: "Also Play On", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
            parent.submenu = submenu
            items.append(.separator())
            items.append(parent)
        }
        return items
    }

    /// Chip label: the chosen speaker's name (+ N more), or the "follow" label.
    func chipTitle(_ uid: String?, extras: [String] = [], follow: String) -> String {
        let base = uid.map { deviceName($0) } ?? follow
        let more = extras.filter { device($0) != nil && $0 != uid }.count
        return more > 0 ? "\(base) +\(more)" : base
    }
}

// MARK: - Speakers

struct SpeakerRow: View {
    @EnvironmentObject var model: AudioModel
    @EnvironmentObject var ui: UIState
    let device: OutputDevice

    var body: some View {
        let color = model.color(for: device.uid)
        let key = "spk:" + device.uid
        let expanded = ui.expanded.contains(key)
        HStack(alignment: .top, spacing: 10) {
            IconBubble(symbol: device.symbol, color: color)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(device.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if device.isDefault { Badge(text: "Mac default") }
                    Spacer(minLength: 4)
                    if !device.isDefault {
                        Button("Make default") { model.makeDefault(device) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .help("Make this the speaker macOS uses for everything without its own setting")
                    }
                    ExpandButton(expanded: expanded) { ui.toggle(key) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    VolumeControl(value: device.volume, muted: device.muted,
                                  setValue: { model.setVolume($0, for: device) },
                                  toggleMute: { model.toggleMute(for: device) })
                    if !device.hasHardwareVolume {
                        Text("Software volume (applies to apps routed here)")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    if expanded {
                        if let balance = device.balance {
                            BalanceControl(value: balance * 2 - 1) { model.setBalance(($0 + 1) / 2, for: device) }
                        }
                        DelayControl(ms: model.delay(for: device.uid)) { model.setDelay($0, for: device) }
                    }
                }
            }
        }
    }
}

/// Delay for lining up speakers when one sound plays on several at once.
struct DelayControl: View {
    let ms: Float
    let setValue: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "timer").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 16)
                Slider(value: Binding(get: { Double(ms) }, set: { setValue(Float(($0 / 10).rounded() * 10)) }), in: 0...500)
                    .labelsHidden().controlSize(.mini)
                    .frame(maxWidth: .infinity)
                Text("\(Int(ms)) ms").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Text("Sync delay: holds this speaker back when a sound plays on several speakers, so they line up.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 22)
        }
    }
}

/// Where alert and notification sounds play.
struct AlertsRow: View {
    @EnvironmentObject var model: AudioModel

    var body: some View {
        let current = model.alertsDevice
        let following = model.alertsSetting == "default" || (model.alertsSetting.isEmpty && current?.isDefault == true)
        HStack(spacing: 10) {
            IconBubble(symbol: "bell.fill", color: .secondary, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Alerts & sound effects").font(.system(size: 12, weight: .medium))
                Text("Notifications, system sounds").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Chip(title: following ? "Mac default" : (current?.name ?? "Mac default"),
                 color: following ? Color(nsColor: Theme.neutral) : model.color(for: current?.uid),
                 help: "Where alerts and notification sounds play") {
                var items: [NSMenuItem] = [
                    ClosureMenuItem("Same as Mac default", image: Theme.dot(Theme.neutral), checked: following) { model.setAlertsDevice(nil) },
                    .separator(),
                ]
                for device in model.devices {
                    items.append(ClosureMenuItem(device.name, image: Theme.dot(model.nsColor(for: device.uid)),
                                                 checked: !following && current?.uid == device.uid) { model.setAlertsDevice(device.uid) })
                }
                return items
            }
        }
    }
}

// MARK: - Apps

struct AppRowView: View {
    @EnvironmentObject var model: AudioModel
    @EnvironmentObject var ui: UIState
    @Environment(\.roomy) private var roomy
    let app: AudioApp
    var showsTabs = true

    var body: some View {
        let rule = model.rule(for: app.id)
        let expanded = ui.expanded.contains(app.id)
        let routedUID = model.isRouted(app.id) ? (rule.deviceUID ?? model.defaultDevice?.uid) : nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Group {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let detail = detail(rule) {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if let routedUID {
                    LevelBars(level: model.levels[app.id] ?? 0, color: model.color(for: routedUID))
                } else if app.isPlaying {
                    PlayingIndicator()
                }
                Chip(title: model.chipTitle(rule.deviceUID, extras: rule.extras, follow: "Mac default"),
                     color: model.color(for: rule.deviceUID),
                     help: "Speaker for \(app.name)", maxTextWidth: roomy ? 170 : 120) {
                    model.speakerMenu(selected: rule.deviceUID, extras: rule.extras,
                                      followTitle: "Mac default (\(model.defaultDevice?.name ?? "system output"))",
                                      onSelect: { model.setDevice($0, for: app) },
                                      onToggleExtra: { model.toggleExtraDevice($0, for: app) })
                }
                ExpandButton(expanded: expanded) { ui.toggle(app.id) }
            }
            .contentShape(Rectangle())
            if expanded {
                VStack(spacing: 4) {
                    VolumeControl(value: rule.volume, muted: rule.muted, boost: true,
                                  setValue: { model.setVolume($0, for: app) },
                                  toggleMute: { model.toggleMute(for: app) })
                    BalanceControl(value: rule.pan) { model.setBalance($0, for: app) }
                }
                .padding(.leading, 31)
            }
            if let error = model.routeErrors[app.id] {
                Label("Couldn’t route audio. Allow SoundRouter in System Settings › Privacy & Security › Screen & System Audio Recording.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .padding(.leading, 31)
                    .help(error)
            }
            if showsTabs && model.isBrowser(app) {
                TabsBlock(tabs: model.tabs(for: app), browser: app.name)
                    .padding(.leading, 31)
            }
        }
    }

    private func detail(_ rule: AppRule) -> String? {
        var parts: [String] = []
        if rule.muted { parts.append("Muted") } else if abs(rule.volume - 1) > 0.005 { parts.append("\(Int((rule.volume * 100).rounded()))%") }
        if abs(rule.pan) > 0.01 { parts.append("Balance \(rule.pan < 0 ? "L" : "R")\(Int((abs(rule.pan) * 100).rounded()))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ExpandButton: View {
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide volume" : "Show volume")
        .animation(.easeOut(duration: 0.15), value: expanded)
    }
}

// MARK: - Tabs

struct TabsBlock: View {
    @EnvironmentObject var model: AudioModel
    let tabs: [BrowserTab]
    let browser: String

    var body: some View {
        if !tabs.isEmpty || model.showAllTabs {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tabs) { TabRowView(tab: $0, browser: browser) }
                Button(model.showAllTabs ? "Show only tabs playing sound" : "Choose a speaker for another tab…") {
                    model.showAllTabs.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        } else {
            Button("Choose a speaker for a tab…") { model.showAllTabs = true }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
        }
    }
}

struct TabRowView: View {
    @EnvironmentObject var model: AudioModel
    @EnvironmentObject var ui: UIState
    @Environment(\.roomy) private var roomy
    let tab: BrowserTab
    let browser: String

    var body: some View {
        let route = model.tabRoutes[tab.id]
        let key = "tab:" + tab.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Favicon(url: tab.favIconURL)
                Text(tab.title.isEmpty ? tab.url : tab.title)
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                    .help(tab.url)
                Spacer(minLength: 4)
                if let route {
                    LevelBars(level: model.levels[key] ?? 0, color: model.color(for: route.deviceUID))
                } else if tab.audible {
                    PlayingIndicator()
                }
                Chip(title: model.chipTitle(route?.deviceUID, extras: route?.extras ?? [], follow: "Same as \(shortName)"),
                     color: model.color(for: route?.deviceUID),
                     help: "Speaker for this tab", maxTextWidth: roomy ? 170 : 92) {
                    model.speakerMenu(selected: route?.deviceUID, extras: route?.extras ?? [], followTitle: "Same as \(browser)",
                                      onSelect: { model.setDevice($0, forTab: tab) },
                                      onToggleExtra: route == nil ? nil : { model.toggleExtraDevice($0, forTab: tab) })
                }
                if route != nil {
                    ExpandButton(expanded: ui.expanded.contains(key)) { ui.toggle(key) }
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
            }
            if let route, ui.expanded.contains(key) {
                VStack(spacing: 4) {
                    VolumeControl(value: route.volume, muted: route.muted, boost: true,
                                  setValue: { model.setVolume($0, forTab: tab) },
                                  toggleMute: { model.toggleMute(forTab: tab) })
                    BalanceControl(value: route.balance) { model.setBalance($0, forTab: tab) }
                }
                .padding(.leading, 21)
            }
            if route == nil, let (host, site) = model.siteRule(for: tab) {
                Text("Remembered for \(host): \(model.deviceName(site.deviceUID)). Click the SoundRouter button in this tab to apply.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
            }
            if let error = model.tabErrors[tab.id] {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
            }
        }
    }

    /// "Google Chrome" -> "Chrome" keeps the chip short.
    private var shortName: String {
        browser.replacingOccurrences(of: "Google ", with: "").replacingOccurrences(of: "Microsoft ", with: "")
            .replacingOccurrences(of: " Browser", with: "")
    }
}

struct Favicon: View {
    let url: String?

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url), parsed.scheme == "https" || parsed.scheme == "data" {
                AsyncImage(url: parsed) { image in
                    image.resizable().interpolation(.high)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 14, height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: "globe").resizable().foregroundStyle(.secondary)
    }
}

// MARK: - Microphones

struct MicRowView: View {
    @EnvironmentObject var model: AudioModel
    let input: InputDevice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconBubble(symbol: input.symbol, color: input.isDefault ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(input.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if input.isDefault { Badge(text: "In use") }
                    if input.isBluetoothHeadset { Badge(text: "Headphones", color: .secondary) }
                    Spacer(minLength: 4)
                    if !input.isDefault {
                        Button("Use this mic") { model.makeDefault(input) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .help(input.isBluetoothHeadset
                                  ? "Using this mic switches these headphones to lower-quality headset mode while it's in use"
                                  : "Make this the mic macOS uses")
                    }
                }
                if input.hasVolume || input.canMute {
                    VolumeControl(value: input.volume, muted: input.muted, enabled: input.hasVolume,
                                  mutedSymbol: "mic.slash.fill", symbol: "mic.fill",
                                  setValue: { model.setVolume($0, for: input) },
                                  toggleMute: input.canMute ? { model.toggleMute(for: input) } : nil)
                }
            }
        }
    }
}

struct HeadphonesQualityToggle: View {
    @EnvironmentObject var model: AudioModel
    var showsExplanation = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $model.keepHeadphonesHighQuality) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep headphones in high quality").font(.system(size: 12))
                    if showsExplanation {
                        Text("If macOS switches to a Bluetooth headphones mic, switch back to the Mac’s mic so the headphones keep full sound quality.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            if let notice = model.micNotice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
