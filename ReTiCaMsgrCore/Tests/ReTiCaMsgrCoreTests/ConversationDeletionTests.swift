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
private func deletionTestStore(_ db: any DatabaseWriter, files: AttachmentStore? = nil,
                               configure: ((inout AppFeature.State) -> Void)? = nil)
    -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: Identity())
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.attachmentStore = files ?? deleteStore()
        $0.date = .constant(deleteNow)
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.badge = .ignored
    }
    store.exhaustivity = .off
    return store
}

@MainActor @Test func deleteCancelsInFlightSends() async throws {
    let db = try AppDatabase.makeInMemory()
    let hash = String(repeating: "87", count: 16)
    let settled = String(repeating: "88", count: 16)
    try await db.write { d in
        try Message.insert { deleteMessage(1, deletePeerA, outgoing: true, status: MessageStatus.sending, hash: hash) }.execute(d)
        try Message.insert { deleteMessage(2, deletePeerA, outgoing: true, status: MessageStatus.delivered, hash: settled) }.execute(d)
    }
    let store = deletionTestStore(db) {
        $0.conversations = [Conversation(peerHex: deletePeerA, lastBody: "m2", lastTimestamp: deleteNow)]
    }
    // Exhaustive for the receive window: a cancel for the settled row would be an unexpected
    // received action and fail the test.
    store.exhaustivity = .on
    await store.send(.deleteConversation(key: deletePeerA, isGroup: false))
    await store.receive(.node(.client(.cancelOutbound(messageHash: Data(hexString: hash)!))))
    await store.receive(.node(.client(.router(.cancelOutbound(messageHash: Data(hexString: hash)!)))))
    await store.receive(\.conversationsLoaded) { $0.conversations = [] }
    await store.finish()
    store.exhaustivity = .off
    #expect(store.state.conversations.first { $0.peerHex == deletePeerA } == nil)
    #expect(try await deleteCount(db, peer: deletePeerA) == 0)
}

/// Only an outgoing row still `sending` is reported for cancelling, not a settled one or a received one.
@Test func deleteReportsOnlySendingOutgoingHashes() async throws {
    let db = try AppDatabase.makeInMemory()
    let hash = String(repeating: "87", count: 16)
    try await db.write { d in
        try Message.insert { deleteMessage(1, deletePeerA, outgoing: true, status: MessageStatus.sending, hash: hash) }.execute(d)
        try Message.insert { deleteMessage(2, deletePeerA, outgoing: true, status: MessageStatus.delivered,
                                           hash: String(repeating: "88", count: 16)) }.execute(d)
        try Message.insert { deleteMessage(3, deletePeerA, outgoing: false, status: MessageStatus.sending,
                                           hash: String(repeating: "89", count: 16)) }.execute(d)
    }
    let result = try await ConversationDeletion.run(db, attachmentStore: deleteStore(), key: deletePeerA, isGroup: false)
    #expect(result.inFlightHashes == [Data(hexString: hash)!])
}

/// A group post's row hash is its post id; the router knows each member's copy by its
/// `GroupDelivery` hash, and only the copies still sending are cancelled.
@Test func deleteGroupCancelsMemberCopiesInFlight() async throws {
    let db = try AppDatabase.makeInMemory()
    let postId = String(repeating: "70", count: 16)
    let g1 = String(repeating: "71", count: 16)
    let g2 = String(repeating: "72", count: 16)
    let post = deleteMessage(1, deletePeerA, outgoing: true, status: MessageStatus.sending, hash: postId, group: deleteGroup)
    try await db.write { d in
        try Message.insert { post }.execute(d)
        try GroupDelivery.insert {
            GroupDelivery(messageId: post.id, memberHex: deletePeerA, messageHash: g1, status: MessageStatus.sending,
                          storedAt: nil, deliveredAt: nil, failedAt: nil)
        }.execute(d)
        try GroupDelivery.insert {
            GroupDelivery(messageId: post.id, memberHex: deletePeerB, messageHash: g2, status: MessageStatus.delivered,
                          storedAt: nil, deliveredAt: deleteNow, failedAt: nil)
        }.execute(d)
    }
    let result = try await ConversationDeletion.run(db, attachmentStore: deleteStore(), key: deleteGroup, isGroup: true)
    #expect(result.inFlightHashes == [Data(hexString: g1)!])
}

@MainActor @Test func deleteGroupConversationRemovesItsPosts() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { d in
        try Message.insert { deleteMessage(1, deletePeerA, group: deleteGroup) }.execute(d)
        try Message.insert { deleteMessage(2, deletePeerB, group: deleteGroup) }.execute(d)
        try Message.insert { deleteMessage(3, deletePeerA) }.execute(d)
    }
    let store = deletionTestStore(db)
    await store.send(.deleteConversation(key: deleteGroup, isGroup: true))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Message.all.fetchAll($0) }.map(\.body) == ["m3"])
    #expect(store.state.conversations.map(\.peerHex) == [deletePeerA])
}

/// Deleting the conversation that is on screen closes the thread.
@MainActor @Test func deleteClosesTheOpenThread() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { d in try Message.insert { deleteMessage(1, deletePeerA) }.execute(d) }
    let store = deletionTestStore(db) { $0.openPeerHex = deletePeerA }
    await store.send(.deleteConversation(key: deletePeerA, isGroup: false))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.openPeerHex == nil)
}

/// The image cache drops the deleted attachments' decoded images.
@MainActor @Test func deleteEvictsTheAttachmentCache() async throws {
    let db = try AppDatabase.makeInMemory()
    let files = deleteStore()
    let message = deleteMessage(1, deletePeerA)
    let path = try files.store(Data([1]), messageHash: message.messageHash, outgoing: false, ext: "bin")
    let attachment = Attachment(id: UUID(), messageId: message.id, kind: AttachmentKind.file, name: "a.bin",
                                format: "bin", size: 1, width: nil, height: nil, path: path)
    try await db.write { d in
        try Message.insert { message }.execute(d)
        try Attachment.insert { attachment }.execute(d)
    }
    let evicted = LockIsolated<[UUID]>([])
    let store = deletionTestStore(db, files: files)
    store.dependencies.attachmentCacheEvictor = AttachmentCacheEvictor { ids in evicted.withValue { $0.append(contentsOf: ids) } }
    await store.send(.deleteConversation(key: deletePeerA, isGroup: false))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(evicted.value == [attachment.id])
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
    await store.send(.deleteConversation(key: deletePeerA, isGroup: false))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.drafts[deletePeerA] == nil)
    #expect(store.state.drafts[deletePeerB]?.text == "other")
}
