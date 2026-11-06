import Foundation
import GRDB
import SQLiteData

/// When a conversation was last read (spec 2026-10-25 Part 2): the chat was on screen with the app
/// frontmost. `key` is the conversation key, `groupHex ?? peerHex`, lowercased. Incoming rows after
/// `readAt` are unread; a key with no row is unread throughout, which is what a deleted conversation
/// that restarts wants.
@Table("conversationReads")
public struct ConversationRead: Equatable, Sendable {
    public var key: String
    public var readAt: Date

    public init(key: String, readAt: Date) {
        self.key = key
        self.readAt = readAt
    }

    /// Monotonic upsert: `readAt` only moves forward. Arrival effects run concurrently and can land
    /// out of order (a photo whose file is written first, a slow arrival after the thread was marked
    /// at a later `now`), and an older mark must not make newer, already-seen messages unread.
    /// `delete` is the only reset.
    ///
    /// `readAt` and `messages.timestamp` are compared as text, so both must come from one encoder.
    /// The date is bound through StructuredQueries, as message rows are: GRDB's own date formatter
    /// can land 1 ms away from it for the same `Date` (SQLiteData applies `nextUp` first). The
    /// migration's seed is the one `readAt` GRDB wrote.
    public static func markRead(_ key: String, at now: Date, _ db: GRDB.Database) throws {
        let key = key.lowercased()
        try #sql("""
            INSERT INTO conversationReads (key, readAt) VALUES (\(bind: key), \(now))
            ON CONFLICT(key) DO UPDATE SET readAt = max(readAt, excluded.readAt)
            """).execute(db)
    }

    /// Marks `key` read up to the stored message `id`, copying its `timestamp` text, so an arrival
    /// into the watched thread is read whatever encoder wrote it. Same monotonic upsert.
    public static func markRead(_ key: String, uptoMessage id: UUID, _ db: GRDB.Database) throws {
        let key = key.lowercased()
        try #sql("""
            INSERT INTO conversationReads (key, readAt) SELECT \(bind: key), timestamp FROM messages WHERE id = \(id)
            ON CONFLICT(key) DO UPDATE SET readAt = max(readAt, excluded.readAt)
            """).execute(db)
    }

    public static func delete(_ key: String, _ db: GRDB.Database) throws {
        let key = key.lowercased()
        try ConversationRead.where { $0.key.eq(key) }.delete().execute(db)
    }
}
