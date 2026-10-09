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
        m.registerMigration("addDisappearingMessages") { db in
            // Disappearing messages (spec 2026-10-05 §2). `expirySeconds` is the duration carried
            // on the wire, `expiresAt` the absolute deletion time the purge reads: NULL with a
            // duration means "received, not yet viewed". `isTimerChange` marks the announcement
            // rows that render as a system line and never expire. Rows from before this
            // migration read back NULL / NULL / false: ordinary, never-expiring bubbles.
            try db.alter(table: "messages") { t in
                t.add(column: "expirySeconds", .integer)
                t.add(column: "expiresAt", .datetime)
                t.add(column: "isTimerChange", .boolean).notNull().defaults(to: false)
            }
            // The shared per-conversation timer. Not in `learnedPeerRows`: that is an announce
            // cache, pruned after 45 days and replaced on every announce.
            try db.create(table: "conversationSettings") { t in
                t.primaryKey("peerHex", .text).notNull()
                t.column("expirySeconds", .integer)   // NULL = off
                t.column("updatedAt", .datetime).notNull()
            }
        }
        m.registerMigration("addExpiresAtIndex") { db in
            // The purge selects due rows and the next deadline by `expiresAt` on every send,
            // arrival, thread open and sleeper wake (amendment A15). Partial on non-NULL so the
            // index holds only the rows with a timer.
            try db.execute(sql: "CREATE INDEX messages_expiresAt ON messages(expiresAt) WHERE expiresAt IS NOT NULL")
        }
        m.registerMigration("createGroups") { db in
            // Group chats (spec 2026-10-09 §2, amendment A1). `chatGroups` holds one row per group
            // the user created or was invited to; `groupMembers` its roster, me included, replaced
            // whole on every applied roster; `groupDeliveries` one row per member per outgoing
            // group row (post or event line), which is where the per-member LXMF hashes and
            // outcomes live. The message row's own `status` is derived from those rows.
            try db.create(table: "chatGroups") { t in
                t.primaryKey("groupHex", .text).notNull()
                t.column("name", .text).notNull()
                t.column("creatorHex", .text).notNull()
                t.column("revision", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "groupMembers") { t in
                t.column("groupHex", .text).notNull().references("chatGroups", onDelete: .cascade)
                t.column("memberHex", .text).notNull()
                t.primaryKey(["groupHex", "memberHex"])
            }
            // `groupHex` keys a row to its group (NULL = one-to-one), `groupPostId` is the 16-byte
            // post id as hex (NULL on event lines), `isGroupEvent` marks roster/leave lines, and
            // `groupControl` marks an outgoing line that carries a roster or leave to its members
            // so a deferred copy can be rebuilt (amendment A3). Rows from before this migration
            // read back NULL / NULL / false / NULL.
            try db.alter(table: "messages") { t in
                t.add(column: "groupHex", .text)
                t.add(column: "groupPostId", .text)
                t.add(column: "isGroupEvent", .boolean).notNull().defaults(to: false)
                t.add(column: "groupControl", .text)
            }
            // The duplicate-post guard (spec §2): one row per post id per group. Partial, so
            // one-to-one rows and event lines (NULL ids) never collide.
            try db.execute(sql: "CREATE UNIQUE INDEX messages_groupPost ON messages(groupHex, groupPostId) WHERE groupHex IS NOT NULL AND groupPostId IS NOT NULL")
            try db.create(table: "groupDeliveries") { t in
                t.column("messageId", .text).notNull().references("messages", onDelete: .cascade)
                t.column("memberHex", .text).notNull()
                t.column("messageHash", .text)          // NULL while waiting
                t.column("status", .text).notNull()
                t.column("storedAt", .datetime)
                t.column("deliveredAt", .datetime)
                t.column("failedAt", .datetime)
                t.primaryKey(["messageId", "memberHex"])
            }
            try db.create(indexOn: "groupDeliveries", columns: ["messageHash"])
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
