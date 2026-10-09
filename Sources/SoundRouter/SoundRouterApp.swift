import AppKit
import SwiftUI

/// Menu bar item with a popover. AppKit rather than SwiftUI's MenuBarExtra so the
/// popover's size is under our control (MenuBarExtra collapsed the scrolling list).
@MainActor
final class StatusBarController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()

    init(openMain: @escaping () -> Void) {
        super.init()
        let image = NSImage(systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: "SoundRouter")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: MenuBarView(openMain: { [weak self] in
            self?.popover.performClose(nil)
            openMain()
        }).environmentObject(AudioModel.shared).environmentObject(UIState.shared))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusBar: StatusBarController?
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(openMain: { [weak self] in self?.showMainWindow() })
        showMainWindow()
        if let i = CommandLine.arguments.firstIndex(of: "--docktest"), CommandLine.arguments.indices.contains(i + 1) {
            let path = CommandLine.arguments[i + 1]
            Task { @MainActor in await DockTest.run(path, delegate: self) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--mictest"), CommandLine.arguments.indices.contains(i + 1) {
            let path = CommandLine.arguments[i + 1]
            Task { @MainActor in try? await Task.sleep(for: .seconds(1)); await MicTest.run(path) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--menutest"), CommandLine.arguments.indices.contains(i + 1) {
            MenuTest.run(CommandLine.arguments[i + 1], statusBar: statusBar!, mainWindow: mainWindow)
        }
    }

    func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "SoundRouter"
            window.contentViewController = NSHostingController(rootView: MainView().environmentObject(AudioModel.shared).environmentObject(UIState.shared))
            window.setContentSize(NSSize(width: 860, height: 620))
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden   // each page has its own heading
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("SoundRouterMain")
            window.delegate = self
            mainWindow = window
        }
        // Show in the Dock and app switcher only while the window is open.
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Closing the window hides SoundRouter from the Dock; it keeps running in the menu bar.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AudioModel.shared.shutdown()
    }
}

@main
struct SoundRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        ExtensionInstaller.install()
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()   // never returns
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(i + 1) {
            MainActor.assumeIsolated { Snapshot.run(CommandLine.arguments[i + 1]) }
        }
    }

    var body: some Scene {
        // Windows and the menu bar item are managed by AppDelegate.
        Settings { EmptyView() }
    }
}
