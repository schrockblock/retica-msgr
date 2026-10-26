import Foundation
import GRDB
import SQLiteData

/// Which of MY display names a peer has confirmed (spec 2026-10-25), mirroring
/// `ProfilePhotoDelivery`. `deliveredName` nil = nothing confirmed, `""` = a clear confirmed.
/// `pendingName`/`pendingHash` track the message in flight that carries a newer name; the delivery
/// outcome for that message hash settles it.
@Table("profileNameDeliveries")
public struct ProfileNameDelivery: Equatable, Sendable {
    public var peerHex: String
    public var deliveredName: String?
    public var pendingName: String?
    public var pendingHash: String?

    public init(
        peerHex: String, deliveredName: String? = nil,
        pendingName: String? = nil, pendingHash: String? = nil
    ) {
        self.peerHex = peerHex
        self.deliveredName = deliveredName
        self.pendingName = pendingName
        self.pendingHash = pendingHash
    }

    public static func fetch(_ peerHex: String, _ db: GRDB.Database) throws -> ProfileNameDelivery? {
        try ProfileNameDelivery.where { $0.peerHex.eq(peerHex) }.fetchOne(db)
    }

    /// Upsert; keeps `deliveredName`.
    public static func markPending(
        _ peerHex: String, name: String, hash: String, _ db: GRDB.Database
    ) throws {
        var row = try fetch(peerHex, db) ?? ProfileNameDelivery(peerHex: peerHex)
        row.pendingName = name
        row.pendingHash = hash
        try save(row, db)
    }

    /// Settles the rows waiting on `hash`: confirmed promotes the pending name to delivered;
    /// either way the pending pair is cleared. Other hashes are ignored.
    public static func applyOutcome(hash: String, confirmed: Bool, _ db: GRDB.Database) throws {
        let rows = try ProfileNameDelivery.where { $0.pendingHash.eq(hash) }.fetchAll(db)
        for var row in rows {
            if confirmed { row.deliveredName = row.pendingName }
            row.pendingName = nil
            row.pendingHash = nil
            try save(row, db)
        }
    }

    /// Launch: the router's pending deliveries are in memory only, so every pending pair is
    /// cleared (the delivered name stays) and the next message carries the name again.
    public static func clearAllPending(_ db: GRDB.Database) throws {
        let none: String? = nil
        try ProfileNameDelivery
            .where { $0.pendingHash.isNot(nil) || $0.pendingName.isNot(nil) }
            .update {
                $0.pendingName = none
                $0.pendingHash = none
            }
            .execute(db)
    }

    private static func save(_ row: ProfileNameDelivery, _ db: GRDB.Database) throws {
        try ProfileNameDelivery.where { $0.peerHex.eq(row.peerHex) }.delete().execute(db)
        try ProfileNameDelivery.insert { row }.execute(db)
    }
}
