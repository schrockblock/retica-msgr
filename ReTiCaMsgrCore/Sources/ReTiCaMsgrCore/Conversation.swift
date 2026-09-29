import Foundation

/// A derived (never-persisted) summary of one peer's message thread.
/// `peerHex` is the other party's lxmf.delivery hash (hex).
public struct Conversation: Identifiable, Equatable, Sendable {
    public var peerHex: String
    public var lastBody: String
    public var lastTimestamp: Date
    public var id: String { peerHex }

    public init(peerHex: String, lastBody: String, lastTimestamp: Date) {
        self.peerHex = peerHex
        self.lastBody = lastBody
        self.lastTimestamp = lastTimestamp
    }
}

public extension Conversation {
    /// Build the conversation list from all messages: keep the newest row per
    /// `peerHex`, sorted most-recent-first. `attachments` (by message id) supplies the preview
    /// for a message whose body is empty because it carried a photo or a file.
    static func list(from messages: [Message], attachments: [UUID: Attachment] = [:]) -> [Conversation] {
        var latest: [String: Message] = [:]
        for m in messages {
            if let existing = latest[m.peerHex] {
                if m.timestamp > existing.timestamp { latest[m.peerHex] = m }
            } else {
                latest[m.peerHex] = m
            }
        }
        return latest.values
            .map {
                Conversation(peerHex: $0.peerHex,
                             lastBody: AttachmentPlaceholder.preview(body: $0.body, attachment: attachments[$0.id]),
                             lastTimestamp: $0.timestamp)
            }
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
    }
}

/// True iff `hex` decodes to a 16-byte lxmf.delivery hash.
public func isValidPeerAddress(_ hex: String) -> Bool {
    Data(hexString: hex)?.count == 16
}
