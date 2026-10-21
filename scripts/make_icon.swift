import AppKit
// Usage: swift scripts/make_icon.swift icon1024.png  (then sips into SongCreator/Assets.xcassets/AppIcon.appiconset)

// Song Creator icon: a dark squircle with a glowing waveform made of takes, and a record dot.
let size: CGFloat = 1024
let out = CommandLine.arguments[1]

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// macOS icon grid: 824 pt body centred in 1024, continuous-corner radius ~185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0, 0, 0, 0.45))
ctx.addPath(shape)
ctx.setFillColor(color(20, 20, 40))
ctx.fillPath()
ctx.restoreGState()

// Background: deep indigo to near-black, with a violet glow behind the waveform.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let bg = CGGradient(colorsSpace: cs, colors: [color(44, 40, 92), color(16, 15, 36)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [color(130, 90, 255, 0.45), color(130, 90, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 520), endRadius: 430, options: [])
// Faint track lanes, like the arrange view.
for y in stride(from: 250.0, through: 790.0, by: 135.0) {
    ctx.setFillColor(color(255, 255, 255, 0.045))
    ctx.fill(CGRect(x: 100, y: y, width: 824, height: 3))
}
// Top sheen.
let sheen = CGGradient(colorsSpace: cs, colors: [color(255, 255, 255, 0.10), color(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

// Waveform: rounded bars, colour sweeping blue → violet → pink, symmetric envelope.
let heights: [CGFloat] = [70, 130, 210, 300, 400, 470, 400, 520, 430, 330, 250, 170, 100]
let barW: CGFloat = 38, gap: CGFloat = 18
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
let x0 = 512 - total / 2, midY: CGFloat = 520
let stops: [(CGFloat, CGFloat, CGFloat)] = [(80, 170, 255), (150, 110, 255), (255, 90, 170)]
func sweep(_ t: CGFloat) -> CGColor {
    let seg = t < 0.5 ? 0 : 1
    let f = (t - CGFloat(seg) * 0.5) / 0.5
    let a = stops[seg], b = stops[seg + 1]
    return color(a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
}
for (i, h) in heights.enumerated() {
    let x = x0 + CGFloat(i) * (barW + gap)
    let r = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
    let c = sweep(CGFloat(i) / CGFloat(heights.count - 1))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: c.copy(alpha: 0.75))
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.setFillColor(c)
    ctx.fillPath()
    ctx.restoreGState()
}

// Playhead.
ctx.setFillColor(color(255, 255, 255, 0.85))
ctx.fill(CGRect(x: 512 + 3 * (barW + gap) - gap / 2 - 3, y: 340, width: 6, height: 485))

// Record button, lower right.
let dot = CGPoint(x: 760, y: 238)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: color(255, 60, 60, 0.8))
ctx.setFillColor(color(255, 255, 255, 0.95))
ctx.fillEllipse(in: CGRect(x: dot.x - 74, y: dot.y - 74, width: 148, height: 148))
ctx.restoreGState()
let red = CGGradient(colorsSpace: cs, colors: [color(255, 95, 90), color(220, 30, 40)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: dot.x - 56, y: dot.y - 56, width: 112, height: 112))
ctx.clip()
ctx.drawLinearGradient(red, start: CGPoint(x: dot.x, y: dot.y + 56), end: CGPoint(x: dot.x, y: dot.y - 56), options: [])
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
