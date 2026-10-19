import Foundation
import GRDB
import SQLiteData

/// Which version of MY photo a peer has confirmed. `deliveredVersion` nil = nothing confirmed,
/// `""` = removal confirmed. `pendingVersion`/`pendingHash` track the message in flight that carries
/// a newer version; the delivery outcome for that message hash settles it.
@Table("profilePhotoDeliveries")
public struct ProfilePhotoDelivery: Equatable, Sendable {
    public var peerHex: String
    public var deliveredVersion: String?
    public var pendingVersion: String?
    public var pendingHash: String?

    public init(
        peerHex: String, deliveredVersion: String? = nil,
        pendingVersion: String? = nil, pendingHash: String? = nil
    ) {
        self.peerHex = peerHex
        self.deliveredVersion = deliveredVersion
        self.pendingVersion = pendingVersion
        self.pendingHash = pendingHash
    }

    public static func fetch(_ peerHex: String, _ db: GRDB.Database) throws -> ProfilePhotoDelivery? {
        try ProfilePhotoDelivery.where { $0.peerHex.eq(peerHex) }.fetchOne(db)
    }

    /// Upsert; keeps `deliveredVersion`.
    public static func markPending(
        _ peerHex: String, version: String, hash: String, _ db: GRDB.Database
    ) throws {
        var row = try fetch(peerHex, db) ?? ProfilePhotoDelivery(peerHex: peerHex)
        row.pendingVersion = version
        row.pendingHash = hash
        try save(row, db)
    }

    /// Settles the rows waiting on `hash`: confirmed promotes the pending version to delivered;
    /// either way the pending pair is cleared. Other hashes are ignored.
    public static func applyOutcome(hash: String, confirmed: Bool, _ db: GRDB.Database) throws {
        let rows = try ProfilePhotoDelivery.where { $0.pendingHash.eq(hash) }.fetchAll(db)
        for var row in rows {
            if confirmed { row.deliveredVersion = row.pendingVersion }
            row.pendingVersion = nil
            row.pendingHash = nil
            try save(row, db)
        }
    }

    /// Launch (final review 1): the router keeps pending deliveries in memory only, so after a
    /// kill no outcome ever arrives for a stored `pendingHash`. Every pending pair is cleared (the
    /// delivered version stays) so the next message carries the photo again.
    public static func clearAllPending(_ db: GRDB.Database) throws {
        let none: String? = nil
        try ProfilePhotoDelivery
            .where { $0.pendingHash.isNot(nil) || $0.pendingVersion.isNot(nil) }
            .update {
                $0.pendingVersion = none
                $0.pendingHash = none
            }
            .execute(db)
    }

    private static func save(_ row: ProfilePhotoDelivery, _ db: GRDB.Database) throws {
        try ProfilePhotoDelivery.where { $0.peerHex.eq(row.peerHex) }.delete().execute(db)
        try ProfilePhotoDelivery.insert { row }.execute(db)
    }
}
