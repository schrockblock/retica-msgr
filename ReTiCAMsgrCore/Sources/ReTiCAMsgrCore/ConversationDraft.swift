import Foundation

/// Unsent composer text for one conversation, kept on disk (`AppFeature.draftsFileURL`) so it
/// survives leaving the chat, backgrounding and a relaunch. Keyed by the conversation key (the
/// peer's address, or a group's id). Only the text is kept: a pending attachment and a reply
/// target stay session-only.
public struct ConversationDraft: Codable, Equatable, Sendable {
    public var text: String
    /// When the text last changed. Orders a draft-only conversation in the list.
    public var updatedAt: Date
    /// A group's draft never makes a row of its own: a group always has its "created" line.
    public var isGroup: Bool

    public init(text: String, updatedAt: Date, isGroup: Bool = false) {
        self.text = text
        self.updatedAt = updatedAt
        self.isGroup = isGroup
    }

    /// Whether the list shows this draft: whitespace alone is not a draft.
    public var isShown: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public extension Conversation {
    /// The list as shown: each row with a draft carries it, and a peer with only a draft (a
    /// conversation started but never sent to) gets a row of its own, dated by the draft. Sorted
    /// most-recent-first, like `list(from:)`.
    static func applyingDrafts(_ conversations: [Conversation],
                               _ drafts: [String: ConversationDraft]) -> [Conversation] {
        var rows = conversations.map { row in
            var row = row
            if let draft = drafts[row.peerHex], draft.isShown { row.draft = draft.text }
            return row
        }
        let listed = Set(conversations.map(\.peerHex))
        for (key, draft) in drafts where draft.isShown && !draft.isGroup
            && !listed.contains(key) && isValidPeerAddress(key) {
            rows.append(Conversation(peerHex: key, lastBody: "", lastTimestamp: draft.updatedAt, draft: draft.text))
        }
        return rows.sorted { a, b in
            a.lastTimestamp != b.lastTimestamp ? a.lastTimestamp > b.lastTimestamp : a.peerHex < b.peerHex
        }
    }

    /// The row's second line: the draft when there is one, else the last message.
    var preview: String {
        draft.map { "Draft: " + $0 } ?? lastBody
    }
}
