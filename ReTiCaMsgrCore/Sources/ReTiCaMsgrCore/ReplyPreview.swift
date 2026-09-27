import Foundation

/// What a reply's bubble shows above its text. Pure: the SwiftUI quote block only lays it out.
public enum ReplyPreview {
    public struct Resolved: Equatable, Sendable {
        /// "You", the peer's display name, or "Them".
        public var senderLabel: String
        public var text: String
        /// The original's row when it is in the thread: the quote block then scrolls to it.
        public var originalID: Message.ID?

        public init(senderLabel: String, text: String, originalID: Message.ID?) {
            self.senderLabel = senderLabel
            self.text = text
            self.originalID = originalID
        }
    }

    public static let you = "You"
    public static let them = "Them"
    public static let unavailable = "Original message not available"

    /// Who wrote the quoted message. Shared with the composer bar ("Replying to …").
    public static func senderLabel(originalIsOutgoing: Bool, peerName: String?) -> String {
        originalIsOutgoing ? you : (peerName ?? them)
    }

    /// nil when `message` is not a reply. Otherwise the original from `thread` when present (its
    /// body, trimmed like a quote), else the carried quote, else "Original message not available".
    ///
    /// When the original IS found but its trimmed body is empty (a whitespace-only body), `text`
    /// still falls back to `unavailable` — but `originalID` stays set, so the quote block still
    /// scrolls to that (blank) original.
    public static func resolve(for message: Message, in thread: [Message], peerName: String?) -> Resolved? {
        guard let hash = message.replyToHash else { return nil }
        if let original = thread.first(where: { $0.messageHash == hash }) {
            let trimmedBody = ReplyWire.trimQuote(original.body)
            return Resolved(
                senderLabel: senderLabel(originalIsOutgoing: original.isOutgoing, peerName: peerName),
                text: trimmedBody.isEmpty ? unavailable : trimmedBody,
                originalID: original.id
            )
        }
        // Without the original, the reply's direction decides: a reply we received quotes one of
        // ours, and a reply we sent quotes one of theirs.
        let label = senderLabel(originalIsOutgoing: !message.isOutgoing, peerName: peerName)
        // An empty quote (a blank original) says nothing, so it counts as no quote.
        if let quote = message.replyQuote, !quote.isEmpty {
            return Resolved(senderLabel: label, text: quote, originalID: nil)
        }
        return Resolved(senderLabel: label, text: unavailable, originalID: nil)
    }
}
