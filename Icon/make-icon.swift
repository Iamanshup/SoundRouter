// Renders the SoundRouter app icon. Usage: swift make-icon.swift <out.png> [size]
import AppKit

let out = CommandLine.arguments[1]
let px = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let s = CGFloat(px) / 1024   // design on a 1024 grid

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ns = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ns
let ctx = ns.cgContext
ctx.scaleBy(x: s, y: s)
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r/255, green: g/255, blue: b/255, alpha: a) }

// Body: macOS icon grid (824pt squircle centred, with drop shadow).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(shape); ctx.setFillColor(rgb(20, 24, 60)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(22, 20, 70), rgb(52, 46, 160), rgb(48, 118, 240)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 160, y: 100), end: CGPoint(x: 864, y: 924), options: [])
ctx.translateBy(x: -14, y: 0)   // optical centring of the glyph
// Soft top highlight.
let glow = CGGradient(colorsSpace: space, colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 380, y: 860), startRadius: 0, endCenter: CGPoint(x: 380, y: 860), endRadius: 560, options: [])

// Routes: one source on the left fanning out to three speakers.
let source = CGPoint(x: 268, y: 512)
let colors = [rgb(255, 176, 64), rgb(92, 230, 196), rgb(255, 104, 150)]
let ends = [CGPoint(x: 640, y: 724), CGPoint(x: 640, y: 512), CGPoint(x: 640, y: 300)]
ctx.setLineCap(.round)
for (i, end) in ends.enumerated() {
    let path = CGMutablePath()
    path.move(to: source)
    path.addCurve(to: end, control1: CGPoint(x: 430, y: source.y), control2: CGPoint(x: 470, y: end.y))
    // Glow under each line.
    ctx.addPath(path); ctx.setStrokeColor(colors[i].copy(alpha: 0.16)!); ctx.setLineWidth(52); ctx.strokePath()
    ctx.addPath(path); ctx.setStrokeColor(colors[i]); ctx.setLineWidth(24); ctx.strokePath()
}

// Source node.
ctx.setShadow(offset: .zero, blur: 30, color: rgb(255, 255, 255, 0.45))
ctx.setFillColor(rgb(255, 255, 255)); ctx.fillEllipse(in: CGRect(x: source.x - 52, y: source.y - 52, width: 104, height: 104))
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setFillColor(rgb(46, 52, 140)); ctx.fillEllipse(in: CGRect(x: source.x - 22, y: source.y - 22, width: 44, height: 44))

// Speakers: a white speaker cone with coloured sound waves.
for (i, end) in ends.enumerated() {
    let c = end
    let speaker = CGMutablePath()
    speaker.addRoundedRect(in: CGRect(x: c.x - 6, y: c.y - 30, width: 44, height: 60), cornerWidth: 10, cornerHeight: 10)
    speaker.move(to: CGPoint(x: c.x + 30, y: c.y - 30))
    speaker.addLine(to: CGPoint(x: c.x + 84, y: c.y - 70))
    speaker.addQuadCurve(to: CGPoint(x: c.x + 96, y: c.y - 62), control: CGPoint(x: c.x + 96, y: c.y - 74))
    speaker.addLine(to: CGPoint(x: c.x + 96, y: c.y + 62))
    speaker.addQuadCurve(to: CGPoint(x: c.x + 84, y: c.y + 70), control: CGPoint(x: c.x + 96, y: c.y + 74))
    speaker.addLine(to: CGPoint(x: c.x + 30, y: c.y + 30))
    speaker.closeSubpath()
    ctx.addPath(speaker); ctx.setFillColor(rgb(255, 255, 255)); ctx.fillPath()

    for (k, r) in [CGFloat(44), 82].enumerated() {
        let center = CGPoint(x: c.x + 96, y: c.y)
        ctx.addArc(center: center, radius: r, startAngle: -.pi / 3.6, endAngle: .pi / 3.6, clockwise: false)
        ctx.setStrokeColor(colors[i])
        ctx.setLineWidth(k == 0 ? 18 : 14)
        ctx.strokePath()
    }
}
ctx.restoreGState()

// Thin inner edge for definition on light backgrounds.
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setStrokeColor(rgb(255, 255, 255, 0.12)); ctx.setLineWidth(3); ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
