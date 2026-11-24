import AppKit

/// Brand logo heads with a glass finish: logo clipped to the circle, a soft
/// top gloss, a darker bottom, and a thin dark rim that hides edge fringing.
enum HeadArt {
    private static var cache: [String: NSImage] = [:]

    /// Logo shipped in the app bundle. Nil under `swift run`, so callers fall back to SF Symbols.
    static func logo(for provider: String, bundle: Bundle = .main) -> NSImage? {
        if let hit = cache[provider] { return hit }
        guard let url = bundle.url(forResource: "head-\(provider)", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[provider] = image
        return image
    }

    /// Where the logo goes relative to the head circle, and what sits behind it.
    private static func layout(for provider: String, in rect: NSRect) -> (logoRect: NSRect, background: NSColor?) {
        switch provider {
        case "codex":
            // The logo is a cloud on white. Blow it up so the circle sits inside the cloud
            // and no white shows; the >_ glyph still fits comfortably.
            let side = rect.width * 1.62
            return (NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side), nil)
        case "gemini":
            // Antigravity mark on transparency, given a white tile like its app icon.
            return (rect.insetBy(dx: rect.width * 0.13, dy: rect.width * 0.13), .white)
        default:
            // Claude and Grok are opaque full bleed tiles; overscale so the rounded corners never show.
            return (rect.insetBy(dx: -rect.width * 0.03, dy: -rect.width * 0.03), nil)
        }
    }

    /// Draws the head face (no drop shadow) into the current context.
    static func drawFace(provider: String, logo: NSImage, in rect: NSRect, pressed: Bool = false, alpha: CGFloat = 1) {
        let circle = NSBezierPath(ovalIn: rect)
        let (logoRect, background) = layout(for: provider, in: rect)
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        if let background { background.withAlphaComponent(alpha).setFill(); rect.fill() }
        NSGraphicsContext.current?.imageInterpolation = .high
        logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: alpha)

        // Bottom half falls slightly into shade, like light from above.
        NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.16 * alpha)])?
            .draw(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.55), angle: -90)

        // Glass gloss: a flattened radial glow near the top that fades to nothing,
        // so there's no hard edge anywhere.
        NSGraphicsContext.saveGraphicsState()
        let squash = NSAffineTransform()
        squash.translateX(by: rect.midX, yBy: rect.maxY - rect.height * 0.2)
        squash.scaleX(by: 1, yBy: 0.6)
        squash.concat()
        let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.42 * alpha),
                                       NSColor.white.withAlphaComponent(0.16 * alpha),
                                       NSColor.white.withAlphaComponent(0)],
                              atLocations: [0, 0.5, 1], colorSpace: .sRGB)
        glow?.draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: rect.width * 0.5, options: [])
        NSGraphicsContext.restoreGraphicsState()

        if pressed {
            NSColor.black.withAlphaComponent(0.18).setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Thin dark rim over the antialiased edge, so nothing light fringes around the head.
        let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        rim.lineWidth = 1
        NSColor.black.withAlphaComponent(0.22 * alpha).setStroke()
        rim.stroke()
    }

    /// A finished head as an image, for SwiftUI (chat header).
    static func image(provider: String, logo: NSImage, diameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { bounds in
            drawFace(provider: provider, logo: logo, in: bounds)
            return true
        }
    }
}
