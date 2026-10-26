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
    /// `delete` is the only reset. `max` on the stored text is safe: every `readAt` is written in
    /// the same fixed-width date format.
    public static func markRead(_ key: String, at now: Date, _ db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT INTO conversationReads (key, readAt) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET readAt = max(readAt, excluded.readAt)
            """, arguments: [key.lowercased(), now])
    }

    public static func delete(_ key: String, _ db: GRDB.Database) throws {
        let key = key.lowercased()
        try ConversationRead.where { $0.key.eq(key) }.delete().execute(db)
    }
}
