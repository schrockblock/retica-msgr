import Testing
import Foundation
import ComposableArchitecture
import Sharing
import SQLiteData
import ReTiCA
import ReTiCANode
import struct ReTiCaMsgrCore.Attachment
@testable import ReTiCaMsgrCore

private let deleteNow = Date(timeIntervalSince1970: 1700000000)
private let deletePeerA = String(repeating: "a", count: 32)
private let deletePeerB = String(repeating: "b", count: 32)
private let deleteGroup = String(repeating: "9", count: 32)

private func deleteStore() -> AttachmentStore {
    AttachmentStore(baseDirectory: FileManager.default.temporaryDirectory
        .appending(path: "conversationDeletionTests-\(UUID().uuidString)"))
}

private func deleteMessage(_ n: Int, _ peer: String, outgoing: Bool = false, status: String = MessageStatus.received,
                           hash: String? = nil, group: String? = nil) -> Message {
    Message(
        id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!,
        peerHex: peer, isOutgoing: outgoing, body: "m\(n)",
        timestamp: deleteNow.addingTimeInterval(TimeInterval(n)),
        status: status, validated: true,
        messageHash: hash ?? String(repeating: String(format: "%02x", n), count: 32),
        groupHex: group
    )
}

private func deleteCount(_ db: any DatabaseWriter, peer: String) async throws -> Int {
    try await db.read { try Message.where { $0.peerHex.eq(peer) }.fetchAll($0) }.count
}

@Test func deletesOnlyThatPeersMessages() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { d in
        for (n, peer) in [(1, deletePeerA), (2, deletePeerA), (3, deletePeerB), (4, deletePeerB)] {
            try Message.insert { deleteMessage(n, peer) }.execute(d)
        }
    }
    let result = try await ConversationDeletion.run(db, attachmentStore: deleteStore(), key: deletePeerA, isGroup: false)
    #expect(result.deleted == 2)
    #expect(try await deleteCount(db, peer: deletePeerA) == 0)
    #expect(try await deleteCount(db, peer: deletePeerB) == 2)
}

/// A one-to-one delete leaves the group posts that the same peer sent into a group.
@Test func deletePeerKeepsThatPeersGroupPosts() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { d in
        try Message.insert { deleteMessage(1, deletePeerA) }.execute(d)
        try Message.insert { deleteMessage(2, deletePeerA, group: deleteGroup) }.execute(d)
    }
    let result = try await ConversationDeletion.run(db, attachmentStore: deleteStore(), key: deletePeerA, isGroup: false)
    #expect(result.deleted == 1)
    #expect(try await db.read { try Message.all.fetchAll($0) }.map(\.groupHex) == [deleteGroup])
}

@Test func deletesAttachmentFilesAndReactions() async throws {
    let db = try AppDatabase.makeInMemory()
    let files = deleteStore()
    let message = deleteMessage(1, deletePeerA)
    let path = try files.store(Data([1, 2, 3]), messageHash: message.messageHash, outgoing: false, ext: "bin")
    let attachment = Attachment(id: UUID(), messageId: message.id, kind: AttachmentKind.file, name: "notes.bin",
                                format: "bin", size: 3, width: nil, height: nil, path: path)
    try await db.write { d in
        try Message.insert { message }.execute(d)
        try Attachment.insert { attachment }.execute(d)
        try Reaction.insert { Reaction(messageHash: message.messageHash, reactorHex: deletePeerA, emoji: "👍", sentAt: 1) }.execute(d)
    }
    #expect(files.exists(path))
    let result = try await ConversationDeletion.run(db, attachmentStore: files, key: deletePeerA, isGroup: false)
    #expect(result.deletedAttachmentIds == [attachment.id])
    #expect(!files.exists(path))
    #expect(try await db.read { try Reaction.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.isEmpty)
}

/// Seen hashes stop a late propagation copy coming back; the timer (A2) is a setting, not content.
@Test func keepsSeenHashesAndTimer() async throws {
    let db = try AppDatabase.makeInMemory()
    let message = deleteMessage(1, deletePeerA)
    try await db.write { d in
        try Message.insert { message }.execute(d)
        try SeenHashRow.insert { SeenHashRow(hashHex: message.messageHash, storedAt: deleteNow) }.execute(d)
        try ConversationSetting.insert {
            ConversationSetting(peerHex: deletePeerA, expirySeconds: 3600, updatedAt: deleteNow)
        }.execute(d)
    }
    _ = try await ConversationDeletion.run(db, attachmentStore: deleteStore(), key: deletePeerA, isGroup: false)
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.map(\.hashHex) == [message.messageHash])
    #expect(try await db.read { try ConversationSetting.all.fetchAll($0) }.map(\.peerHex) == [deletePeerA])
}

@Test func deleteGroupKeepsGroupAndMembers() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { d in
        try ChatGroup.insert {
            ChatGroup(groupHex: deleteGroup, name: "Crew", creatorHex: deletePeerA, revision: 1,
                      state: GroupState.active, updatedAt: deleteNow)
        }.execute(d)
        try GroupMember.insert { GroupMember(groupHex: deleteGroup, memberHex: deletePeerA) }.execute(d)
        try Message.insert { deleteMessage(1, deletePeerA, group: deleteGroup) }.execute(d)
        try Message.insert { deleteMessage(2, deletePeerB, group: deleteGroup) }.execute(d)
        try Message.insert { deleteMessage(3, deletePeerA) }.execute(d)
    }
    let result = try await ConversationDeletion.run(db, attachmentStore: deleteStore(), key: deleteGroup, isGroup: true)
    #expect(result.deleted == 2)
    #expect(try await db.read { try Message.all.fetchAll($0) }.map(\.body) == ["m3"])
    #expect(try await db.read { try ChatGroup.all.fetchAll($0) }.count == 1)
    #expect(try await db.read { try GroupMember.all.fetchAll($0) }.count == 1)
}

@MainActor
private func deletionTestStore(_ db: any DatabaseWriter, configure: ((inout AppFeature.State) -> Void)? = nil)
    -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: Identity())
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.attachmentStore = deleteStore()
        $0.date = .constant(deleteNow)
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    return store
}

@MainActor @Test func deleteCancelsInFlightSends() async throws {
    let db = try AppDatabase.makeInMemory()
    let hash = String(repeating: "87", count: 16)
    try await db.write { d in
        try Message.insert { deleteMessage(1, deletePeerA, outgoing: true, status: MessageStatus.sending, hash: hash) }.execute(d)
    }
    let store = deletionTestStore(db)
    await store.send(.deleteConversation(key: deletePeerA))
    await store.receive(.node(.client(.cancelOutbound(messageHash: Data(hexString: hash)!))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.conversations.first { $0.peerHex == deletePeerA } == nil)
    #expect(try await deleteCount(db, peer: deletePeerA) == 0)
}

@MainActor @Test func deleteClearsDraft() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { d in try Message.insert { deleteMessage(1, deletePeerA) }.execute(d) }
    let store = deletionTestStore(db) {
        $0.$drafts.withLock {
            $0[deletePeerA] = ConversationDraft(text: "half", updatedAt: deleteNow)
            $0[deletePeerB] = ConversationDraft(text: "other", updatedAt: deleteNow)
        }
    }
    await store.send(.deleteConversation(key: deletePeerA))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.drafts[deletePeerA] == nil)
    #expect(store.state.drafts[deletePeerB]?.text == "other")
}
