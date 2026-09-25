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
}
