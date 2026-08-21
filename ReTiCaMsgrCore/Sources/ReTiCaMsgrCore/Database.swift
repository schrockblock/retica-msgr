import Foundation
import GRDB
import SQLiteData

public enum AppDatabase {
    /// GRDB migrator creating the `messages` table.
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
}
