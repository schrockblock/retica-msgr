import Foundation
import ComposableArchitecture
import GRDB
import SQLiteData

/// The number on the app-icon badge (spec 2026-10-25 Part 2): incoming messages that arrived after
/// their conversation was last read. Timer-change and group-event lines never count, and neither
/// does anything from a blocked sender, so blocking someone drops their unread messages at once.
/// Group posts count under the group's key. For incoming rows `timestamp` is arrival time.
public enum UnreadCount {
    public static func count(_ db: GRDB.Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM messages m
            LEFT JOIN conversationReads r ON r.key = lower(COALESCE(m.groupHex, m.peerHex))
            LEFT JOIN blockedPeers b ON b.peerHex = lower(m.peerHex)
            WHERE m.isOutgoing = 0 AND m.isTimerChange = 0 AND m.isGroupEvent = 0
              AND b.peerHex IS NULL
              AND (r.readAt IS NULL OR m.timestamp > r.readAt)
            """) ?? 0
    }
}

/// Counts and sets the badge, and through the live client the extension's counter (drift
/// correction). A failed read throws and leaves the badge at its last value.
func refreshBadge(_ database: any DatabaseWriter) async throws {
    @Dependency(\.badge) var badge
    let n = try await database.read { try UnreadCount.count($0) }
    await badge.set(n)
}

/// Marks `key` read at `now` and resets the badge to the new count.
func markConversationRead(_ key: String, at now: Date, _ database: any DatabaseWriter) async throws {
    try await database.write { try ConversationRead.markRead(key, at: now, $0) }
    try await refreshBadge(database)
}

extension AppFeature {
    /// Recomputes the badge from the database (launch, a drained push inbox, a block or unblock).
    func recomputeBadge(_ database: any DatabaseWriter) -> Effect<Action> {
        .run { _ in try await refreshBadge(database) }
    }
}
