import Testing
import Foundation
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
import struct ReTiCaMsgrCore.Attachment
@testable import ReTiCaMsgrCore

// Message forgery fixes (spec 2026-10-28), app core: unverified rows keep their packed bytes, stay
// out of the unread counts, and are verified or deleted once the sender's identity is learned.

private let unverifiedT0 = Date(timeIntervalSince1970: 1700000000)

private func unverifiedFiles() -> AttachmentStore {
    AttachmentStore(baseDirectory: FileManager.default.temporaryDirectory
        .appending(path: "unverifiedSenderTests-\(UUID().uuidString)"))
}

/// A message as it comes off the wire, so `packed` returns the received bytes.
private func wireMessage(from sender: Identity, to me: Identity, content: Data = Data("hi".utf8)) -> LXMessage {
    let built = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                 timestamp: 1699999999, title: Data(), content: content, fields: [])
    return LXMessage.unpack(built.packed)!
}

/// The same message with its 64-byte signature replaced by junk: what a forger without the key sends.
private func forgedBytes(from sender: Identity, to me: Identity) -> Data {
    var bytes = wireMessage(from: sender, to: me).packed
    let start = 2 * LXMessage.destinationLength
    bytes.replaceSubrange(start..<(start + LXMessage.signatureLength),
                          with: Data(repeating: 0x5a, count: LXMessage.signatureLength))
    return bytes
}

private func storedRow(_ peerHex: String, validated: Bool, packed: Data?, hash: String = "",
                       at offset: TimeInterval = -10) -> Message {
    Message(id: UUID(), peerHex: peerHex, isOutgoing: false, body: "hi",
            timestamp: unverifiedT0.addingTimeInterval(offset), status: MessageStatus.received,
            validated: validated, messageHash: hash, unverifiedPacked: packed)
}

private func insert(_ db: any DatabaseWriter, _ rows: [Message]) async throws {
    try await db.write { d in
        for r in rows { try Message.insert { r }.execute(d) }
    }
}

private func unreadCount(_ db: any DatabaseWriter) async throws -> Int {
    try await db.read { try UnreadCount.count($0) }
}

private func learned(_ identity: Identity) -> LearnedDestination {
    LearnedDestination(identity: identity, appData: nil, ratchet: nil,
                       interfaceID: DefaultNode.entry.interfaceID, hops: 1, nextHop: nil,
                       announceEmitted: 1700000000, learnedAt: unverifiedT0)
}

@MainActor
private func makeUnverifiedStore(_ db: any DatabaseWriter, identity: Identity, badge: BadgeClient,
                                 clock: TestClock<Duration> = TestClock()) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: AppFeature.State(identity: identity)) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.attachmentStore = unverifiedFiles()
        $0.date = .constant(unverifiedT0)
        $0.transportDate = .constant(unverifiedT0)
        $0.uuid = .incrementing
        $0.continuousClock = clock
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

private func onlyRow(_ db: any DatabaseWriter) async throws -> Message {
    let rows = try await db.read { try Message.all.fetchAll($0) }
    try #require(rows.count == 1)
    return rows[0]
}

/// A message from a sender the router could not check is stored unverified with its packed bytes.
@MainActor @Test func unverifiedRowStoresPackedBytes() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me)
    let store = makeUnverifiedStore(db, identity: me, badge: .ignored)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: false,
                                                              method: .opportunistic)))))
    await settle(store)
    let row = try await onlyRow(db)
    #expect(row.validated == false)
    #expect(row.unverifiedPacked == m.packed)
}

/// Unverified rows never reach the badge or the per-row counts; a validated row beside them does.
@Test func unverifiedRowsDoNotCount() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    try await insert(db, [storedRow(senderHex, validated: false, packed: wireMessage(from: sender, to: me).packed)])
    #expect(try await unreadCount(db) == 0)
    #expect(try await db.read { try UnreadCount.perConversation($0) }.isEmpty)
    try await insert(db, [storedRow(senderHex, validated: true, packed: nil, at: -5)])
    #expect(try await unreadCount(db) == 1)
    #expect(try await db.read { try UnreadCount.perConversation($0) } == [senderHex: 1])
}

/// Bytes signed by the sender's real key verify once the identity is known: the row is validated,
/// its bytes dropped, and it counts.
@Test func recheckVerifiesGenuineRow() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    try await insert(db, [storedRow(senderHex, validated: false, packed: wireMessage(from: sender, to: me).packed)])
    #expect(try await unreadCount(db) == 0, "precondition: unverified, so not counted yet")
    let result = try await UnverifiedRecheck.run(db, attachmentStore: unverifiedFiles(),
                                                 sourceHex: senderHex, identity: sender)
    #expect(result.verified == 1)
    #expect(result.removed.isEmpty)
    let row = try await onlyRow(db)
    #expect(row.validated == true)
    #expect(row.unverifiedPacked == nil)
    #expect(try await unreadCount(db) == 1)
}

/// Review Focus 3: a row whose signature fails against the sender's real key is a forgery. It goes,
/// with its attachment file.
@Test func recheckDeletesForgedRow() async throws {
    let db = try AppDatabase.makeInMemory()
    let files = unverifiedFiles()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let hash = String(repeating: "ab", count: 32)
    let row = storedRow(senderHex, validated: false, packed: forgedBytes(from: sender, to: me), hash: hash)
    let path = try files.store(Data("forged".utf8), messageHash: hash, outgoing: false, ext: "txt")
    let attachment = Attachment(id: UUID(), messageId: row.id, kind: AttachmentKind.file, name: "a.txt",
                                format: "txt", size: 6, width: nil, height: nil, path: path)
    try await insert(db, [row])
    try await db.write { try Attachment.insert { attachment }.execute($0) }
    #expect(files.exists(path))

    let result = try await UnverifiedRecheck.run(db, attachmentStore: files, sourceHex: senderHex, identity: sender)
    #expect(result.verified == 0)
    #expect(result.removed == [attachment.id])
    #expect(try await db.read { try Message.fetchCount($0) } == 0)
    #expect(try await db.read { try Attachment.fetchCount($0) } == 0)
    #expect(!files.exists(path))
}

/// The announce that teaches us the sender's path also brings its identity: the stored row is
/// re-checked, validated, and the badge gets the new count.
@MainActor @Test func pathLearnedTriggersRecheck() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHash = LXMessage.deliveryHash(identityHash: sender.hash)
    let calls = LockIsolated<[Int]>([])
    let clock = TestClock()
    let store = makeUnverifiedStore(db, identity: me, badge: .recording(into: calls), clock: clock)
    await store.send(.node(.client(.delegate(.messageReceived(message: wireMessage(from: sender, to: me),
                                                              signatureValidated: false, method: .opportunistic)))))
    await settle(store)
    #expect(try await onlyRow(db).validated == false)
    #expect(calls.value == [0])

    await store.send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations([senderHash: learned(sender)]))))))
    await store.send(.node(.client(.endpoint(.delegate(.pathLearned(destinationHash: senderHash, hops: 1))))))
    // The learned-destination debounce sleeps on the clock; let it fire so `finish` can return.
    await clock.advance(by: .seconds(30))
    await settle(store)
    let row = try await onlyRow(db)
    #expect(row.validated == true)
    #expect(row.unverifiedPacked == nil)
    #expect(calls.value == [0, 1])
}

/// Review Focus 4: an unverified message over 256 KB is stored, with no bytes, and never re-checked.
@MainActor @Test func oversizedUnverifiedStoresNoBytes() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me, content: Data(repeating: 0x61, count: 270_000))
    #expect(m.packed.count > UnverifiedRecheck.maxStoredBytes)
    let store = makeUnverifiedStore(db, identity: me, badge: .ignored)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: false,
                                                              method: .direct)))))
    await settle(store)
    let row = try await onlyRow(db)
    #expect(row.validated == false)
    #expect(row.unverifiedPacked == nil)
}

/// Review Focus 5: a row stored before this change (unverified, no bytes) is left alone by the
/// re-check and never counts.
@Test func legacyUnverifiedRowsAreLeftAlone() async throws {
    let db = try AppDatabase.makeInMemory()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let legacy = storedRow(senderHex, validated: false, packed: nil)
    try await insert(db, [legacy])
    let result = try await UnverifiedRecheck.run(db, attachmentStore: unverifiedFiles(),
                                                 sourceHex: senderHex, identity: sender)
    #expect(result.verified == 0)
    #expect(result.removed.isEmpty)
    #expect(try await onlyRow(db) == legacy)
    #expect(try await unreadCount(db) == 0)
}
