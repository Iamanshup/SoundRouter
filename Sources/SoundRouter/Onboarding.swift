import AppKit
import CoreAudio
import SwiftUI

final class WelcomeState: ObservableObject {
    @Published var page = 0
    @Published var askedForAudio = false
}

/// First-run guide: what SoundRouter is, the audio permission, browser tabs, and tips.
struct WelcomeView: View {
    @StateObject private var state: WelcomeState
    let done: () -> Void

    init(startPage: Int = 0, done: @escaping () -> Void) {
        let s = WelcomeState()
        s.page = startPage
        _state = StateObject(wrappedValue: s)
        self.done = done
    }
    private let pages = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch state.page {
                case 0: intro
                case 1: permission
                case 2: tabs
                default: tips
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36).padding(.top, 30)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Circle().fill(i == state.page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if state.page > 0 { Button("Back") { state.page -= 1 } }
                if state.page < pages - 1 {
                    Button(state.page == 2 ? "Skip for Now" : "Continue") { state.page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Using SoundRouter", action: done).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 540, height: 470)
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Welcome to SoundRouter").font(.system(size: 24, weight: .bold))
            Text("Send each app — or a single browser tab — to the speaker you choose. YouTube on the speaker, calls in your headphones, alerts on the Mac.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(systemName: "hifispeaker.2.fill").font(.system(size: 16))
                    .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                Text("SoundRouter lives in the menu bar. Click this icon at the top of the screen any time.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Allow audio access", systemImage: "waveform.badge.mic").font(.system(size: 20, weight: .semibold))
            Text("To move an app’s sound to another speaker, SoundRouter captures the sound that app plays. macOS asks you to allow this once.")
                .fixedSize(horizontal: false, vertical: true)
            Label("SoundRouter never records your microphone and nothing leaves your Mac.", systemImage: "lock.fill")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(state.askedForAudio ? "Asked — Choose “Allow” in the macOS Prompt" : "Allow Audio Access…") {
                    Welcome.requestAudioAccess()
                    state.askedForAudio = true
                }
                .disabled(state.askedForAudio)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .buttonStyle(.link)
            }
            Text("If you choose “Don’t Allow”, you can turn it on later under System Settings › Privacy & Security › Screen & System Audio Recording.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Route single browser tabs (optional)", systemImage: "rectangle.on.rectangle").font(.system(size: 20, weight: .semibold))
            Text("Add the SoundRouter extension to Chrome, Brave or Edge to send one tab to its own speaker.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open chrome://extensions and turn on Developer mode.")
                step(2, "Click “Load unpacked”, press ⌘⇧G and choose the extension folder (use the button below).")
                step(3, "In a tab, click the SoundRouter toolbar button and pick a speaker.")
            }
            HStack {
                Button("Show Extension Folder") { NSWorkspace.shared.activateFileViewerSelecting([ExtensionInstaller.folder]) }
                Button("Copy chrome://extensions") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("chrome://extensions", forType: .string)
                }
            }
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("A few things to try", systemImage: "sparkles").font(.system(size: 20, weight: .semibold))
            tip("speaker.wave.2.fill", "Click a colored speaker chip next to any app to send it elsewhere.")
            tip("phone.fill", "During calls, other apps are turned down automatically. Change the level in Settings.")
            tip("square.stack.3d.up.fill", "Save setups as presets; let a speaker connecting switch them for you.")
            tip("slider.vertical.3", "Expand a speaker or app for volume boost, sync delay and the equalizer.")
            tip("keyboard", "\(HotKeys.shared.combo(for: .switchSpeaker)?.label ?? "⌃⌥⌘S") switches the Mac default speaker; \(HotKeys.shared.combo(for: .mute)?.label ?? "⌃⌥⌘M") mutes the app playing.")
            tip("link", "Automate with links like soundrouter://preset/Work (see Settings).")
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
enum Welcome {
    private static var window: NSWindow?

    static var hasBeenShown: Bool {
        get { UserDefaults.standard.bool(forKey: "welcomeShown") }
        set { UserDefaults.standard.set(newValue, forKey: "welcomeShown") }
    }

    static func show(page: Int = 0) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 470), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Welcome to SoundRouter"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: WelcomeView(startPage: page) { close() })
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
        hasBeenShown = true
    }

    static func close() {
        window?.close()
        window = nil
    }

    /// Creating a process tap is what makes macOS show the "record system audio" prompt.
    static func requestAudioAccess() {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.isPrivate = true
        var id = AudioObjectID(kAudioObjectUnknown)
        if AudioHardwareCreateProcessTap(tap, &id) == noErr {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AudioHardwareDestroyProcessTap(id) }
        }
    }
}
