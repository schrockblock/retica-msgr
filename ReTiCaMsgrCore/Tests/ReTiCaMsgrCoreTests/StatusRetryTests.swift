import Testing
import Foundation
import ComposableArchitecture
import Sharing
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
@testable import ReTiCaMsgrCore

// Status labels, Retry, and the "Message not sent" notification (brief 2026-10-21).

// MARK: - Helpers (mirrors ResendOnLaunchTests.makeStore)

private let now = Date(timeIntervalSince1970: 1700000000)
private let earlier = now.addingTimeInterval(-600)
private let peer = String(repeating: "a", count: 32)
private let otherPeer = String(repeating: "b", count: 32)

/// `sent` records every message handed to the node and `posted` every local notification, in
/// order: a `.off` TestStore cannot assert an action absent.
@MainActor
private func makeStore(_ db: any DatabaseWriter, sent: LockIsolated<[LXMessage]> = LockIsolated([]),
                       posted: LockIsolated<[LocalNotificationClient.Posted]> = LockIsolated([]),
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: Identity())
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        CombineReducers {
            AppFeature()
            Reduce<AppFeature.State, AppFeature.Action> { _, action in
                if case let .node(.client(.sendMessage(message, _))) = action {
                    sent.withValue { $0.append(message) }
                }
                return .none
            }
        }
    } withDependencies: {
        $0.defaultDatabase = db
        $0.attachmentStore = AttachmentStore.testValue
        $0.localNotifications = .recording(into: posted)
        $0.date = .constant(now)
        $0.transportDate = .constant(now)
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in }, close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in }, openChannel: { _ in },
                                 send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
    }
    store.exhaustivity = .off
    return store
}

/// An outgoing one-to-one row to `to`.
private func outgoingRow(_ n: Int, _ body: String, to: String = peer, status: String = MessageStatus.failed,
                         replyToHash: String? = nil) -> Message {
    var row = Message(id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!,
                      peerHex: to, isOutgoing: true, body: body, timestamp: earlier, status: status,
                      validated: false, messageHash: String(repeating: String(format: "%02x", n), count: 32),
                      senderTimestamp: earlier, replyToHash: replyToHash)
    if status == MessageStatus.failed {
        row.failedAt = earlier
        row.failureReason = FailureReason.rejected
    }
    return row
}

private func insert(_ db: any DatabaseWriter, _ rows: [Message]) async throws {
    try await db.write { db in
        for row in rows { try Message.insert { row }.execute(db) }
    }
}

private func row(_ db: any DatabaseWriter, _ id: UUID) async throws -> Message {
    try #require(try await db.read { try Message.where { $0.id.eq(id) }.fetchOne($0) })
}

/// Sends `action` and waits for every effect it started.
@MainActor
private func run(_ store: TestStoreOf<AppFeature>, _ action: AppFeature.Action) async {
    await store.send(action)
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

private func failed(_ row: Message) -> AppFeature.Action {
    .node(.client(.delegate(.deliveryFailed(messageHash: Data(hexString: row.messageHash)!))))
}

// MARK: - Labels

/// Mutation: return the raw string → "stored".
@Test func storedLabelSaysStoredForPickup() {
    #expect(MessageStatusLabel.text(for: MessageStatus.propagated) == "Stored for pickup")
    #expect(MessageStatusLabel.text(for: MessageStatus.sending) == "Sending…")
    #expect(MessageStatusLabel.text(for: "something new") == "something new")
}

// MARK: - Retry, one-to-one

/// Mutation: don't send → nothing is handed to the node and the row stays failed.
@MainActor @Test func retryResendsAFailedMessageUnderANewHash() async throws {
    let db = try AppDatabase.makeInMemory()
    let original = outgoingRow(1, "did this go?")
    try await insert(db, [original])
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent) { s in
        s.openPeerHex = peer
        s.threadMessages = [original]
    }
    await run(store, .retryTapped(original.id))
    let message = try #require(sent.value.first)
    #expect(sent.value.count == 1)
    #expect(message.content == Data("did this go?".utf8))
    #expect(message.hash.hexString != original.messageHash)
    let stored = try await row(db, original.id)
    #expect(stored.messageHash == message.hash.hexString)
    #expect(stored.status == MessageStatus.sending)
    #expect(stored.failedAt == nil)
    #expect(stored.failureReason == nil)
    // Reserved like a send, and in flight once handed over.
    #expect(store.state.pendingHandOvers == 0)
    #expect(store.state.inFlightSends.contains(message.hash))
}

/// Mutation: skip the migration → the reactions and the reply still name the old hash.
@MainActor @Test func retryMovesReactionsToTheNewHash() async throws {
    let db = try AppDatabase.makeInMemory()
    let original = outgoingRow(1, "react to me")
    var reply = outgoingRow(2, "replying", status: MessageStatus.received, replyToHash: original.messageHash)
    reply.isOutgoing = false
    try await insert(db, [original, reply])
    try await db.write { db in
        _ = try Reaction.apply(Reaction(messageHash: original.messageHash, reactorHex: peer, emoji: "👍", sentAt: 1), db)
    }
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent) { s in
        s.openPeerHex = peer
        s.threadMessages = [original, reply]
    }
    await run(store, .retryTapped(original.id))
    // Read from the row, not the send, so this checks the migration alone.
    let newHash = try await row(db, original.id).messageHash
    #expect(newHash != original.messageHash)
    let replyId = reply.id
    let (reactions, replyRow) = try await db.read { db in
        (try Reaction.all.fetchAll(db), try Message.where { $0.id.eq(replyId) }.fetchOne(db))
    }
    #expect(reactions.count == 1)
    #expect(reactions.allSatisfy { $0.messageHash == newHash })
    #expect(replyRow?.replyToHash == newHash)
}

/// Spec 2026-10-15 §2: nothing is sent to a blocked contact.
/// Mutation: send anyway → it is sent and the row becomes `sending`.
@MainActor @Test func retryKeepsABlockedPeersMessageFailed() async throws {
    let db = try AppDatabase.makeInMemory()
    let original = outgoingRow(1, "before the block")
    try await insert(db, [original])
    try await db.write { try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: peer, blockedAt: earlier), $0) }
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent) { s in
        s.openPeerHex = peer
        s.threadMessages = [original]
        s.blockedPeers = [peer]
    }
    await run(store, .retryTapped(original.id))
    #expect(sent.value.isEmpty)
    let stored = try await row(db, original.id)
    #expect(stored.status == MessageStatus.failed)
    #expect(stored.messageHash == original.messageHash)
    #expect(stored.failedAt == earlier)
    #expect(store.state.pendingHandOvers == 0)
}

// MARK: - Retry, group post

private let groupHex = String(repeating: "1a", count: 16)
private let memberC = String(repeating: "c", count: 32)
private let memberD = String(repeating: "d", count: 32)

/// A failed copy to D (who has a path) goes out again at once under a new hash; one to C (no
/// path) waits for it. The post's derived status is refreshed.
/// Mutation: leave them failed → nothing is sent and both copies stay failed.
@MainActor @Test func retryResetsAGroupPostsFailedCopiesToWaiting() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let group = ChatGroup(groupHex: groupHex, name: "Mutual Aid", creatorHex: myHex, revision: 1,
                          state: GroupState.active, updatedAt: earlier)
    let postId = String(repeating: "31", count: 16)
    let post = Message(id: UUID(), peerHex: myHex, isOutgoing: true, body: "post", timestamp: earlier,
                       status: MessageStatus.failed, validated: false, messageHash: postId,
                       groupHex: groupHex, groupPostId: postId)
    let toC = GroupDelivery(messageId: post.id, memberHex: memberC, messageHash: String(repeating: "7c", count: 32),
                            status: MessageStatus.failed, storedAt: nil, deliveredAt: nil, failedAt: earlier)
    let toD = GroupDelivery(messageId: post.id, memberHex: memberD, messageHash: String(repeating: "7d", count: 32),
                            status: MessageStatus.failed, storedAt: nil, deliveredAt: nil, failedAt: earlier)
    try await db.write { db in
        try ChatGroup.upsert(group, db)
        try GroupMember.replace(groupHex, with: [myHex, memberC, memberD].sorted(), db)
        try Message.insert { post }.execute(db)
        try GroupDelivery.insert { toC }.execute(db)
        try GroupDelivery.insert { toD }.execute(db)
    }
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent) { s in
        s.identity = me
        s.myAddressHex = myHex
        s.openPeerHex = groupHex
        s.openConversationKind = .group
        s.threadMessages = [post]
        s.reachablePeers = [memberD]
    }
    await run(store, .retryTapped(post.id))
    let rows = try await db.read { try GroupDelivery.all.fetchAll($0) }
    let c = try #require(rows.first { $0.memberHex == memberC })
    let d = try #require(rows.first { $0.memberHex == memberD })
    #expect(c.status == GroupDeliveryStatus.waiting)
    #expect(c.messageHash == nil)
    let message = try #require(sent.value.first)
    #expect(sent.value.count == 1)
    #expect(message.destinationHash.hexString == memberD)
    #expect(d.status == MessageStatus.sending)
    #expect(d.messageHash == message.hash.hexString)
    #expect(try await row(db, post.id).status == MessageStatus.sending)
}

// MARK: - Failure notifications

/// Mutation: skip the post → nothing is recorded.
@MainActor @Test func failureInBackgroundPostsALocalNotification() async throws {
    let db = try AppDatabase.makeInMemory()
    let original = outgoingRow(1, "meet at the north gate", status: MessageStatus.sending)
    try await insert(db, [original])
    let posted = LockIsolated<[LocalNotificationClient.Posted]>([])
    let store = makeStore(db, posted: posted) { s in s.isForeground = false }
    await run(store, failed(original))
    let note = try #require(posted.value.first)
    #expect(posted.value.count == 1)
    #expect(note.id == "send-failed-\(peer)")
    #expect(note.threadID == "send-failed-\(peer)")
    #expect(note.title == "Message not sent")
    #expect(note.body == "Tap to retry.")
    #expect(note.userInfo == ["kind": "sendFailed", "peerHex": peer])
    // Privacy: no address and no text, anywhere a lock screen shows.
    for text in [note.title, note.body] {
        #expect(!text.contains(peer))
        #expect(!text.contains("north gate"))
    }
    #expect(try await row(db, original.id).status == MessageStatus.failed)
}

/// In front, but on another chat: the failure is out of sight.
/// Mutation: only check isForeground → nothing is posted.
@MainActor @Test func failureInAnotherChatPostsALocalNotification() async throws {
    let db = try AppDatabase.makeInMemory()
    let original = outgoingRow(1, "hello", status: MessageStatus.sending)
    try await insert(db, [original])
    let posted = LockIsolated<[LocalNotificationClient.Posted]>([])
    let store = makeStore(db, posted: posted) { s in
        s.isForeground = true
        s.chatVisible = true
        s.openPeerHex = otherPeer
    }
    await run(store, failed(original))
    #expect(posted.value.map(\.id) == ["send-failed-\(peer)"])
}

/// The bubble already says Failed where the user is looking.
/// Mutation: always post → one is recorded.
@MainActor @Test func failureInTheOpenChatPostsNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let original = outgoingRow(1, "hello", status: MessageStatus.sending)
    try await insert(db, [original])
    let posted = LockIsolated<[LocalNotificationClient.Posted]>([])
    let store = makeStore(db, posted: posted) { s in
        s.isForeground = true
        s.chatVisible = true
        s.openPeerHex = peer
    }
    await run(store, failed(original))
    #expect(posted.value.isEmpty)
    #expect(try await row(db, original.id).status == MessageStatus.failed)
}

/// The user's own cancel is no news.
/// Mutation: notify on cancelled too → one is recorded.
@MainActor @Test func cancelledPostsNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let original = outgoingRow(1, "never mind", status: MessageStatus.sending)
    try await insert(db, [original])
    let posted = LockIsolated<[LocalNotificationClient.Posted]>([])
    let store = makeStore(db, posted: posted) { s in s.isForeground = false }
    await run(store, .node(.client(.delegate(.deliveryCancelled(messageHash: Data(hexString: original.messageHash)!)))))
    #expect(posted.value.isEmpty)
    #expect(try await row(db, original.id).status == MessageStatus.cancelled)
}
