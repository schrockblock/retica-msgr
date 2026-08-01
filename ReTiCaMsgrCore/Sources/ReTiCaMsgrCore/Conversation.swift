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
    /// `peerHex`, sorted most-recent-first.
    static func list(from messages: [Message]) -> [Conversation] {
        var latest: [String: Message] = [:]
        for m in messages {
            if let existing = latest[m.peerHex] {
                if m.timestamp > existing.timestamp { latest[m.peerHex] = m }
            } else {
                latest[m.peerHex] = m
            }
        }
        return latest.values
            .map { Conversation(peerHex: $0.peerHex, lastBody: $0.body, lastTimestamp: $0.timestamp) }
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
    }
}
