import Foundation

/// Keeps a copy of the bundled browser extension at a stable path, so "Load unpacked"
/// keeps working when the app is rebuilt or moved.
enum ExtensionInstaller {
    static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SoundRouter/BrowserExtension", isDirectory: true)

    static func install() {
        guard let source = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] {
            let dest = folder.appendingPathComponent(name)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: source.appendingPathComponent(name), to: dest)
        }
    }
}
