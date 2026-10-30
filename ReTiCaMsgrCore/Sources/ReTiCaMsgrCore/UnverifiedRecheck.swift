import Foundation
import GRDB
import OSLog
import ReTiCA
import SQLiteData

/// The later signature check for incoming rows stored unverified (spec 2026-10-28 "It turns
/// verified automatically"). A message whose sender's identity was unknown on arrival is stored
/// with `validated = false` and its packed bytes; once that identity is learned (an announce or a
/// path response), each such row is checked against it:
/// - a good signature makes the row validated and drops the bytes;
/// - a bad one, bytes addressed to someone else, or bytes that no longer unpack mean a forgery,
///   so the row goes with its
///   attachment and reactions.
///
/// Withheld fields (name, photo, expiry, group control, reactions) are not applied after the fact.
/// Rows with no stored bytes (oversized, or stored before `addUnverifiedPacked`) are left alone.
public enum UnverifiedRecheck {
    /// The largest packed message whose bytes are kept for the re-check (spec settled detail 3).
    public static let maxStoredBytes = 262_144

    static let log = Logger(subsystem: "com.reticamsgr", category: "inbound")

    /// `deliveryHash` is our own lxmf.delivery hash. A genuinely signed message addressed to someone
    /// else is not ours to accept (security review Finding 2), so it is removed like a forgery; this
    /// does not rely on the router having dropped it first. nil (not registered yet) leaves every
    /// row alone for a later pass.
    public static func run(_ database: any DatabaseWriter, attachmentStore: AttachmentStore,
                           sourceHex: String, identity: Identity,
                           deliveryHash: Data?) async throws -> (verified: Int, removed: [UUID]) {
        guard let deliveryHash else { return (0, []) }
        let rows = try await database.read { db in
            try Message.where { $0.peerHex.eq(sourceHex) && !$0.validated && $0.unverifiedPacked.isNot(nil) }
                .fetchAll(db)
        }
        guard !rows.isEmpty else { return (0, []) }
        var verifiedIds: [UUID] = []
        var forged: [Message] = []
        for row in rows {
            guard let bytes = row.unverifiedPacked else { continue }
            // The bytes must also claim this sender: `peerHex` is the stored `sourceHash`, so a
            // mismatch means the row and its bytes disagree, and it is treated as forged. They
            // must be addressed to us, too.
            if let message = LXMessage.unpack(bytes), message.sourceHash.hexString == sourceHex,
               message.destinationHash == deliveryHash,
               message.validateSignature(source: identity) {
                verifiedIds.append(row.id)
            } else {
                forged.append(row)
            }
        }
        if !verifiedIds.isEmpty {
            let ids = verifiedIds
            let none: Data? = nil
            try await database.write { db in
                try Message.where { $0.id.in(ids) }
                    .update {
                        $0.validated = true
                        $0.unverifiedPacked = none
                    }
                    .execute(db)
            }
        }
        var removed: [UUID] = []
        if !forged.isEmpty {
            log.notice("recheck: removing \(forged.count, privacy: .public) forged message(s) claiming \(String(sourceHex.prefix(8)), privacy: .public)")
            removed = try await MessagePurge.removeMessages(database, attachmentStore: attachmentStore,
                                                            ids: forged.map(\.id), hashes: forged.map(\.messageHash))
        }
        return (verifiedIds.count, removed)
    }

    /// Every sender with stored bytes waiting for a check, for the launch pass.
    static func pendingPeers(_ database: any DatabaseWriter) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT peerHex FROM messages
                WHERE validated = 0 AND unverifiedPacked IS NOT NULL
                """)
        }
    }
}
