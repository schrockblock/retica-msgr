import Foundation

/// A derived (never-persisted) summary of one thread: a peer's, or a group's (spec 2026-10-09
/// §2, amendment A11). `peerHex` is the list key: the other party's lxmf.delivery hash (hex), or
/// for a group its group id.
public struct Conversation: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case peer, group }

    public var peerHex: String
    public var kind: Kind
    /// The group's name; nil for a peer.
    public var title: String?
    /// `GroupState.*` for a group; nil for a peer.
    public var groupState: String?
    public var lastBody: String
    public var lastTimestamp: Date
    /// Unsent composer text, set by `applyingDrafts`; nil when there is none.
    public var draft: String?
    public var id: String { peerHex }

    public init(peerHex: String, kind: Kind = .peer, title: String? = nil, groupState: String? = nil,
                lastBody: String, lastTimestamp: Date, draft: String? = nil) {
        self.peerHex = peerHex
        self.kind = kind
        self.title = title
        self.groupState = groupState
        self.lastBody = lastBody
        self.lastTimestamp = lastTimestamp
        self.draft = draft
    }
}

public extension Conversation {
    /// A group row whose group is not stored (it should not happen) shows this.
    static let unknownGroupTitle = "Group"

    /// Build the conversation list from all messages: keep the newest row per key (the group id
    /// for a group row, else `peerHex`), sorted most-recent-first. `attachments` (by message id)
    /// supplies the preview for a message whose body is empty because it carried a photo or a
    /// file; `groups` (by group id) supplies the titles.
    static func list(from messages: [Message], attachments: [UUID: Attachment] = [:],
                     groups: [String: ChatGroup] = [:]) -> [Conversation] {
        var latest: [String: Message] = [:]
        for m in messages {
            let key = m.groupHex ?? m.peerHex
            if let existing = latest[key] {
                if m.timestamp > existing.timestamp { latest[key] = m }
            } else {
                latest[key] = m
            }
        }
        return latest
            .map { key, m in
                let group = m.groupHex.flatMap { groups[$0] }
                return Conversation(
                    peerHex: key,
                    kind: m.groupHex == nil ? .peer : .group,
                    title: m.groupHex == nil ? nil : (group?.name ?? unknownGroupTitle),
                    groupState: group?.state,
                    lastBody: AttachmentPlaceholder.preview(body: m.body, attachment: attachments[m.id]),
                    lastTimestamp: m.timestamp)
            }
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
    }
}

/// True iff `hex` decodes to a 16-byte lxmf.delivery hash.
public func isValidPeerAddress(_ hex: String) -> Bool {
    Data(hexString: hex)?.count == 16
}
