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

        public init(purged: Int, nextDue: Date?) {
            self.purged = purged
            self.nextDue = nextDue
        }
    }

    static let log = Logger(subsystem: "com.reticamsgr", category: "expiry")

    /// The comparison runs in Swift over the stamped rows (amendment A3): there are few of them,
    /// and it avoids depending on optional-column comparison in the query builder.
    public static func run(_ database: any DatabaseWriter, attachmentStore: AttachmentStore,
                           now: Date) async throws -> Result {
        let stamped = try await database.read { db in
            try Message.where { $0.expiresAt.isNot(nil) }.fetchAll(db)
        }
        let due = stamped.filter { ($0.expiresAt ?? .distantFuture) <= now }
        guard !due.isEmpty else {
            return Result(purged: 0, nextDue: stamped.compactMap(\.expiresAt).min())
        }
        let ids = due.map(\.id)
        let hashes = due.map(\.messageHash).filter { !$0.isEmpty }
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
        let remaining = try await database.read { db in
            try Message.where { $0.expiresAt.isNot(nil) }.fetchAll(db)
        }
        return Result(purged: due.count, nextDue: remaining.compactMap(\.expiresAt).min())
    }
}
