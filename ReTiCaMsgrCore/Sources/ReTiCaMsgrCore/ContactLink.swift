import Foundation
import GRDB
import SQLiteData

/// One iOS Contact attached to one Reticulum peer (spec 2026-10-11 §1). `peerHex` is the peer's
/// LXMF delivery address, the key conversations use; `contactIdentifier` is `CNContact.identifier`.
/// Strict 1:1: the primary key and the unique `contactIdentifier` enforce it, and
/// `insertReplacing` is the one write path for a new link.
@Table
public struct ContactLink: Equatable, Sendable {
    public var peerHex: String
    public var contactIdentifier: String
    /// The contact's formatted name at link time, refreshed when the contact loads. What every
    /// surface shows, and what keeps a name on screen when Contacts access is gone.
    public var cachedName: String
    /// `ContactLinkSource.*`.
    public var source: String
    public var discoveredViaHex: String?
    public var discoveredSessionId: String?
    public var discoveredAt: Date?
    /// JSON array of `ContactConfirmation`; use `confirmations`.
    public var confirmationsJSON: String
    /// True at creation for `manual` and `scanned`; false for `discovered` and `imported` until
    /// the user marks it. Never set by a confirmation alone (the app asks).
    public var verified: Bool
    public var conflictedAt: Date?
    public var conflictPeerHex: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(peerHex: String, contactIdentifier: String, cachedName: String, source: String,
                discoveredViaHex: String?, discoveredSessionId: String?, discoveredAt: Date?,
                confirmationsJSON: String, verified: Bool, conflictedAt: Date?, conflictPeerHex: String?,
                createdAt: Date, updatedAt: Date) {
        self.peerHex = peerHex
        self.contactIdentifier = contactIdentifier
        self.cachedName = cachedName
        self.source = source
        self.discoveredViaHex = discoveredViaHex
        self.discoveredSessionId = discoveredSessionId
        self.discoveredAt = discoveredAt
        self.confirmationsJSON = confirmationsJSON
        self.verified = verified
        self.conflictedAt = conflictedAt
        self.conflictPeerHex = conflictPeerHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Decoded `confirmationsJSON`; unreadable JSON reads as none rather than failing a load.
    public var confirmations: [ContactConfirmation] {
        get {
            guard let data = confirmationsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([ContactConfirmation].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            confirmationsJSON = (try? encoder.encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
    }

    public var isConflicted: Bool { conflictedAt != nil }

    public static func fetch(peerHex: String, _ db: GRDB.Database) throws -> ContactLink? {
        try ContactLink.where { $0.peerHex.eq(peerHex) }.fetchOne(db)
    }

    public static func fetch(contactIdentifier: String, _ db: GRDB.Database) throws -> ContactLink? {
        try ContactLink.where { $0.contactIdentifier.eq(contactIdentifier) }.fetchOne(db)
    }

    public static func all(_ db: GRDB.Database) throws -> [ContactLink] {
        try ContactLink.all.order(by: \.peerHex).fetchAll(db)
    }

    /// The one write path for a new or replaced link: any row holding this peer OR this contact
    /// is deleted first, so the 1:1 rule can never be violated by a write.
    public static func insertReplacing(_ link: ContactLink, _ db: GRDB.Database) throws {
        try ContactLink.where { $0.peerHex.eq(link.peerHex) || $0.contactIdentifier.eq(link.contactIdentifier) }
            .delete().execute(db)
        try ContactLink.insert { link }.execute(db)
    }

    public static func delete(peerHex: String, _ db: GRDB.Database) throws {
        try ContactLink.where { $0.peerHex.eq(peerHex) }.delete().execute(db)
    }
}

public enum ContactLinkSource {
    /// Linked from a chat by the user.
    public static let manual = "manual"
    /// Linked after a QR scan by the user.
    public static let scanned = "scanned"
    /// Returned by a contact exchange (a later feature).
    public static let discovered = "discovered"
    /// Read from a `reticulum:` URL on the contact card.
    public static let imported = "imported"
}

/// A later exchange that returned the same identity for this contact.
public struct ContactConfirmation: Codable, Equatable, Sendable {
    public var peerHex: String
    public var sessionId: String
    public var date: Date

    public init(peerHex: String, sessionId: String, date: Date) {
        self.peerHex = peerHex
        self.sessionId = sessionId
        self.date = date
    }
}
