import Foundation
import GRDB
import SQLiteData

/// One person's current reaction to one message. `messageHash` is the target's LXMF hash (hex);
/// `reactorHex` is the reactor's lxmf.delivery hash (hex) — the peer's, or our own
/// `myAddressHex`. `emoji == ""` is a tombstone (reaction removed). `sentAt` is the reaction
/// LXMessage's own timestamp, i.e. the reactor's clock.
@Table
public struct Reaction: Equatable, Sendable {
    public var messageHash: String
    public var reactorHex: String
    public var emoji: String
    public var sentAt: Double

    public init(messageHash: String, reactorHex: String, emoji: String, sentAt: Double) {
        self.messageHash = messageHash
        self.reactorHex = reactorHex
        self.emoji = emoji
        self.sentAt = sentAt
    }

    /// Last-writer-wins upsert. Writes only if there is no row for (messageHash, reactorHex) or
    /// `r.sentAt` is strictly newer; an equal timestamp is a duplicate delivery and is ignored.
    @discardableResult
    public static func apply(_ r: Reaction, _ db: GRDB.Database) throws -> Bool {
        let existing = try Reaction
            .where { $0.messageHash.eq(r.messageHash) && $0.reactorHex.eq(r.reactorHex) }
            .fetchOne(db)
        if let existing, existing.sentAt >= r.sentAt { return false }
        try Reaction
            .where { $0.messageHash.eq(r.messageHash) && $0.reactorHex.eq(r.reactorHex) }
            .delete()
            .execute(db)
        try Reaction.insert { r }.execute(db)
        return true
    }

    /// How long an orphan (a reaction with no stored target message) is kept before launch prunes
    /// it (amendment A17). Reactions can legitimately arrive before their message over a mesh, so
    /// a fresh orphan is a message still on its way, not a leftover of a purged one.
    public static let orphanGraceInterval: TimeInterval = 24 * 60 * 60

    /// Deletes reactions whose target message no longer exists and whose `sentAt` is before
    /// `cutoff` (seconds since 1970). The target of a purged disappearing message is one such case.
    public static func pruneOrphans(olderThan cutoff: Double, _ db: GRDB.Database) throws {
        try db.execute(
            sql: """
                DELETE FROM reactions
                WHERE sentAt < ? AND messageHash NOT IN (SELECT messageHash FROM messages)
                """,
            arguments: [cutoff]
        )
    }
}
