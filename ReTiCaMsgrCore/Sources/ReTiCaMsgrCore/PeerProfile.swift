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
    /// When the sender set the stored photo or removal: its timestamp, capped at arrival (the
    /// expiry amendment A10 pattern). nil = nothing applied yet, so anything applies.
    public var photoSetAt: Date?
    public var iconName: String?
    public var iconFg: String?
    public var iconBg: String?
    public var updatedAt: Date

    public init(
        peerHex: String, photoVersion: String? = nil, photoPath: String? = nil, photoSetAt: Date? = nil,
        iconName: String? = nil, iconFg: String? = nil, iconBg: String? = nil, updatedAt: Date
    ) {
        self.peerHex = peerHex
        self.photoVersion = photoVersion
        self.photoPath = photoPath
        self.photoSetAt = photoSetAt
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

    /// Whether a photo or removal the sender set at `setAt` is newer than what `row` holds:
    /// strictly later than the stored time, or no stored time at all.
    public static func isNewer(_ setAt: Date, than row: PeerProfile?) -> Bool {
        guard let stored = row?.photoSetAt else { return true }
        return setAt > stored
    }

    /// Stores the photo and returns the path it replaced (nil if there was none), so the caller can
    /// delete the old file. `setAt` is when the sender set it; the caller decides newer-ness.
    public static func setPhoto(
        _ peerHex: String, version: String, path: String, setAt: Date, at: Date, _ db: GRDB.Database
    ) throws -> String? {
        var row = try fetch(peerHex, db) ?? PeerProfile(peerHex: peerHex, updatedAt: at)
        let replaced = row.photoPath
        row.photoVersion = version
        row.photoPath = path
        row.photoSetAt = setAt
        row.updatedAt = at
        try save(row, db)
        // A re-delivered message stores the same file again: it is not "replaced", and a caller
        // deleting the returned path would delete the file just written.
        return replaced == path ? nil : replaced
    }

    /// Drops the photo (the icon stays), remembers when the sender removed it, and returns the
    /// removed path. With no row yet, one is made so an older photo arriving later is refused.
    public static func clearPhoto(_ peerHex: String, setAt: Date, at: Date, _ db: GRDB.Database) throws -> String? {
        var row = try fetch(peerHex, db) ?? PeerProfile(peerHex: peerHex, updatedAt: at)
        let removed = row.photoPath
        row.photoVersion = nil
        row.photoPath = nil
        row.photoSetAt = setAt
        row.updatedAt = at
        try save(row, db)
        return removed
    }

    /// Launch (final review 5b): a row whose photo file is gone (a backup restore leaves the rows
    /// but not the excluded files) loses its photo, so the avatar falls through to the contact,
    /// icon or initials. `fileExists` takes the stored relative path. Returns how many changed.
    @discardableResult
    public static func clearMissingPhotos(
        fileExists: (String) -> Bool, at: Date, _ db: GRDB.Database
    ) throws -> Int {
        let missing = try PeerProfile.all.fetchAll(db).filter { row in
            guard let path = row.photoPath else { return row.photoVersion != nil }
            return !fileExists(path)
        }
        for var row in missing {
            row.photoVersion = nil
            row.photoPath = nil
            row.updatedAt = at
            try save(row, db)
        }
        return missing.count
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
