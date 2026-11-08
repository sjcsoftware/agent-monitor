// Renders the Agent Monitor app icon into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset> [preview.png]
//
// Design: three glass status pills on a deep-navy squircle — working, needs you, finished.
import AppKit

let args = CommandLine.arguments.dropFirst()
let output = URL(fileURLWithPath: args.first ?? "AppIcon.iconset")
let preview = args.dropFirst().first.map { URL(fileURLWithPath: $0) }
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a,
    ])!
}

/// Continuous-corner rounded rect approximating Apple's squircle.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let c = radius * 1.28
    p.move(to: CGPoint(x: r.minX + c, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + c), control1: CGPoint(x: r.maxX - c * 0.35, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + c * 0.35))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
    p.addCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - c * 0.35), control2: CGPoint(x: r.maxX - c * 0.35, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control1: CGPoint(x: r.minX + c * 0.35, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - c * 0.35))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
    p.addCurve(to: CGPoint(x: r.minX + c, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + c * 0.35), control2: CGPoint(x: r.minX + c * 0.35, y: r.minY))
    p.closeSubpath()
    return p
}

func draw(_ ctx: CGContext) {
    // Everything is drawn in a 1024-point design space.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body, radius: 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x0A1020))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x1B2847), rgb(0x0A1020), rgb(0x060A14)] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Three pills: working, needs you, finished.
    let states: [UInt32] = [0xF5C97A, 0xEC6A7D, 0x5FE0B8]
    let pill: CGFloat = 196, gap: CGFloat = 46
    let total = pill * 3 + gap * 2
    for (i, color) in states.enumerated() {
        let r = CGRect(x: 512 - total / 2 + CGFloat(i) * (pill + gap), y: 512 - pill / 2, width: pill, height: pill)
        let path = CGPath(roundedRect: r, cornerWidth: 66, cornerHeight: 66, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(rgb(0x162038, 0.85))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(rgb(color, 0.45))
        ctx.setLineWidth(6)
        ctx.strokePath()
        let dot = r.insetBy(dx: 58, dy: 58)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 36, color: rgb(color, 0.75))
        ctx.setFillColor(rgb(color))
        ctx.fillEllipse(in: dot)
        ctx.restoreGState()
    }

    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0x7D98FF, 0.22))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

// The 1024 px rendition is skipped: a menu-bar app's icon only shows in Finder and Spotlight.
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    if base < 512 { try render(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png")) }
}
if let preview { try render(256).write(to: preview) }
