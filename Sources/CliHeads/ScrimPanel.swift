import AppKit

/// Watches for clicks outside CliHeads while a chat is open, so clicking anywhere
/// else collapses it like Messenger. Nothing is drawn: the screen is never dimmed
/// and other apps keep getting their clicks.
@MainActor
final class ScrimPanel {
    var onClick: (() -> Void)?
    private var monitor: Any?

    func present(on frame: CGRect, aboveWindowNumber: Int) {
        guard monitor == nil else { return }
        // Global monitors only see events going to other apps, never our own windows.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.onClick?() }
        }
    }

    func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
