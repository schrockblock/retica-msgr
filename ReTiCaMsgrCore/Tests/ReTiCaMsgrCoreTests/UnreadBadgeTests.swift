import Testing
import Foundation
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
@testable import ReTiCaMsgrCore

private let badgeT0 = Date(timeIntervalSince1970: 1700000000)
private let peerA = String(repeating: "a", count: 32)
private let peerB = String(repeating: "b", count: 32)
private let groupG = String(repeating: "c", count: 32)

private func incoming(_ peer: String, at offset: TimeInterval, group: String? = nil,
                      isTimerChange: Bool = false, isGroupEvent: Bool = false) -> Message {
    Message(id: UUID(), peerHex: peer, isOutgoing: false, body: "hi",
            timestamp: badgeT0.addingTimeInterval(offset), status: MessageStatus.received,
            validated: true, messageHash: "", isTimerChange: isTimerChange, groupHex: group,
            isGroupEvent: isGroupEvent)
}

private func insert(_ db: any DatabaseWriter, _ rows: [Message]) async throws {
    try await db.write { d in
        for r in rows { try Message.insert { r }.execute(d) }
    }
}

private func unread(_ db: any DatabaseWriter) async throws -> Int {
    try await db.read { try UnreadCount.count($0) }
}

private func deliveryHex(_ identity: Identity) -> String {
    LXMessage.deliveryHash(identityHash: identity.hash).hexString
}

private func wire(from sender: Identity, to me: Identity, content: String = "hi") -> LXMessage {
    let built = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                 timestamp: 1699999999, title: Data(), content: Data(content.utf8), fields: [])
    return LXMessage.unpack(built.packed)!
}

@MainActor
private func makeBadgeStore(_ db: any DatabaseWriter, identity: Identity, badge: BadgeClient, now: Date = badgeT0,
                            configure: (inout AppFeature.State) -> Void) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: identity)
    configure(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.attachmentStore = AttachmentStore.testValue
        $0.date = .constant(now)
        $0.transportDate = .constant(badgeT0)
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in }, close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in }, openChannel: { _ in },
                                 send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
        $0.badge = badge
    }
    store.exhaustivity = .off
    return store
}

@MainActor
private func settle(_ store: TestStoreOf<AppFeature>) async {
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

// MARK: - The count

/// Review Focus 2: the first launch after the update must not badge the existing history.
@Test func migrationSeedsReadMarkersForExistingConversations() async throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator().migrate(queue, upTo: "createProfilePhotoDeliveries")
    try await insert(queue, [incoming(peerA, at: -10), incoming(peerA, at: -5), incoming(peerB, at: -1),
                             incoming(peerB, at: -1, group: groupG)])
    try AppDatabase.migrator().migrate(queue)
    #expect(try await unread(queue) == 0)
}

@Test func countsIncomingAfterReadAt() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { try ConversationRead.markRead(peerA, at: badgeT0, $0) }
    var outgoing = incoming(peerA, at: 3)
    outgoing.isOutgoing = true
    // The row at exactly readAt was read: only strictly later rows count.
    try await insert(db, [incoming(peerA, at: -1), incoming(peerA, at: 0), incoming(peerA, at: 1),
                          incoming(peerA, at: 2), outgoing])
    #expect(try await unread(db) == 2)
}

/// Review fix 1: arrival effects can mark out of order; an older mark must not undo a newer one.
@Test func markReadNeverMovesBackwards() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write {
        try ConversationRead.markRead(peerA, at: badgeT0.addingTimeInterval(2), $0)
        try ConversationRead.markRead(peerA, at: badgeT0.addingTimeInterval(1), $0)
    }
    try await insert(db, [incoming(peerA, at: 1.5)])
    #expect(try await unread(db) == 0)
}

@Test func keyWithoutMarkerCountsAll() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { try ConversationRead.markRead(peerA, at: badgeT0, $0) }
    try await insert(db, [incoming(peerB, at: -30), incoming(peerB, at: -20), incoming(peerB, at: -10)])
    #expect(try await unread(db) == 3)
}

@Test func excludesTimerChangesGroupEventsAndBlocked() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: peerB, blockedAt: badgeT0), $0) }
    try await insert(db, [
        incoming(peerA, at: 1, isTimerChange: true),
        incoming(peerA, at: 2, group: groupG, isGroupEvent: true),
        incoming(peerB, at: 3),
        // A blocked member's group post: blocking goes by sender, not by conversation.
        incoming(peerB, at: 5, group: groupG),
        incoming(peerA, at: 4),
    ])
    #expect(try await unread(db) == 1)
}

@Test func groupPostsCountUnderGroupKey() async throws {
    let db = try AppDatabase.makeInMemory()
    try await insert(db, [incoming(peerA, at: 1, group: groupG), incoming(peerB, at: 2, group: groupG)])
    #expect(try await unread(db) == 2)
    // The senders' own keys are not the conversation.
    try await db.write {
        try ConversationRead.markRead(peerA, at: badgeT0.addingTimeInterval(10), $0)
        try ConversationRead.markRead(peerB, at: badgeT0.addingTimeInterval(10), $0)
    }
    #expect(try await unread(db) == 2)
    try await db.write { try ConversationRead.markRead(groupG, at: badgeT0.addingTimeInterval(10), $0) }
    #expect(try await unread(db) == 0)
}

/// The chat list's per-row counts use the same rules as the badge, keyed by conversation.
@Test func perConversationCountsFollowTheBadgeRules() async throws {
    let db = try AppDatabase.makeInMemory()
    let blocked = String(repeating: "d", count: 32)
    try await db.write {
        try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: blocked, blockedAt: badgeT0), $0)
        try ConversationRead.markRead(peerB, at: badgeT0, $0)
    }
    try await insert(db, [
        incoming(peerA, at: 1), incoming(peerA, at: 2),
        incoming(peerA, at: 3, isTimerChange: true),
        incoming(peerB, at: -1), incoming(peerB, at: 1),
        incoming(peerA, at: 4, group: groupG),
        incoming(blocked, at: 5),
    ])
    let counts = try await db.read { try UnreadCount.perConversation($0) }
    #expect(counts == [peerA: 2, peerB: 1, groupG: 1])
    #expect(counts.values.reduce(0, +) == (try await unread(db)))
}

// MARK: - Mark-read in the reducer

/// The list's counts follow the same refreshes as the badge: an unwatched arrival shows on its
/// row, and opening the chat clears it.
@MainActor @Test func unreadCountsFollowArrivalAndOpening() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = deliveryHex(sender)
    let store = makeBadgeStore(db, identity: me, badge: .ignored) { _ in }
    await store.send(.node(.client(.delegate(.messageReceived(message: wire(from: sender, to: me),
                                                              signatureValidated: true, method: .opportunistic)))))
    await settle(store)
    #expect(store.state.unreadCounts == [senderHex: 1])
    await store.send(.openConversation(senderHex))
    await settle(store)
    #expect(store.state.unreadCounts == [:])
}

/// Review Focus 3: a message arriving in the chat you're watching is read at once.
@MainActor @Test func arrivalInWatchedThreadIsRead() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let calls = LockIsolated<[Int]>([])
    let store = makeBadgeStore(db, identity: me, badge: .recording(into: calls)) {
        $0.openPeerHex = deliveryHex(sender)
        $0.chatVisible = true
    }
    #expect(store.state.isForeground)
    await store.send(.node(.client(.delegate(.messageReceived(message: wire(from: sender, to: me),
                                                              signatureValidated: true, method: .opportunistic)))))
    await settle(store)
    #expect(try await db.read { try Message.fetchCount($0) } == 1)
    #expect(calls.value == [0])
    #expect(try await unread(db) == 0)
}

/// Final review F4: `readAt` and `messages.timestamp` must be written by one encoder. At half a
/// millisecond GRDB's formatter rounds up (".001") while StructuredQueries, which writes the
/// message rows, truncates (".000"). A `readAt` from GRDB would then sit 1 ms ahead of the row it
/// marked and swallow the next message to land in that millisecond. Copying the stored row's text
/// keeps them equal: the watched arrival is read and the later one still counts.
@MainActor @Test func markReadAtArrivalUsesStoredTimestamp() async throws {
    let boundary = Date(timeIntervalSince1970: 1_761_400_000.0005)
    let later = Date(timeIntervalSince1970: 1_761_400_000.0012)
    // The premise: the two encoders disagree at `boundary`, and agree at `later`.
    let scratch = try DatabaseQueue()
    func encoded(_ date: Date) throws -> (grdb: String?, queries: String?) {
        try scratch.read { db in
            (try String.fetchOne(db, sql: "SELECT ?", arguments: [date]),
             try #sql("SELECT \(date)", as: String.self).fetchOne(db))
        }
    }
    let atBoundary = try encoded(boundary)
    #expect(atBoundary.grdb == "2025-10-25 13:46:40.001")
    #expect(atBoundary.queries == "2025-10-25 13:46:40.000")
    let atLater = try encoded(later)
    #expect(atLater.grdb == atLater.queries)

    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeBadgeStore(db, identity: me, badge: .ignored, now: boundary) {
        $0.openPeerHex = deliveryHex(sender)
        $0.chatVisible = true
    }
    await store.send(.node(.client(.delegate(.messageReceived(message: wire(from: sender, to: me),
                                                              signatureValidated: true, method: .opportunistic)))))
    await settle(store)
    #expect(try await db.read { try Message.fetchCount($0) } == 1)
    #expect(try await unread(db) == 0)
    let readAt = try await db.read { try String.fetchOne($0, sql: "SELECT readAt FROM conversationReads") }
    let stamp = try await db.read { try String.fetchOne($0, sql: "SELECT timestamp FROM messages") }
    #expect(readAt == stamp)

    // The user steps away; the next message lands 0.7 ms later, in the following millisecond.
    await store.send(.activityChanged(isActive: false)) { $0.isForeground = false }
    await settle(store)
    store.dependencies.date = .constant(later)
    await store.send(.node(.client(.delegate(.messageReceived(message: wire(from: sender, to: me, content: "later"),
                                                              signatureValidated: true, method: .opportunistic)))))
    await settle(store)
    #expect(try await db.read { try Message.fetchCount($0) } == 2)
    #expect(try await unread(db) == 1)
}

/// Review Focus 3: on the Mac, an app that is open but not frontmost isn't reading the chat.
@MainActor @Test func arrivalWhileInactiveIsUnread() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let calls = LockIsolated<[Int]>([])
    let store = makeBadgeStore(db, identity: me, badge: .recording(into: calls)) {
        $0.openPeerHex = deliveryHex(sender)
        $0.chatVisible = true
    }
    await store.send(.activityChanged(isActive: false)) { $0.isForeground = false }
    await settle(store)
    await store.send(.node(.client(.delegate(.messageReceived(message: wire(from: sender, to: me),
                                                              signatureValidated: true, method: .opportunistic)))))
    await settle(store)
    #expect(calls.value == [1])
    #expect(try await unread(db) == 1)
}

@MainActor @Test func openingThreadMarksRead() async throws {
    let db = try AppDatabase.makeInMemory()
    try await insert(db, [incoming(peerA, at: -20), incoming(peerA, at: -10)])
    #expect(try await unread(db) == 2)
    let calls = LockIsolated<[Int]>([])
    let store = makeBadgeStore(db, identity: Identity(), badge: .recording(into: calls)) { _ in }
    await store.send(.openConversation(peerA))
    await settle(store)
    #expect(calls.value == [0])
    #expect(try await unread(db) == 0)
}

/// Deleting an unread conversation drops its count from the badge and its read marker with it, so
/// a later message from that peer starts a conversation that is unread throughout.
@MainActor @Test func deleteRecomputesBadge() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = deliveryHex(sender)
    try await db.write { try ConversationRead.markRead(senderHex, at: badgeT0.addingTimeInterval(-20), $0) }
    try await insert(db, [incoming(senderHex, at: -10)])
    #expect(try await unread(db) == 1)
    let calls = LockIsolated<[Int]>([])
    let store = makeBadgeStore(db, identity: me, badge: .recording(into: calls)) { _ in }
    await store.send(.deleteConversation(key: senderHex, isGroup: false))
    await settle(store)
    #expect(calls.value == [0])
    #expect(try await db.read { try ConversationRead.fetchCount($0) } == 0)
    await store.send(.node(.client(.delegate(.messageReceived(message: wire(from: sender, to: me),
                                                              signatureValidated: true, method: .opportunistic)))))
    await settle(store)
    #expect(calls.value == [0, 1])
    #expect(try await unread(db) == 1)
}
