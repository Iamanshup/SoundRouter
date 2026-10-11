import AppKit
import SwiftUI

final class HeightBox: ObservableObject {
    @Published var height: CGFloat = 420
}

/// The menu bar popover: speakers, what's playing, and the mic, as Control Center-style cards.
struct MenuBarView: View {
    @EnvironmentObject var model: AudioModel
    @EnvironmentObject var ui: UIState
    var openMain: () -> Void = {}
    @StateObject private var measured = HeightBox()

    /// Leave room for the menu bar and Dock.
    private var maxHeight: CGFloat {
        min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 150)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Explicit height: a ScrollView has no natural height and would collapse.
            ScrollView {
                VStack(spacing: 10) {
                    if model.isInCall && model.duckingEnabled { callBanner }
                    presetsCard
                    speakersCard
                    nowPlayingCard
                    micCard
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured.height = $0 }
            }
            .frame(height: min(measured.height, maxHeight))
        }
        .frame(width: 390)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
            Text("SoundRouter").font(.system(size: 13, weight: .semibold))
            Spacer()
            HeaderButton(symbol: "macwindow", help: "Open the SoundRouter window", action: openMain)
            HeaderButton(symbol: "ellipsis.circle", help: "More") { PopUp.show(moreMenu) }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
    }

    private var moreMenu: [NSMenuItem] {
        [
            ClosureMenuItem("Open SoundRouter…") { openMain() },
            .separator(),
            ClosureMenuItem("Save Current Setup as Preset…") { promptSavePreset(model) },
            ClosureMenuItem("Show Welcome Guide") { Welcome.show() },
            .separator(),
            ClosureMenuItem("Launch at Login", checked: model.launchAtLogin) { model.launchAtLogin.toggle() },
            ClosureMenuItem("Keyboard Shortcuts", checked: model.shortcutsEnabled) { model.shortcutsEnabled.toggle() },
            ClosureMenuItem("Lower Other Apps During Calls", checked: model.duckingEnabled) { model.duckingEnabled.toggle() },
            ClosureMenuItem("Show Background Processes", checked: model.showBackgroundProcesses) { model.showBackgroundProcesses.toggle() },
            ClosureMenuItem("Reset All Apps to Mac Default") { model.resetAll() },
            .separator(),
            ClosureMenuItem("Quit SoundRouter") { NSApp.terminate(nil) },
        ]
    }

    private var callBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.fill").foregroundStyle(.green)
            Text("In a call: other apps lowered to \(Int((model.duckLevel * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Button("Don’t Lower") { model.duckingEnabled = false }
                .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.12)))
    }

    private var presetsCard: some View {
        Card(title: "Presets", accessory: AnyView(
            Button { promptSavePreset(model) } label: {
                Label("Save", systemImage: "plus").font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Save the current setup as a preset")
        )) {
            if model.presets.isEmpty {
                Text("Save your current setup to switch back to it in one click.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(Array(model.presets.enumerated()), id: \.element.id) { index, preset in
                        PresetPill(preset: preset, index: index)
                    }
                }
            }
        }
    }

    private var speakersCard: some View {
        Card(title: "Speakers") {
            ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { Divider().padding(.leading, 36) }
                SpeakerRow(device: device)
            }
            Divider().padding(.leading, 36)
            AlertsRow()
        }
    }

    private var nowPlayingCard: some View {
        Card(title: "Now Playing", accessory: AnyView(PinAppButton())) {
            let playing = model.nowPlaying
            if playing.isEmpty && model.unmatchedBrowsers.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "music.note").foregroundStyle(.tertiary)
                    Text("Nothing playing. Start audio in any app to send it to a speaker.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            ForEach(Array(playing.enumerated()), id: \.element.id) { index, app in
                if index > 0 { Divider().padding(.leading, 31) }
                AppRowView(app: app)
            }
            ForEach(model.unmatchedBrowsers, id: \.name) { browser in
                Text(browser.name).font(.system(size: 12, weight: .medium))
                TabsBlock(tabs: browser.tabs, browser: browser.name)
            }
            let others = model.otherApps
            if !others.isEmpty {
                Divider()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { ui.showOtherApps.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(ui.showOtherApps ? 90 : 0))
                        Text("\(others.count) more app\(others.count == 1 ? "" : "s")")
                        Spacer()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if ui.showOtherApps {
                    ForEach(others) { AppRowView(app: $0) }
                }
            }
        }
    }

    @ViewBuilder
    private var micCard: some View {
        if let mic = model.inputs.first(where: \.isDefault) ?? model.inputs.first {
            Card(title: "Microphone", accessory: AnyView(
                Chip(title: mic.name, color: .accentColor, help: "Choose the mic macOS uses") {
                    model.inputs.map { input in
                        ClosureMenuItem(input.name + (input.isBluetoothHeadset ? "  (lowers headphone quality)" : ""),
                                        checked: input.isDefault) { model.makeDefault(input) }
                    }
                }
            )) {
                if mic.hasVolume || mic.canMute {
                    VolumeControl(value: mic.volume, muted: mic.muted, enabled: mic.hasVolume,
                                  mutedSymbol: "mic.slash.fill", symbol: "mic.fill",
                                  setValue: { model.setVolume($0, for: mic) },
                                  toggleMute: mic.canMute ? { model.toggleMute(for: mic) } : nil)
                }
                Toggle(isOn: $model.duckingEnabled) {
                    Text("Lower other apps during calls").font(.system(size: 12))
                }
                .toggleStyle(.switch).controlSize(.mini)
                .help("When an app uses the mic, other apps drop to \(Int((model.duckLevel * 100).rounded()))%. Change the level in Settings.")
                HeadphonesQualityToggle(showsExplanation: false)
                    .help("If macOS switches to a Bluetooth headphones mic, switch back to the Mac’s mic so the headphones keep full sound quality.")
            }
        }
    }
}

struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "Pin" menu: running apps not listed yet.
struct PinAppButton: View {
    @EnvironmentObject var model: AudioModel

    var body: some View {
        Button {
            let listed = Set(model.nowPlaying.map(\.id))
            let candidates = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
                .compactMap { app -> (String, String, NSImage?)? in
                    guard let id = app.bundleIdentifier, !listed.contains(id), model.ignoredApps[id] == nil else { return nil }
                    return (id, app.localizedName ?? id, app.icon)
                }
                .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            var items: [NSMenuItem] = candidates.map { id, name, icon in
                let image = icon.map { i -> NSImage in let c = i.copy() as! NSImage; c.size = NSSize(width: 16, height: 16); return c }
                return ClosureMenuItem(name, image: image) { model.pin(id: id, name: name) }
            }
            if items.isEmpty { items = [ClosureMenuItem("No other apps running") {}] }
            let header = NSMenuItem(title: "Pin an app to set it up before it plays:", action: nil, keyEquivalent: "")
            header.isEnabled = false
            PopUp.show([header] + items)
        } label: {
            Label("Pin", systemImage: "pin").font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help("Pin an app so it's always listed, even before it plays")
    }
}
