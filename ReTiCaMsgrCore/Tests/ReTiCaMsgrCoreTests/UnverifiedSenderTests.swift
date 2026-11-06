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

/// A message row and the bytes kept for it in `unverifiedPackets` (nil: none).
private struct StoredRow {
    var message: Message
    var packed: Data?
    var id: UUID { message.id }
}

private func storedRow(_ peerHex: String, validated: Bool, packed: Data?, hash: String = "",
                       at offset: TimeInterval = -10) -> StoredRow {
    StoredRow(message: Message(id: UUID(), peerHex: peerHex, isOutgoing: false, body: "hi",
                               timestamp: unverifiedT0.addingTimeInterval(offset), status: MessageStatus.received,
                               validated: validated, messageHash: hash),
              packed: packed)
}

private func insert(_ db: any DatabaseWriter, _ rows: [StoredRow]) async throws {
    try await db.write { d in
        for r in rows {
            let message = r.message
            try Message.insert { message }.execute(d)
            if let packed = r.packed {
                try UnverifiedPacket.insert { UnverifiedPacket(messageId: message.id, bytes: packed) }.execute(d)
            }
        }
    }
}

/// The bytes kept for message `id` in the side table, nil when none.
private func storedBytes(_ db: any DatabaseWriter, _ id: UUID) async throws -> Data? {
    try await db.read { try UnverifiedPacket.where { $0.messageId.eq(id) }.fetchOne($0)?.bytes }
}

private func packetCount(_ db: any DatabaseWriter) async throws -> Int {
    try await db.read { try UnverifiedPacket.fetchCount($0) }
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
                                 clock: TestClock<Duration> = TestClock(),
                                 configure: (inout AppFeature.State) -> Void = { _ in }) -> TestStoreOf<AppFeature> {
    // Registered, as at runtime: the re-check compares each message's destination with this.
    var initial = AppFeature.State(identity: identity)
    initial.node.client.deliveryDestinationHash = LXMessage.deliveryHash(identityHash: identity.hash)
    configure(&initial)
    let store = TestStore(initialState: initial) {
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
    #expect(try await storedBytes(db, row.id) == m.packed)
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
                                                 sourceHex: senderHex, identity: sender,
                                                 deliveryHash: LXMessage.deliveryHash(identityHash: me.hash))
    #expect(result.verified == 1)
    #expect(result.removed.isEmpty)
    let row = try await onlyRow(db)
    #expect(row.validated == true)
    #expect(try await packetCount(db) == 0)
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

    let result = try await UnverifiedRecheck.run(db, attachmentStore: files, sourceHex: senderHex, identity: sender,
                                                 deliveryHash: LXMessage.deliveryHash(identityHash: me.hash))
    #expect(result.verified == 0)
    #expect(result.removed == [attachment.id])
    #expect(try await db.read { try Message.fetchCount($0) } == 0)
    #expect(try await db.read { try Attachment.fetchCount($0) } == 0)
    #expect(try await packetCount(db) == 0, "the side row cascades with its message")
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
    #expect(try await storedBytes(db, row.id) == nil)
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
    #expect(try await storedBytes(db, row.id) == nil)
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
                                                 sourceHex: senderHex, identity: sender,
                                                 deliveryHash: LXMessage.deliveryHash(identityHash: Identity().hash))
    #expect(result.verified == 0)
    #expect(result.removed.isEmpty)
    #expect(try await onlyRow(db) == legacy.message)
    #expect(try await unreadCount(db) == 0)
}

/// Review fix 1 (Finding 2 at the re-check): Bob's genuine signed message to Carol, stored
/// unverified under Bob on Alice's device, is not ours. A valid signature must not promote it.
@Test func recheckDoesNotValidateMessageForAnotherRecipient() async throws {
    let db = try AppDatabase.makeInMemory()
    let alice = Identity()
    let bob = Identity()
    let carol = Identity()
    let bobHex = LXMessage.deliveryHash(identityHash: bob.hash).hexString
    let toCarol = wireMessage(from: bob, to: carol)
    #expect(toCarol.validateSignature(source: bob), "precondition: the signature itself is genuine")
    try await insert(db, [storedRow(bobHex, validated: false, packed: toCarol.packed)])
    let result = try await UnverifiedRecheck.run(db, attachmentStore: unverifiedFiles(),
                                                 sourceHex: bobHex, identity: bob,
                                                 deliveryHash: LXMessage.deliveryHash(identityHash: alice.hash))
    #expect(result.verified == 0)
    #expect(try await db.read { try Message.fetchCount($0) } == 0)
}

/// The size limit is inclusive: exactly 262_144 packed bytes are kept, one more is not.
/// Content n gives 114 + n packed bytes (96-byte header, payload with a bin32 body).
@MainActor @Test func unverifiedSizeLimitBoundary() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let atLimit = wireMessage(from: sender, to: me, content: Data(repeating: 0x61, count: 262_030))
    let overLimit = wireMessage(from: sender, to: me, content: Data(repeating: 0x62, count: 262_031))
    #expect(atLimit.packed.count == UnverifiedRecheck.maxStoredBytes)
    #expect(overLimit.packed.count == UnverifiedRecheck.maxStoredBytes + 1)
    let store = makeUnverifiedStore(db, identity: me, badge: .ignored)
    await store.send(.node(.client(.delegate(.messageReceived(message: atLimit, signatureValidated: false,
                                                              method: .direct)))))
    await settle(store)
    await store.send(.node(.client(.delegate(.messageReceived(message: overLimit, signatureValidated: false,
                                                              method: .direct)))))
    await settle(store)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    let byHash = Dictionary(uniqueKeysWithValues: rows.map { ($0.messageHash, $0) })
    let at = try #require(byHash[atLimit.hash.hexString])
    #expect(try await storedBytes(db, at.id) == atLimit.packed)
    let over = try #require(byHash[overLimit.hash.hexString])
    #expect(try await storedBytes(db, over.id) == nil)
}

/// Settled detail 4: the transport already holds the sender's identity, but the router reported the
/// message unvalidated. The row is checked right after storing and ends validated.
@MainActor @Test func storeTimeRecheckValidatesKnownSender() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHash = LXMessage.deliveryHash(identityHash: sender.hash)
    let calls = LockIsolated<[Int]>([])
    let store = makeUnverifiedStore(db, identity: me, badge: .recording(into: calls)) {
        $0.node.client.endpoint.transport.learned[senderHash] = learned(sender)
    }
    await store.send(.node(.client(.delegate(.messageReceived(message: wireMessage(from: sender, to: me),
                                                              signatureValidated: false, method: .opportunistic)))))
    await settle(store)
    let row = try await onlyRow(db)
    #expect(row.validated == true)
    #expect(try await storedBytes(db, row.id) == nil)
    #expect(calls.value.last == 1)
}

/// Settled detail 4, the launch pass: the sender's identity is rehydrated from the learned table
/// before `registerDelivery` has run (that waits for `interfaceConnected`), so the check must use
/// the delivery hash derived from our identity, not the registered one.
@MainActor @Test func launchRecheckValidatesBeforeRegistration() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHash = LXMessage.deliveryHash(identityHash: sender.hash)
    let senderHex = senderHash.hexString
    try await insert(db, [storedRow(senderHex, validated: false, packed: wireMessage(from: sender, to: me).packed)])
    let destinationRow = try #require(LearnedDestinationRow(hash: senderHash, destination: learned(sender)))
    try await db.write { try LearnedDestinationRow.insert { destinationRow }.execute($0) }
    let store = makeUnverifiedStore(db, identity: me, badge: .ignored) {
        $0.node.client.deliveryDestinationHash = nil
    }
    await store.send(.onLaunch)
    await store.receive { action in
        if case let ._recheckUnverified(peers) = action { return peers == [senderHex] }
        return false
    }
    #expect(store.state.node.client.deliveryDestinationHash == nil, "precondition: not registered yet")
    // The launch's other effects (the node start, the sleepers) never finish here, so wait on the row.
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var row = try await onlyRow(db)
    while !row.validated, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
        row = try await onlyRow(db)
    }
    #expect(row.validated == true)
    #expect(try await storedBytes(db, row.id) == nil)
    await store.skipReceivedActions(strict: false)
}

/// Review Focus 1, end to end through the real `LXMFNode`: Bob is known, and over his link to us
/// he hands over a message he validly signed to Carol. ReTiCA's destination check drops it, so no
/// row is stored. His own message to us on the same link, sent next, is the control: it lands.
@MainActor @Test func forgedMessageForAnotherRecipientNeverStored() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let bob = Identity()
    let carol = Identity()
    let bobHash = LXMessage.deliveryHash(identityHash: bob.hash)
    let myHash = LXMessage.deliveryHash(identityHash: me.hash)
    let linkID = Data(repeating: 0xB0, count: 16)
    let store = makeUnverifiedStore(db, identity: me, badge: .ignored) {
        $0.node.client.endpoint.transport.learned[bobHash] = learned(bob)
        $0.node.client.linkDestinations[linkID] = myHash   // Bob's link terminates on our delivery destination
    }
    await store.send(.node(.client(.router(.learnedIdentity(destinationHash: bobHash, identity: bob)))))
    #expect(store.state.node.client.router.knownIdentities[bobHash] != nil, "precondition: Bob is known")

    let forCarol = LXMessage.create(source: bob, destinationHash: LXMessage.deliveryHash(identityHash: carol.hash),
                                    timestamp: 1699999999, title: Data(), content: Data("for carol".utf8))
    await store.send(.node(.client(.endpoint(.delegate(.linkDataReceived(
        linkID: linkID, data: forCarol.packed, packetHash: Data(repeating: 0xC1, count: 32)))))))
    await settle(store)
    #expect(try await db.read { try Message.fetchCount($0) } == 0)

    let forMe = LXMessage.create(source: bob, destinationHash: myHash,
                                 timestamp: 1699999999, title: Data(), content: Data("for me".utf8))
    await store.send(.node(.client(.endpoint(.delegate(.linkDataReceived(
        linkID: linkID, data: forMe.packed, packetHash: Data(repeating: 0xC2, count: 32)))))))
    await settle(store)
    let row = try await onlyRow(db)
    #expect(row.body == "for me")
    #expect(row.validated == true)
}

// MARK: - Final review fixes

/// F1: the table every list and thread reload reads (`Message.fetchAll`) carries no bytes. The
/// unverified message's packed bytes are in `unverifiedPackets` instead.
@MainActor @Test func listReloadDoesNotLoadUnverifiedBytes() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me)
    let store = makeUnverifiedStore(db, identity: me, badge: .ignored)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: false,
                                                              method: .opportunistic)))))
    await settle(store)
    let columns = try await db.read { try $0.columns(in: "messages") }
    #expect(!columns.contains { $0.name == "unverifiedPacked" })
    #expect(!columns.contains { $0.type.uppercased() == "BLOB" }, "no column a reload could pull bytes from")
    let row = try await onlyRow(db)
    #expect(Mirror(reflecting: row).children.allSatisfy {
        type(of: $0.value) != Data.self && type(of: $0.value) != Optional<Data>.self
    }, "a fetched Message holds no bytes")
    #expect(try await storedBytes(db, row.id) == m.packed)
}

/// F1: at most `maxStoredMessages` (100) unverified messages keep their bytes. The 101st is stored,
/// unverified, with no bytes, so it keeps its marker and is never re-checked.
@MainActor @Test func unverifiedStoreCapsAt100() async throws {
    #expect(UnverifiedRecheck.maxStoredMessages == 100)
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeUnverifiedStore(db, identity: me, badge: .ignored)
    var last: LXMessage?
    for i in 0...UnverifiedRecheck.maxStoredMessages {
        let m = wireMessage(from: Identity(), to: me, content: Data("spam \(i)".utf8))
        await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: false,
                                                                  method: .opportunistic)))))
        await settle(store)
        last = m
    }
    #expect(try await db.read { try Message.fetchCount($0) } == 101)
    #expect(try await packetCount(db) == 100)
    let hashHex = try #require(last).hash.hexString
    let over = try #require(try await db.read { try Message.where { $0.messageHash.eq(hashHex) }.fetchOne($0) })
    #expect(over.validated == false)
    #expect(try await storedBytes(db, over.id) == nil)
}

/// F1 migration: a row stored with `unverifiedPacked` before `moveUnverifiedPackedToSideTable` has
/// its bytes in the side table afterwards, and the re-check still verifies it.
@Test func migrationMovesUnverifiedBytesToSideTable() async throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator().migrate(queue, upTo: "addUnverifiedPacked")
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let m = wireMessage(from: sender, to: me)
    let id = UUID()
    // Raw SQL: at this schema version `messages` still has the column `Message` no longer names.
    try await queue.write { db in
        try db.execute(sql: """
            INSERT INTO messages (id, peerHex, isOutgoing, body, timestamp, status, validated,
                                  messageHash, isTimerChange, isGroupEvent, unverifiedPacked)
            VALUES (?, ?, 0, 'hi', ?, ?, 0, ?, 0, 0, ?)
            """, arguments: [id.uuidString.lowercased(), senderHex, unverifiedT0, MessageStatus.received,
                             m.hash.hexString, m.packed])
    }
    try AppDatabase.migrator().migrate(queue)
    #expect(try await storedBytes(queue, id) == m.packed)
    let result = try await UnverifiedRecheck.run(queue, attachmentStore: unverifiedFiles(),
                                                 sourceHex: senderHex, identity: sender,
                                                 deliveryHash: LXMessage.deliveryHash(identityHash: me.hash))
    #expect(result.verified == 1)
    #expect(try await onlyRow(queue).validated == true)
    #expect(try await packetCount(queue) == 0)
}

/// F2: Bob is only in the learned table restored at launch (no live announce). The router is fed
/// his identity with it, so his first message is validated on arrival and its name field applies.
/// Without the feed it is stored unverified and the store-time re-check validates the row, but the
/// withheld name is never applied: the name is what tells the two apart.
@MainActor @Test func rehydratedContactIsValidatedOnFirstMessage() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let bob = Identity()
    let bobHash = LXMessage.deliveryHash(identityHash: bob.hash)
    let myHash = LXMessage.deliveryHash(identityHash: me.hash)
    let linkID = Data(repeating: 0xB1, count: 16)
    let store = makeUnverifiedStore(db, identity: me, badge: .ignored) {
        $0.node.client.linkDestinations[linkID] = myHash   // Bob's link terminates on our delivery destination
    }
    await store.send(.rehydrateLearnedDestinations([bobHash: learned(bob)]))
    await settle(store)

    let first = LXMessage.create(source: bob, destinationHash: myHash, timestamp: 1699999999, title: Data(),
                                 content: Data("hello".utf8), fields: NameWire.encode("Bob"))
    await store.send(.node(.client(.endpoint(.delegate(.linkDataReceived(
        linkID: linkID, data: first.packed, packetHash: Data(repeating: 0xC3, count: 32)))))))
    await settle(store)
    let row = try await onlyRow(db)
    #expect(row.body == "hello")
    #expect(row.validated == true)
    #expect(try await db.read { try PeerProfile.fetch(bobHash.hexString, $0) }?.name == "Bob")
}

/// A big restored table feeds the router in the same step, not through one chained
/// `.learnedIdentity` send per identity. On 2026-11-01 the Mac's table held 24,603 rows: about
/// 6,000 chained sends nested deep enough to overflow the main thread's stack at every launch.
@MainActor @Test func rehydratingThousandsOfDestinationsFeedsTheRouterAtOnce() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeUnverifiedStore(db, identity: Identity(), badge: .ignored)
    var table: [Data: LearnedDestination] = [:]
    for _ in 0..<8000 {
        let peer = Identity()
        table[LXMessage.deliveryHash(identityHash: peer.hash)] = learned(peer)
    }
    // A destination that is not an lxmf.delivery hash for its identity is not fed (same check).
    let otherHash = Data(repeating: 0x0D, count: 16)
    table[otherHash] = learned(Identity())

    await store.send(.rehydrateLearnedDestinations(table))
    let known = store.state.node.client.router.knownIdentities
    #expect(known.count == 8000)
    #expect(known[otherHash] == nil)
    await settle(store)
}
