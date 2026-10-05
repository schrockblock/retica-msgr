import Foundation
import GRDB
import SQLiteData

/// The shared disappearing-messages timer of one conversation (spec 2026-10-05 §2). `peerHex` is
/// the other party's lxmf.delivery hash (hex). `expirySeconds` NULL means off; the row is kept so
/// `updatedAt` records when the timer last changed.
@Table
public struct ConversationSetting: Equatable, Sendable {
    public var peerHex: String
    public var expirySeconds: Int?
    public var updatedAt: Date

    public init(peerHex: String, expirySeconds: Int?, updatedAt: Date) {
        self.peerHex = peerHex
        self.expirySeconds = expirySeconds
        self.updatedAt = updatedAt
    }

    /// The active timer for `peerHex` in seconds, or nil when there is none: no row, NULL, or 0.
    public static func expiry(for peerHex: String, _ db: GRDB.Database) throws -> Int? {
        guard let row = try ConversationSetting.where({ $0.peerHex.eq(peerHex) }).fetchOne(db),
              let seconds = row.expirySeconds, seconds > 0
        else { return nil }
        return seconds
    }

    /// The stored row, or nil when the conversation never had a timer set.
    public static func current(for peerHex: String, _ db: GRDB.Database) throws -> ConversationSetting? {
        try ConversationSetting.where({ $0.peerHex.eq(peerHex) }).fetchOne(db)
    }

    /// Upsert. 0 (and any negative value) is stored as NULL, meaning off.
    public static func set(_ peerHex: String, seconds: Int, at now: Date, _ db: GRDB.Database) throws {
        try ConversationSetting.where { $0.peerHex.eq(peerHex) }.delete().execute(db)
        try ConversationSetting.insert {
            ConversationSetting(peerHex: peerHex, expirySeconds: seconds > 0 ? seconds : nil, updatedAt: now)
        }.execute(db)
    }
}
