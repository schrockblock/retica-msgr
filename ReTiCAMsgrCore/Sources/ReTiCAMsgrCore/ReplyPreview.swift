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
    /// body, trimmed like a quote — or, when the body is empty and the original carries a photo or
    /// a file, its placeholder from `attachments`, keyed by message id), else the carried quote,
    /// else "Original message not available". In a group thread `names` (sender address → display
    /// name) labels the original by its own sender; `peerName` is the fallback.
    ///
    /// When the original IS found but its trimmed text is empty (a whitespace-only body with no
    /// attachment), `text` still falls back to `unavailable` — but `originalID` stays set, so the
    /// quote block still scrolls to that (blank) original.
    public static func resolve(for message: Message, in thread: [Message], peerName: String?,
                               attachments: [UUID: Attachment] = [:], names: [String: String] = [:]) -> Resolved? {
        guard let hash = message.replyToHash else { return nil }
        if let original = thread.first(where: { $0.messageHash == hash }) {
            // Spec 2026-09-28 §4: a caption-less photo or file quotes its placeholder.
            let body = AttachmentPlaceholder.preview(body: original.body, attachment: attachments[original.id])
            let trimmedBody = ReplyWire.trimQuote(body)
            return Resolved(
                senderLabel: senderLabel(originalIsOutgoing: original.isOutgoing,
                                         peerName: names[original.peerHex] ?? peerName),
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
