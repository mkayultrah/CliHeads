import Foundation

/// Unread state and the momentary Messenger-style blue preview are independent.
/// The former persists until the chat is read; the latter expires automatically.
enum PreviewPolicy {
    static let duration: TimeInterval = 5

    static func shouldShow(unread: Int, text: String, expanded: Bool,
                           eligible: Bool, now: TimeInterval, expiresAt: TimeInterval) -> Bool {
        unread > 0 && !text.isEmpty && !expanded && eligible && now < expiresAt
    }
}
