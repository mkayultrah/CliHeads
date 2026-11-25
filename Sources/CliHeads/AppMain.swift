import AppKit
import Foundation
import SwiftUI
import QuartzCore
import ServiceManagement

@main
@MainActor
enum CliHeadsMain {
    private static let retainedDelegate = CliHeadsDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = retainedDelegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class CliHeadsDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private var providerItems: [AgentProvider: NSMenuItem] = [:]
    private var loginItem: NSMenuItem?
    private var windows: [UUID: HeadWindows] = [:]
    private var eventMonitors: [Any] = []
    private var sessionPicker: NSWindow?
    private var optionsPanel: FloatingPanel?
    private var optionsSurface: OptionsSurface?
    private var activationCounter: UInt64 = 0
    private var activationOrder: [UUID: UInt64] = [:]
    // Each display edge owns an independent messenger-style stack.
    // Only one stack is open (lined up along the top) at a time.
    private var expandedStack: BubbleStackKey?
    private var activeHeadID: UUID?
    private var rowOrder: [UUID] = []
    private var frontHeadByStack: [BubbleStackKey: UUID] = [:]
    private var lastUsedStack: BubbleStackKey?
    private var isReflowing = false
    private var suppressCollapseCallback = false
    private var lastBubbleTapAt: CFTimeInterval = -100
    // Drag state: the leader is under the pointer, followers trail behind.
    private var lifted: [UUID] = []
    private var chainTimer: Timer?
    private var chainSprings: [UUID: MagneticSpringPoint] = [:]
    private var scrim: ScrimPanel?
    private var lastChainTick: CFTimeInterval = 0
    private var pendingDropLeader: UUID?
    private let dismissTarget = DismissTarget()
    // Heads mid fling-to-close. They stay out of layout and ignore clicks.
    private var closing: Set<UUID> = []
    private static let maxVisibleFollowers = 4
    private static let maxPeeks = 2

    private var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CliHeads", isDirectory: true)
            .appendingPathComponent("heads.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A dead CLI's stdin must not kill the app on write.
        signal(SIGPIPE, SIG_IGN)
        let firstRun = !FileManager.default.fileExists(atPath: storageURL.path)
        createStatusMenu()
        createEditMenu()
        createOptionsBubble()
        restoreSavedHeads()
        if firstRun && windows.isEmpty {
            createHead(in: NSHomeDirectory(), provider: Self.defaultProvider, activate: false)
        }
        // Reading the login shell PATH can take a moment, so do it off the main thread.
        DispatchQueue.global(qos: .utility).async { CLILocator.warmUp() }
        layoutStacks(animated: false)
        persistHeads()
        installDismissMonitors()
        dismissTarget.onHeadCenter = { [weak self] center in self?.magnetTick(center) }
    }

    /// The menu bar never shows for an accessory app, but its key equivalents still
    /// fire. Without this, Cmd+C/V/X/A/Z do nothing in the chat.
    private func createEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// The first installed CLI, for chats where nobody picked one.
    private static var defaultProvider: AgentProvider {
        AgentProvider.allCases.first { CLILocator.find($0.executable) != nil } ?? .claude
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        // All panels reattach before stack membership is recalculated.
        isReflowing = true
        closeActiveChat()
        expandedStack = nil
        activeHeadID = nil
        for head in windows.values { head.reconcileScreenLayout(animated: false) }
        isReflowing = false
        layoutStacks(animated: false)
        persistHeads()
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistHeads()
        windows.values.forEach { $0.session.terminate() }
    }

    private func createStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: "CliHeads")
            button.toolTip = "CliHeads • local AI agent conversations"
        }
        let menu = NSMenu()
        menu.delegate = self
        let browse = NSMenuItem(title: "Chats… (New / Resume)", action: #selector(showSessionPicker), keyEquivalent: "o")
        browse.target = self; menu.addItem(browse)
        menu.addItem(.separator())
        for (provider, selector) in [
            (AgentProvider.claude, #selector(newClaude)),
            (.codex, #selector(newCodex)),
            (.gemini, #selector(newGemini)),
            (.grok, #selector(newGrok))
        ] {
            let action = NSMenuItem(title: "New \(provider.title) chat", action: selector, keyEquivalent: "")
            action.target = self; menu.addItem(action)
            providerItems[provider] = action
        }
        let folder = NSMenuItem(title: "New chat in folder…", action: #selector(newFolderHead), keyEquivalent: "")
        folder.target = self; menu.addItem(folder)
        menu.addItem(.separator())
        let show = NSMenuItem(title: "Regroup chat heads", action: #selector(showAll), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self; menu.addItem(login); loginItem = login
        let about = NSMenuItem(title: "About CliHeads", action: #selector(showAbout), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CliHeads", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu; statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for (provider, item) in providerItems {
            let installed = CLILocator.find(provider.executable) != nil
            item.title = "New \(provider.title) chat" + (installed ? "" : " (not installed)")
            item.isEnabled = installed
        }
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let provider = providerItems.first(where: { $0.value === item })?.key {
            return CLILocator.find(provider.executable) != nil
        }
        return true
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change launch at login"
            alert.informativeText = error.localizedDescription + "\n\nYou can also add CliHeads in System Settings > General > Login Items."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        collapseAll()
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(string: "Chat heads for the Claude Code, Codex, Gemini and Grok CLIs.\n")
        let link = "github.com/mkayultrah/CliHeads"
        credits.append(NSAttributedString(string: link, attributes: [.link: URL(string: "https://" + link)!]))
        credits.addAttributes([.font: NSFont.systemFont(ofSize: 11)], range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func createOptionsBubble() {
        let size = HeadWindows.bubbleSize
        let panel = HeadBubblePanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let container = BubbleGlassContainer(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let blur = NSVisualEffectView(frame: container.bounds.insetBy(dx: 5, dy: 5))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = (size - 10) / 2
        blur.layer?.masksToBounds = true
        let surface = OptionsSurface(frame: container.bounds)
        container.interactiveSurface = surface
        surface.onClick = { [weak self] in self?.openOptionsMenu() }
        container.addSubview(blur)
        container.addSubview(surface)
        panel.contentView = container
        optionsSurface = surface
        optionsPanel = panel
        panel.orderOut(nil)
    }

    private func openOptionsMenu() {
        guard let optionsSurface else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (provider, selector) in [
            (AgentProvider.claude, #selector(newClaude)),
            (.codex, #selector(newCodex)),
            (.gemini, #selector(newGemini)),
            (.grok, #selector(newGrok))
        ] {
            let installed = CLILocator.find(provider.executable) != nil
            let item = NSMenuItem(title: "New \(provider.title) chat" + (installed ? "" : " (not installed)"),
                                  action: selector, keyEquivalent: "")
            item.target = self
            item.isEnabled = installed
            menu.addItem(item)
        }
        let folder = NSMenuItem(title: "New chat in folder…", action: #selector(newFolderHead), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        let resume = NSMenuItem(title: "Browse / resume conversations…",
                                action: #selector(showSessionPicker), keyEquivalent: "")
        resume.target = self
        menu.addItem(resume)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: optionsSurface.bounds.midX, y: 6), in: optionsSurface)
    }

    private func rememberActivity(_ id: UUID) {
        activationCounter &+= 1
        activationOrder[id] = activationCounter
    }

    private func chosenWorkingDirectory() -> String {
        if let activeHeadID, let head = windows[activeHeadID] { return head.session.directory }
        if let key = expandedStack ?? lastUsedStack, let id = frontHeadByStack[key],
           let head = windows[id] { return head.session.directory }
        return NSHomeDirectory()
    }

    @objc private func newClaude() { createHead(in: chosenWorkingDirectory(), provider: .claude) }
    @objc private func newCodex() { createHead(in: chosenWorkingDirectory(), provider: .codex) }
    @objc private func newGemini() { createHead(in: chosenWorkingDirectory(), provider: .gemini) }
    @objc private func newGrok() { createHead(in: chosenWorkingDirectory(), provider: .grok) }

    @objc private func newFolderHead() {
        let panel = NSOpenPanel()
        panel.title = "Choose a CLI working directory"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        // Accessory apps can open panels behind the front app, and the chat would cover it.
        collapseAll()
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { createHead(in: url.path, provider: Self.defaultProvider) }
    }

    @objc private func showSessionPicker() {
        collapseAll()
        // A picker closed with the red button is rebuilt so its list isn't stale.
        if let window = sessionPicker, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let currentSessionIDs = Set(windows.values.compactMap { head -> String? in
            guard let sid = head.session.agentSessionID else { return nil }
            return head.session.provider.rawValue + ":" + sid
        })
        let view = SessionPickerView(
            existing: currentSessionIDs,
            onResume: { [weak self] record in
                self?.createHead(in: record.directory, provider: record.provider,
                                 sessionID: record.sessionID, title: record.title,
                                 history: SessionCatalog.recentHistory(record))
                self?.closeSessionPicker()
            },
            onManualResume: { [weak self] provider, id, directory in
                self?.createHead(in: directory, provider: provider,
                                 sessionID: id, title: "Resumed \(provider.title)")
                self?.closeSessionPicker()
            },
            onNew: { [weak self] provider, directory in
                self?.createHead(in: directory, provider: provider, continueLatest: false)
                self?.closeSessionPicker()
            }
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "CliHeads – Conversations"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sessionPicker = window
    }

    private func closeSessionPicker() {
        sessionPicker?.close()
        sessionPicker = nil
    }

    @objc private func showAll() {
        collapseAll()
        // Pull any head that ended up off screen back onto a display.
        for head in windows.values where !closing.contains(head.session.id) {
            head.reconcileScreenLayout(animated: true)
        }
        layoutStacks(animated: true)
        persistHeads()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

    private func createHead(in directory: String, provider: AgentProvider,
                            sessionID: String? = nil, title: String? = nil,
                            history: [TranscriptMessage] = [], activate: Bool = true,
                            continueLatest: Bool = true) {
        if let sessionID, let existing = windows.values.first(where: {
            $0.session.provider == provider && $0.session.agentSessionID == sessionID
        }) {
            openConversationDirectly(existing.session.id)
            return
        }
        let number = windows.values.filter { $0.session.provider == provider }.count + 1
        let name = title ?? (number == 1 ? provider.title : "\(provider.title) \(number)")
        var initialMessage: [ChatMessage] = history.map {
            ChatMessage(role: $0.role == "user" ? .user : .assistant, text: $0.text, date: .distantPast)
        }
        if let sessionID {
            initialMessage.append(ChatMessage(role: .notice, text:
                "Resuming \(provider.title) session \(sessionID). The messages above are a local preview; the CLI restores the actual context. Avoid opening the same session simultaneously in Terminal."))
        }
        let saved = SavedHead(title: name, directory: directory, provider: provider,
                              agentSessionID: sessionID, messages: initialMessage)
        addHead(saved)
        if continueLatest, sessionID == nil, history.isEmpty {
            let taken = Set(windows.values.compactMap { head -> String? in
                guard let sid = head.session.agentSessionID else { return nil }
                return head.session.provider.rawValue + ":" + sid
            })
            windows[saved.id]?.session.continueLatestSession(excluding: taken, isTaken: { [weak self] in
                self?.sessionInUse($0) ?? false
            })
        }
        if activate {
            windows[saved.id]?.prepareFlyIn()
            openConversationDirectly(saved.id)
        }
        else { layoutStacks() }
        persistHeads()
    }

    private func sessionInUse(_ key: String) -> Bool {
        windows.values.contains { head in
            head.session.agentSessionID.map { head.session.provider.rawValue + ":" + $0 } == key
        }
    }

    private func addHead(_ saved: SavedHead) {
        let session = AgentSession(saved: saved)
        // New bubbles must not spawn directly on top of existing ones.
        let position: NSPoint?
        if let x = saved.x, let y = saved.y {
            position = NSPoint(x: x, y: y)
        } else if let key = expandedStack ?? lastUsedStack, let id = frontHeadByStack[key],
                  let front = windows[id] {
            // New chats join the stack you were last using, like Messenger.
            position = front.anchorPosition
        } else if let screen = NSScreen.main {
            let slot = CGFloat(windows.count % 7)
            let size = HeadWindows.bubbleSize
            let available = screen.visibleFrame
            position = NSPoint(x: available.maxX - size + 8,
                               y: max(available.minY + 14,
                                      min(available.midY - slot * (size + 10), available.maxY - size - 14)))
        } else {
            position = nil
        }
        let head = HeadWindows(session: session, initialPosition: position)
        windows[session.id] = head
        session.onSave = { [weak self] in self?.persistHeads() }
        let id = session.id
        session.onIncomingReply = { [weak self] in self?.sessionDidReceiveReply(id) }
        head.onMoved = { [weak self] in self?.headDidFinishMoving(session.id) }
        head.onTapped = { [weak self] in self?.tapHead(session.id) }
        head.onOpenDirect = { [weak self] in self?.openConversationDirectly(session.id) }
        head.onCollapsed = { [weak self] in self?.headDidCollapse(session.id) }
        head.onDragStarted = { [weak self] in self?.headDidStartDragging(session.id) }
        head.onUnreadChanged = { [weak self] in
            // @Published notifies before assigning the new value. Recalculate
            // after the assignment so grouped unread badges clear immediately.
            DispatchQueue.main.async { [weak self] in self?.refreshBadges() }
        }
        head.onDropRequest = { [weak self] pointer, velocity in
            self?.headDidDrop(session.id, pointer: pointer, velocity: velocity) ?? false
        }
        head.bubbleView.dragFilter = { [weak self] origin, pointer in
            self?.filterDrag(origin: origin, pointer: pointer) ?? origin
        }
        head.onClose = { [weak self] in self?.removeHead(session.id) }
        head.onManageChats = { [weak self] in self?.showSessionPicker() }
        head.onNewChat = { [weak self] in self?.createHead(in: session.directory, provider: session.provider) }
    }

    private func groupedHeads() -> [BubbleStackKey: [HeadWindows]] {
        let displays = HeadWindows.magneticDisplays
        let liftedSet = Set(lifted)
        var result: [BubbleStackKey: [HeadWindows]] = [:]
        for head in windows.values where !liftedSet.contains(head.session.id) && !closing.contains(head.session.id) {
            guard let key = BubbleStackLayout.key(for: head.anchorPosition,
                    size: head.bubblePanel.frame.size, displays: displays) else { continue }
            result[key, default: []].append(head)
        }
        for key in result.keys {
            result[key]?.sort { lhs, rhs in
                let leftRank = activationOrder[lhs.session.id] ?? 0
                let rightRank = activationOrder[rhs.session.id] ?? 0
                if leftRank != rightRank { return leftRank > rightRank }
                return lhs.session.id.uuidString < rhs.session.id.uuidString
            }
        }
        return result
    }

    private func groupKey(for head: HeadWindows) -> BubbleStackKey? {
        BubbleStackLayout.key(for: head.anchorPosition,
                              size: head.bubblePanel.frame.size,
                              displays: HeadWindows.magneticDisplays)
    }

    private func frontHead(of key: BubbleStackKey, in heads: [HeadWindows]) -> HeadWindows? {
        let front = heads.first { $0.session.id == frontHeadByStack[key] } ?? heads.first
        frontHeadByStack[key] = front?.session.id
        return front
    }

    /// Closed stacks sit on their edge with a couple of heads peeking out
    /// behind the front one. The open stack lines up along the top of the
    /// screen with the selected conversation hanging underneath.
    private func layoutStacks(animated: Bool = true) {
        guard !isReflowing else { return }
        let groups = groupedHeads()
        let displays = HeadWindows.magneticDisplays
        var gear: (position: CGPoint, start: CGPoint)?
        if let key = expandedStack, groups[key] == nil {
            expandedStack = nil
            activeHeadID = nil
        }
        if expandedStack == nil { hideScrim() }
        for (key, heads) in groups {
            guard let front = frontHead(of: key, in: heads) else { continue }
            if expandedStack == key,
               let display = displays.first(where: { $0.id == key.displayID }) {
                let ids = Set(heads.map { $0.session.id })
                rowOrder = rowOrder.filter { ids.contains($0) }
                for head in heads where !rowOrder.contains(head.session.id) {
                    rowOrder.append(head.session.id)
                }
                let size = front.bubblePanel.frame.size
                // Open in place: the row stays at the stack's height, only
                // nudged when the cog or the chat would run off screen.
                let cogLift = size.height - 4
                let visible = display.visibleFrame
                let topLimit = visible.maxY - 6 - size.height - cogLift
                let bottomLimit = visible.minY + 8 + HeadWindows.chatSize.height - 1
                let rowY = min(topLimit, max(bottomLimit, front.anchorPosition.y))
                let positions = BubbleStackLayout.rowPositions(count: rowOrder.count, size: size,
                                                               display: display, side: key.side)
                    .map { CGPoint(x: $0.x, y: rowY) }
                if activeHeadID == nil || !ids.contains(activeHeadID!) { activeHeadID = rowOrder.first }
                showScrim(on: display.visibleFrame, below: heads.map(\.bubblePanel.windowNumber))
                for (index, id) in rowOrder.enumerated() {
                    guard let head = windows[id] else { continue }
                    head.setStackUnread(nil)
                    head.setPreviewEligible(false)
                    head.presentBubble(at: positions[index], animated: animated)
                    if id == activeHeadID {
                        let chatSize = HeadWindows.chatSize
                        let origin = BubbleStackLayout.chatOrigin(rowY: positions[index].y, chatSize: chatSize,
                                                                  display: display, side: key.side)
                        let caret = positions[index].x + size.width / 2 - origin.x
                        head.showChat(at: origin, caretX: max(26, min(chatSize.width - 26, caret)))
                    } else {
                        closeChat(head)
                    }
                }
                gear = (CGPoint(x: positions[0].x, y: positions[0].y + cogLift), front.anchorPosition)
            } else {
                if expandedStack == nil { hideScrim() }
                let ordered = [front] + heads.filter { $0.session.id != front.session.id }
                let totalUnread = heads.reduce(0) { $0 + $1.session.unread }
                for (depth, head) in ordered.enumerated() {
                    closeChat(head)
                    head.setPreviewEligible(depth == 0)
                    head.setStackUnread(depth == 0 ? (heads.count > 1 ? totalUnread : nil) : 0)
                    if depth <= Self.maxPeeks {
                        let peek = BubbleStackLayout.stackPeekOffset(depth: depth, side: key.side)
                        head.presentBubble(at: CGPoint(x: front.anchorPosition.x + peek.x,
                                                       y: front.anchorPosition.y + peek.y),
                                           animated: animated)
                    } else {
                        head.tuckBubble(into: front.anchorPosition, animated: animated)
                    }
                }
                // Front head drawn on top of the ones peeking out behind it.
                for head in ordered.prefix(Self.maxPeeks + 1).reversed() where head.bubblePanel.isVisible {
                    head.bubblePanel.orderFrontRegardless()
                }
                // The cog always sits beside a closed stack so settings are
                // easy to find. With stacks on several edges, the last used wins.
                let cogStack = lastUsedStack.flatMap { groups[$0] == nil ? nil : $0 } ?? groups.keys.first
                if expandedStack == nil, key == cogStack {
                    gear = (pinnedCogPosition(above: front.anchorPosition, size: front.bubblePanel.frame.size),
                            front.anchorPosition)
                }
            }
        }
        if gear == nil, let screen = NSScreen.main?.visibleFrame {
            // No heads at all: park the cog on the right edge on its own.
            let size = HeadWindows.bubbleSize
            let spot = CGPoint(x: screen.maxX - size, y: screen.midY)
            gear = (spot, spot)
        }
        if let gear, let optionsPanel {
            if !optionsPanel.isVisible { optionsPanel.setFrameOrigin(gear.start) }
            optionsPanel.orderFrontRegardless()
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.28
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.05)
                    optionsPanel.animator().setFrame(NSRect(origin: gear.position, size: optionsPanel.frame.size), display: true)
                }
            } else {
                optionsPanel.setFrameOrigin(gear.position)
            }
        } else {
            optionsPanel?.orderOut(nil)
        }
    }

    /// Just above the head, or just below it when the head sits at the top.
    private func pinnedCogPosition(above anchor: CGPoint, size: CGSize) -> CGPoint {
        let lift = size.height - 4
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        let y = anchor.y + size.height + lift <= screen.maxY ? anchor.y + lift : anchor.y - lift
        return CGPoint(x: anchor.x, y: y)
    }

    /// Badge only refresh, safe to run mid animation.
    private func refreshBadges() {
        for (key, heads) in groupedHeads() {
            if expandedStack == key {
                heads.forEach { $0.setStackUnread(nil) }
                continue
            }
            let total = heads.reduce(0) { $0 + $1.session.unread }
            let frontID = frontHeadByStack[key] ?? heads.first?.session.id
            for head in heads {
                head.setStackUnread(head.session.id == frontID ? (heads.count > 1 ? total : nil) : 0)
            }
        }
    }

    private func closeChat(_ head: HeadWindows) {
        guard head.isExpanded else { return }
        suppressCollapseCallback = true
        head.collapse()
        suppressCollapseCallback = false
    }

    private func closeActiveChat() {
        if let id = activeHeadID, let head = windows[id] { closeChat(head) }
    }

    private func expand(_ key: BubbleStackKey, selecting id: UUID?) {
        if let open = expandedStack, open != key { collapseAll(animated: false) }
        let heads = groupedHeads()[key] ?? []
        guard let front = frontHead(of: key, in: heads) else { return }
        let active = id ?? front.session.id
        expandedStack = key
        lastUsedStack = key
        rowOrder = [front.session.id] + heads.map(\.session.id).filter { $0 != front.session.id }
        activeHeadID = active
        rememberActivity(active)
        layoutStacks(animated: true)
    }

    private func select(_ id: UUID) {
        guard id != activeHeadID else { return }
        closeActiveChat()
        activeHeadID = id
        rememberActivity(id)
        layoutStacks(animated: true)
    }

    private func collapseAll(animated: Bool = true) {
        guard let key = expandedStack else { return }
        closeActiveChat()
        if let id = activeHeadID { frontHeadByStack[key] = id }
        lastUsedStack = key
        expandedStack = nil
        activeHeadID = nil
        layoutStacks(animated: animated)
    }

    private func openConversationDirectly(_ id: UUID) {
        guard !closing.contains(id) else { return }
        guard let head = windows[id], let key = groupKey(for: head) else { return }
        if expandedStack == key {
            select(id)
        } else {
            frontHeadByStack[key] = id
            expand(key, selecting: id)
        }
    }

    private func tapHead(_ id: UUID) {
        guard !closing.contains(id) else { return }
        guard let head = windows[id], let key = groupKey(for: head) else { return }
        lastBubbleTapAt = CACurrentMediaTime()
        if expandedStack == key {
            // Tapping the open chat's head closes everything, any other head
            // switches the conversation without shuffling the row.
            if id == activeHeadID { collapseAll() } else { select(id) }
        } else {
            expand(key, selecting: nil)
        }
    }

    private func headDidCollapse(_ id: UUID) {
        guard !suppressCollapseCallback, activeHeadID == id else { return }
        collapseAll()
    }

    private func sessionDidReceiveReply(_ id: UUID) {
        guard !closing.contains(id) else { return }
        guard let head = windows[id], let key = groupKey(for: head) else { return }
        if expandedStack == key {
            // Row stays put while open; the head just gets its badge.
            refreshBadges()
            persistHeads()
            return
        }
        rememberActivity(id)
        frontHeadByStack[key] = id
        // The new front head must be positioned before its preview is shown.
        layoutStacks(animated: false)
        head.showTransientReplyPreview()
        persistHeads()
    }

    // MARK: dragging

    private func headDidStartDragging(_ id: UUID) {
        guard !closing.contains(id) else { return }
        guard let head = windows[id], let key = groupKey(for: head) else { return }
        // The cog comes back beside the head once it's dropped.
        optionsPanel?.orderOut(nil)
        let peers = (groupedHeads()[key] ?? []).filter { $0.session.id != id }
        if expandedStack == key {
            // Pull a single head out of the open row.
            closeActiveChat()
            let previous = activeHeadID
            expandedStack = nil
            activeHeadID = nil
            if let previous, previous != id { frontHeadByStack[key] = previous }
            else if frontHeadByStack[key] == id { frontHeadByStack[key] = nil }
            lifted = [id]
        } else {
            // A closed stack travels together, trailing behind the one you grabbed.
            let front = frontHeadByStack[key]
            let ordered = peers.sorted { lhs, rhs in
                (lhs.session.id == front ? 0 : 1) < (rhs.session.id == front ? 0 : 1)
            }
            lifted = [id] + ordered.map(\.session.id)
            frontHeadByStack[key] = nil
        }
        head.setPreviewEligible(false)
        head.setStackUnread(lifted.count > 1 ? lifted.reduce(0) { $0 + (windows[$1]?.session.unread ?? 0) } : nil)
        let followers = lifted.dropFirst().compactMap { windows[$0] }
        chainSprings = [:]
        var ahead = head.bubblePanel.frame.origin
        for (index, follower) in followers.enumerated() {
            follower.setPreviewEligible(false)
            follower.setStackUnread(0)
            if index < Self.maxVisibleFollowers {
                let origin = follower.bubblePanel.frame.origin
                chainSprings[follower.session.id] = MagneticSpringPoint(origin: origin, velocity: .zero,
                                                                        destination: ahead, spec: Springs.follow)
                ahead = origin
            } else {
                follower.hideBubble()
            }
        }
        for follower in followers.prefix(Self.maxVisibleFollowers).reversed() {
            follower.setVisualOrigin(follower.bubblePanel.frame.origin)
            follower.bubblePanel.orderFrontRegardless()
        }
        head.bubblePanel.orderFrontRegardless()
        let leaderFrame = head.bubblePanel.frame
        dismissTarget.beginDrag(near: CGPoint(x: leaderFrame.midX, y: leaderFrame.midY),
                                displays: HeadWindows.magneticDisplays)
        if followers.isEmpty { stopChain() } else { startChain() }
        layoutStacks(animated: true)
    }

    /// The pointer-derived head position goes through the magnet, which pulls
    /// the displayed head toward the close circle inside the strip.
    private func filterDrag(origin: NSPoint, pointer: NSPoint) -> NSPoint {
        guard lifted.first != nil else { return origin }
        let size = HeadWindows.bubbleSize
        let pointerCenter = CGPoint(x: origin.x + size / 2, y: origin.y + size / 2)
        let shown = dismissTarget.dragMoved(pointerCenter: pointerCenter,
                                            displays: HeadWindows.magneticDisplays)
        return NSPoint(x: shown.x - size / 2, y: shown.y - size / 2)
    }

    /// Timer driven update so the head keeps gliding while the pointer is still.
    private func magnetTick(_ center: CGPoint) {
        guard let id = lifted.first, let head = windows[id] else { return }
        let size = HeadWindows.bubbleSize
        head.bubblePanel.setFrameOrigin(NSPoint(x: center.x - size / 2, y: center.y - size / 2))
    }

    private func startChain() {
        chainTimer?.invalidate()
        lastChainTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickChain() }
        }
        chainTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopChain() {
        chainTimer?.invalidate()
        chainTimer = nil
        chainSprings = [:]
    }

    /// Each follower chases the one in front of it on a follow spring.
    private func tickChain() {
        guard let leaderID = lifted.first, let leader = windows[leaderID] else { stopChain(); return }
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastChainTick)
        lastChainTick = now
        var target = leader.bubblePanel.frame.origin
        for id in lifted.dropFirst() {
            guard let head = windows[id], var spring = chainSprings[id] else { continue }
            spring.retarget(target)
            spring.step(elapsed: dt)
            chainSprings[id] = spring
            head.setVisualOrigin(spring.origin)
            target = spring.origin
        }
    }

    /// Returns true when the drop is handled here (it always is while a
    /// drag is in progress).
    private func headDidDrop(_ id: UUID, pointer: CGPoint, velocity: CGPoint) -> Bool {
        guard lifted.first == id, let head = windows[id] else { return false }
        let group = lifted
        let captured = dismissTarget.isCaptured
        stopChain()
        if captured {
            DismissTarget.haptic()
            dismissTarget.hide()
            lifted = []
            removeHeads(group)
            return true
        }
        if flingsToClose(velocity: velocity, head: head) {
            dismissTarget.forceFull()
            lifted = []
            closing.formUnion(group)
            head.flingTo(center: dismissTarget.circleCenter, velocity: velocity) { [weak self] in
                self?.finishClosing(group)
            }
            // The spring can get cancelled, so don't rely on its completion alone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.finishClosing(group)
            }
            for follower in group.dropFirst().compactMap({ windows[$0] }) { follower.hideBubble() }
            return true
        }
        dismissTarget.hide()
        head.snapToEdge(releasePointer: pointer, velocity: velocity)
        // Followers move to the leader's edge too, or the stack splits.
        for follower in group.dropFirst().compactMap({ windows[$0] }) {
            follower.setAnchor(head.anchorPosition)
        }
        lifted = []
        if let key = groupKey(for: head) {
            // Everything on that edge now shares the dropped head's anchor.
            for other in groupedHeads()[key] ?? [] where other.session.id != id {
                other.setAnchor(head.anchorPosition)
            }
            frontHeadByStack[key] = id
            lastUsedStack = key
        }
        rememberActivity(id)
        pendingDropLeader = id
        layoutStacks(animated: true)
        persistHeads()
        return true
    }

    /// Runs once per fling, from the spring or the fallback timer.
    private func finishClosing(_ group: [UUID]) {
        let pending = group.filter { closing.remove($0) != nil }
        // Leave the X up if the next head is already being dragged.
        if lifted.isEmpty { dismissTarget.hide() }
        guard !pending.isEmpty else { return }
        DismissTarget.haptic()
        removeHeads(pending)
    }

    /// Fast downward fling whose line reaches the circle at the bottom.
    private func flingsToClose(velocity: CGPoint, head: HeadWindows) -> Bool {
        let speed = hypot(velocity.x, velocity.y)
        guard speed >= 500, velocity.y < 0 else { return false }
        let frame = head.bubblePanel.frame
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        guard let display = MagneticSnapEngine.display(at: centre, in: HeadWindows.magneticDisplays) else { return false }
        let visible = display.visibleFrame
        let anchorY = visible.minY + DismissTarget.anchorLift
        let t = (anchorY - centre.y) / velocity.y
        guard t >= 0 else { return false }
        let hitX = centre.x + velocity.x * t
        return abs(hitX - visible.midX) <= 90
    }

    private func headDidFinishMoving(_ id: UUID) {
        guard !isReflowing, windows[id] != nil else { return }
        if pendingDropLeader == id {
            pendingDropLeader = nil
            refreshBadges()
        } else {
            layoutStacks()
        }
        persistHeads()
    }

    private func removeHead(_ id: UUID) { removeHeads([id]) }

    private func removeHeads(_ ids: [UUID]) {
        for id in ids {
            guard let head = windows.removeValue(forKey: id) else { continue }
            activationOrder.removeValue(forKey: id)
            if activeHeadID == id { activeHeadID = nil }
            head.dismiss()
        }
        lifted.removeAll { ids.contains($0) }
        layoutStacks()
        persistHeads()
    }

    private func restoreSavedHeads() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        let snapshots: [SavedHead]
        if let items = try? JSONDecoder().decode([FailableDecodable<SavedHead>].self, from: data) {
            snapshots = items.compactMap(\.value)
            if snapshots.count != items.count { backUpBadHeadsFile() }
        } else {
            snapshots = []
            backUpBadHeadsFile()
        }
        isReflowing = true
        for saved in snapshots { addHead(saved) }
        // Restored heads that never got a conversation carry on from the
        // latest CLI chat in their folder.
        let taken = Set(windows.values.compactMap { head -> String? in
            guard let sid = head.session.agentSessionID else { return nil }
            return head.session.provider.rawValue + ":" + sid
        })
        for head in windows.values where head.session.agentSessionID == nil && head.session.messages.isEmpty {
            head.session.continueLatestSession(excluding: taken, isTaken: { [weak self] in
                self?.sessionInUse($0) ?? false
            })
        }
        isReflowing = false
        layoutStacks(animated: false)
    }

    /// Keep a copy of a heads file we couldn't fully read before it gets overwritten.
    private func backUpBadHeadsFile() {
        let url = storageURL
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("heads.json.bad-\(Int(Date().timeIntervalSince1970))")
        do { try FileManager.default.copyItem(at: url, to: backup) }
        catch { NSLog("CliHeads: cannot back up heads.json: %@", error.localizedDescription) }
    }

    private func persistHeads() {
        let snapshots = windows.values.map { head -> SavedHead in
            let p = head.anchorPosition
            return head.session.snapshot(x: Double(p.x), y: Double(p.y))
        }.sorted { $0.title < $1.title }
        let url = storageURL
        do {
            // Chats are private, so keep the folder owner-only even if it already existed.
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let data = try JSONEncoder().encode(snapshots)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { NSLog("CliHeads: cannot persist chat heads: %@", error.localizedDescription) }
    }

    private func showScrim(on frame: CGRect, below windowNumbers: [Int]) {
        if scrim == nil {
            let panel = ScrimPanel()
            panel.onClick = { [weak self] in self?.collapseAll() }
            scrim = panel
        }
        scrim?.present(on: frame, aboveWindowNumber: windowNumbers.min() ?? 0)
    }

    private func hideScrim() { scrim?.dismiss() }

    /// Esc closes the open chat, even mid-turn (the agent keeps working), unless
    /// something inside wants the key: a popup list, a permission card or the Full CLI terminal.
    private func escapeCollapses(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        guard let id = activeHeadID, let head = windows[id], window === head.chatPanel else {
            return windows.values.contains { $0.bubblePanel === window }
        }
        guard window.firstResponder is NSTextView else { return false }
        let session = head.session
        return session.resumeQuery == nil && !session.draft.hasPrefix("/")
            && session.pendingPermissions.isEmpty
    }

    private func installDismissMonitors() {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 /* Esc */, let self, self.expandedStack != nil, self.escapeCollapses(event) {
                self.collapseAll()
                return nil
            }
            return event
        }) {
            eventMonitors.append(keys)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown,
            handler: { [weak self] _ in
                let clickLocation = NSEvent.mouseLocation
                DispatchQueue.main.async { [weak self] in
                    self?.collapseWhenOutside(at: clickLocation, clickedWindow: nil)
                }
            }) {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown,
            handler: { [weak self] event in
                self?.collapseWhenOutside(at: NSEvent.mouseLocation,
                                          clickedWindow: event.windowNumber)
                return event
            }) {
            eventMonitors.append(local)
        }
    }

    private func collapseWhenOutside(at point: CGPoint, clickedWindow: Int?) {
        guard expandedStack != nil else { return }
        // Ignore an asynchronous global monitor echo from an activation click.
        if CACurrentMediaTime() - lastBubbleTapAt < 0.22 { return }
        if let clickedWindow {
            if optionsPanel?.windowNumber == clickedWindow { return }
            if sessionPicker?.windowNumber == clickedWindow { return }
            if windows.values.contains(where: { head in
                head.bubblePanel.windowNumber == clickedWindow ||
                    head.chatPanel.windowNumber == clickedWindow ||
                    head.previewPanel.windowNumber == clickedWindow
            }) { return }
        }
        let onOptions = optionsPanel?.isVisible == true &&
            optionsPanel?.frame.contains(point) == true
        let onAnyPanel = onOptions || windows.values.contains { head in
            (head.bubblePanel.isVisible && head.bubblePanel.frame.contains(point)) ||
            (head.isExpanded && head.chatPanel.isVisible && head.chatPanel.frame.contains(point))
        }
        guard !onAnyPanel else { return }
        collapseAll()
    }
}

/// Decodes to nil instead of throwing, so one bad array element doesn't sink the rest.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
