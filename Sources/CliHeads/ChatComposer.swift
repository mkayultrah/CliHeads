import AppKit
import SwiftUI

/// Native NSTextView intercepts Return before TextEditor inserts a newline.
/// Return sends; Shift+Return makes a new line. Keeps IME composition intact.
struct ChatComposer: NSViewRepresentable {
    enum Key { case tab, backtab, up, down, escape }

    @Binding var text: String
    var onSend: () -> Void
    /// Return true if the key was used (slash list, mode cycling), false to let the editor have it.
    var onKey: (Key) -> Bool = { _ in false }
    /// Images pasted or dropped into the box. Nil means images aren't accepted.
    var onImages: (([ImageAttachment]) -> Void)? = nil
    /// Grey hint shown while the box is empty.
    var placeholder: String = ""

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposer
        init(_ parent: ChatComposer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertTab(_:)): return parent.onKey(.tab)
            case #selector(NSResponder.insertBacktab(_:)): return parent.onKey(.backtab)
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.cancelOperation(_:)):
                // Always handled, so NSTextView doesn't pop a word completion list.
                _ = parent.onKey(.escape)
                return true
            default: return false
            }
        }
    }

    final class ReturnToSendTextView: NSTextView {
        var onSend: (() -> Void)?
        var onImages: (([ImageAttachment]) -> Void)?
        var placeholder = "" { didSet { needsDisplay = true } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Ready to type as soon as the chat opens.
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if window.firstResponder !== self { window.makeFirstResponder(self) }
            }
        }

        /// The app has no Edit menu (it lives in the menu bar as an accessory), so the
        /// usual Cmd+V/C/X/A/Z shortcuts never get routed. Handle them here.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags == .command {
                switch key {
                case "v": paste(nil); return true
                case "c": copy(nil); return true
                case "x": cut(nil); return true
                case "a": selectAll(nil); return true
                case "z": undoManager?.undo(); return true
                default: break
                }
            } else if flags == [.command, .shift], key == "z" {
                undoManager?.redo(); return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty, !hasMarkedText() else { return }
            let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                                 y: textContainerInset.height)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
            NSAttributedString(string: placeholder, attributes: attributes).draw(at: origin)
        }

        override func paste(_ sender: Any?) {
            if let onImages {
                let images = ImageAttachment.from(pasteboard: .general)
                if !images.isEmpty { onImages(images); return }
            }
            super.paste(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let onImages {
                let images = ImageAttachment.from(pasteboard: sender.draggingPasteboard)
                if !images.isEmpty { onImages(images); return true }
            }
            return super.performDragOperation(sender)
        }

        override func keyDown(with event: NSEvent) {
            // Let the input method finish composing text before intercepting Return.
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if isReturn, !hasMarkedText(),
               !event.modifierFlags.contains(.shift),
               !event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.control) {
                onSend?()
                return
            }
            super.keyDown(with: event)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = ReturnToSendTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.font = NSFont.systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 3, height: 5)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.onSend = onSend
        editor.onImages = onImages
        editor.placeholder = placeholder
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = nsView.documentView as? ReturnToSendTextView else { return }
        editor.onSend = onSend
        editor.onImages = onImages
        editor.placeholder = placeholder
        if editor.string != text {
            editor.string = text
            // Completions (like /res -> /resume ) should leave the cursor at the end.
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }
}
