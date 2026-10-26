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

// Display name carried in messages (spec 2026-10-25 name-in-messages).

private let namePeer = String(repeating: "b", count: 32)
private let nameT1 = Date(timeIntervalSince1970: 1_699_990_000)
private let nameT2 = Date(timeIntervalSince1970: 1_699_991_000)
private let nameT3 = Date(timeIntervalSince1970: 1_699_992_000)

// MARK: - Wire

@Test func encodeTruncatesAtCharacterBoundary() throws {
    // "é" is two UTF-8 bytes: 100 of them are 200 bytes.
    let fields = NameWire.encode(String(repeating: "é", count: 100))
    let field = try #require(fields.first { $0.key == NameWire.fieldDisplayName })
    guard case let .bin(bytes) = field.value else { Issue.record("not a bin"); return }
    #expect(bytes.count <= NameWire.maxBytes)
    #expect(bytes.count == 128)
    let decoded = try #require(String(data: bytes, encoding: .utf8))
    #expect(decoded == String(repeating: "é", count: 64))
    #expect(NameWire.decode(fields) == decoded)
    // Trimmed before it is measured.
    #expect(NameWire.decode(NameWire.encode("  Ada \n")) == "Ada")
}

@Test func decodeRejectsOversizeAndBadUTF8() {
    let oversize = [MsgPackValue.IntPair(NameWire.fieldDisplayName, .bin(Data(repeating: 0x41, count: 129)))]
    #expect(NameWire.decode(oversize) == nil)
    let badUTF8 = [MsgPackValue.IntPair(NameWire.fieldDisplayName, .bin(Data([0xC3, 0x28])))]
    #expect(NameWire.decode(badUTF8) == nil)
    #expect(NameWire.decode([]) == nil)
    let atLimit = [MsgPackValue.IntPair(NameWire.fieldDisplayName, .bin(Data(repeating: 0x41, count: 128)))]
    #expect(NameWire.decode(atLimit) == String(repeating: "A", count: 128))
    // An empty bin is a cleared name.
    #expect(NameWire.decode(NameWire.encode("")) == "")
}

// MARK: - Plan

@Test func planRidesUntilConfirmed() {
    let none = ProfileNameOutbox.plan(myName: "Ada", delivery: nil)
    #expect(NameWire.decode(none.fields) == "Ada")
    #expect(none.pendingName == "Ada")

    let pending = ProfileNameOutbox.plan(
        myName: "Ada", delivery: ProfileNameDelivery(peerHex: namePeer, pendingName: "Ada", pendingHash: "h1"))
    #expect(pending.fields.isEmpty)
    #expect(pending.pendingName == nil)

    let delivered = ProfileNameOutbox.plan(
        myName: "Ada", delivery: ProfileNameDelivery(peerHex: namePeer, deliveredName: "Ada"))
    #expect(delivered.fields.isEmpty)
    #expect(delivered.pendingName == nil)

    let changed = ProfileNameOutbox.plan(
        myName: "Ada L", delivery: ProfileNameDelivery(peerHex: namePeer, deliveredName: "Ada"))
    #expect(NameWire.decode(changed.fields) == "Ada L")
    #expect(changed.pendingName == "Ada L")
}

@Test func planClearOnlyAfterDeliveredName() {
    let clear = ProfileNameOutbox.plan(myName: "", delivery: ProfileNameDelivery(peerHex: namePeer, deliveredName: "Al"))
    #expect(NameWire.decode(clear.fields) == "")
    #expect(clear.pendingName == "")

    let nothing = ProfileNameOutbox.plan(myName: "", delivery: nil)
    #expect(nothing.fields.isEmpty)
    #expect(nothing.pendingName == nil)
}

// MARK: - Receiving

@Test func olderNameDoesNotOverwriteNewer() throws {
    let db = try AppDatabase.makeInMemory()
    let applied = try db.write { db in
        (try PeerProfile.setName(namePeer, name: "New", setAt: nameT2, at: nameT3, db),
         try PeerProfile.setName(namePeer, name: "Old", setAt: nameT1, at: nameT3, db))
    }
    #expect(applied.0)
    #expect(applied.1 == false)
    let row = try db.read { try PeerProfile.fetch(namePeer, $0) }
    #expect(row?.name == "New")
    #expect(row?.nameSetAt == nameT2)
}

// MARK: - Display precedence

@Test func displayPrefersContactThenNewer() throws {
    let hash = try #require(Data(hexString: namePeer))
    func state(carried: String?, at carriedAt: Date?, announced: String?, at announcedAt: Date,
               contact: String? = nil) -> AppFeature.State {
        var s = AppFeature.State(identity: Identity())
        if let carried {
            s.peerProfiles[namePeer] = PeerProfile(peerHex: namePeer, updatedAt: nameT3,
                                                   name: carried, nameSetAt: carriedAt)
        }
        if let announced {
            s.node.client.learnedPeers[hash] = LXMFNode.LearnedPeer(
                displayName: announced, stampCost: nil, supportsCompression: false, learnedAt: announcedAt)
        }
        if let contact {
            s.contactLinks[namePeer] = ContactLink(
                peerHex: namePeer, contactIdentifier: "c1", cachedName: contact, source: ContactLinkSource.manual,
                discoveredViaHex: nil, discoveredSessionId: nil, discoveredAt: nil, confirmationsJSON: "[]",
                verified: true, promptDismissed: false, conflictedAt: nil, conflictPeerHex: nil,
                createdAt: nameT1, updatedAt: nameT1)
        }
        return s
    }
    // A contact name beats everything.
    #expect(state(carried: "Msg", at: nameT3, announced: "Ann", at: nameT3, contact: "Jane")
        .peerDisplayName(namePeer) == "Jane")
    // A message name at T2 beats an announce at T1.
    #expect(state(carried: "Msg", at: nameT2, announced: "Ann", at: nameT1).peerDisplayName(namePeer) == "Msg")
    // An announce at T3 beats a message name at T2.
    #expect(state(carried: "Msg", at: nameT2, announced: "Ann", at: nameT3).peerDisplayName(namePeer) == "Ann")
    // A newer cleared message name gives nil.
    #expect(state(carried: "", at: nameT2, announced: "Ann", at: nameT1).peerDisplayName(namePeer) == nil)
}

// MARK: - TestStore

@MainActor
private func nameStore(_ db: any DatabaseWriter, identity: Identity = Identity(), clock: any Clock<Duration>,
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: identity)
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.attachmentStore = AttachmentStore.testValue
        $0.avatarStore = AvatarStore.testValue
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in },
                                     close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in },
                                 openChannel: { _ in }, send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
        $0.badge = .ignored
    }
    store.exhaustivity = .off
    return store
}

/// Types `text`, taps Send and returns the message handed to the node.
@MainActor
private func sendNamed(_ store: TestStoreOf<AppFeature>, _ text: String) async -> LXMessage? {
    var sent: LXMessage? = nil
    await store.send(.binding(.set(\.draft, text)))
    await store.send(.sendTapped)
    await store.receive { a in
        if case let .node(.client(.sendMessage(m, _))) = a { sent = m; return true }
        return false
    }
    return sent
}

private func carriesName(_ m: LXMessage?) -> Bool {
    m?.fields.contains { $0.key == NameWire.fieldDisplayName } ?? false
}

/// A `TestClock` nobody advances, so the router's retry timers for this unreachable peer never
/// report `deliveryFailed` and settle the pending name behind the test's back.
@MainActor @Test func outgoingMessageCarriesNameUntilDelivered() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = nameStore(db, clock: TestClock()) { s in
        s.openPeerHex = namePeer
        s.chatVisible = true
        s.$displayName.withLock { $0 = "  Ada " }
    }
    let first = try #require(await sendNamed(store, "one"))
    #expect(carriesName(first))
    #expect(NameWire.decode(first.fields) == "Ada")
    let pending = try await db.read { try ProfileNameDelivery.fetch(namePeer, $0) }
    #expect(pending?.pendingName == "Ada")
    #expect(pending?.pendingHash == first.hash.hexString)

    await store.send(.node(.client(.delegate(.deliveryConfirmed(messageHash: first.hash)))))
    for _ in 0..<400 {
        if try await db.read({ try ProfileNameDelivery.fetch(namePeer, $0) })?.deliveredName == "Ada" { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await db.read { try ProfileNameDelivery.fetch(namePeer, $0) }?.deliveredName == "Ada")

    let second = try #require(await sendNamed(store, "two"))
    #expect(!carriesName(second))
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func receivedNameIsShownForThePeer() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = nameStore(db, identity: me, clock: ImmediateClock())
    let sender = Identity()
    let built = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                 timestamp: 1699999900, title: Data(), content: Data("hi".utf8),
                                 fields: NameWire.encode("Bea"))
    let m = try #require(LXMessage.unpack(built.packed))
    let hex = m.sourceHash.hexString
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true,
                                                              method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.peerProfiles[hex]?.name == "Bea")
    #expect(store.state.peerDisplayName(hex) == "Bea")
    let row = try await db.read { try PeerProfile.fetch(hex, $0) }
    #expect(row?.nameSetAt == Date(timeIntervalSince1970: 1699999900))
}

/// Only a validated sender may set a name: an unsigned message could be forged to rename a contact.
@MainActor @Test func unvalidatedMessageCannotSetName() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let built = LXMessage.create(source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                 timestamp: 1699999900, title: Data(), content: Data("hi".utf8),
                                 fields: NameWire.encode("Fake"))
    let m = try #require(LXMessage.unpack(built.packed))
    let hex = m.sourceHash.hexString
    let store = nameStore(db, identity: me, clock: ImmediateClock()) { s in
        s.node.client.learnedPeers[m.sourceHash] = LXMFNode.LearnedPeer(
            displayName: "Real", stampCost: nil, supportsCompression: false, learnedAt: nameT1)
    }
    #expect(store.state.peerDisplayName(hex) == "Real")
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: false,
                                                              method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    // The message itself is stored: only its name is ignored.
    #expect(try await db.read { try Message.fetchCount($0) } == 1)
    #expect(store.state.peerProfiles[hex]?.name == nil)
    #expect(try await db.read { try PeerProfile.fetch(hex, $0) }?.name == nil)
    #expect(store.state.peerDisplayName(hex) == "Real")
}

/// The first message from a peer carries its name and a timer change: the timer line it writes
/// already names the sender, rather than "Them".
@MainActor @Test func timerLineUsesTheNameItsMessageCarries() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = nameStore(db, identity: me, clock: ImmediateClock())
    let built = LXMessage.create(source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                 timestamp: 1699999900, title: Data(), content: Data(),
                                 fields: ExpiryWire.encodeChange(seconds: 3600) + NameWire.encode("Bea"))
    let m = try #require(LXMessage.unpack(built.packed))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true,
                                                              method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.body) == [ExpiryPreset.peerAnnouncement(peerName: "Bea", seconds: 3600)])
}
