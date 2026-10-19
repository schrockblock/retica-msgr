import Foundation
import GRDB
import SQLiteData

/// What a peer told us about how to draw them: a received photo (file name in `AvatarStore`) and/or
/// an LXMF icon appearance. Photo and icon are independent; setting one never touches the other.
/// `peerHex` is the lowercase lxmf.delivery hash.
@Table("peerProfiles")
public struct PeerProfile: Equatable, Sendable {
    public var peerHex: String
    public var photoVersion: String?
    public var photoPath: String?
    public var iconName: String?
    public var iconFg: String?
    public var iconBg: String?
    public var updatedAt: Date

    public init(
        peerHex: String, photoVersion: String? = nil, photoPath: String? = nil,
        iconName: String? = nil, iconFg: String? = nil, iconBg: String? = nil, updatedAt: Date
    ) {
        self.peerHex = peerHex
        self.photoVersion = photoVersion
        self.photoPath = photoPath
        self.iconName = iconName
        self.iconFg = iconFg
        self.iconBg = iconBg
        self.updatedAt = updatedAt
    }

    public static func fetch(_ peerHex: String, _ db: GRDB.Database) throws -> PeerProfile? {
        try PeerProfile.where { $0.peerHex.eq(peerHex) }.fetchOne(db)
    }

    public static func all(_ db: GRDB.Database) throws -> [PeerProfile] {
        try PeerProfile.all.fetchAll(db)
    }

    /// Stores the photo and returns the path it replaced (nil if there was none), so the caller can
    /// delete the old file.
    public static func setPhoto(
        _ peerHex: String, version: String, path: String, at: Date, _ db: GRDB.Database
    ) throws -> String? {
        var row = try fetch(peerHex, db) ?? PeerProfile(peerHex: peerHex, updatedAt: at)
        let replaced = row.photoPath
        row.photoVersion = version
        row.photoPath = path
        row.updatedAt = at
        try save(row, db)
        return replaced
    }

    /// Drops the photo (the icon stays) and returns the removed path.
    public static func clearPhoto(_ peerHex: String, at: Date, _ db: GRDB.Database) throws -> String? {
        guard var row = try fetch(peerHex, db) else { return nil }
        let removed = row.photoPath
        row.photoVersion = nil
        row.photoPath = nil
        row.updatedAt = at
        try save(row, db)
        return removed
    }

    /// Stores the icon appearance (the photo stays).
    public static func setIcon(
        _ peerHex: String, _ icon: IconAppearance, at: Date, _ db: GRDB.Database
    ) throws {
        var row = try fetch(peerHex, db) ?? PeerProfile(peerHex: peerHex, updatedAt: at)
        row.iconName = icon.name
        row.iconFg = icon.fg
        row.iconBg = icon.bg
        row.updatedAt = at
        try save(row, db)
    }

    private static func save(_ row: PeerProfile, _ db: GRDB.Database) throws {
        try PeerProfile.where { $0.peerHex.eq(row.peerHex) }.delete().execute(db)
        try PeerProfile.insert { row }.execute(db)
    }
}
