// Draws the app icon and writes Assets/icon.png (1024px) and Resources/AppIcon.icns.
// Run: swift Scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }

func drawIcon(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // macOS icon grid: 824pt body, room for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(color(0x4B2FD6)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x9A86FF), color(0x5B3BEA), color(0x2E1A9E)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    // Soft glow behind the front head.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 560, y: 460), startRadius: 0,
                           endCenter: CGPoint(x: 560, y: 460), endRadius: 420, options: [])

    // The stack: two heads peeking out behind the front one.
    let front = CGPoint(x: 560, y: 450), frontR: CGFloat = 235
    for (centre, r, alpha) in [(CGPoint(x: 300, y: 735), CGFloat(112), CGFloat(0.30)),
                               (CGPoint(x: 395, y: 625), CGFloat(165), CGFloat(0.52))] {
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x1A0B66, 0.35))
        ctx.setFillColor(color(0xFFFFFF, alpha))
        ctx.fillEllipse(in: circle(centre, r))
    }

    // Front head with a little speech bubble tail.
    let head = CGMutablePath()
    head.addEllipse(in: circle(front, frontR))
    let tail = CGMutablePath()
    let a1 = CGFloat.pi * 1.08, a2 = CGFloat.pi * 1.38
    let p1 = CGPoint(x: front.x + cos(a1) * (frontR - 20), y: front.y + sin(a1) * (frontR - 20))
    let p2 = CGPoint(x: front.x + cos(a2) * (frontR - 20), y: front.y + sin(a2) * (frontR - 20))
    let tip = CGPoint(x: 318, y: 205)
    tail.move(to: p1)
    tail.addQuadCurve(to: tip, control: CGPoint(x: 330, y: 300))
    tail.addQuadCurve(to: p2, control: CGPoint(x: 410, y: 250))
    tail.closeSubpath()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x14085A, 0.45))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.addPath(head); ctx.addPath(tail); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Terminal prompt inside the head, filled with the background gradient.
    let font = NSFont.monospacedSystemFont(ofSize: 250, weight: .heavy)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: ">_", attributes: [.font: font]))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.saveGState()
    ctx.textPosition = CGPoint(x: front.x - bounds.midX, y: front.y - bounds.midY + 6)
    ctx.setTextDrawingMode(.clip)
    CTLineDraw(line, ctx)
    let ink = CGGradient(colorsSpace: space, colors: [color(0x7A62FF), color(0x3A21C2)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ink, start: CGPoint(x: 0, y: front.y + 140), end: CGPoint(x: 0, y: front.y - 140), options: [])
    ctx.restoreGState()

    // Unread badge.
    let badge = CGPoint(x: front.x + frontR * 0.72, y: front.y + frontR * 0.72), badgeR: CGFloat = 70
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.25))
    ctx.setFillColor(color(0xFFFFFF)); ctx.fillEllipse(in: circle(badge, badgeR + 14))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(color(0xFF3B5C)); ctx.fillEllipse(in: circle(badge, badgeR))
    ctx.restoreGState()

    // Thin inner edge so it reads on dark docks.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.18)); ctx.setLineWidth(3); ctx.strokePath()
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / size, y: CGFloat(px) / size)
    drawIcon(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let assets = root.appendingPathComponent("Assets"), resources = root.appendingPathComponent("Resources")
try fm.createDirectory(at: assets, withIntermediateDirectories: true)
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
try render(1024).write(to: assets.appendingPathComponent("icon.png"))

let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Assets/icon.png and Resources/AppIcon.icns")
