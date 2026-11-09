import Testing
import Foundation
import Security
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCAKeychain
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
import ReTiCAPushCore
@testable import ReTiCAMsgrPushService
@testable import ReTiCAMsgrCore

// Ratchets plan Task 4: the delivery destination's own ratchet ring lives in the Keychain and is
// handed back before the first announce; a peer's ratchet survives a relaunch in
// `KnownDestinationRow`; `LearnedDestinationRow.ratchetHex` is no longer written.
// Every ring here is minted by ReTiCA in the test (or is random bytes); none is a real identity's.

private let testNow = Date(timeIntervalSince1970: 1700000000)
private let tcpID = DefaultNode.entry.interfaceID

/// What the recorder saw, in the order the store processed it.
private enum Seen: Equatable {
    case enableRatchets(destinationHash: Data, ring: [Data])
    case start
    case registerDelivery
}

/// An `AppFeature` store over `db` and `ratchets`, with a recorder in front of the reducer, so the
/// test sees every action in processing order (a `.off` TestStore's `receive` can't see the ones
/// an earlier `receive` skipped).
@MainActor
private func ratchetStore(_ db: any DatabaseWriter, identity: Identity, ratchets: OwnRatchetStore,
                          log: LockIsolated<[Seen]> = LockIsolated([])) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: AppFeature.State(identity: identity)) {
        CombineReducers {
            Reduce<AppFeature.State, AppFeature.Action> { _, action in
                switch action {
                case let .node(.client(.endpoint(.enableRatchets(hash, ring)))):
                    log.withValue { $0.append(.enableRatchets(destinationHash: hash, ring: ring)) }
                case .node(.client(.endpoint(.start))):
                    log.withValue { $0.append(.start) }
                case .node(.client(.registerDelivery)):
                    log.withValue { $0.append(.registerDelivery) }
                default:
                    break
                }
                return .none
            }
            AppFeature()
        }
    } withDependencies: {
        $0.badge = .ignored
        $0.defaultDatabase = db
        $0.date = .constant(testNow)
        $0.transportDate = .constant(testNow)
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.ownRatchetStore = ratchets
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in },
                                     close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in },
                                 openChannel: { _ in }, send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
    }
    store.exhaustivity = .off
    return store
}

/// `.onLaunch`, then (once `.endpoint(.start)` has gone out, as a real interface can only come up
/// after it) the first interface-up, which registers the delivery destination and announces.
@MainActor
private func launchAndConnect(_ store: TestStoreOf<AppFeature>) async {
    await store.send(.onLaunch)
    await store.receive { if case .node(.client(.endpoint(.start))) = $0 { return true }; return false }
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(tcpID, .tcp))))))
}

@MainActor
private func receiveRotation(_ store: TestStoreOf<AppFeature>) async -> [Data] {
    var ring: [Data] = []
    await store.receive { action in
        if case let .node(.client(.endpoint(.delegate(.ratchetsChanged(_, rotated))))) = action {
            ring = rotated
            return true
        }
        return false
    }
    return ring
}

@MainActor
private func settle(_ store: TestStoreOf<AppFeature>) async {
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// First launch enables with `[]`; the rotation the first announce performs is written to the
/// Keychain; a relaunch hands exactly that ring to `.enableRatchets`, before `.endpoint(.start)` and
/// so before `.registerDelivery`; and the relaunch's own rotation keeps the restored keys behind the
/// new one and saves the whole ring again.
@MainActor @Test func ownRatchetRingIsSavedOnRotationAndRestoredBeforeRegisterDelivery() async throws {
    let db = try AppDatabase.makeInMemory()
    let keychain = InMemoryKeychain()
    let ratchets = OwnRatchetStore.live(ops: keychain.ops)
    let me = Identity()
    let deliveryHash = LXMessage.deliveryHash(identityHash: me.hash)
    let location = OwnRatchetStore.location(destinationHash: deliveryHash)

    // --- Session 1: no saved ring ---
    let log1 = LockIsolated<[Seen]>([])
    let store1 = ratchetStore(db, identity: me, ratchets: ratchets, log: log1)
    await launchAndConnect(store1)
    let firstRing = await receiveRotation(store1)
    await settle(store1)

    #expect(log1.value.first == .enableRatchets(destinationHash: deliveryHash, ring: []),
            "the first launch must enable with an empty ring, before anything else this test records")
    #expect(firstRing.count == 1)
    #expect(keychain.item(at: location) == firstRing.reduce(Data(), +),
            "the rotation's ring must be in the Keychain")

    // --- Session 2: relaunch, same Keychain ---
    let log2 = LockIsolated<[Seen]>([])
    let store2 = ratchetStore(db, identity: me, ratchets: ratchets, log: log2)
    await launchAndConnect(store2)
    let secondRing = await receiveRotation(store2)
    await settle(store2)

    let enable = Seen.enableRatchets(destinationHash: deliveryHash, ring: firstRing)
    let enableAt = try #require(log2.value.firstIndex(of: enable), "the saved ring must be passed to .enableRatchets")
    let startAt = try #require(log2.value.firstIndex(of: .start))
    let registerAt = try #require(log2.value.firstIndex(of: .registerDelivery))
    #expect(enableAt < startAt, "enable must reach Transport before any interface can start")
    #expect(startAt < registerAt)
    #expect(Array(secondRing.dropFirst()) == firstRing, "the relaunch must rotate the restored ring, not a new one")
    #expect(keychain.item(at: location) == secondRing.reduce(Data(), +))
}

/// A Keychain read that fails leaves ratchets off for the run (no `.enableRatchets`, no rotation on
/// the announce) and leaves the saved ring as it was, so it is still there for the next launch.
@MainActor @Test func unreadableRingLeavesRatchetsOffAndTheSavedRingUntouched() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let deliveryHash = LXMessage.deliveryHash(identityHash: me.hash)
    let location = OwnRatchetStore.location(destinationHash: deliveryHash)
    let saved = SecureRandom.bytes(64)
    let keychain = InMemoryKeychain([location: saved])
    keychain.failRead(at: location, status: errSecInteractionNotAllowed)

    let log = LockIsolated<[Seen]>([])
    let store = ratchetStore(db, identity: me, ratchets: .live(ops: keychain.ops), log: log)
    await launchAndConnect(store)
    await store.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    await settle(store)

    #expect(!log.value.contains { if case .enableRatchets = $0 { return true }; return false })
    #expect(store.state.node.client.endpoint.transport.ownRatchets[deliveryHash] == nil)
    #expect(keychain.item(at: location) == saved)
}

/// A peer's ratchet and its receive time are written to `knownDestinationRows` and restored to
/// Transport by the next launch.
@MainActor @Test func peerRatchetSurvivesRelaunchViaKnownDestinationRow() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let peer = Identity()
    let peerHash = LXMessage.deliveryHash(identityHash: peer.hash)
    let ratchet = try #require(Identity.ratchetPublicKey(privateKey: SecureRandom.bytes(32)))
    let received = testNow.addingTimeInterval(-3600)

    // --- Session 1: Transport knows the peer's ratchet; backgrounding writes the table ---
    let store1 = ratchetStore(db, identity: me, ratchets: .inert)
    await store1.send(.node(.client(.endpoint(.transport(.rehydrateKnownDestinations([peerHash: KnownDestination(
        identity: peer, appData: nil, lastHeard: testNow, ratchet: ratchet, ratchetReceived: received)]))))))
    #expect(store1.state.node.client.endpoint.knownDestinations[peerHash]?.ratchet == ratchet,
            "precondition: Transport accepted the seeded ratchet")
    await store1.send(.backgrounded)
    // `finish()` (in `settle`) waits for every in-flight effect, the flush's write included, so the
    // table is written once it returns. No sleep.
    await settle(store1)

    let row = try #require(try await db.read { try KnownDestinationRow.all.fetchAll($0) }.first)
    #expect(row.ratchetHex == ratchet.hexString)
    #expect(row.ratchetReceived == received)

    // --- Session 2: relaunch, same database ---
    let store2 = ratchetStore(db, identity: me, ratchets: .inert)
    await store2.send(.onLaunch)
    await store2.receive {
        if case .node(.client(.endpoint(.transport(.rehydrateKnownDestinations)))) = $0 { return true }
        return false
    }
    let restored = store2.state.node.client.endpoint.knownDestinations[peerHash]
    #expect(restored?.ratchet == ratchet)
    #expect(restored?.ratchetReceived == received)
    await settle(store2)
}

/// `LearnedDestinationRow` no longer writes the deprecated ratchet: the row built for a learned
/// destination that still carries one has a nil `ratchetHex`.
@Test func learnedDestinationRowNoLongerWritesTheRatchet() throws {
    let peer = Identity()
    let hash = LXMessage.deliveryHash(identityHash: peer.hash)
    let destination = LearnedDestination(identity: peer, appData: nil, ratchet: SecureRandom.bytes(32),
                                         interfaceID: tcpID, hops: 1, nextHop: nil, announceEmitted: 0,
                                         learnedAt: testNow)
    let row = try #require(LearnedDestinationRow(hash: hash, destination: destination))
    #expect(row.ratchetHex == nil)
}

/// Fails the next write (`add` or `update`), once; every other call goes to the in-memory Keychain.
private final class FailNextRingWrite: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    private func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { armed = false }
        return armed
    }

    func ops(over keychain: InMemoryKeychain) -> KeychainOps {
        let inner = keychain.ops
        return KeychainOps(
            read: inner.read,
            add: { [self] location, data in take() ? .failed(errSecNotAvailable) : inner.add(location, data) },
            delete: inner.delete,
            deleteItem: inner.deleteItem,
            update: { [self] location, data in take() ? .failed(errSecNotAvailable) : inner.update(location, data) })
    }
}

/// The store reads back what it saved (newest first, `[]` with no item, a partial trailing key
/// ignored, one item per destination), a failed write keeps the ring it replaced, and an empty
/// ring is refused and never erases the saved one.
@Test func ownRatchetStoreRoundTripsAndKeepsTheRingWhenAWriteFails() {
    let keychain = InMemoryKeychain()
    let failing = FailNextRingWrite()
    let store = OwnRatchetStore.live(ops: failing.ops(over: keychain))
    let hashA = Data(repeating: 0xA1, count: 16)
    let hashB = Data(repeating: 0xB2, count: 16)
    let ring = [SecureRandom.bytes(32), SecureRandom.bytes(32)]

    #expect(store.load(hashA) == [])
    #expect(store.save(hashA, ring))
    #expect(store.load(hashA) == ring)
    #expect(store.load(hashB) == [], "items are per destination")

    failing.arm()
    #expect(!store.save(hashA, [SecureRandom.bytes(32)] + ring))
    #expect(store.load(hashA) == ring, "a failed write must leave the previous ring in place")

    #expect(!store.save(hashA, []))
    #expect(store.load(hashA) == ring, "an empty ring must never erase the saved one")

    keychain.set(ring.reduce(Data(), +) + Data([1, 2, 3]), at: OwnRatchetStore.location(destinationHash: hashB))
    #expect(store.load(hashB) == ring, "a trailing partial key is ignored")
}

/// After the first save the ring item is never missing, checked after EVERY Keychain call: a later
/// save updates it in place (a failing add can't touch it), and a failing update leaves the old
/// ring. A delete-then-add would leave no copy between its two calls, which a kill could land in.
@Test func ownRatchetSaveNeverLeavesTheItemMissing() {
    let keychain = InMemoryKeychain()
    let hash = Data(repeating: 0xC3, count: 16)
    let location = OwnRatchetStore.location(destinationHash: hash)
    let watching = LockIsolated(false)
    let missing = LockIsolated(false)
    let inner = keychain.ops
    @Sendable func check() {
        if watching.value, keychain.item(at: location) == nil { missing.setValue(true) }
    }
    let ops = KeychainOps(
        read: { let r = inner.read($0); check(); return r },
        add: { let r = inner.add($0, $1); check(); return r },
        delete: { let r = inner.delete($0); check(); return r },
        deleteItem: { let r = inner.deleteItem($0); check(); return r },
        update: { let r = inner.update($0, $1); check(); return r })
    let store = OwnRatchetStore.live(ops: ops)
    let first = [SecureRandom.bytes(32)]
    let second = [SecureRandom.bytes(32)] + first

    #expect(store.save(hash, first))
    watching.setValue(true)
    keychain.failAdd(at: location, status: errSecNotAvailable)
    #expect(store.save(hash, second), "an existing ring is updated, never re-added")
    #expect(store.load(hash) == second)
    keychain.failUpdate(at: location, status: errSecNotAvailable)
    #expect(!store.save(hash, [SecureRandom.bytes(32)] + second))
    #expect(!missing.value, "the ring item was missing after some Keychain call")
    #expect(keychain.item(at: location) == second.reduce(Data(), +))
}

/// An empty `.ratchetsChanged` is ignored by the reducer: the store is never asked to save it.
@MainActor @Test func emptyRatchetsChangedIsNotSaved() async throws {
    let saves = LockIsolated<[[Data]]>([])
    let spy = OwnRatchetStore(load: { _ in [] }, save: { _, ring in
        saves.withValue { $0.append(ring) }
        return true
    })
    let store = ratchetStore(try AppDatabase.makeInMemory(), identity: Identity(), ratchets: spy)
    let hash = Data(repeating: 0xD4, count: 16)
    await store.send(.node(.client(.endpoint(.delegate(.ratchetsChanged(destinationHash: hash, ring: []))))))
    let ring = [SecureRandom.bytes(32)]
    await store.send(.node(.client(.endpoint(.delegate(.ratchetsChanged(destinationHash: hash, ring: ring))))))
    await settle(store)
    #expect(saves.value == [ring])
}

/// Printing our own ratchets (as a TestStore diff, `dump` or a log of state would) never shows the
/// keys: every path says the ring is redacted and carries no key hex.
@Test func ownRatchetsPrintRedacted() {
    let key = SecureRandom.bytes(32)
    let own = Transport.State.OwnRatchets(ring: [key, SecureRandom.bytes(32)])
    var dumped = ""
    dump(own, to: &dumped)
    for printed in [String(describing: own), String(reflecting: own), String(customDumping: own), dumped] {
        // Booleans only, so a failure message never carries the printed text.
        let leaks = printed.lowercased().contains(key.hexString)
        let redacted = printed.contains("redacted")
        #expect(!leaks, "a printing path shows a ratchet key")
        #expect(redacted, "a printing path does not redact the ring")
    }
}

/// The Notification Service Extension's handler reads the ring the app saved (same location, same
/// access group) for our delivery hash, and only reads: no Keychain write. No ring, or an
/// unreadable one, gives nil (attribute with the identity key only).
@Test func extensionReadsTheSavedRingReadOnly() {
    let keychain = InMemoryKeychain()
    let me = Identity()
    let deliveryHash = LXMessage.deliveryHash(identityHash: me.hash)
    let ring = [SecureRandom.bytes(32), SecureRandom.bytes(32)]
    #expect(OwnRatchetStore.live(ops: keychain.ops).save(deliveryHash, ring))
    let saved = keychain.item(at: OwnRatchetStore.location(destinationHash: deliveryHash))
    let adds = keychain.addCount

    let storage = PushStorage.temporary()
    storage.settings.save(SharedPushSettings(keychainService: SharedIdentityLocation.service,
                                             keychainAccessGroup: SharedIdentityLocation.accessGroup))
    let handler = ReTiCAMsgrPush.makeServiceHandler(storage: storage, ops: keychain.ops)
    #expect(handler.loadRatchets(deliveryHash) == ring)
    #expect(handler.loadRatchets(Data(repeating: 0xEE, count: 16)) == nil, "no ring for that hash")
    #expect(keychain.addCount == adds)
    #expect(keychain.item(at: OwnRatchetStore.location(destinationHash: deliveryHash)) == saved)

    keychain.failRead(at: OwnRatchetStore.location(destinationHash: deliveryHash), status: errSecInteractionNotAllowed)
    #expect(handler.loadRatchets(deliveryHash) == nil)
}
