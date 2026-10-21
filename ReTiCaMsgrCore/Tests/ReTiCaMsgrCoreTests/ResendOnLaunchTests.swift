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

// MARK: - Group helpers

private let groupHex = String(repeating: "1a", count: 16)
private let memberC = String(repeating: "c", count: 32)
private let memberD = String(repeating: "d", count: 32)
private let memberE = String(repeating: "e", count: 32)

/// An active group of me, C, D and E. Returns my identity and address.
private func makeGroup(_ db: any DatabaseWriter) async throws -> (me: Identity, myHex: String) {
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let group = ChatGroup(groupHex: groupHex, name: "Mutual Aid", creatorHex: myHex, revision: 1,
                          state: GroupState.active, updatedAt: beforeLaunch)
    try await db.write { db in
        try ChatGroup.upsert(group, db)
        try GroupMember.replace(groupHex, with: [myHex, memberC, memberD, memberE].sorted(), db)
    }
    return (me, myHex)
}

/// My post `n` to the group, stamped `timestamp`.
private func groupPost(_ n: Int, myHex: String, at timestamp: Date = beforeLaunch,
                       status: String = MessageStatus.sending) -> Message {
    let postId = String(repeating: String(format: "%02x", 0x30 + n), count: 16)
    return Message(id: UUID(), peerHex: myHex, isOutgoing: true, body: "post \(n)", timestamp: timestamp,
                   status: status, validated: false, messageHash: postId, groupHex: groupHex, groupPostId: postId)
}

private func copy(of post: Message, to member: String, hash: String?, status: String = MessageStatus.sending,
                  deliveredAt: Date? = nil) -> GroupDelivery {
    GroupDelivery(messageId: post.id, memberHex: member, messageHash: hash, status: status,
                  storedAt: nil, deliveredAt: deliveredAt, failedAt: nil)
}

private func insertGroupRows(_ db: any DatabaseWriter, posts: [Message], copies: [GroupDelivery]) async throws {
    try await db.write { db in
        for post in posts { try Message.insert { post }.execute(db) }
        for copy in copies { try GroupDelivery.insert { copy }.execute(db) }
    }
}

private func deliveries(_ db: any DatabaseWriter) async throws -> [String: GroupDelivery] {
    let rows = try await db.read { try GroupDelivery.all.fetchAll($0) }
    return Dictionary(uniqueKeysWithValues: rows.map { ("\($0.messageId)/\($0.memberHex)", $0) })
}

/// A group copy left `sending` goes back to waiting before this connect's group dispatch, so a
/// reachable member gets it again at once and an unreachable one waits for a path. Settled copies
/// stay as they are, and the post's derived status is refreshed (post 2 is stored with a stale
/// `sent` so the refresh shows).
/// Mutations: leave them as sending → C and E keep their old hashes; skip the refresh → post 2
/// stays `sent`; dispatch before the reset → nothing goes to C on this connect.
@MainActor @Test func groupSendingDeliveriesGoBackToWaiting() async throws {
    let db = try AppDatabase.makeInMemory()
    let (me, myHex) = try await makeGroup(db)
    let post1 = groupPost(1, myHex: myHex)
    let post2 = groupPost(2, myHex: myHex, status: MessageStatus.sent)
    let toC = copy(of: post1, to: memberC, hash: String(repeating: "7c", count: 32))
    let done = copy(of: post1, to: memberD, hash: String(repeating: "7d", count: 32),
                    status: MessageStatus.delivered, deliveredAt: beforeLaunch)
    let toE = copy(of: post2, to: memberE, hash: String(repeating: "7e", count: 32))
    try await insertGroupRows(db, posts: [post1, post2], copies: [toC, done, toE])
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent) { s in
        s.identity = me
        s.myAddressHex = myHex
        s.reachablePeers = [memberC]
    }
    await connect(store)
    let rows = try await deliveries(db)
    let c = try #require(rows["\(post1.id)/\(memberC)"])
    let d = try #require(rows["\(post1.id)/\(memberD)"])
    let e = try #require(rows["\(post2.id)/\(memberE)"])
    // C has a path: its copy went out again on this connect, under a new hash.
    let message = try #require(sent.value.first)
    #expect(sent.value.count == 1)
    #expect(message.destinationHash.hexString == memberC)
    #expect(c.status == MessageStatus.sending)
    #expect(c.messageHash == message.hash.hexString)
    #expect(c.messageHash != toC.messageHash)
    // E has none yet: its copy waits for `pathLearned`.
    #expect(e.status == GroupDeliveryStatus.waiting)
    #expect(e.messageHash == nil)
    #expect(d == done)
    #expect(try await row(db, post2.id).status == MessageStatus.sending)
}

/// Only the previous run's copies are reset: a copy of a post this run made, or one whose hash
/// this run has in flight, is live and keeps its hash.
/// Mutations: drop the launch-time filter → post 3's copy goes back to waiting; drop the
/// in-flight filter → post 4's copy does.
@MainActor @Test func groupCopySentThisRunIsNotReset() async throws {
    let db = try AppDatabase.makeInMemory()
    let (me, myHex) = try await makeGroup(db)
    let post3 = groupPost(3, myHex: myHex, at: launch)
    let post4 = groupPost(4, myHex: myHex)
    let fresh = copy(of: post3, to: memberC, hash: String(repeating: "73", count: 32))
    let inFlight = copy(of: post4, to: memberD, hash: String(repeating: "74", count: 32))
    try await insertGroupRows(db, posts: [post3, post4], copies: [fresh, inFlight])
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent) { s in
        s.identity = me
        s.myAddressHex = myHex
        s.inFlightSends = [try! #require(Data(hexString: String(repeating: "74", count: 32)))]
    }
    await connect(store)
    let rows = try await deliveries(db)
    #expect(rows["\(post3.id)/\(memberC)"] == fresh)
    #expect(rows["\(post4.id)/\(memberD)"] == inFlight)
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
/// hash is settled as not delivered (I have no photo here, so nothing is re-planned).
/// Mutations: skip the migration → the reactions and the reply still name the old hash; skip the
/// photo settle → the pending pair still names the old hash.
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
    let pendingBefore = try await db.read { try ProfilePhotoDelivery.fetch(peer, $0) }
    #expect(pendingBefore?.pendingHash == orphan.messageHash)
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
    let settled = try #require(photo)
    #expect(settled.pendingHash == nil)
    #expect(settled.pendingVersion == nil)
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

/// A disappearing orphan whose timer already fell due is left for the purge: never resent, never
/// marked failed. A live one is resent with its timer on the wire and keeps the first send's
/// deadline.
/// Mutation: drop the expiry filter → the due orphan is sent and rehashed too.
@MainActor @Test func expiredOrphanIsNotResent() async throws {
    let db = try AppDatabase.makeInMemory()
    var due = outgoingRow(1, "gone at launch")
    due.expirySeconds = 3600
    due.expiresAt = launch
    var live = outgoingRow(2, "still counting")
    live.expirySeconds = 3600
    live.expiresAt = launch.addingTimeInterval(600)
    try await insert(db, [due, live])
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent)
    await connect(store)
    let message = try #require(sent.value.first)
    #expect(sent.value.count == 1)
    #expect(message.content == Data("still counting".utf8))
    #expect(ExpiryWire.decode(message.fields) == ExpiryWire.Decoded(seconds: 3600, isChange: false))
    let storedLive = try await row(db, live.id)
    #expect(storedLive.messageHash == message.hash.hexString)
    #expect(storedLive.expiresAt == live.expiresAt)
    let storedDue = try await row(db, due.id)
    #expect(storedDue.status == MessageStatus.sending)
    #expect(storedDue.messageHash == due.messageHash)
}

/// A rebuild that throws changes nothing and clears the flag, so the next connect tries again.
/// Mutation: keep the flag set on failure → the second connect sends nothing.
@MainActor @Test func failedResendIsRetriedOnTheNextConnect() async throws {
    let db = try AppDatabase.makeInMemory()
    let orphan = outgoingRow(1, "try again")
    try await insert(db, [orphan])
    try await db.write { db in
        try db.execute(sql: "CREATE TRIGGER refuseUpdates BEFORE UPDATE ON messages BEGIN SELECT RAISE(ABORT, 'refused'); END")
    }
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(db, sent: sent)
    await connect(store)
    #expect(sent.value.isEmpty)
    #expect(store.state.orphansResent == false)
    #expect(store.state.pendingHandOvers == 0)
    #expect(try await row(db, orphan.id).messageHash == orphan.messageHash)
    try await db.write { try $0.execute(sql: "DROP TRIGGER refuseUpdates") }
    await connect(store, InterfaceID("tcp:other.example:4242"))
    let message = try #require(sent.value.first)
    #expect(sent.value.count == 1)
    #expect(try await row(db, orphan.id).messageHash == message.hash.hexString)
    #expect(store.state.orphansResent == true)
}

/// With nothing to resend, the reservation made on connect is still ended.
/// Mutation: return early when there are no orphans → `pendingHandOvers` stays 1.
@MainActor @Test func noOrphansStillEndsTheReservation() async throws {
    let sent = LockIsolated<[LXMessage]>([])
    let store = makeStore(try AppDatabase.makeInMemory(), sent: sent)
    await connect(store)
    #expect(sent.value.isEmpty)
    #expect(store.state.orphansResent == true)
    #expect(store.state.pendingHandOvers == 0)
}
