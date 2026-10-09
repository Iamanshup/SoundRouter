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
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch ui.section ?? .apps {
            case .apps: AppsPage()
            case .speakers: SpeakersPage()
            case .microphones: MicrophonesPage()
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
                }
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
                Section("Browser Tabs") { ExtensionSetup() }
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
