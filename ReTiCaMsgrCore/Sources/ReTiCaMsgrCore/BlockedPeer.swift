import Foundation
import GRDB
import SQLiteData

/// A sender the user blocked (spec 2026-10-15 §2). The row IS the block: `AppFeature.State.blockedPeers`,
/// the node's ignore list and the app-group mirror are all derived from this table. Nothing else is
/// stored, and blocking deletes nothing. `peerHex` is the lowercase lxmf.delivery hash.
@Table
public struct BlockedPeer: Equatable, Sendable {
    public var peerHex: String
    public var blockedAt: Date

    public init(peerHex: String, blockedAt: Date) {
        self.peerHex = peerHex
        self.blockedAt = blockedAt
    }

    /// Every row, newest block first (the Settings list order).
    public static func all(_ db: GRDB.Database) throws -> [BlockedPeer] {
        try BlockedPeer.all.fetchAll(db).sorted { $0.blockedAt > $1.blockedAt }
    }

    public static func fetch(peerHex: String, _ db: GRDB.Database) throws -> BlockedPeer? {
        try BlockedPeer.where { $0.peerHex.eq(peerHex) }.fetchOne(db)
    }

    /// Idempotent: a second block keeps the first date.
    public static func insertIfAbsent(_ row: BlockedPeer, _ db: GRDB.Database) throws {
        guard try fetch(peerHex: row.peerHex, db) == nil else { return }
        try BlockedPeer.insert { row }.execute(db)
    }

    public static func delete(peerHex: String, _ db: GRDB.Database) throws {
        try BlockedPeer.where { $0.peerHex.eq(peerHex) }.delete().execute(db)
    }
}
