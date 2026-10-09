import AppKit
import SwiftUI

/// Main window: a sidebar of sections, each a native grouped form.
struct MainView: View {
    @EnvironmentObject var model: AudioModel
    @EnvironmentObject var ui: UIState

    var body: some View {
        NavigationSplitView {
            List(selection: $ui.section) {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
        } detail: {
            switch ui.section ?? .apps {
            case .apps: AppsPage()
            case .speakers: SpeakersPage()
            case .microphones: MicrophonesPage()
            case .presets: PresetsPage()
            case .settings: SettingsPage()
            }
        }
        .environment(\.roomy, true)
        .frame(minWidth: 720, minHeight: 500)
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppsPage: View {
    @EnvironmentObject var model: AudioModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Apps & Tabs", subtitle: "Choose a speaker and volume for each app, or for a single browser tab.")
            Form {
                Section("Now Playing") {
                    if model.nowPlaying.isEmpty {
                        Text("Nothing is playing. Start audio in any app and it appears here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.nowPlaying) { AppRowView(app: $0).padding(.vertical, 2) }
                    ForEach(model.unmatchedBrowsers, id: \.name) { browser in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(browser.name).font(.system(size: 12, weight: .medium))
                            TabsBlock(tabs: browser.tabs, browser: browser.name)
                        }
                    }
                }
                if !model.otherApps.isEmpty {
                    Section {
                        ForEach(model.otherApps) { AppRowView(app: $0).padding(.vertical, 2) }
                    } header: {
                        HStack {
                            Text("Other Apps")
                            Spacer()
                            Toggle("Show background processes", isOn: $model.showBackgroundProcesses)
                                .toggleStyle(.checkbox).font(.system(size: 11))
                        }
                    }
                }
                if !model.dormantRules.isEmpty {
                    Section("Saved for Apps Not Running") {
                        ForEach(model.dormantRules, id: \.0) { id, rule in
                            HStack {
                                Text(rule.name ?? id)
                                Spacer()
                                Text(model.chipTitle(rule.deviceUID, follow: "Mac default") + " · \(Int(rule.volume * 100))%")
                                    .foregroundStyle(.secondary)
                                Button("Forget") { model.removeRule(id) }
                            }
                        }
                    }
                }
                if !model.siteRules.isEmpty {
                    Section {
                        ForEach(model.siteRules.keys.sorted(), id: \.self) { host in
                            let rule = model.siteRules[host]!
                            HStack(spacing: 8) {
                                Image(systemName: "globe").foregroundStyle(.secondary)
                                Text(host)
                                Spacer()
                                Chip(title: model.chipTitle(rule.deviceUID, extras: rule.extraDeviceUIDs, follow: ""),
                                     color: model.color(for: rule.deviceUID), help: "Speaker for \(host)", maxTextWidth: 170) {
                                    model.devices.map { d in
                                        ClosureMenuItem(d.name, image: Theme.dot(model.nsColor(for: d.uid)), checked: d.uid == rule.deviceUID) {
                                            model.setSiteDevice(d.uid, for: host)
                                        }
                                    }
                                }
                                Button("Forget") { model.forgetSite(host) }
                            }
                        }
                    } header: {
                        Text("Remembered Websites")
                    } footer: {
                        Text("When you click the SoundRouter button on one of these sites, its tab goes straight to the remembered speaker.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if model.browserConnections.isEmpty {
                    Section("Browser Tabs") { ExtensionSetup() }
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct SpeakersPage: View {
    @EnvironmentObject var model: AudioModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Speakers", subtitle: "Volume for each speaker. “Mac default” is where apps without their own setting play.")
            Form {
                Section {
                    ForEach(model.devices) { SpeakerRow(device: $0).padding(.vertical, 3) }
                } footer: {
                    Text("Expand a speaker for balance and sync delay.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section { AlertsRow() }
            }
            .formStyle(.grouped)
        }
    }
}

struct MicrophonesPage: View {
    @EnvironmentObject var model: AudioModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Microphones", subtitle: "The mic macOS uses, and input levels. Call apps can still pick their own mic.")
            Form {
                Section {
                    if model.inputs.isEmpty { Text("No microphones found.").foregroundStyle(.secondary) }
                    ForEach(model.inputs) { MicRowView(input: $0).padding(.vertical, 3) }
                }
                Section { HeadphonesQualityToggle() }
            }
            .formStyle(.grouped)
        }
    }
}

struct SettingsPage: View {
    @EnvironmentObject var model: AudioModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings", subtitle: "SoundRouter keeps running in the menu bar when this window is closed.")
            Form {
                Section("General") {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                    Toggle("Show background processes in the app list", isOn: $model.showBackgroundProcesses)
                }
                Section("Keyboard Shortcuts") {
                    Toggle("Enable keyboard shortcuts", isOn: $model.shortcutsEnabled)
                    if model.shortcutsEnabled {
                        ShortcutRow(keys: "S", title: "Switch the Mac default speaker")
                        ShortcutRow(keys: "M", title: "Mute or unmute the app in front")
                        ShortcutRow(keys: "↑ / ↓", title: "Louder / quieter: the app in front (up to 200%)")
                        ShortcutRow(keys: "1 – 9", title: "Apply preset 1 to 9")
                        ShortcutRow(keys: "0", title: "Open the SoundRouter panel")
                    }
                }
                Section("Browser Tabs") {
                    ExtensionSetup()
                    Toggle("Remember the speaker for each website", isOn: $model.rememberSites)
                }
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset all apps")
                            Text("Send every app back to the Mac default speaker at full volume.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset", role: .destructive) { model.resetAll() }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// Browser extension status and install steps.
struct ExtensionSetup: View {
    @EnvironmentObject var model: AudioModel

    var body: some View {
        if !model.browserConnections.isEmpty {
            Label("Connected: " + Set(model.browserConnections.values).sorted().joined(separator: ", "),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Click the SoundRouter button in a tab’s toolbar once to allow it, then choose its speaker here or in the menu bar.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("To route individual tabs, add the SoundRouter extension to Chrome, Brave or Edge:")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    step(1, "Open chrome://extensions and turn on Developer mode.")
                    step(2, "Click “Load unpacked” and choose the extension folder.")
                    step(3, "In a tab, click the SoundRouter button and pick a speaker.")
                }
                HStack {
                    Button("Show Extension Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ExtensionInstaller.folder])
                    }
                    Button("Copy chrome://extensions") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("chrome://extensions", forType: .string)
                    }
                }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 16, height: 16).background(Circle().fill(Color.accentColor))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ShortcutRow: View {
    let keys: String
    let title: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(HotKeys.modifierLabel + keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }
    }
}

struct PresetsPage: View {
    @EnvironmentObject var model: AudioModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Presets & Automation", subtitle: "Save setups, switch with one click or a shortcut, and let speakers trigger them.")
            Form {
                Section {
                    if model.presets.isEmpty {
                        Text("No presets yet. Set things up the way you like, then save it.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.presets.enumerated()), id: \.element.id) { index, preset in
                        PresetRow(preset: preset, index: index)
                    }
                    Button("Save Current Setup as Preset…") { promptSavePreset(model) }
                } header: {
                    Text("Presets")
                } footer: {
                    Text("A preset stores every app’s speaker, volume and balance, the Mac default speaker and the alerts speaker.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section {
                    if model.automations.isEmpty {
                        Text("No automations yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.automations) { AutomationRow(automation: $0) }
                    Button("Add Automation") {
                        let uid = model.devices.first(where: { !$0.isDefault })?.uid ?? model.devices.first?.uid ?? ""
                        model.addAutomation(Automation(deviceUID: uid, deviceName: model.deviceName(uid),
                                                       makeDefault: true, presetID: model.presets.first?.id))
                    }
                    .disabled(model.knownDevices.isEmpty)
                } header: {
                    Text("Automation")
                } footer: {
                    Text("Apps already set to a speaker switch to it by themselves whenever it connects, and back to the Mac default when it disconnects. Use automations to change more than that.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct PresetRow: View {
    @EnvironmentObject var model: AudioModel
    let preset: Preset
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(index < 9 ? "\(index + 1)" : "")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .help(index < 9 ? "Shortcut: \(HotKeys.modifierLabel)\(index + 1)" : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(preset.name).font(.system(size: 13, weight: .medium))
                    if model.activePresetID == preset.id { Badge(text: "Active") }
                }
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Apply") { model.applyPreset(preset.id) }
            Menu {
                PresetMenuItems(preset: preset)
                Divider()
                Button("Move Up") { model.movePreset(preset.id, by: -1) }.disabled(index == 0)
                Button("Move Down") { model.movePreset(preset.id, by: 1) }.disabled(index == model.presets.count - 1)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var summary: String {
        var parts = ["\(preset.rules.count) app\(preset.rules.count == 1 ? "" : "s")"]
        if let uid = preset.defaultUID { parts.append("Mac default: \(model.deviceName(uid))") }
        if preset.alerts != "" && preset.alerts != "default" { parts.append("Alerts: \(model.deviceName(preset.alerts))") }
        return parts.joined(separator: " · ")
    }
}

struct AutomationRow: View {
    @EnvironmentObject var model: AudioModel
    let automation: Automation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("When")
                Picker("", selection: binding(\.deviceUID)) {
                    ForEach(model.knownDevices.sorted { $0.value < $1.value }, id: \.key) { uid, name in
                        Text(name).tag(uid)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Picker("", selection: binding(\.onConnect)) {
                    Text("connects").tag(true)
                    Text("disconnects").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button { model.deleteAutomation(automation.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete automation")
            }
            HStack(spacing: 16) {
                if automation.onConnect {
                    Toggle("Make it the Mac default", isOn: binding(\.makeDefault))
                }
                HStack(spacing: 6) {
                    Text("Apply preset")
                    Picker("", selection: binding(\.presetID)) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.presets) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .font(.system(size: 12))
            .padding(.leading, 2)
        }
        .padding(.vertical, 2)
    }

    private func binding<T>(_ path: WritableKeyPath<Automation, T>) -> Binding<T> {
        Binding(get: { automation[keyPath: path] }, set: { value in
            var updated = automation
            updated[keyPath: path] = value
            updated.deviceName = model.deviceName(updated.deviceUID)
            model.updateAutomation(updated)
        })
    }
}
