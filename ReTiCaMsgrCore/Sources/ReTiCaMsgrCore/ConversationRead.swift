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

    /// Upsert: the latest read wins, whatever was stored before.
    public static func markRead(_ key: String, at now: Date, _ db: GRDB.Database) throws {
        let key = key.lowercased()
        try delete(key, db)
        try ConversationRead.insert { ConversationRead(key: key, readAt: now) }.execute(db)
    }

    public static func delete(_ key: String, _ db: GRDB.Database) throws {
        let key = key.lowercased()
        try ConversationRead.where { $0.key.eq(key) }.delete().execute(db)
    }
}
