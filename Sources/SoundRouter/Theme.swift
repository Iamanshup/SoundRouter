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

/// Mute button + slider + percentage. With `boost`, goes to 200% (with a limiter).
struct VolumeControl: View {
    let value: Float
    let muted: Bool
    var enabled = true
    var boost = false
    var mutedSymbol = "speaker.slash.fill"
    var symbol = "speaker.wave.2.fill"
    var showPercent = true
    let setValue: (Float) -> Void
    let toggleMute: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Button { toggleMute?() } label: {
                Image(systemName: muted ? mutedSymbol : (value > 1 ? "speaker.wave.3.fill" : symbol))
                    .font(.system(size: 10))
                    .foregroundStyle(muted ? Color.red : (value > 1 ? Color.orange : Color.secondary))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .disabled(toggleMute == nil)
            .help(muted ? "Unmute" : "Mute")
            ZStack {
                Slider(value: Binding(get: { Double(value) }, set: { setValue(snap(Float($0))) }),
                       in: 0...(boost ? 2 : 1))
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(value > 1 ? .orange : nil)
                if boost {
                    // Tick at 100%.
                    GeometryReader { geo in
                        Rectangle().fill(Color.secondary.opacity(0.5))
                            .frame(width: 1, height: 6)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2 + 7)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(!enabled)
            .opacity(muted ? 0.5 : 1)
            .help(boost ? "Up to 200%. Above 100% a limiter prevents distortion." : "")
            if showPercent {
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(value > 1 ? Color.orange : Color.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    /// Makes 100% easy to hit when boosting.
    private func snap(_ v: Float) -> Float { boost && abs(v - 1) < 0.04 ? 1 : v }
}

/// Left/right balance, -1 … +1, snapping to the centre.
struct BalanceControl: View {
    let value: Float
    let setValue: (Float) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("L").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16)
            Slider(value: Binding(get: { Double(value) }, set: { v in setValue(abs(Float(v)) < 0.06 ? 0 : Float(v)) }), in: -1...1)
                .labelsHidden()
                .controlSize(.mini)
                .frame(maxWidth: .infinity)
            Text("R").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .help("Balance")
    }

    private var label: String {
        if abs(value) < 0.01 { return "C" }
        return (value < 0 ? "L" : "R") + "\(Int((abs(value) * 100).rounded()))"
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
    case apps, speakers, microphones, presets, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apps: return "Apps & Tabs"
        case .speakers: return "Speakers"
        case .microphones: return "Microphones"
        case .presets: return "Presets & Automation"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .speakers: return "hifispeaker.2"
        case .microphones: return "mic"
        case .presets: return "square.stack.3d.up"
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

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

@MainActor
enum Prompt {
    /// Asks for a line of text (e.g. a preset name). nil if cancelled.
    static func text(_ title: String, message: String, initial: String = "", button: String = "Save") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func confirm(_ title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Clickable preset pill; right-click for more.
struct PresetPill: View {
    @EnvironmentObject var model: AudioModel
    let preset: Preset
    let index: Int

    var body: some View {
        let active = model.activePresetID == preset.id
        Button { model.applyPreset(preset.id) } label: {
            HStack(spacing: 5) {
                if active { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                Text(preset.name).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(index < 9 ? "Apply (\(HotKeys.modifierLabel)\(index + 1)). Right-click for more." : "Apply. Right-click for more.")
        .contextMenu { PresetMenuItems(preset: preset) }
    }
}

struct PresetMenuItems: View {
    @EnvironmentObject var model: AudioModel
    let preset: Preset

    var body: some View {
        Button("Apply") { model.applyPreset(preset.id) }
        Button("Update with Current Setup") { model.updatePreset(preset.id) }
        Button("Rename…") {
            if let name = Prompt.text("Rename Preset", message: "", initial: preset.name, button: "Rename") {
                model.renamePreset(preset.id, to: name)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { model.deletePreset(preset.id) }
    }
}

@MainActor
func promptSavePreset(_ model: AudioModel) {
    if let name = Prompt.text("Save Preset",
                              message: "Saves every app’s speaker and volume, the Mac default speaker and the alerts speaker.",
                              initial: "Preset \(model.presets.count + 1)") {
        model.savePreset(named: name)
    }
}
