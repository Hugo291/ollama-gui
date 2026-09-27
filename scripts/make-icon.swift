// Renders the app icon (1024×1024 PNG) with Core Graphics.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size = 1024
let arguments = CommandLine.arguments.dropFirst()
let output = arguments.first { !$0.hasPrefix("--") } ?? "icon_1024.png"
/// Windows icons fill more of the canvas and use a plain rounded square.
let windowsStyle = arguments.contains("--windows")

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Can't create the bitmap context")
}
NSGraphicsContext.current = graphics
let context = graphics.cgContext
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Superellipse approximating the macOS icon shape.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / exponent), s)
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// Rhombus (one layer of the stack) with rounded corners.
func layer(center: CGPoint, halfWidth w: CGFloat, halfHeight h: CGFloat, radius: CGFloat) -> CGPath {
    let left = CGPoint(x: center.x - w, y: center.y)
    let top = CGPoint(x: center.x, y: center.y + h)
    let right = CGPoint(x: center.x + w, y: center.y)
    let bottom = CGPoint(x: center.x, y: center.y - h)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: (left.x + top.x) / 2, y: (left.y + top.y) / 2))
    path.addArc(tangent1End: top, tangent2End: right, radius: radius)
    path.addArc(tangent1End: right, tangent2End: bottom, radius: radius)
    path.addArc(tangent1End: bottom, tangent2End: left, radius: radius)
    path.addArc(tangent1End: left, tangent2End: top, radius: radius)
    path.closeSubpath()
    return path
}

// Background tile: the macOS 824 pt grid with a soft shadow, or a larger rounded square for Windows.
let tileRect = windowsStyle ? CGRect(x: 40, y: 40, width: 944, height: 944) : CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = windowsStyle
    ? CGPath(roundedRect: tileRect, cornerWidth: 190, cornerHeight: 190, transform: nil)
    : squircle(in: tileRect)

context.saveGState()
if !windowsStyle {
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
}
context.addPath(tile)
context.setFillColor(color(0x4B3BE0))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(tile)
context.clip()
let background = CGGradient(colorsSpace: colorSpace, colors: [color(0x8A7DFF), color(0x5A45F0), color(0x3322B8)] as CFArray, locations: [0, 0.55, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
let gloss = CGGradient(colorsSpace: colorSpace, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(gloss, startCenter: CGPoint(x: 400, y: 900), startRadius: 0, endCenter: CGPoint(x: 400, y: 900), endRadius: 620, options: [])
context.restoreGState()

// Stack of three layers; each upper layer cuts a gap in the ones below it.
let halfWidth: CGFloat = 238
let halfHeight: CGFloat = 132
let spacing: CGFloat = 92
let gap: CGFloat = 22
let centers = [CGPoint(x: 512, y: 512 - spacing), CGPoint(x: 512, y: 512), CGPoint(x: 512, y: 512 + spacing)]
let alphas: [CGFloat] = [0.55, 0.78, 1]

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x1A0F6B, 0.45))
context.beginTransparencyLayer(auxiliaryInfo: nil)
for (index, center) in centers.enumerated() {
    let path = layer(center: center, halfWidth: halfWidth, halfHeight: halfHeight, radius: 34)
    if index > 0 {
        // Knock out a gap around this layer so the one below reads as a separate sheet.
        context.saveGState()
        context.setBlendMode(.clear)
        context.addPath(path)
        context.setLineWidth(gap * 2)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }
    context.addPath(path)
    context.setFillColor(color(0xFFFFFF, alphas[index]))
    context.fillPath()
}
context.endTransparencyLayer()
context.restoreGState()

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
