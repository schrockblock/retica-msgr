import Foundation
import GRDB
import SQLiteData

public enum AppDatabase {
    /// GRDB migrator for the app's tables. Migrations are append-only: never edit a shipped one.
    static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("createMessages") { db in
            try db.create(table: "messages") { t in
                t.primaryKey("id", .text).notNull()
                t.column("peerHex", .text).notNull()
                t.column("isOutgoing", .boolean).notNull()
                t.column("body", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("validated", .boolean).notNull()
                t.column("messageHash", .text).notNull()
            }
        }
        m.registerMigration("createPropagationEntries") { db in
            try db.create(table: "propagationEntryRows") { t in
                t.primaryKey("transientIdHex", .text).notNull()
                t.column("destinationHashHex", .text).notNull()
                t.column("lxmfData", .blob).notNull()
                t.column("storedAt", .datetime).notNull()
            }
        }
        m.registerMigration("createLearnedDestinations") { db in
            // Learned transport paths: mirrors Transport.State.learned so a cold start can route
            // to known destinations without waiting for re-announces. Pruned at launch (before the
            // read) on the same 7-day cutoff as Transport.maintenanceTick. Write policy differs
            // from the dedup tables: debounced at ~30 s (not per-event) because path updates are
            // continuous on a meshed network. A flush fires on applicationDidEnterBackground /
            // applicationWillTerminate.
            try db.create(table: "learnedDestinationRows") { t in
                t.primaryKey("destinationHashHex", .text).notNull()
                t.column("publicKeyHex", .text).notNull()
                t.column("appDataHex", .text)           // nullable — absent when announce has no app-data
                t.column("ratchetHex", .text)           // nullable — absent when no ratchet
                t.column("interfaceId", .text).notNull()
                t.column("hops", .integer).notNull()
                t.column("nextHopHex", .text)           // nullable — nil if directly heard
                t.column("announceEmitted", .integer).notNull()
                t.column("learnedAt", .datetime).notNull()
            }
        }
        m.registerMigration("createDedupPersistence") { db in
            // Seen-message hashes: mirrors LXMFRouter.State.seen (RingSet capacity 10_000).
            // Pruned to the ring capacity on every write (oldest pruned first, matching what the
            // ring would evict). Column "hashHex" matches the @Table-generated name.
            try db.create(table: "seenHashRows") { t in
                t.primaryKey("hashHex", .text).notNull()
                t.column("storedAt", .datetime).notNull()
            }

            // Downloaded transient IDs: mirrors LXMFRouter.State.downloadedTransientIds.
            // Deliberately NOT pruned — see DownloadedTransientIdRow for the ruling and revisit
            // trigger.
            try db.create(table: "downloadedTransientIdRows") { t in
                t.primaryKey("transientIdHex", .text).notNull()
                t.column("storedAt", .datetime).notNull()
            }

            // Learned peer data: mirrors LXMFNode.State.learnedPeers. Expiry is handled by the
            // library on rehydration; this table is never pruned at write time.
            try db.create(table: "learnedPeerRows") { t in
                t.primaryKey("destinationHashHex", .text).notNull()
                t.column("displayName", .text)     // nullable — absent when peer sent no name
                t.column("stampCost", .integer)    // nullable — absent when peer sent no cost
                t.column("supportsCompression", .boolean).notNull()
                t.column("learnedAt", .datetime).notNull()
            }
        }
        m.registerMigration("createReactions") { db in
            // One row per (message, reactor): Signal/iMessage semantics, one reaction per person.
            // Removals are tombstones (emoji = "") so a late, older add can't resurrect them.
            // sentAt is REAL seconds-since-1970 so last-writer-wins comparisons are exact.
            try db.create(table: "reactions") { t in
                t.column("messageHash", .text).notNull()
                t.column("reactorHex", .text).notNull()
                t.column("emoji", .text).notNull()
                t.column("sentAt", .double).notNull()
                t.primaryKey(["messageHash", "reactorHex"])
            }
        }
        m.registerMigration("addMessageInfo") { db in
            // Debugging metadata for the message Info sheet. Every column is nullable: rows stored
            // before this migration read back NULL, which the sheet shows as "—".
            try db.alter(table: "messages") { t in
                t.add(column: "senderTimestamp", .datetime)
                t.add(column: "arrivalMethod", .text)
                t.add(column: "sentViaPropagation", .boolean)
                t.add(column: "storedAt", .datetime)
                t.add(column: "deliveredAt", .datetime)
                t.add(column: "failedAt", .datetime)
                t.add(column: "wireSize", .integer)
                t.add(column: "titleSize", .integer)
                t.add(column: "contentSize", .integer)
                t.add(column: "fieldKeys", .text)
                t.add(column: "stampState", .text)
            }
        }
        m.registerMigration("addReplies") { db in
            // Message replies: LXMF FIELD_REPLY_TO (0x30) as hex, FIELD_REPLY_QUOTE (0x31) as text.
            // Nullable: rows stored before this migration, and every non-reply, read back NULL.
            try db.alter(table: "messages") { t in
                t.add(column: "replyToHash", .text)
                t.add(column: "replyQuote", .text)
            }
        }
        m.registerMigration("createAttachments") { db in
            // One row per attachment (spec 2026-09-28 §1). `messageId` cascades so a deleted
            // message can never leave a row pointing at a file. Indexed, not unique: the app
            // enforces one attachment per message today, the schema does not assume it.
            try db.create(table: "attachments") { t in
                t.primaryKey("id", .text).notNull()
                t.column("messageId", .text).notNull().references("messages", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("format", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("path", .text).notNull()
            }
            try db.create(indexOn: "attachments", columns: ["messageId"])
            // Outgoing-only reasons for the Info sheet. Nullable: rows from before this migration
            // and every ordinary row read back NULL.
            try db.alter(table: "messages") { t in
                t.add(column: "failureReason", .text)
                t.add(column: "propagationRefused", .text)
            }
        }
        return m
    }

    public static func makeInMemory() throws -> any DatabaseWriter {
        let queue = try DatabaseQueue()
        try migrator().migrate(queue)
        return queue
    }

    public static func makeOnDisk(path: String) throws -> any DatabaseWriter {
        let queue = try DatabaseQueue(path: path)
        try migrator().migrate(queue)
        return queue
    }

    /// Any row in `messages`: the local state tied to this device's identity (every peer in a
    /// conversation knows this address). Throws when the table cannot be read.
    public static func hasMessages(_ database: any DatabaseWriter) throws -> Bool {
        try database.read { try Message.fetchCount($0) > 0 }
    }
}
