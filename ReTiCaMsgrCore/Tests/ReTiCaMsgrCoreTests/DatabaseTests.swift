import Testing
import Foundation
import GRDB
import SQLiteData
@testable import ReTiCaMsgrCore

@Test func messageInsertAndFetchByPeer() throws {
    let db = try AppDatabase.makeInMemory()
    let peer = "aa" + String(repeating: "00", count: 15)
    let m = Message(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        peerHex: peer,
        isOutgoing: true,
        body: "hi",
        timestamp: Date(timeIntervalSince1970: 1),
        status: MessageStatus.sent,
        validated: false,
        messageHash: "abcd"
    )
    try db.write { try Message.insert { m }.execute($0) }
    let rows = try db.read { try Message.where { $0.peerHex.eq(peer) }.order(by: \.timestamp).fetchAll($0) }
    #expect(rows == [m])
}

// MARK: - Message Info metadata (addMessageInfo)

/// A row written before `addMessageInfo` existed must read back through the new `Message` shape
/// with every metadata field nil. Nil is what the Info sheet shows as "—".
@Test func infoMigrationLegacyRowReadsBackWithNilMetadata() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator().migrate(queue, upTo: "createReactions")
    // Raw SQL: the Swift `Message` type already has the new columns, so it cannot insert into the
    // old schema. Values use the encodings SQLiteData writes: lowercase UUID text, ISO-8601 ms text.
    try queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO messages (id, peerHex, isOutgoing, body, timestamp, status, validated, messageHash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: ["00000000-0000-0000-0000-000000000001", String(repeating: "a", count: 32),
                        0, "old", "2023-11-14 22:13:20.000", MessageStatus.received, 1, ""]
        )
    }
    try AppDatabase.migrator().migrate(queue)
    let rows = try queue.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.body == "old")
    #expect(row.timestamp == Date(timeIntervalSince1970: 1700000000))
    #expect(row.validated == true)
    #expect(row.senderTimestamp == nil)
    #expect(row.arrivalMethod == nil)
    #expect(row.sentViaPropagation == nil)
    #expect(row.storedAt == nil)
    #expect(row.deliveredAt == nil)
    #expect(row.failedAt == nil)
    #expect(row.wireSize == nil)
    #expect(row.titleSize == nil)
    #expect(row.contentSize == nil)
    #expect(row.fieldKeys == nil)
    #expect(row.stampState == nil)
}

/// Every new column round-trips. The expectations use literals, not `back == m`, so a model that
/// silently drops a field on init cannot pass by dropping it on both sides.
@Test func infoMigrationRoundTripsEveryMetadataColumn() throws {
    let db = try AppDatabase.makeInMemory()
    let m = Message(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        peerHex: String(repeating: "b", count: 32),
        isOutgoing: true,
        body: "hi",
        timestamp: Date(timeIntervalSince1970: 1700000000),
        status: MessageStatus.delivered,
        validated: false,
        messageHash: "abcd",
        senderTimestamp: Date(timeIntervalSince1970: 1699999999.5),
        arrivalMethod: ArrivalMethod.direct,
        sentViaPropagation: true,
        storedAt: Date(timeIntervalSince1970: 1700000005),
        deliveredAt: Date(timeIntervalSince1970: 1700000010),
        failedAt: Date(timeIntervalSince1970: 1700000003),
        wireSize: 412,
        titleSize: 3,
        contentSize: 17,
        fieldKeys: "0xfb,0xfc",
        stampState: StampState.valid
    )
    try db.write { try Message.insert { m }.execute($0) }
    let back = try #require(try db.read { try Message.all.fetchAll($0) }.first)
    #expect(back.senderTimestamp == Date(timeIntervalSince1970: 1699999999.5))
    #expect(back.arrivalMethod == "direct")
    #expect(back.sentViaPropagation == true)
    #expect(back.storedAt == Date(timeIntervalSince1970: 1700000005))
    #expect(back.deliveredAt == Date(timeIntervalSince1970: 1700000010))
    #expect(back.failedAt == Date(timeIntervalSince1970: 1700000003))
    #expect(back.wireSize == 412)
    #expect(back.titleSize == 3)
    #expect(back.contentSize == 17)
    #expect(back.fieldKeys == "0xfb,0xfc")
    #expect(back.stampState == "valid")
    #expect(back == m)
}

// MARK: - Message replies (addReplies)

/// A row written before `addReplies` existed reads back as "not a reply".
@Test func replyMigrationLegacyRowReadsBackWithNilReplyColumns() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator().migrate(queue, upTo: "addMessageInfo")
    // Raw SQL: the Swift `Message` type already has the new columns, so it cannot insert into the
    // old schema. Values use the encodings SQLiteData writes: lowercase UUID text, ISO-8601 ms text.
    try queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO messages (id, peerHex, isOutgoing, body, timestamp, status, validated, messageHash, fieldKeys)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: ["00000000-0000-0000-0000-000000000003", String(repeating: "a", count: 32),
                        0, "before replies", "2023-11-14 22:13:20.000", MessageStatus.received, 1,
                        String(repeating: "c", count: 64), ""]
        )
    }
    try AppDatabase.migrator().migrate(queue)
    let rows = try queue.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.body == "before replies")
    #expect(row.fieldKeys == "")
    #expect(row.replyToHash == nil)
    #expect(row.replyQuote == nil)
}

/// Both columns round-trip. Literal expectations, not only `back == m`, so a model that drops a
/// field on init cannot pass by dropping it on both sides.
@Test func replyMigrationRoundTripsReplyColumns() throws {
    let db = try AppDatabase.makeInMemory()
    let m = Message(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        peerHex: String(repeating: "b", count: 32),
        isOutgoing: false,
        body: "yes!",
        timestamp: Date(timeIntervalSince1970: 1700000000),
        status: MessageStatus.received,
        validated: true,
        messageHash: String(repeating: "d", count: 64),
        fieldKeys: "0x30,0x31",
        replyToHash: "00112233445566778899aabbccddeeff0123456789abcdeffedcba9876543210",
        replyQuote: "are you coming? ☕"
    )
    try db.write { try Message.insert { m }.execute($0) }
    let back = try #require(try db.read { try Message.all.fetchAll($0) }.first)
    #expect(back.replyToHash == "00112233445566778899aabbccddeeff0123456789abcdeffedcba9876543210")
    #expect(back.replyQuote == "are you coming? ☕")
    #expect(back == m)
}
