import Foundation
import GRDB
import SQLiteData

/// "Delete conversation" (spec 2026-10-25 §1): removes one conversation's messages from this
/// device, with the attachment files, export copies and reactions that hang off them (the same
/// clean-up the disappearing-message purge does). Everything that is not message content stays:
/// the seen hashes (a late propagation copy must not come back as a new message), the
/// conversation's timer (A2), the group and its roster, profiles, contact links and blocks.
public enum ConversationDeletion {
    public struct Result: Equatable, Sendable {
        public var deleted: Int
        /// The attachment rows that went with the messages, for the app's image cache.
        public var deletedAttachmentIds: [UUID]
        /// Hashes of the outgoing rows still `sending` (for a group, the member copies still
        /// `sending`), read before the delete, so the caller can tell the node to stop working on them.
        public var inFlightHashes: [Data]

        public init(deleted: Int, deletedAttachmentIds: [UUID] = [], inFlightHashes: [Data] = []) {
            self.deleted = deleted
            self.deletedAttachmentIds = deletedAttachmentIds
            self.inFlightHashes = inFlightHashes
        }
    }

    /// `key` is a peer's address hex, or a group id hex when `isGroup`. A peer's one-to-one thread
    /// excludes group posts, which also carry that peer's address.
    public static func run(_ database: any DatabaseWriter, attachmentStore: AttachmentStore,
                           key: String, isGroup: Bool) async throws -> Result {
        let rows = try await database.read { db in
            let sql = isGroup
                ? "SELECT id, messageHash, isOutgoing, status FROM messages WHERE groupHex = ?"
                : "SELECT id, messageHash, isOutgoing, status FROM messages WHERE peerHex = ? AND groupHex IS NULL"
            return try Row.fetchAll(db, sql: sql, arguments: [key])
        }
        let messages = rows.compactMap { row -> (id: UUID, hash: String, inFlight: Bool)? in
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            let outgoing: Bool = row["isOutgoing"]
            let status: String = row["status"]
            return (id, row["messageHash"], outgoing && status == MessageStatus.sending)
        }
        guard !messages.isEmpty else { return Result(deleted: 0) }
        // A group post's `messageHash` is its post id; the router knows each member's copy by the
        // hash on its `GroupDelivery`, so those are what get cancelled.
        let inFlightHex: [String]
        if isGroup {
            let ids = messages.map(\.id)
            inFlightHex = try await database.read { db in
                try GroupDelivery.where { $0.messageId.in(ids) && $0.status.eq(MessageStatus.sending) }
                    .fetchAll(db).compactMap(\.messageHash)
            }
        } else {
            inFlightHex = messages.filter(\.inFlight).map(\.hash)
        }
        let inFlight = inFlightHex.compactMap { Data(hexString: $0) }.filter { !$0.isEmpty }
        let attachmentIds = try await MessagePurge.removeMessages(
            database, attachmentStore: attachmentStore, ids: messages.map(\.id), hashes: messages.map(\.hash))
        return Result(deleted: messages.count, deletedAttachmentIds: attachmentIds, inFlightHashes: inFlight)
    }
}
