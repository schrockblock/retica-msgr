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

// Resend on launch (brief 2026-10-21): an outgoing row a previous run left `sending` was held in
// ReTiCA's memory when iOS killed the app, so the first `interfaceConnected` of this launch sends
// it again under a new hash, and group copies left `sending` go back to waiting.

// MARK: - Helpers (mirrors PropagationPushTests.makeStore)

private let launch = Date(timeIntervalSince1970: 1700000000)
private let beforeLaunch = launch.addingTimeInterval(-600)
private let peer = String(repeating: "a", count: 32)
private let connectID = DefaultNode.entry.interfaceID

/// A store launched at `launch` (the `onLaunch` time is set directly: `onLaunch` itself starts
/// effects that never finish, and these tests `finish()`). `sent` records every message handed to
/// the node, in order: a `.off` TestStore cannot assert an action absent.
@MainActor
private func makeStore(_ db: any DatabaseWriter, sent: LockIsolated<[LXMessage]>,
                       attachmentStore: AttachmentStore = AttachmentStore.testValue,
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: Identity())
    initial.launchedAt = launch
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
        $0.attachmentStore = attachmentStore
        $0.date = .constant(launch)
        $0.transportDate = .constant(launch)
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

/// An outgoing one-to-one row to `peer`.
private func outgoingRow(_ n: Int, _ body: String, at timestamp: Date = beforeLaunch,
                         status: String = MessageStatus.sending, replyToHash: String? = nil,
                         replyQuote: String? = nil, isTimerChange: Bool = false) -> Message {
    Message(id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!,
            peerHex: peer, isOutgoing: true, body: body, timestamp: timestamp, status: status,
            validated: false, messageHash: String(repeating: String(format: "%02x", n), count: 32),
            senderTimestamp: timestamp, replyToHash: replyToHash, replyQuote: replyQuote,
            isTimerChange: isTimerChange)
}

private func insert(_ db: any DatabaseWriter, _ rows: [Message]) async throws {
    try await db.write { db in
        for row in rows { try Message.insert { row }.execute(db) }
    }
}

private func row(_ db: any DatabaseWriter, _ id: UUID) async throws -> Message {
    try #require(try await db.read { try Message.where { $0.id.eq(id) }.fetchOne($0) })
}

/// Connects an interface and waits for every effect it started.
@MainActor
private func connect(_ store: TestStoreOf<AppFeature>, _ id: InterfaceID = connectID) async {
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(id, .tcp))))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

// MARK: - Tests

/// Mutation: don't resend → nothing is sent and the row keeps its old hash.
@MainActor @Test func orphanTextIsResentOnFirstConnect() async throws {
    let db = try AppDatabase.makeInMemory()
    let orphan = outgoingRow(1, "still here?")
    try await insert(db, [orphan])
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent)
    await connect(store)
    let message = try #require(sent.value.first)
    #expect(sent.value.count == 1)
    #expect(message.content == Data("still here?".utf8))
    #expect(message.hash.hexString != orphan.messageHash)
    let stored = try await row(db, orphan.id)
    #expect(stored.messageHash == message.hash.hexString)
    #expect(stored.status == MessageStatus.sending)
    #expect(store.state.orphansResent == true)
}

/// Mutation: drop the flag → the second connect sends the row again.
@MainActor @Test func orphansResentOncePerLaunch() async throws {
    let db = try AppDatabase.makeInMemory()
    try await insert(db, [outgoingRow(1, "once")])
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent)
    await connect(store)
    #expect(sent.value.count == 1)
    await connect(store, InterfaceID("tcp:other.example:4242"))
    #expect(sent.value.count == 1)
}

/// A row stamped at or after the launch was sent by this run, which still owns it.
/// Mutation: drop the launch-time filter → the row is resent.
@MainActor @Test func rowsSentThisRunAreNotOrphans() async throws {
    let db = try AppDatabase.makeInMemory()
    let fresh = outgoingRow(1, "just now", at: launch)
    try await insert(db, [fresh])
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent)
    await connect(store)
    #expect(sent.value.isEmpty)
    #expect(try await row(db, fresh.id).messageHash == fresh.messageHash)
}

/// Only `sending` one-to-one rows are orphans: settled rows, timer changes and incoming rows stay.
/// Mutation: resend every outgoing row → messages are sent and hashes change.
@MainActor @Test func deliveredAndFailedRowsAreLeftAlone() async throws {
    let db = try AppDatabase.makeInMemory()
    let delivered = outgoingRow(1, "delivered", status: MessageStatus.delivered)
    let failed = outgoingRow(2, "failed", status: MessageStatus.failed)
    let timer = outgoingRow(3, "Disappearing messages set to 1 day", isTimerChange: true)
    var incoming = outgoingRow(4, "from them", status: MessageStatus.received)
    incoming.isOutgoing = false
    let rows = [delivered, failed, timer, incoming]
    try await insert(db, rows)
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent)
    await connect(store)
    #expect(sent.value.isEmpty)
    for original in rows {
        let stored = try await row(db, original.id)
        #expect(stored.messageHash == original.messageHash)
        #expect(stored.status == original.status)
    }
}

/// Mutation: drop the reply fields → the rebuilt message decodes as no reply.
@MainActor @Test func orphanReplyKeepsItsReplyFields() async throws {
    let db = try AppDatabase.makeInMemory()
    let target = String(repeating: "5e", count: 32)
    try await insert(db, [outgoingRow(1, "agreed", replyToHash: target, replyQuote: "shall we?")])
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent)
    await connect(store)
    let message = try #require(sent.value.first)
    let reply = try #require(ReplyWire.decode(message.fields))
    #expect(reply.replyTo == Data(hexString: target))
    #expect(reply.quote == "shall we?")
}

/// Mutation: drop the attachment → the rebuilt message carries no file field.
@MainActor @Test func orphanAttachmentRidesAgain() async throws {
    let db = try AppDatabase.makeInMemory()
    let files = AttachmentStore.testValue
    let orphan = outgoingRow(1, "")
    let bytes = Data("the minutes".utf8)
    let path = try files.store(bytes, messageHash: orphan.messageHash, outgoing: true, ext: "txt")
    try await insert(db, [orphan])
    try await db.write { db in
        try Attachment.insert {
            Attachment(id: UUID(), messageId: orphan.id, kind: AttachmentKind.file, name: "minutes.txt",
                       format: "txt", size: bytes.count, width: nil, height: nil, path: path)
        }.execute(db)
    }
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent, attachmentStore: files)
    await connect(store)
    let message = try #require(sent.value.first)
    let attachment = try #require(AttachmentWire.decode(message.fields))
    #expect(attachment.name == "minutes.txt")
    #expect(attachment.data == bytes)
    // The attachment field comes first, as at the first send.
    #expect(message.fields.first?.key == AttachmentWire.fieldFileAttachments)
}

/// Mutation: skip it silently → the row stays `sending`.
@MainActor @Test func orphanWithAMissingAttachmentIsMarkedFailed() async throws {
    let db = try AppDatabase.makeInMemory()
    let orphan = outgoingRow(1, "")
    try await insert(db, [orphan])
    try await db.write { db in
        try Attachment.insert {
            Attachment(id: UUID(), messageId: orphan.id, kind: AttachmentKind.image, name: "IMG_1.jpg",
                       format: "jpeg", size: 10, width: 1, height: 1, path: "gone-out.jpeg")
        }.execute(db)
    }
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent)
    await connect(store)
    #expect(sent.value.isEmpty)
    let stored = try await row(db, orphan.id)
    #expect(stored.status == MessageStatus.failed)
    #expect(stored.failedAt != nil)
}

/// A group copy left `sending` goes back to waiting, so the group dispatch sends it again once
/// the member has a path. Settled copies stay as they are.
/// Mutation: leave them as sending → the copy keeps its status and hash.
@MainActor @Test func groupSendingDeliveriesGoBackToWaiting() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let groupHex = String(repeating: "1a", count: 16)
    let memberC = String(repeating: "c", count: 32)
    let memberD = String(repeating: "d", count: 32)
    let group = ChatGroup(groupHex: groupHex, name: "Mutual Aid", creatorHex: myHex, revision: 1,
                          state: GroupState.active, updatedAt: beforeLaunch)
    let post = Message(id: UUID(), peerHex: myHex, isOutgoing: true, body: "to the group", timestamp: beforeLaunch,
                       status: MessageStatus.sending, validated: false, messageHash: String(repeating: "3c", count: 16),
                       groupHex: groupHex, groupPostId: String(repeating: "3c", count: 16))
    let stuck = GroupDelivery(messageId: post.id, memberHex: memberC, messageHash: String(repeating: "7c", count: 32),
                              status: MessageStatus.sending, storedAt: nil, deliveredAt: nil, failedAt: nil)
    let done = GroupDelivery(messageId: post.id, memberHex: memberD, messageHash: String(repeating: "7d", count: 32),
                             status: MessageStatus.delivered, storedAt: nil, deliveredAt: beforeLaunch, failedAt: nil)
    try await db.write { db in
        try ChatGroup.upsert(group, db)
        try GroupMember.replace(groupHex, with: [myHex, memberC, memberD].sorted(), db)
        try Message.insert { post }.execute(db)
        try GroupDelivery.insert { stuck }.execute(db)
        try GroupDelivery.insert { done }.execute(db)
    }
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent) { s in
        s.identity = me
        s.myAddressHex = myHex
    }
    await connect(store)
    let deliveries = try await db.read { try GroupDelivery.where { $0.messageId.eq(post.id) }.fetchAll($0) }
    let c = try #require(deliveries.first { $0.memberHex == memberC })
    let d = try #require(deliveries.first { $0.memberHex == memberD })
    #expect(c.status == GroupDeliveryStatus.waiting)
    #expect(c.messageHash == nil)
    #expect(d == done)
    // No member has a path yet, so nothing went out: the copy waits for `pathLearned`.
    #expect(sent.value.isEmpty)
}

/// Mutation: don't record the launch time → `launchedAt` stays nil and nothing is ever resent.
@MainActor @Test func onLaunchRecordsTheLaunchTime() async throws {
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(try AppDatabase.makeInMemory(), sent: sent) { $0.launchedAt = nil }
    await store.send(.onLaunch)
    #expect(store.state.launchedAt == launch)
}

/// Spec 2026-10-15 §2: nothing is sent to a blocked contact, so an orphan to a peer blocked since
/// the send fails instead.
/// Mutation: resend it anyway → it is sent and the row stays `sending`.
@MainActor @Test func orphanToABlockedPeerIsMarkedFailed() async throws {
    let db = try AppDatabase.makeInMemory()
    let orphan = outgoingRow(1, "before the block")
    try await insert(db, [orphan])
    try await db.write { try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: peer, blockedAt: beforeLaunch), $0) }
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent) { $0.blockedPeers = [peer] }
    await connect(store)
    #expect(sent.value.isEmpty)
    let stored = try await row(db, orphan.id)
    #expect(stored.status == MessageStatus.failed)
    #expect(stored.failedAt != nil)
    #expect(stored.messageHash == orphan.messageHash)
}

/// Reactions on the orphan and replies to it stay attached: every local reference to the old hash
/// moves to the new one in the write that rehashes the row, and a profile photo pending on the old
/// hash no longer waits for an outcome that cannot come.
/// Mutation: skip the migration → the reactions and the reply still name the old hash.
@MainActor @Test func orphanReactionsFollowTheNewHash() async throws {
    let db = try AppDatabase.makeInMemory()
    let orphan = outgoingRow(1, "react to me")
    var reply = outgoingRow(2, "replying", status: MessageStatus.received, replyToHash: orphan.messageHash,
                            replyQuote: "react to me")
    reply.isOutgoing = false
    let me = String(repeating: "e", count: 32)
    try await insert(db, [orphan, reply])
    try await db.write { db in
        _ = try Reaction.apply(Reaction(messageHash: orphan.messageHash, reactorHex: peer, emoji: "👍", sentAt: 1), db)
        _ = try Reaction.apply(Reaction(messageHash: orphan.messageHash, reactorHex: me, emoji: "❤️", sentAt: 2), db)
        try ProfilePhotoDelivery.markPending(peer, version: "ab", hash: orphan.messageHash, db)
    }
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent)
    await connect(store)
    let newHash = try #require(sent.value.first).hash.hexString
    let replyId = reply.id
    let (reactions, replyRow, photo) = try await db.read { db in
        (try Reaction.all.fetchAll(db),
         try Message.where { $0.id.eq(replyId) }.fetchOne(db),
         try ProfilePhotoDelivery.fetch(peer, db))
    }
    #expect(reactions.count == 2)
    #expect(reactions.allSatisfy { $0.messageHash == newHash })
    #expect(replyRow?.replyToHash == newHash)
    #expect(photo?.pendingHash != orphan.messageHash)
}

/// Holds the database's writer queue until released, so an effect's write waits.
private final class DatabaseGate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func hold(_ db: any DatabaseWriter) async {
        let (held, holding) = AsyncStream.makeStream(of: Void.self)
        Task.detached { [semaphore] in
            try? await db.write { _ in
                holding.yield()
                semaphore.wait()
            }
        }
        for await _ in held { return }
    }

    func release() { semaphore.signal() }
}

/// The resend is reserved as a hand-over from the moment the interface comes up, as `sendTapped`
/// reserves its send, so a `.backgrounded` before the rows are rebuilt still asks for time.
/// Mutation: no reservation → `pendingHandOvers` is 0 while the rebuild waits on the database.
@MainActor @Test func resendIsReservedUntilHandedOver() async throws {
    let db = try AppDatabase.makeInMemory()
    try await insert(db, [outgoingRow(1, "hold on")])
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent)
    let gate = DatabaseGate()
    await gate.hold(db)
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(connectID, .tcp))))))
    #expect(store.state.pendingHandOvers == 1)
    gate.release()
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let message = try #require(sent.value.first)
    #expect(store.state.pendingHandOvers == 0)
    #expect(store.state.inFlightSends.contains(message.hash))
}
