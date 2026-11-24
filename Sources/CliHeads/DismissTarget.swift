import AppKit
import SwiftUI
import QuartzCore

/// Bottom gradient plus the round X that rises while a head is dragged.
/// Also owns the magnet: close to the X the dragged head is pulled onto it.
/// Coordinates are AppKit (y up), so the spec's "screen y grows down" values
/// are mirrored here.
@MainActor
final class DismissTarget {
    static let circleDiameter: CGFloat = 76
    static let panelSize: CGFloat = 110
    static let gradientHeight: CGFloat = 164
    static let anchorLift: CGFloat = 59
    static let stripWidth: CGFloat = 200
    static let stripHeight: CGFloat = 130
    static let captureDistance: CGFloat = 30
    static let hideDrop: CGFloat = 85
    static let followGain: CGFloat = 0.1
    static let maxRise: CGFloat = 25
    static let restingScale: Double = 0.7

    private let circlePanel: NSPanel
    private let gradientPanel: NSPanel
    private let circleView = DismissView(frame: NSRect(x: 0, y: 0, width: panelSize, height: panelSize))
    private var visible = CGRect.zero
    private var displayID: String?

    private var presence = MagneticSpringAxis(position: 0, target: 0)
    private var offsetX = MagneticSpringAxis(position: 0, target: 0)
    private var offsetY = MagneticSpringAxis(position: 0, target: 0)
    private var scale = MagneticSpringAxis(position: DismissTarget.restingScale, target: DismissTarget.restingScale,
                                           spec: Springs.targetScale, restDistance: 0.002, restSpeed: 0.02)
    private var magnet = MagneticSpringAxis(position: 0, target: 0, spec: Springs.magnetOut,
                                            restDistance: 0.002, restSpeed: 0.02)

    private var wantsVisible = false
    private var tracking = false
    private var forcedFull = false
    private var pointerCenter = CGPoint.zero
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private(set) var isCaptured = false

    /// Called each tick with the magnet-adjusted head centre while tracking.
    var onHeadCenter: ((CGPoint) -> Void)?

    init() {
        circlePanel = DismissTarget.makePanel(size: NSSize(width: Self.panelSize, height: Self.panelSize))
        circlePanel.contentView = circleView
        gradientPanel = DismissTarget.makePanel(size: NSSize(width: 800, height: Self.gradientHeight))
        gradientPanel.contentView = GradientView(frame: NSRect(x: 0, y: 0, width: 800, height: Self.gradientHeight))
    }

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // Just under the heads so a captured head sits on top of the X.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        return panel
    }

    var windowNumber: Int { circlePanel.windowNumber }
    var gradientWindowNumber: Int { gradientPanel.windowNumber }

    private var anchor: CGPoint { CGPoint(x: visible.midX, y: visible.minY + Self.anchorLift) }

    /// Where the circle's centre is right now (includes the hide/show drop).
    var circleCenter: CGPoint {
        CGPoint(x: anchor.x + offsetX.position,
                y: anchor.y + offsetY.position - (1 - presence.position) * Self.hideDrop)
    }

    /// Starts a drag session: the target appears on the first drag movement.
    func beginDrag(near pointer: CGPoint, displays: [MagneticDisplay]) {
        isCaptured = false
        forcedFull = false
        tracking = true
        pointerCenter = pointer
        selectDisplay(at: pointer, displays: displays)
        wantsVisible = true
        magnet.position = 0
        magnet.velocity = 0
        magnet.target = 0
        scale.position = Self.restingScale
        scale.velocity = 0
        scale.target = Self.restingScale
        if timer == nil {
            offsetX.position = 0; offsetX.velocity = 0
            offsetY.position = 0; offsetY.velocity = 0
        }
        applyTargets()
        startTimer()
        render()
    }

    private func selectDisplay(at point: CGPoint, displays: [MagneticDisplay]) {
        guard let display = MagneticSnapEngine.display(at: point, in: displays) else { return }
        if display.id != displayID || display.visibleFrame != visible {
            displayID = display.id
            visible = display.visibleFrame
        }
    }

    /// Feed the pointer-derived head centre. Returns the head centre to show.
    func dragMoved(pointerCenter point: CGPoint, displays: [MagneticDisplay]) -> CGPoint {
        guard tracking else { return point }
        pointerCenter = point
        selectDisplay(at: point, displays: displays)
        applyTargets()
        updateCapture()
        return displayedCenter()
    }

    private func displayedCenter() -> CGPoint {
        let s = CGFloat(Swift.max(0, Swift.min(magnet.position, 1)))
        let c = circleCenter
        return CGPoint(x: pointerCenter.x + (c.x - pointerCenter.x) * s,
                       y: pointerCenter.y + (c.y - pointerCenter.y) * s)
    }

    private var inStrip: Bool {
        pointerCenter.y <= visible.minY + Self.stripHeight &&
        abs(pointerCenter.x - visible.midX) <= Self.stripWidth / 2
    }

    private func applyTargets() {
        presence.target = wantsVisible ? 1 : 0
        if wantsVisible && tracking {
            offsetX.target = Double((pointerCenter.x - visible.midX) * Self.followGain)
            offsetY.target = Double(Swift.min(Self.maxRise, (pointerCenter.y - anchor.y) * Self.followGain))
        } else if !wantsVisible {
            offsetX.target = 0
            offsetY.target = 0
        }
        let inside = tracking && inStrip
        let full = inside || forcedFull
        scale.target = full ? 1 : Self.restingScale
        let wantMagnet: Double = inside ? 1 : 0
        if magnet.target != wantMagnet {
            let spec = inside ? Springs.magnetIn : Springs.magnetOut
            magnet.stiffness = spec.stiffness
            magnet.damping = spec.damping
            magnet.target = wantMagnet
        }
    }

    private func updateCapture() {
        guard tracking, wantsVisible, presence.position > 0.5 else {
            isCaptured = false
            return
        }
        let d = displayedCenter(), c = circleCenter
        let captured = hypot(d.x - c.x, d.y - c.y) < Self.captureDistance
        if captured && !isCaptured { Self.haptic() }
        isCaptured = captured
    }

    static func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Fling-to-close: show the circle at full size and stop magnet tracking.
    func forceFull() {
        forcedFull = true
        tracking = false
        isCaptured = false
        scale.target = 1
    }

    func hide() {
        wantsVisible = false
        tracking = false
        forcedFull = false
        isCaptured = false
        applyTargets()
        scale.target = Self.restingScale
        startTimer()
    }

    // MARK: animation

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        applyTargets()
        presence.advance(dt)
        offsetX.advance(dt)
        offsetY.advance(dt)
        scale.advance(dt)
        magnet.advance(dt)
        render()
        if tracking {
            updateCapture()
            onHeadCenter?(displayedCenter())
        }
        if !wantsVisible && presence.atRest && offsetX.atRest && offsetY.atRest {
            presence.position = 0
            timer?.invalidate()
            timer = nil
            circlePanel.orderOut(nil)
            gradientPanel.orderOut(nil)
        }
    }

    private func render() {
        guard visible.width > 0 else { return }
        let alpha = CGFloat(Swift.max(0, Swift.min(presence.position, 1)))
        let gradientFrame = NSRect(x: visible.minX, y: visible.minY,
                                   width: visible.width, height: Self.gradientHeight)
        if gradientPanel.frame != gradientFrame { gradientPanel.setFrame(gradientFrame, display: false) }
        let c = circleCenter
        circlePanel.setFrameOrigin(NSPoint(x: c.x - Self.panelSize / 2, y: c.y - Self.panelSize / 2))
        circleView.circleScale = CGFloat(scale.position)
        gradientPanel.alphaValue = alpha
        circlePanel.alphaValue = alpha
        if alpha > 0 && !circlePanel.isVisible {
            gradientPanel.orderFrontRegardless()
            circlePanel.orderFrontRegardless()
        }
    }
}

final class GradientView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        // Dark at the bottom, fading to clear at the top.
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.55), NSColor.black.withAlphaComponent(0)])?
            .draw(in: bounds, angle: 90)
    }
}

final class DismissView: NSView {
    var circleScale: CGFloat = 0.7 { didSet { if circleScale != oldValue { needsDisplay = true } } }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = DismissTarget.circleDiameter / 2 * max(0.01, circleScale)
        let circle = NSRect(x: bounds.midX - radius, y: bounds.midY - radius,
                            width: radius * 2, height: radius * 2)
        let path = NSBezierPath(ovalIn: circle)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        NSColor(calibratedWhite: 0.12, alpha: 0.82).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 2
        path.stroke()
        let point = 28 * max(0.01, circleScale)
        if let icon = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close chat")?
            .withSymbolConfiguration(.init(pointSize: point, weight: .bold)),
           let white = icon.withSymbolConfiguration(.init(paletteColors: [.white])) {
            let s = white.size
            white.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2,
                                  width: s.width, height: s.height))
        }
    }
}

/// Holds the caret position for an open conversation, so the little pointer
/// above the chat lines up with whichever head is selected in the row.
@MainActor
final class ChatChrome: ObservableObject {
    @Published var caretX: CGFloat = 40
    /// Bumped each time the chat opens, so the message list is rebuilt while visible.
    @Published var openCount = 0
}

struct CaretShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control: CGPoint(x: rect.midX - 3, y: rect.maxY - 2))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.midX + 3, y: rect.maxY - 2))
        path.closeSubpath()
        return path
    }
}

struct ChatContainer: View {
    @ObservedObject var chrome: ChatChrome
    let session: AgentSession
    let collapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CaretShape()
                .fill(.ultraThinMaterial)
                .frame(width: 24, height: HeadWindows.caretHeight)
                .offset(x: chrome.caretX - 12)
                .frame(width: HeadWindows.chatSize.width, alignment: .leading)
            ChatView(session: session, collapse: collapse, openCount: chrome.openCount)
        }
        .frame(width: HeadWindows.chatSize.width, height: HeadWindows.chatSize.height)
    }
}
