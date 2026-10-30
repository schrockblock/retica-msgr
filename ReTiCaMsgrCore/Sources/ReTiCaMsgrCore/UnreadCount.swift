import Foundation
import ComposableArchitecture
import GRDB
import SQLiteData

/// The number on the app-icon badge (spec 2026-10-25 Part 2): incoming messages that arrived after
/// their conversation was last read. Timer-change and group-event lines never count, and neither
/// does anything from a blocked sender, so blocking someone drops their unread messages at once.
/// Group posts count under the group's key. For incoming rows `timestamp` is arrival time.
/// Unverified rows (`validated = 0`) never count (spec 2026-10-28): a forged sender must not
/// raise the badge. They start counting if the re-check verifies them.
public enum UnreadCount {
    public static func count(_ db: GRDB.Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM messages m
            LEFT JOIN conversationReads r ON r.key = lower(COALESCE(m.groupHex, m.peerHex))
            LEFT JOIN blockedPeers b ON b.peerHex = lower(m.peerHex)
            WHERE m.isOutgoing = 0 AND m.isTimerChange = 0 AND m.isGroupEvent = 0
              AND m.validated = 1
              AND b.peerHex IS NULL
              AND (r.readAt IS NULL OR m.timestamp > r.readAt)
            """) ?? 0
    }

    /// The same count split by conversation key (lowercased), for the chat list. Keys with
    /// nothing unread are absent; the values sum to `count`. The alias is not `key`: `GROUP BY key`
    /// would resolve to `conversationReads.key`, NULL for every unmarked conversation, and merge them.
    public static func perConversation(_ db: GRDB.Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT lower(COALESCE(m.groupHex, m.peerHex)) AS convoKey, COUNT(*) AS n FROM messages m
            LEFT JOIN conversationReads r ON r.key = lower(COALESCE(m.groupHex, m.peerHex))
            LEFT JOIN blockedPeers b ON b.peerHex = lower(m.peerHex)
            WHERE m.isOutgoing = 0 AND m.isTimerChange = 0 AND m.isGroupEvent = 0
              AND m.validated = 1
              AND b.peerHex IS NULL
              AND (r.readAt IS NULL OR m.timestamp > r.readAt)
            GROUP BY convoKey
            """)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["convoKey"] as String, $0["n"] as Int) })
    }
}

/// Counts unread per conversation, publishes those counts for the chat list, and sets the badge
/// to their sum, and through the live client the extension's counter (drift correction). A failed
/// read throws and leaves both at their last value.
func refreshBadge(_ database: any DatabaseWriter) async throws {
    @Dependency(\.badge) var badge
    @Shared(.inMemory("unreadCounts")) var unreadCounts: [String: Int] = [:]
    let counts = try await database.read { try UnreadCount.perConversation($0) }
    $unreadCounts.withLock { $0 = counts }
    await badge.set(counts.values.reduce(0, +))
}

/// Marks `key` read at `now` and resets the badge to the new count.
func markConversationRead(_ key: String, at now: Date, _ database: any DatabaseWriter) async throws {
    try await database.write { try ConversationRead.markRead(key, at: now, $0) }
    try await refreshBadge(database)
}

/// Marks `key` read up to the message `id` that just arrived in the watched thread, at that row's
/// own stored timestamp, and resets the badge.
func markConversationRead(_ key: String, uptoMessage id: UUID, _ database: any DatabaseWriter) async throws {
    try await database.write { try ConversationRead.markRead(key, uptoMessage: id, $0) }
    try await refreshBadge(database)
}

extension AppFeature {
    /// Recomputes the badge from the database (launch, a drained push inbox, a block or unblock).
    func recomputeBadge(_ database: any DatabaseWriter) -> Effect<Action> {
        .run { _ in try await refreshBadge(database) }
    }
}
