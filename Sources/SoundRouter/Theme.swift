import AppKit
import SwiftUI

/// Speaker colours echo the app icon's three routes, plus a few more for bigger setups.
enum Theme {
    static let nsPalette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.69, blue: 0.25, alpha: 1), // amber
        NSColor(srgbRed: 0.27, green: 0.82, blue: 0.69, alpha: 1), // mint
        NSColor(srgbRed: 1.00, green: 0.41, blue: 0.59, alpha: 1), // pink
        NSColor(srgbRed: 0.30, green: 0.66, blue: 1.00, alpha: 1), // sky
        NSColor(srgbRed: 0.64, green: 0.49, blue: 1.00, alpha: 1), // violet
        NSColor(srgbRed: 0.55, green: 0.80, blue: 0.30, alpha: 1), // lime
    ]
    static let neutral = NSColor.systemGray

    /// A coloured dot for NSMenu items (non-template so the colour survives).
    static func dot(_ color: NSColor, size: CGFloat = 10) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Pop-up menus

/// NSMenu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.image = image
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { handler() }
}

enum PopUp {
    /// Shows a menu at the mouse pointer (used by chips, which are plain SwiftUI buttons).
    static func show(_ items: [NSMenuItem]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Building blocks

/// Rounded "Control Center" card.
struct Card<Content: View>: View {
    var title: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || accessory != nil {
                HStack {
                    if let title {
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    accessory
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

/// Icon in a tinted circle.
struct IconBubble: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.2))
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

struct Badge: View {
    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// Coloured capsule showing where something plays; click for a menu of speakers.
struct Chip: View {
    let title: String
    let color: Color
    var help: String = ""
    /// The chip keeps its size; neighbouring text (app or tab titles) truncates instead.
    var maxTextWidth: CGFloat = 130
    let menu: () -> [NSMenuItem]

    var body: some View {
        Button { PopUp.show(menu()) } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: maxTextWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .layoutPriority(1)
    }
}

/// Live output level (for audio we route) as four little bars.
struct LevelBars: View {
    let level: Float
    let color: Color

    private static let shape: [CGFloat] = [0.55, 1, 0.7, 0.85]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: max(3, 14 * CGFloat(min(1, sqrt(level) * 1.5)) * Self.shape[i]))
            }
        }
        .frame(width: 18, height: 14)
        .animation(.easeOut(duration: 0.22), value: level)
    }
}

/// Animated "playing" indicator for audio we don't route (no level available).
struct PlayingIndicator: View {
    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.green)
            .symbolEffect(.variableColor.iterative, options: .repeating)
            .frame(width: 18, height: 14)
            .help("Playing audio")
    }
}

/// Mute button + slider + percentage.
struct VolumeControl: View {
    let value: Float
    let muted: Bool
    var enabled = true
    var mutedSymbol = "speaker.slash.fill"
    var symbol = "speaker.wave.2.fill"
    var showPercent = true
    let setValue: (Float) -> Void
    let toggleMute: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Button { toggleMute?() } label: {
                Image(systemName: muted ? mutedSymbol : symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(muted ? Color.red : Color.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .disabled(toggleMute == nil)
            .help(muted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { Double(value) }, set: { setValue(Float($0)) }), in: 0...1)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .controlSize(.small)
                .disabled(!enabled)
                .opacity(muted ? 0.5 : 1)
            if showPercent {
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }
}

/// UI-only state shared by the panel and the window.
final class UIState: ObservableObject {
    static let shared = UIState()
    @Published var expanded: Set<String> = []
    @Published var showOtherApps = false
    @Published var section: SidebarSection? = .apps

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case apps, speakers, microphones, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apps: return "Apps & Tabs"
        case .speakers: return "Speakers"
        case .microphones: return "Microphones"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .speakers: return "hifispeaker.2"
        case .microphones: return "mic"
        case .settings: return "gearshape"
        }
    }
}

/// True inside the main window, where rows have more room than in the menu bar panel.
private struct RoomyKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var roomy: Bool {
        get { self[RoomyKey.self] }
        set { self[RoomyKey.self] = newValue }
    }
}
