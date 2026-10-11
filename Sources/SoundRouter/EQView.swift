import AppKit
import SwiftUI

/// Vertical slider for one EQ band (−12…+12 dB), snapping to 0.
struct BandSlider: View {
    let value: Double
    let label: String
    let tint: Color
    let setValue: (Double) -> Void
    private let range = 12.0

    var body: some View {
        VStack(spacing: 4) {
            Text(value == 0 ? "0" : String(format: "%+.0f", value))
                .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                .frame(height: 12)
            GeometryReader { geo in
                let h = geo.size.height
                let y = h / 2 - CGFloat(value / range) * (h / 2 - 7)
                ZStack {
                    Capsule().fill(Color.primary.opacity(0.1)).frame(width: 4)
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 10, height: 1)   // 0 dB
                    Capsule().fill(tint)
                        .frame(width: 4, height: abs(y - h / 2))
                        .position(x: geo.size.width / 2, y: (y + h / 2) / 2)
                    Circle().fill(.white).shadow(radius: 1, y: 0.5)
                        .frame(width: 14, height: 14)
                        .position(x: geo.size.width / 2, y: y)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let v = Double((h / 2 - g.location.y) / (h / 2 - 7)) * range
                    let clamped = max(-range, min(range, v))
                    setValue(abs(clamped) < 0.7 ? 0 : (clamped * 2).rounded() / 2)
                })
            }
            .frame(width: 22, height: 120)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

/// 10-band graphic EQ with presets.
struct GraphicEQEditor: View {
    let gains: [Double]
    let tint: Color
    let setGains: ([Double]?) -> Void

    var body: some View {
        let values = gains.count == 10 ? gains : Array(repeating: 0, count: 10)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu(GraphicEQ.presetName(values) ?? "Custom") {
                    ForEach(GraphicEQ.presets, id: \.name) { preset in
                        Button(preset.name) { setGains(preset.gains) }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Reset") { setGains(nil) }.disabled(values.allSatisfy { $0 == 0 })
            }
            HStack(spacing: 6) {
                ForEach(0..<10, id: \.self) { i in
                    BandSlider(value: values[i], label: GraphicEQ.labels[i], tint: tint) { v in
                        var next = values
                        next[i] = v
                        setGains(next)
                    }
                }
            }
            HStack {
                Text("+12 dB … −12 dB").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Text("Hz").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// EQ popover for an app.
struct AppEQPopover: View {
    @EnvironmentObject var model: AudioModel
    let app: AudioApp

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Equalizer: \(app.name)").font(.system(size: 13, weight: .semibold))
            GraphicEQEditor(gains: model.rule(for: app.id).eq ?? [], tint: .accentColor) { model.setEQ($0, for: app) }
        }
        .padding(16)
        .frame(width: 330)
    }
}

/// EQ popover for a speaker: a headphone correction profile plus a graphic EQ.
struct SpeakerEQPopover: View {
    @EnvironmentObject var model: AudioModel
    let device: OutputDevice

    var body: some View {
        let profile = model.speakerProfiles[device.uid]
        VStack(alignment: .leading, spacing: 12) {
            Text("Equalizer: \(device.name)").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Headphone correction").font(.system(size: 11, weight: .medium))
                Menu(profile?.name ?? "None") {
                    Button("None") { model.setProfile(nil, for: device) }
                    Divider()
                    ForEach(AudioModel.bundledProfiles, id: \.name) { p in
                        Button(p.name) { model.setProfile(p, for: device) }
                    }
                    Divider()
                    Button("Import AutoEQ Profile…") { importProfile() }
                }
                .fixedSize()
                Text("Flattens your headphones’ sound using measurements from AutoEQ. Get profiles for other headphones at autoeq.app (format: “Equalizer APO ParametricEQ”).")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            GraphicEQEditor(gains: model.speakerEQ[device.uid] ?? [], tint: model.color(for: device.uid)) { model.setEQ($0, for: device) }
            Text("Applies to everything SoundRouter plays on this speaker. Apps that are playing are routed through SoundRouter automatically so the EQ reaches them.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose a ParametricEQ.txt file from autoeq.app"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ParametricEQ", with: "")
        if let profile = CorrectionProfile.parse(text, name: name) {
            model.setProfile(profile, for: device)
        } else {
            _ = Prompt.confirm("Couldn’t read that file", message: "Choose an AutoEQ “ParametricEQ.txt” file (Equalizer APO format).", button: "OK")
        }
    }
}
