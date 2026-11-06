import Testing
import Foundation
import SQLiteData
import struct ReTiCAMsgrCore.Attachment
@testable import ReTiCAMsgrCore

private let purgeNow = Date(timeIntervalSince1970: 1700000000)
private let purgePeer = String(repeating: "7a", count: 16)

private func purgeStore() -> AttachmentStore {
    AttachmentStore(baseDirectory: FileManager.default.temporaryDirectory
        .appending(path: "expiryPurgeTests-\(UUID().uuidString)"))
}

private func purgeMessage(_ n: Int, expiresAt: Date?, expirySeconds: Int? = 60, hash: String? = nil) -> Message {
    Message(
        id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!,
        peerHex: purgePeer, isOutgoing: false, body: "m\(n)",
        timestamp: purgeNow.addingTimeInterval(TimeInterval(n)),
        status: MessageStatus.received, validated: true,
        messageHash: hash ?? String(repeating: String(format: "%02x", n), count: 32),
        expirySeconds: expirySeconds, expiresAt: expiresAt
    )
}

/// Spec §3 purge: the row, its attachment row (cascade), the attachment file, the export copy and
/// its reaction rows all go. `purged` counts the rows.
@Test func expiryPurgeDeletesDueRowWithFileExportAttachmentAndReactions() async throws {
    let db = try AppDatabase.makeInMemory()
    let files = purgeStore()
    let due = purgeMessage(1, expiresAt: purgeNow.addingTimeInterval(-1))
    let path = try files.store(Data([1, 2, 3]), messageHash: due.messageHash, outgoing: false, ext: "bin")
    let attachment = Attachment(id: UUID(), messageId: due.id, kind: AttachmentKind.file, name: "notes.bin",
                                format: "bin", size: 3, width: nil, height: nil, path: path)
    let export = try files.exportURL(for: attachment)
    #expect(FileManager.default.fileExists(atPath: export.path))
    try await db.write { d in
        try Message.insert { due }.execute(d)
        try Attachment.insert { attachment }.execute(d)
        try Reaction.insert { Reaction(messageHash: due.messageHash, reactorHex: purgePeer, emoji: "👍", sentAt: 1) }.execute(d)
    }

    let result = try await MessagePurge.run(db, attachmentStore: files, now: purgeNow)

    #expect(result == MessagePurge.Result(purged: 1, nextDue: nil, purgedAttachmentIds: [attachment.id]))
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Reaction.all.fetchAll($0) }.isEmpty)
    #expect(!files.exists(path))
    #expect(!FileManager.default.fileExists(atPath: export.deletingLastPathComponent().path))
}

/// A row due exactly now is due. Later rows stay and the earliest of them is the next due time.
@Test func expiryPurgeKeepsLaterRowsAndReturnsTheirDueTime() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { d in
        try Message.insert { purgeMessage(1, expiresAt: purgeNow) }.execute(d)
        try Message.insert { purgeMessage(2, expiresAt: purgeNow.addingTimeInterval(50)) }.execute(d)
        try Message.insert { purgeMessage(3, expiresAt: purgeNow.addingTimeInterval(5)) }.execute(d)
    }
    let result = try await MessagePurge.run(db, attachmentStore: purgeStore(), now: purgeNow)
    #expect(result == MessagePurge.Result(purged: 1, nextDue: purgeNow.addingTimeInterval(5), purgedAttachmentIds: []))
    let bodies = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }.map(\.body)
    #expect(bodies == ["m2", "m3"])
}

/// A received row that has a duration but was never viewed has no `expiresAt` and is never touched.
/// An ordinary row (no duration) is never touched either, and with nothing stamped there is no
/// next due time.
@Test func expiryPurgeIgnoresUnstampedAndOrdinaryRows() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { d in
        try Message.insert { purgeMessage(1, expiresAt: nil) }.execute(d)
        try Message.insert { purgeMessage(2, expiresAt: nil, expirySeconds: nil) }.execute(d)
    }
    let result = try await MessagePurge.run(db, attachmentStore: purgeStore(), now: purgeNow.addingTimeInterval(1_000_000))
    #expect(result == MessagePurge.Result(purged: 0, nextDue: nil, purgedAttachmentIds: []))
    #expect(try await db.read { try Message.all.fetchAll($0) }.count == 2)
}

/// Only the purged messages' reactions go; the seen-hash table is untouched so a late propagation
/// copy is not re-stored as a new message.
@Test func expiryPurgeKeepsOtherReactionsAndSeenHashes() async throws {
    let db = try AppDatabase.makeInMemory()
    let due = purgeMessage(1, expiresAt: purgeNow.addingTimeInterval(-1))
    let kept = purgeMessage(2, expiresAt: nil, expirySeconds: nil)
    try await db.write { d in
        try Message.insert { due }.execute(d)
        try Message.insert { kept }.execute(d)
        try Reaction.insert { Reaction(messageHash: due.messageHash, reactorHex: purgePeer, emoji: "👍", sentAt: 1) }.execute(d)
        try Reaction.insert { Reaction(messageHash: kept.messageHash, reactorHex: purgePeer, emoji: "❤️", sentAt: 1) }.execute(d)
        try SeenHashRow.insert { SeenHashRow(hashHex: due.messageHash, storedAt: purgeNow) }.execute(d)
    }
    _ = try await MessagePurge.run(db, attachmentStore: purgeStore(), now: purgeNow)
    let reactions = try await db.read { try Reaction.all.fetchAll($0) }
    #expect(reactions.map(\.messageHash) == [kept.messageHash])
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.map(\.hashHex) == [due.messageHash])
}

@Test func expiryPurgeDeleteExportsRemovesTheDirectoryAndToleratesAbsence() throws {
    let files = purgeStore()
    let attachment = Attachment(id: UUID(), messageId: UUID(), kind: AttachmentKind.file, name: "a.txt",
                                format: "txt", size: 1, width: nil, height: nil, path: "")
    files.deleteExports(for: attachment)   // nothing there: not an error
    var withBytes = attachment
    withBytes.path = try files.store(Data([9]), messageHash: String(repeating: "ab", count: 32), outgoing: true, ext: "txt")
    let export = try files.exportURL(for: withBytes)
    let directory = export.deletingLastPathComponent()
    #expect(FileManager.default.fileExists(atPath: directory.path))
    files.deleteExports(for: withBytes)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}
