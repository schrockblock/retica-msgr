import Foundation
import GRDB
import OSLog
import SQLiteData

/// Deletes every message whose `expiresAt` has passed (spec 2026-10-05 §3 "Purge", amendment A2).
/// The app's first message deletion, so it owns every on-disk consequence: the export copies and
/// the attachment file go first (a row that outlives its file shows "unavailable"; a file that
/// outlives its row is the leak this feature exists to prevent), then the reaction rows (no
/// foreign key on that table) and the message row, whose attachment row cascades. Seen hashes are
/// kept so a late propagation copy is not re-stored.
public enum MessagePurge {
    public struct Result: Equatable, Sendable {
        /// Rows deleted in this run.
        public var purged: Int
        /// The earliest `expiresAt` still in the table, for the reducer's sleeper. nil = nothing armed.
        public var nextDue: Date?
        /// The attachment rows that went with the messages, for the app's image cache (A17).
        public var purgedAttachmentIds: [UUID]

        public init(purged: Int, nextDue: Date?, purgedAttachmentIds: [UUID] = []) {
            self.purged = purged
            self.nextDue = nextDue
            self.purgedAttachmentIds = purgedAttachmentIds
        }
    }

    static let log = Logger(subsystem: "com.reticamsgr", category: "expiry")

    /// Only `id` and `messageHash` of the due rows are read, and the next deadline is a `MIN` over
    /// the indexed column (amendment A15), so a long disappearing conversation does not pull every
    /// stamped body into memory on each trigger.
    public static func run(_ database: any DatabaseWriter, attachmentStore: AttachmentStore,
                           now: Date) async throws -> Result {
        let due = try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, messageHash FROM messages WHERE expiresAt IS NOT NULL AND expiresAt <= ?",
                             arguments: [now])
                .compactMap { row -> (id: UUID, hash: String)? in
                    guard let id = UUID(uuidString: row["id"]) else { return nil }
                    return (id, row["messageHash"])
                }
        }
        guard !due.isEmpty else {
            return Result(purged: 0, nextDue: try await nextDeadline(database, after: now))
        }
        let ids = due.map(\.id)
        let hashes = due.map(\.hash).filter { !$0.isEmpty }
        let attachments = try await database.read { db in
            try Attachment.where { $0.messageId.in(ids) }.fetchAll(db)
        }
        for attachment in attachments {
            attachmentStore.deleteExports(for: attachment)
            guard attachment.hasBytes else { continue }
            do {
                try attachmentStore.delete(attachment.path)
            } catch {
                // The path embeds the message hash, so it stays out of the public log.
                log.error("purge: could not delete \(attachment.path, privacy: .private): \(String(describing: error), privacy: .public)")
            }
        }
        try await database.write { db in
            if !hashes.isEmpty {
                try Reaction.where { $0.messageHash.in(hashes) }.delete().execute(db)
            }
            try Message.where { $0.id.in(ids) }.delete().execute(db)
        }
        return Result(purged: due.count, nextDue: try await nextDeadline(database, after: now),
                      purgedAttachmentIds: attachments.map(\.id))
    }

    /// The earliest `expiresAt` still ahead of `now`. Anything at or before `now` was just deleted
    /// (or will be on the next run), so it never becomes a zero-delay deadline.
    static func nextDeadline(_ database: any DatabaseWriter, after now: Date) async throws -> Date? {
        try await database.read { db in
            try Date.fetchOne(db, sql: "SELECT MIN(expiresAt) FROM messages WHERE expiresAt IS NOT NULL AND expiresAt > ?",
                              arguments: [now])
        }
    }
}
