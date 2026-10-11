// A throwaway app that puts one window into full screen (its own Space), for testing that
// SoundRouter's menu bar panel works over full-screen apps.
// Usage: fullscreen-helper <marker file>   — writes the marker once it is full screen.
import AppKit

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let marker = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Full Screen Helper"
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.window.toggleFullScreen(nil) }
    }

    func windowDidEnterFullScreen(_ n: Notification) {
        if let marker { try? "\(window.windowNumber)".write(toFile: marker, atomically: true, encoding: .utf8) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
