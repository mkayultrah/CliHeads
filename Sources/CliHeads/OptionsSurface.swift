import AppKit

/// The grey Messenger-style circle at the end of the expanded chat tray.
final class OptionsSurface: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 5, dy: 5)
        let circle = NSBezierPath(ovalIn: rect)
        NSColor(calibratedWhite: 0.28, alpha: 0.23).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.43).setStroke()
        circle.lineWidth = 1.2
        circle.stroke()
        if let icon = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Chat options")?
            .withSymbolConfiguration(.init(pointSize: 23, weight: .medium)) {
            let whiteIcon = icon.withSymbolConfiguration(.init(paletteColors: [.white])) ?? icon
            whiteIcon.draw(in: NSRect(x: rect.midX - 15, y: rect.midY - 15,
                                      width: 30, height: 30),
                           from: .zero, operation: .sourceOver, fraction: 0.95)
        }
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
}
