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
            .separator(),
            ClosureMenuItem("Launch at Login", checked: model.launchAtLogin) { model.launchAtLogin.toggle() },
            ClosureMenuItem("Keyboard Shortcuts (\(HotKeys.modifierLabel)S, M, ↑, ↓, 1–9)", checked: model.shortcutsEnabled) { model.shortcutsEnabled.toggle() },
            ClosureMenuItem("Show Background Processes", checked: model.showBackgroundProcesses) { model.showBackgroundProcesses.toggle() },
            ClosureMenuItem("Reset All Apps to Mac Default") { model.resetAll() },
            .separator(),
            ClosureMenuItem("Quit SoundRouter") { NSApp.terminate(nil) },
        ]
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
        Card(title: "Now Playing") {
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
