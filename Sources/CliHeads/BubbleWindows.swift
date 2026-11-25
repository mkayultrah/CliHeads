import AppKit
import SwiftUI
import Combine
import QuartzCore

/// An AppKit panel is deliberately used instead of a SwiftUI WindowGroup: this
/// permits transparent, borderless, cross-Space floating heads.
class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The head never takes keyboard focus from the application underneath it.
/// The expanded chat panel remains a normal key-capable panel for typing.
final class HeadBubblePanel: FloatingPanel {
    override var canBecomeKey: Bool { false }
}

/// Always route mouse hits to the interactive overlay, not the blur view below.
final class BubbleGlassContainer: NSView {
    weak var interactiveSurface: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? interactiveSurface : nil
    }
}

final class BubbleSurface: NSView {
    var provider: AgentProvider = .claude { didSet { needsDisplay = true } }
    var edgeSide: MagneticSide = .right { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onPress: (() -> Void)?
    var onDrag: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDrop: ((_ releasePointer: CGPoint, _ velocity: CGPoint) -> Void)?
    /// Lets the controller pull a dragged head into the dismiss target.
    var dragFilter: ((_ proposedOrigin: NSPoint, _ pointer: NSPoint) -> NSPoint)?
    var onContextMenu: (() -> Void)?
    var working = false { didSet { needsDisplay = true } }
    var unread = 0 { didSet { needsDisplay = true } }
    // Set by the stack controller; the badge may represent several hidden chats.
    var totalUnread: Int? { didSet { needsDisplay = true } }

    private struct MotionSample {
        let point: CGPoint
        let timestamp: TimeInterval
    }

    /// Receives the head scale (1 = rest). The host applies it as a layer transform.
    var scaleSink: ((CGFloat) -> Void)?
    static let pressedScale: CGFloat = 0.91
    private(set) var scale: CGFloat = 1
    private var scaleSpring = MagneticSpringAxis(position: 1, target: 1, spec: Springs.scale,
                                                 restDistance: 0.002, restSpeed: 0.02)
    private var scaleTimer: Timer?
    private var scaleLast: CFTimeInterval = 0

    private var samples: [MotionSample] = []
    private var initialCursor = NSPoint.zero
    private var initialOrigin = NSPoint.zero
    private var didDrag = false
    private var pressed = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }

    /// Instant scale change (press feedback).
    func snapScale(_ value: CGFloat) {
        scaleTimer?.invalidate()
        scaleTimer = nil
        scale = value
        scaleSpring.position = Double(value)
        scaleSpring.velocity = 0
        scaleSpring.target = Double(value)
        scaleSink?(value)
    }

    /// Bouncy scale spring from the current value.
    func springScale(from start: CGFloat? = nil, to value: CGFloat) {
        if let start { snapScale(start) }
        scaleSpring = MagneticSpringAxis(position: Double(scale), velocity: scaleSpring.velocity,
                                         target: Double(value), spec: Springs.scale,
                                         restDistance: 0.002, restSpeed: 0.02)
        scaleLast = CACurrentMediaTime()
        guard scaleTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advanceScale() }
        }
        scaleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceScale() {
        let now = CACurrentMediaTime()
        scaleSpring.advance(now - scaleLast)
        scaleLast = now
        if scaleSpring.atRest {
            snapScale(CGFloat(scaleSpring.target))
        } else {
            scale = CGFloat(scaleSpring.position)
            scaleSink?(scale)
        }
    }

    func stopAnimations() {
        scaleTimer?.invalidate()
        scaleTimer = nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Keep the face, the frosted layer and the symbol centred on the same
        // 56pt circle. A pressed head changes tint, not the circle's geometry.
        let baseRect = bounds.insetBy(dx: 5, dy: 5)
        // Heads behind the front one are their own windows, so no stack is painted here.
        drawBubble(in: baseRect)

        let badgeCount = totalUnread ?? unread
        if badgeCount > 0 {
            // Red pill, 18pt tall, on the top corner toward the screen centre.
            let countText = badgeCount > 99 ? "99+" : String(badgeCount)
            let font = NSFont.systemFont(ofSize: 11, weight: .bold)
            let textWidth = (countText as NSString).size(withAttributes: [.font: font]).width
            let width = max(18, ceil(textWidth) + 10)
            let x = edgeSide == .right ? bounds.minX + 8 : bounds.maxX - 8 - width
            let badge = NSRect(x: x, y: bounds.maxY - 6 - 18, width: width, height: 18)
            NSColor(calibratedRed: 0xf4 / 255, green: 0x3d / 255, blue: 0x32 / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9).fill()
            drawCentredBadgeText(countText, in: badge, size: 11)
        } else if working {
            // Same rule as the badge: the corner facing away from the screen edge.
            let dot = NSRect(x: edgeSide == .right ? bounds.minX + 6 : bounds.maxX - 18, y: 8, width: 12, height: 12)
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.7, dy: -1.7)).fill()
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    private func drawCentredBadgeText(_ text: String, in rect: NSRect, size: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let measured = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: rect.midX - measured.width / 2,
                                            y: rect.midY - measured.height / 2),
                                withAttributes: attrs)
    }

    private func drawBubble(in rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect)
        if let logo = HeadArt.logo(for: provider.rawValue) {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.set()
            // Shadow caster sits just inside the face so its edge never peeks out.
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSGraphicsContext.restoreGraphicsState()
            HeadArt.drawFace(provider: provider.rawValue, logo: logo, in: rect, pressed: pressed)
            return
        }
        // Translucent colour over the NSVisualEffectView, so the blur shows through.
        let tint: CGFloat = pressed ? 0.34 : 0.20
        let gradientColors: [NSColor]
        switch provider {
        case .claude:
            gradientColors = [NSColor(calibratedRed: 0.79, green: 0.45, blue: 0.30, alpha: tint),
                              NSColor(calibratedRed: 0.52, green: 0.29, blue: 0.26, alpha: tint)]
        case .codex:
            gradientColors = [NSColor(calibratedRed: 0.15, green: 0.64, blue: 0.44, alpha: tint),
                              NSColor(calibratedRed: 0.08, green: 0.40, blue: 0.32, alpha: tint)]
        case .gemini:
            gradientColors = [NSColor(calibratedRed: 0.34, green: 0.49, blue: 0.95, alpha: tint),
                              NSColor(calibratedRed: 0.59, green: 0.34, blue: 0.80, alpha: tint)]
        case .grok:
            gradientColors = [NSColor(calibratedRed: 0.36, green: 0.37, blue: 0.42, alpha: tint),
                              NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.15, alpha: tint)]
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.set()
        NSGradient(colors: gradientColors)?.draw(in: circle, angle: 60)
        NSGraphicsContext.restoreGraphicsState()

        // The blur comes from the NSVisualEffectView underneath.
        let iconName: String
        switch provider {
        case .claude: iconName = "terminal.fill"
        case .codex: iconName = "circle.hexagongrid.fill"
        case .gemini: iconName = "sparkles"
        case .grok: iconName = "bolt.fill"
        }
        if let symbol = NSImage(systemSymbolName: iconName, accessibilityDescription: provider.title) {
            let size = NSSize(width: 30, height: 30)
            let position = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            let configured = symbol.withSymbolConfiguration(.init(pointSize: 25, weight: .medium)) ?? symbol
            let whiteIcon = configured.withSymbolConfiguration(.init(paletteColors: [.white])) ?? configured
            whiteIcon.draw(in: NSRect(origin: position, size: size), from: .zero,
                           operation: .sourceOver, fraction: 1)
        }
    }

    private func addSample(_ point: CGPoint, timestamp: TimeInterval) {
        samples.append(MotionSample(point: point, timestamp: timestamp))
        let cutoff = timestamp - 0.135
        samples.removeAll { $0.timestamp < cutoff }
        if samples.count > 20 { samples.removeFirst(samples.count - 20) }
    }

    private func releaseVelocity() -> CGPoint {
        guard let last = samples.last, let first = samples.first else { return .zero }
        let dt = last.timestamp - first.timestamp
        guard dt >= 0.012 else { return .zero }
        return CGPoint(x: max(-3200, min(3200, (last.point.x - first.point.x) / dt)),
                       y: max(-3200, min(3200, (last.point.y - first.point.y) / dt)))
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        snapScale(Self.pressedScale)
        onPress?()
        initialCursor = NSEvent.mouseLocation
        initialOrigin = window?.frame.origin ?? .zero
        didDrag = false
        samples = []
        addSample(initialCursor, timestamp: event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let cursor = NSEvent.mouseLocation
        let dx = cursor.x - initialCursor.x, dy = cursor.y - initialCursor.y
        addSample(cursor, timestamp: event.timestamp)
        if !didDrag && hypot(dx, dy) > 5 {
            didDrag = true
            pressed = false
            onDragStarted?()
        }
        guard didDrag else { return }
        var origin = NSPoint(x: initialOrigin.x + dx, y: initialOrigin.y + dy)
        if let dragFilter { origin = dragFilter(origin, cursor) }
        window.setFrameOrigin(origin)
        onDrag?()
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        snapScale(1)
        let pointer = NSEvent.mouseLocation
        addSample(pointer, timestamp: event.timestamp)
        if didDrag { onDrop?(pointer, releaseVelocity()) }
        else { onClick?() }
        samples = []
    }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?() }
}

final class PreviewSurface: NSView {
    var text: String = "" { didSet { needsDisplay = true } }
    var bubbleSide: MagneticSide = .right { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    static let tailWidth: CGFloat = 12
    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 248
    static let maxLines = 3
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    private static var attributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        // Wrap up to maxLines; .truncatesLastVisibleLine adds the ellipsis.
        style.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: style]
    }

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: width, height: lineHeight * CGFloat(maxLines)),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        return min(lineHeight * CGFloat(maxLines), max(lineHeight, ceil(measured.height)))
    }

    /// Panel size for a message: 220-248 wide, at most three lines of text.
    static func preferredSize(for text: String) -> NSSize {
        let natural = (text as NSString).size(withAttributes: [.font: font]).width
        let width = min(maxWidth, max(minWidth, ceil(natural) + 26 + tailWidth + 4))
        let textWidth = width - tailWidth - 4 - 26
        return NSSize(width: width, height: textHeight(text, width: textWidth) + 20 + 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !text.isEmpty else { return }
        let tailWidth = Self.tailWidth
        let bubbleRect: NSRect
        let tailBaseX: CGFloat
        let tailTipX: CGFloat
        if bubbleSide == .right {
            bubbleRect = NSRect(x: 2, y: 8, width: bounds.width - tailWidth - 4, height: bounds.height - 16)
            tailBaseX = bubbleRect.maxX
            tailTipX = bounds.maxX - 2
        } else {
            bubbleRect = NSRect(x: tailWidth + 2, y: 8, width: bounds.width - tailWidth - 4, height: bounds.height - 16)
            tailBaseX = bubbleRect.minX
            tailTipX = 2
        }

        // The tail sits near the top, pointing back at the head.
        let bubblePath = NSBezierPath(roundedRect: bubbleRect, xRadius: 16, yRadius: 16)
        bubblePath.move(to: NSPoint(x: tailBaseX, y: bubbleRect.maxY - 11))
        bubblePath.line(to: NSPoint(x: tailBaseX, y: bubbleRect.maxY - 23))
        bubblePath.line(to: NSPoint(x: tailTipX, y: bubbleRect.maxY - 17))
        bubblePath.close()

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.set()
        NSColor(calibratedRed: 0.15, green: 0.57, blue: 0.98, alpha: 0.97).setFill()
        bubblePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        let textWidth = bubbleRect.width - 26
        let height = Self.textHeight(text, width: textWidth)
        let textRect = NSRect(x: bubbleRect.minX + 13,
                              y: bubbleRect.midY - height / 2,
                              width: textWidth, height: height)
        (text as NSString).draw(with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: Self.attributes)
    }
}

@MainActor
final class HeadWindows {
    let session: AgentSession
    let bubblePanel: FloatingPanel
    let chatPanel: FloatingPanel
    let bubbleView: BubbleSurface
    let previewPanel: HeadBubblePanel
    let previewView: PreviewSurface
    let chrome = ChatChrome()
    var onClose: (() -> Void)?
    var onMoved: (() -> Void)?
    var onManageChats: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onTapped: (() -> Void)?
    var onOpenDirect: (() -> Void)?
    var onCollapsed: (() -> Void)?
    var onDragStarted: (() -> Void)?
    /// Return true when the drop was consumed (eg. dropped on the X).
    var onDropRequest: ((_ pointer: CGPoint, _ velocity: CGPoint) -> Bool)?
    var onUnreadChanged: (() -> Void)?
    private(set) var anchorPosition: CGPoint
    /// Where the head sat before a display went away, so it can go back later.
    private var displacedAnchor: CGPoint?
    private var cancellables = Set<AnyCancellable>()
    private(set) var isExpanded = false

    private var spring: MagneticSpringPoint?
    private var springTimer: Timer?
    private var springDestination: CGPoint?
    private var springCommits = false
    private var springCompletion: (() -> Void)?
    private var lastSpringTime: CFTimeInterval = 0
    private var springStartedAt: CFTimeInterval = 0
    private var visibilityGeneration: UInt64 = 0
    private var previewTimer: Timer?
    private var previewExpiresAt: TimeInterval = 0
    private var previewEligible = false
    private var previewGeneration: UInt64 = 0
    private var launchVelocity: CGPoint?
    // Chat panel open/close animation.
    private let chatRoot = NSView()
    private var panelAxis = MagneticSpringAxis(position: 0, target: 0, spec: Springs.panelOpen,
                                               restDistance: 0.002, restSpeed: 0.02)
    private var panelTimer: Timer?
    private var panelLast: CFTimeInterval = 0
    private var panelOpening = true

    static let previewSideOffset: CGFloat = 73
    static let previewTopDrop: CGFloat = 8
    static let flyInDistance: CGFloat = 78

    static let bubbleSize: CGFloat = 66
    static let caretHeight: CGFloat = 11
    static let chatSize = NSSize(width: 430, height: 570 + caretHeight)

    private static var displays: [MagneticDisplay] {
        NSScreen.screens.enumerated().map { index, screen in
            // The screen number survives displays coming and going; the index doesn't.
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return MagneticDisplay(id: number?.stringValue ?? String(index), frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
    static var magneticDisplays: [MagneticDisplay] { displays }

    init(session: AgentSession, initialPosition: NSPoint?) {
        self.session = session
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = initialPosition ?? NSPoint(x: screen.maxX - Self.bubbleSize, y: screen.midY)
        anchorPosition = origin
        bubblePanel = HeadBubblePanel(contentRect: NSRect(origin: origin, size: NSSize(width: Self.bubbleSize, height: Self.bubbleSize)),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        bubbleView = BubbleSurface(frame: NSRect(x: 0, y: 0, width: Self.bubbleSize, height: Self.bubbleSize))
        bubbleView.provider = session.provider
        let glassContainer = BubbleGlassContainer(frame: bubbleView.frame)
        glassContainer.interactiveSurface = bubbleView
        let frosted = NSVisualEffectView(frame: bubbleView.bounds.insetBy(dx: 5, dy: 5))
        frosted.material = .popover
        frosted.blendingMode = .behindWindow
        frosted.state = .active
        frosted.wantsLayer = true
        frosted.layer?.cornerRadius = (Self.bubbleSize - 10) / 2
        frosted.layer?.masksToBounds = true
        // Logo heads paint their own glass; the blur behind them only fringes the edge.
        frosted.isHidden = HeadArt.logo(for: session.provider.rawValue) != nil
        glassContainer.addSubview(frosted)
        glassContainer.addSubview(bubbleView)
        // The transform lives on a child of the content view, so the window's
        // root layer is left alone.
        let bubbleRoot = NSView(frame: glassContainer.frame)
        bubbleRoot.wantsLayer = true
        glassContainer.wantsLayer = true
        bubbleRoot.addSubview(glassContainer)
        bubblePanel.contentView = bubbleRoot
        bubbleView.scaleSink = { [weak glassContainer] scale in
            guard let glassContainer else { return }
            Self.applyScale(scale, to: glassContainer)
        }
        bubblePanel.becomesKeyOnlyIfNeeded = true
        previewPanel = HeadBubblePanel(contentRect: NSRect(origin: origin, size: NSSize(width: 250, height: 86)),
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        previewView = PreviewSurface(frame: NSRect(x: 0, y: 0, width: 250, height: 86))
        previewPanel.contentView = previewView
        chatPanel = FloatingPanel(contentRect: NSRect(origin: origin, size: Self.chatSize),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        configure(panel: bubblePanel)
        configure(panel: previewPanel)
        configure(panel: chatPanel)
        chatPanel.hasShadow = true
        let chatHost = NSHostingView(rootView: ChatContainer(chrome: chrome, session: session, collapse: { [weak self] in
            self?.collapse()
        }))
        let chatShell = NSView(frame: NSRect(origin: .zero, size: Self.chatSize))
        chatShell.wantsLayer = true
        chatRoot.frame = chatShell.bounds
        chatRoot.autoresizingMask = [.width, .height]
        chatRoot.wantsLayer = true
        chatHost.frame = chatRoot.bounds
        chatHost.autoresizingMask = [.width, .height]
        chatRoot.addSubview(chatHost)
        chatShell.addSubview(chatRoot)
        chatPanel.contentView = chatShell
        previewView.onClick = { [weak self] in
            guard let self else { return }
            if let onTapped = self.onTapped { onTapped() } else { self.toggle() }
        }
        bubbleView.onClick = { [weak self] in
            guard let self else { return }
            if let onTapped = self.onTapped { onTapped() }
            else { self.toggle() }
        }
        bubbleView.onPress = { [weak self] in self?.cancelSpring() }
        bubbleView.onDragStarted = { [weak self] in self?.onDragStarted?() }
        bubbleView.onDrag = { [weak self] in
            guard let self else { return }
            self.refreshPreviewVisibility()
        }
        bubbleView.onDrop = { [weak self] pointer, velocity in
            guard let self else { return }
            if self.onDropRequest?(pointer, velocity) == true { return }
            self.snapToEdge(releasePointer: pointer, velocity: velocity)
        }
        bubbleView.onContextMenu = { [weak self] in self?.showMenu() }
        session.$status.sink { [weak self] state in
            self?.bubbleView.working = (state == .working || state == .starting)
            self?.refreshPreviewVisibility()
        }.store(in: &cancellables)
        session.$unread.sink { [weak self] count in
            self?.bubbleView.unread = count
            self?.refreshPreviewVisibility()
            self?.onUnreadChanged?()
        }.store(in: &cancellables)
        session.$latestAssistantPreview.sink { [weak self] text in
            guard let self else { return }
            self.previewView.text = text
            if !text.isEmpty { self.previewPanel.setContentSize(PreviewSurface.preferredSize(for: text)) }
            self.refreshPreviewVisibility()
        }.store(in: &cancellables)
        bubblePanel.orderFrontRegardless()
        reconcileScreenLayout(animated: false)
    }

    private func configure(panel: FloatingPanel) {
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none // our spring engine owns the movement
    }

    func toggle() { if isExpanded { collapse() } else { showChat(at: chatPanel.frame.origin, caretX: 40) } }

    /// Shows this head's conversation hanging under the row, caret pointing
    /// at the head. Calling it again just moves the panel and caret.
    func showChat(at origin: CGPoint, caretX: CGFloat) {
        chrome.caretX = caretX
        chatPanel.setFrameOrigin(origin)
        guard !isExpanded else { return }
        isExpanded = true
        chrome.openCount += 1
        previewTimer?.invalidate()
        previewExpiresAt = 0
        session.markRead()
        previewPanel.orderOut(nil)
        if !chatPanel.isVisible {
            panelAxis.position = 0
            panelAxis.velocity = 0
            applyPanel()
        }
        chatPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPanel(opening: true)
        focusComposer()
    }

    /// Puts the cursor in the message box every time the chat opens, not just the first.
    private func focusComposer() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isExpanded, let root = self.chatPanel.contentView,
                  let editor = Self.firstView(of: ChatComposer.ReturnToSendTextView.self, in: root),
                  self.chatPanel.firstResponder !== editor else { return }
            self.chatPanel.makeFirstResponder(editor)
        }
    }

    private static func firstView<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = firstView(of: type, in: child) { return match }
        }
        return nil
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        startPanel(opening: false)
        session.markCollapsed()
        refreshPreviewVisibility()
        onCollapsed?()
    }

    /// Scales a view about its centre, whatever the layer's anchor point is.
    private static func applyScale(_ scale: CGFloat, to view: NSView) {
        guard let layer = view.layer else { return }
        layer.transform = scaleTransform(scale, about: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
                                         layer: layer, size: view.bounds.size)
    }

    private static func scaleTransform(_ scale: CGFloat, about pivot: CGPoint,
                                       layer: CALayer, size: CGSize) -> CATransform3D {
        if abs(scale - 1) < 0.0005 { return CATransform3DIdentity }
        let anchor = CGPoint(x: layer.anchorPoint.x * size.width, y: layer.anchorPoint.y * size.height)
        let move = CATransform3DMakeTranslation((1 - scale) * (pivot.x - anchor.x),
                                                (1 - scale) * (pivot.y - anchor.y), 0)
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), move)
    }

    private func startPanel(opening: Bool) {
        panelOpening = opening
        let spec = opening ? Springs.panelOpen : Springs.panelClose
        panelAxis.stiffness = spec.stiffness
        panelAxis.damping = spec.damping
        panelAxis.target = opening ? 1 : 0
        panelLast = CACurrentMediaTime()
        guard panelTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advancePanel() }
        }
        panelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPanelTimer() {
        panelTimer?.invalidate()
        panelTimer = nil
    }

    private func advancePanel() {
        let now = CACurrentMediaTime()
        panelAxis.advance(now - panelLast)
        panelLast = now
        if !panelOpening && panelAxis.position <= 0 {
            // Closing never overshoots below zero.
            panelAxis.position = 0
            panelAxis.velocity = 0
        }
        if panelAxis.atRest {
            panelAxis.position = panelAxis.target
            panelAxis.velocity = 0
            stopPanelTimer()
            if !panelOpening { chatPanel.orderOut(nil) }
        }
        applyPanel()
    }

    /// Pivot is the top of the panel under the selected head; at rest the
    /// transform is exactly identity so text stays sharp.
    private func applyPanel() {
        guard let layer = chatRoot.layer else { return }
        let p = panelAxis.position
        let upper: Double = panelOpening ? 1.06 : 1
        let scale = CGFloat(max(0.001, min(p, upper)))
        let pivot = CGPoint(x: chrome.caretX,
                            y: chatRoot.isFlipped ? 0 : chatRoot.bounds.height)
        layer.transform = Self.scaleTransform(scale, about: pivot, layer: layer, size: chatRoot.bounds.size)
        chatPanel.alphaValue = CGFloat(max(0, min(p, 1)))
    }

    func setStackUnread(_ count: Int?) { bubbleView.totalUnread = count }

    func setPreviewEligible(_ eligible: Bool) {
        previewEligible = eligible
        refreshPreviewVisibility()
    }

    /// Only the blue tooltip is transient. The red badge remains until read.
    func showTransientReplyPreview() {
        previewGeneration &+= 1
        let generation = previewGeneration
        previewTimer?.invalidate()
        previewExpiresAt = CACurrentMediaTime() + PreviewPolicy.duration
        previewPanel.alphaValue = 1
        refreshPreviewVisibility()
        let timer = Timer(timeInterval: PreviewPolicy.duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.previewGeneration == generation else { return }
                self.previewExpiresAt = 0
                self.refreshPreviewVisibility()
            }
        }
        previewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Glides the head behind the front of its stack, then hides it.
    func tuckBubble(into origin: CGPoint, animated: Bool) {
        previewPanel.orderOut(nil)
        guard animated && bubblePanel.isVisible else {
            visibilityGeneration &+= 1
            cancelSpring()
            bubblePanel.setFrameOrigin(origin)
            bubblePanel.orderOut(nil)
            return
        }
        if springDestination == origin { return }
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        runSpring(to: origin, velocity: .zero, commits: false) { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            self.bubblePanel.orderOut(nil)
        }
    }

    /// Visual placement is separate from the remembered magnetic anchor.
    /// A head sitting in the open row must not overwrite its dock position.
    func presentBubble(at origin: CGPoint, animated: Bool) {
        visibilityGeneration &+= 1
        if !bubblePanel.isVisible { bubblePanel.orderFrontRegardless() }
        bubbleView.edgeSide = currentSide()
        if animated {
            // Keep a spring that is already heading here, so velocity survives
            // repeated layout passes.
            if springDestination == origin { return }
            if spring == nil && bubblePanel.frame.origin == origin { refreshPreviewVisibility(); return }
            let launch = launchVelocity ?? .zero
            launchVelocity = nil
            runSpring(to: origin, velocity: launch, commits: false, completion: nil)
        } else {
            launchVelocity = nil
            cancelSpring()
            bubblePanel.setFrameOrigin(origin)
            refreshPreviewVisibility()
        }
    }

    /// Used by the follow-the-leader chain while a stack is being dragged.
    func setVisualOrigin(_ origin: CGPoint) {
        cancelSpring()
        visibilityGeneration &+= 1
        if !bubblePanel.isVisible { bubblePanel.orderFrontRegardless() }
        bubblePanel.setFrameOrigin(origin)
        previewPanel.orderOut(nil)
    }

    func hideBubble() {
        visibilityGeneration &+= 1
        cancelSpring()
        bubblePanel.orderOut(nil)
        previewPanel.orderOut(nil)
    }

    func setAnchor(_ origin: CGPoint) { anchorPosition = origin; displacedAnchor = nil }

    private func currentSide() -> MagneticSide {
        let center = CGPoint(x: bubblePanel.frame.midX, y: bubblePanel.frame.midY)
        if let display = MagneticSnapEngine.display(at: center, in: Self.displays) {
            return center.x < display.visibleFrame.midX ? .left : .right
        }
        return .right
    }

    private func previewFrame(for bubble: NSRect) -> NSRect {
        let side = currentSide()
        let size = previewPanel.frame.size
        let center = CGPoint(x: bubble.midX, y: bubble.midY)
        let visible = MagneticSnapEngine.display(at: center, in: Self.displays)?.visibleFrame
        // On the screen-centre side, ~73pt out from the head centre. The
        // bubble body (8pt inset in the panel) sits 8pt below the head top.
        let x: CGFloat = side == .right ? center.x - Self.previewSideOffset - size.width
                                        : center.x + Self.previewSideOffset
        let preferredY = bubble.maxY - Self.previewTopDrop + 8 - size.height
        guard let visible else { return NSRect(x: x, y: preferredY, width: size.width, height: size.height) }
        let y = max(visible.minY + 2, min(preferredY, visible.maxY - size.height - 2))
        let boundedX = max(visible.minX + 3, min(x, visible.maxX - size.width - 3))
        return NSRect(x: boundedX, y: y, width: size.width, height: size.height)
    }

    private func refreshPreviewVisibility() {
        bubbleView.edgeSide = currentSide()
        previewView.bubbleSide = currentSide()
        guard bubblePanel.isVisible,
              PreviewPolicy.shouldShow(unread: session.unread,
                                       text: session.latestAssistantPreview,
                                       expanded: isExpanded,
                                       eligible: previewEligible,
                                       now: CACurrentMediaTime(),
                                       expiresAt: previewExpiresAt) else {
            previewPanel.orderOut(nil)
            return
        }
        previewPanel.setFrame(previewFrame(for: bubblePanel.frame), display: false)
        previewPanel.orderFrontRegardless()
    }

    /// Called after dragging. Selects the screen containing the release
    /// pointer even if the bubble still overlaps the previous display.
    func snapToEdge(releasePointer: CGPoint, velocity: CGPoint) {
        guard let target = MagneticSnapEngine.target(
            for: bubblePanel.frame.origin,
            bubbleSize: bubblePanel.frame.size,
            releasePointer: releasePointer,
            velocity: velocity,
            displays: Self.displays
        ) else { return }
        // The position spring carries the full release velocity.
        anchorPosition = target.origin; displacedAnchor = nil
        runSpring(to: target.origin, velocity: velocity, commits: true, completion: nil)
    }

    /// Fling-to-close: spring the head onto the close circle, then call back.
    func flingTo(center: CGPoint, velocity: CGPoint, completion: @escaping () -> Void) {
        let size = bubblePanel.frame.size
        runSpring(to: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                  velocity: velocity, commits: false, completion: completion)
    }

    /// New head: scale 0.3 -> 1 with a bouncy pop, flying in from past the screen edge.
    func prepareFlyIn() {
        let side = currentSide()
        let center = CGPoint(x: bubblePanel.frame.midX, y: bubblePanel.frame.midY)
        guard let visible = MagneticSnapEngine.display(at: center, in: Self.displays)?.visibleFrame else { return }
        var origin = bubblePanel.frame.origin
        origin.x = side == .right ? visible.maxX + Self.flyInDistance
                                  : visible.minX - Self.flyInDistance - bubblePanel.frame.width
        bubblePanel.setFrameOrigin(origin)
        launchVelocity = CGPoint(x: side == .right ? -1000 : 1000, y: 1500)
        bubbleView.springScale(from: 0.3, to: 1)
    }

    /// When the hardware layout changes, bubbles attach to the nearest
    /// connected display.
    func reconcileScreenLayout(animated: Bool = true) {
        let size = bubblePanel.frame.size, displays = Self.displays
        func fits(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 40 }
        let destination: CGPoint
        if let wanted = displacedAnchor,
           let back = MagneticSnapEngine.recoveryTarget(for: wanted, bubbleSize: size, displays: displays),
           fits(back.origin, wanted) {
            // The display it was moved off has come back, so go home.
            destination = back.origin; displacedAnchor = nil
        } else if let target = MagneticSnapEngine.recoveryTarget(for: anchorPosition, bubbleSize: size, displays: displays) {
            if displacedAnchor == nil, !fits(target.origin, anchorPosition) { displacedAnchor = anchorPosition }
            destination = target.origin
        } else { return }
        anchorPosition = destination
        if animated {
            runSpring(to: destination, velocity: .zero, commits: true, completion: nil)
        } else {
            cancelSpring()
            bubblePanel.setFrameOrigin(destination)
            bubbleView.edgeSide = currentSide()
            refreshPreviewVisibility()
            onMoved?()
        }
    }

    /// Interruptible velocity-preserving Hooke spring. `commits` springs are
    /// real dock moves and report onMoved when they settle; the others are
    /// purely visual (row expansion, stacking).
    private func runSpring(to destination: CGPoint, velocity: CGPoint,
                           spec: Springs.Spec = Springs.pos,
                           commits: Bool, completion: (() -> Void)?) {
        cancelSpring()
        let origin = bubblePanel.frame.origin
        if abs(origin.x - destination.x) < Springs.restDistance && abs(origin.y - destination.y) < Springs.restDistance
            && hypot(velocity.x, velocity.y) < 10 {
            bubblePanel.setFrameOrigin(destination)
            bubbleView.edgeSide = currentSide()
            refreshPreviewVisibility()
            if commits { onMoved?() }
            completion?()
            return
        }
        spring = MagneticSpringPoint(origin: origin, velocity: velocity, destination: destination,
                                     spec: spec)
        springDestination = destination
        springCommits = commits
        springCompletion = completion
        lastSpringTime = CACurrentMediaTime()
        springStartedAt = lastSpringTime
        let fps = min(120, max(60, bubblePanel.screen?.maximumFramesPerSecond ?? 60))
        let timer = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in
            // Timer callbacks are not actor-isolated in Swift 6, even when
            // scheduled on the main run loop. Hop explicitly to MainActor.
            Task { @MainActor [weak self] in
                self?.advanceSpring()
            }
        }
        springTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceSpring() {
        guard var model = spring, let destination = springDestination else {
            cancelSpring()
            return
        }
        let now = CACurrentMediaTime()
        model.step(elapsed: now - lastSpringTime)
        lastSpringTime = now
        spring = model
        bubblePanel.setFrameOrigin(model.origin)
        bubbleView.edgeSide = currentSide()
        refreshPreviewVisibility()
        if model.atRest || now - springStartedAt > 2.5 {
            bubblePanel.setFrameOrigin(destination)
            bubbleView.edgeSide = currentSide()
            refreshPreviewVisibility()
            let commits = springCommits
            let completion = springCompletion
            cancelSpring()
            if commits { onMoved?() }
            completion?()
        }
    }

    private func cancelSpring() {
        springTimer?.invalidate()
        springTimer = nil
        spring = nil
        springDestination = nil
        springCommits = false
        springCompletion = nil
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: isExpanded ? "Collapse" : "Open conversation", action: #selector(menuToggle), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let browse = NSMenuItem(title: "Chats… (New / Resume)", action: #selector(menuBrowse), keyEquivalent: "")
        browse.target = self
        menu.addItem(browse)
        let fresh = NSMenuItem(title: "New \(session.provider.title) chat", action: #selector(menuNew), keyEquivalent: "")
        fresh.target = self
        menu.addItem(fresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Close this head and stop agent", action: #selector(menuClose), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 52, y: 32), in: bubbleView)
    }

    @objc private func menuToggle() {
        if isExpanded { collapse() }
        else if let onOpenDirect { onOpenDirect() }
        else { toggle() }
    }
    @objc private func menuBrowse() { onManageChats?() }
    @objc private func menuNew() { onNewChat?() }
    @objc private func menuClose() { onClose?() }

    func dismiss() {
        previewTimer?.invalidate()
        previewTimer = nil
        cancelSpring()
        stopPanelTimer()
        bubbleView.stopAnimations()
        session.terminate()
        bubblePanel.orderOut(nil)
        previewPanel.orderOut(nil)
        chatPanel.orderOut(nil)
        bubblePanel.close()
        previewPanel.close()
        chatPanel.close()
    }
}
