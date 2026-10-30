import Foundation
import GRDB
import OSLog
import ReTiCA
import SQLiteData

/// The later signature check for incoming rows stored unverified (spec 2026-10-28 "It turns
/// verified automatically"). A message whose sender's identity was unknown on arrival is stored
/// with `validated = false`, and its packed bytes go to `unverifiedPackets`; once that identity is
/// learned (an announce or a path response), each such row is checked against it:
/// - a good signature makes the row validated and drops the bytes;
/// - a bad one, bytes addressed to someone else, or bytes that no longer unpack mean a forgery,
///   so the row goes with its
///   attachment and reactions.
///
/// Withheld fields (name, photo, expiry, group control, reactions) are not applied after the fact.
/// Rows with no stored bytes (oversized, over the row cap, or stored before `addUnverifiedPacked`)
/// are left alone.
public enum UnverifiedRecheck {
    /// The largest packed message whose bytes are kept for the re-check (spec settled detail 3).
    public static let maxStoredBytes = 262_144
    /// At most this many unverified messages keep their bytes, in total (final review F1): spam
    /// from unknown senders cannot grow the side table without bound. A message past the cap is
    /// stored without bytes, so it keeps its marker and is never re-checked.
    public static let maxStoredMessages = 100

    static let log = Logger(subsystem: "com.reticamsgr", category: "inbound")

    /// Keeps `bytes` for the re-check, unless `maxStoredMessages` rows already hold bytes. Runs in
    /// the transaction that inserts the message row.
    static func storeBytes(_ bytes: Data, messageId: UUID, _ db: GRDB.Database) throws {
        guard try UnverifiedPacket.fetchCount(db) < maxStoredMessages else {
            log.notice("unverified bytes cap reached: storing a message without bytes")
            return
        }
        try UnverifiedPacket.insert { UnverifiedPacket(messageId: messageId, bytes: bytes) }.execute(db)
    }

    /// `deliveryHash` is our own lxmf.delivery hash. A genuinely signed message addressed to someone
    /// else is not ours to accept (security review Finding 2), so it is removed like a forgery; this
    /// does not rely on the router having dropped it first. nil (not registered yet) leaves every
    /// row alone for a later pass.
    ///
    /// The fetch, the promotions and the forged-row collection share one write transaction (final
    /// review F4), so a row cannot change between being read and being promoted. File removal
    /// follows, for exactly the forged ids that transaction collected.
    public static func run(_ database: any DatabaseWriter, attachmentStore: AttachmentStore,
                           sourceHex: String, identity: Identity,
                           deliveryHash: Data?) async throws -> (verified: Int, removed: [UUID]) {
        guard let deliveryHash else { return (0, []) }
        let (verified, forged) = try await database.write { db -> (Int, [(id: UUID, hash: String)]) in
            let rows = try Message.where { $0.peerHex.eq(sourceHex) && !$0.validated }.fetchAll(db)
            guard !rows.isEmpty else { return (0, []) }
            let ids = rows.map(\.id)
            let packets = try UnverifiedPacket.where { $0.messageId.in(ids) }.fetchAll(db)
            let bytesById = Dictionary(uniqueKeysWithValues: packets.map { ($0.messageId, $0.bytes) })
            var verifiedIds: [UUID] = []
            var forged: [(id: UUID, hash: String)] = []
            for row in rows {
                guard let bytes = bytesById[row.id] else { continue }
                // The bytes must also claim this sender: `peerHex` is the stored `sourceHash`, so a
                // mismatch means the row and its bytes disagree, and it is treated as forged. They
                // must be addressed to us, too.
                if let message = LXMessage.unpack(bytes), message.sourceHash.hexString == sourceHex,
                   message.destinationHash == deliveryHash,
                   message.validateSignature(source: identity) {
                    verifiedIds.append(row.id)
                } else {
                    forged.append((row.id, row.messageHash))
                }
            }
            if !verifiedIds.isEmpty {
                let promoted = verifiedIds
                try Message.where { $0.id.in(promoted) }
                    .update { $0.validated = true }
                    .execute(db)
                try UnverifiedPacket.where { $0.messageId.in(promoted) }.delete().execute(db)
            }
            return (verifiedIds.count, forged)
        }
        var removed: [UUID] = []
        if !forged.isEmpty {
            log.notice("recheck: removing \(forged.count, privacy: .public) forged message(s) claiming \(String(sourceHex.prefix(8)), privacy: .public)")
            removed = try await MessagePurge.removeMessages(database, attachmentStore: attachmentStore,
                                                            ids: forged.map(\.id), hashes: forged.map(\.hash))
        }
        return (verified, removed)
    }

    /// Every sender with stored bytes waiting for a check, for the launch pass.
    static func pendingPeers(_ database: any DatabaseWriter) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT m.peerHex FROM unverifiedPackets u
                JOIN messages m ON m.id = u.messageId
                WHERE m.validated = 0
                """)
        }
    }
}
