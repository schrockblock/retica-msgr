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

// MARK: - Attachments (createAttachments)

private func attachTableMessage(_ id: String, hash: String) -> Message {
    Message(
        id: UUID(uuidString: id)!,
        peerHex: String(repeating: "b", count: 32),
        isOutgoing: true,
        body: "",
        timestamp: Date(timeIntervalSince1970: 1700000000),
        status: MessageStatus.sending,
        validated: false,
        messageHash: hash
    )
}

/// Every column round-trips. Literal expectations, not only `back == a`, so a model that drops a
/// field on init cannot pass by dropping it on both sides.
@Test func attachTableRoundTripsEveryColumn() throws {
    let db = try AppDatabase.makeInMemory()
    let m = attachTableMessage("00000000-0000-0000-0000-000000000010", hash: String(repeating: "e", count: 64))
    let a = Attachment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        messageId: m.id,
        kind: AttachmentKind.image,
        name: "IMG_20231114_221320.jpg",
        format: "jpeg",
        size: 34_211,
        width: 1280,
        height: 853,
        path: "eeee-out.jpg"
    )
    try db.write { d in
        try Message.insert { m }.execute(d)
        try Attachment.insert { a }.execute(d)
    }
    let back = try #require(try db.read { try Attachment.all.fetchAll($0) }.first)
    #expect(back.messageId == m.id)
    #expect(back.kind == "image")
    #expect(back.name == "IMG_20231114_221320.jpg")
    #expect(back.format == "jpeg")
    #expect(back.size == 34_211)
    #expect(back.width == 1280)
    #expect(back.height == 853)
    #expect(back.path == "eeee-out.jpg")
    #expect(back == a)
}

/// A file attachment has no dimensions, and an empty path means "bytes unavailable".
@Test func attachTableFileRowHasNilDimensions() throws {
    let db = try AppDatabase.makeInMemory()
    let m = attachTableMessage("00000000-0000-0000-0000-000000000012", hash: String(repeating: "f", count: 64))
    let a = Attachment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
        messageId: m.id, kind: AttachmentKind.file, name: "notes.pdf", format: "pdf",
        size: 12, width: nil as Int?, height: nil as Int?, path: ""
    )
    try db.write { d in
        try Message.insert { m }.execute(d)
        try Attachment.insert { a }.execute(d)
    }
    let back = try #require(try db.read { try Attachment.all.fetchAll($0) }.first)
    #expect(back.kind == "file")
    #expect(back.width == nil)
    #expect(back.height == nil)
    #expect(back.path == "")
}

/// Deleting a message deletes its attachment row (ON DELETE CASCADE), so a future "delete
/// conversation" cannot leave orphan rows pointing at files.
@Test func attachTableRowIsDeletedWithItsMessage() throws {
    let db = try AppDatabase.makeInMemory()
    let m = attachTableMessage("00000000-0000-0000-0000-000000000014", hash: String(repeating: "1", count: 64))
    let a = Attachment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!,
        messageId: m.id, kind: AttachmentKind.file, name: "a.bin", format: "bin",
        size: 1, width: nil as Int?, height: nil as Int?, path: "1111-in.bin"
    )
    try db.write { d in
        try Message.insert { m }.execute(d)
        try Attachment.insert { a }.execute(d)
    }
    try db.write { d in try Message.where { $0.id.eq(m.id) }.delete().execute(d) }
    let remaining = try db.read { try Attachment.all.fetchAll($0) }
    #expect(remaining.isEmpty)
}

/// An attachment row must point at an existing message: the foreign key is enforced.
@Test func attachTableRejectsAnOrphanRow() throws {
    let db = try AppDatabase.makeInMemory()
    let orphan = Attachment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000016")!,
        messageId: UUID(uuidString: "00000000-0000-0000-0000-0000000000ff")!,
        kind: AttachmentKind.file, name: "x", format: "", size: 0, width: nil as Int?, height: nil as Int?, path: ""
    )
    #expect(throws: (any Error).self) {
        try db.write { d in try Attachment.insert { orphan }.execute(d) }
    }
}

/// A row written before `createAttachments` reads back with nil for the two new message columns.
@Test func attachTableLegacyMessageReadsBackWithNilNewColumns() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator().migrate(queue, upTo: "addReplies")
    try queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO messages (id, peerHex, isOutgoing, body, timestamp, status, validated, messageHash, fieldKeys)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: ["00000000-0000-0000-0000-000000000017", String(repeating: "a", count: 32),
                        1, "before attachments", "2023-11-14 22:13:20.000", MessageStatus.failed, 0,
                        String(repeating: "c", count: 64), ""]
        )
    }
    try AppDatabase.migrator().migrate(queue)
    let row = try #require(try queue.read { try Message.all.fetchAll($0) }.first)
    #expect(row.body == "before attachments")
    #expect(row.failureReason == nil)
    #expect(row.propagationRefused == nil)
    let attachments = try queue.read { try Attachment.all.fetchAll($0) }
    #expect(attachments.isEmpty)
}

/// The two new message columns round-trip, and the new status/reason constants are the strings
/// the spec names.
@Test func attachTableMessageColumnsRoundTripAndConstantsMatchSpec() throws {
    let db = try AppDatabase.makeInMemory()
    var m = attachTableMessage("00000000-0000-0000-0000-000000000018", hash: String(repeating: "2", count: 64))
    m.status = MessageStatus.cancelled
    m.failureReason = FailureReason.cancelled
    m.propagationRefused = PropagationRefusal.tooLargeForNode
    try db.write { try Message.insert { m }.execute($0) }
    let back = try #require(try db.read { try Message.all.fetchAll($0) }.first)
    #expect(back.status == "cancelled")
    #expect(back.failureReason == "cancelled")
    #expect(back.propagationRefused == "too large for node")
    #expect(FailureReason.rejected == "rejected")
    #expect(AttachmentKind.image == "image")
    #expect(AttachmentKind.file == "file")
}
