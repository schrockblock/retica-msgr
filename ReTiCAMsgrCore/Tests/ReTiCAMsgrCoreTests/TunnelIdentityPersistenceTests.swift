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
@testable import ReTiCAMsgrCore

// ReTiCA parity batch 2, Task 9: the tunnel identity that signs tunnel-synthesis packets is minted
// once into its own Keychain item, handed to Transport at launch before `.endpoint(.start)`, and
// reused by every later launch (the hub files the tunnel under its public key).

private let testNow = Date(timeIntervalSince1970: 1700000000)

private enum Seen: Equatable {
    case setTunnelIdentity(Identity?)
    case start
}

@MainActor
private func launchStore(_ db: any DatabaseWriter, identity: Identity, tunnel: TunnelIdentityStore,
                         log: LockIsolated<[Seen]>) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: identity)
    initial.autoInterfaceAvailable = false   // hermetic: no AutoInterface slot
    let store = TestStore(initialState: initial) {
        CombineReducers {
            Reduce<AppFeature.State, AppFeature.Action> { _, action in
                switch action {
                case let .node(.client(.endpoint(.setTunnelIdentity(id)))):
                    log.withValue { $0.append(.setTunnelIdentity(id)) }
                case .node(.client(.endpoint(.start))):
                    log.withValue { $0.append(.start) }
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
        $0.tunnelIdentityStore = tunnel
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

/// One launch: `.onLaunch` until `.endpoint(.start)` has gone out, then everything settles.
@MainActor
private func launch(_ store: TestStoreOf<AppFeature>) async {
    await store.send(.onLaunch)
    await store.receive { if case .node(.client(.endpoint(.start))) = $0 { return true }; return false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// The first launch mints the tunnel identity into its own Keychain item and hands it to Transport
/// before `.endpoint(.start)`; a relaunch over the same Keychain (a new store, as a new process
/// builds) hands over the SAME identity and mints nothing. It is not the LXMF identity, and setting
/// it leaves the node a leaf.
@MainActor @Test func tunnelIdentityIsMintedOnceAndReusedAcrossRelaunches() async throws {
    let db = try AppDatabase.makeInMemory()
    let keychain = InMemoryKeychain()
    let me = Identity()

    // --- Session 1: nothing saved ---
    let log1 = LockIsolated<[Seen]>([])
    let store1 = launchStore(db, identity: me, tunnel: .live(ops: keychain.ops), log: log1)
    await launch(store1)
    guard case let .setTunnelIdentity(sent1?) = log1.value.first else {
        Issue.record("the first action recorded must be .setTunnelIdentity, got \(log1.value)")
        return
    }
    #expect(log1.value.firstIndex(of: .start) != nil)
    #expect(store1.state.node.client.endpoint.transport.tunnelIdentity == sent1)
    #expect(store1.state.node.client.endpoint.transport.transportIdentity == nil, "a tunnel identity is not a relay identity")
    #expect(sent1 != me, "the tunnel identity is not the LXMF identity")
    let saved = try #require(keychain.item(at: TunnelIdentityStore.location))
    #expect(saved == sent1.privateKey, "the identity handed over is the one in the Keychain")
    let addsAfterFirst = keychain.addCount

    // --- Session 2: relaunch, same Keychain, a new store ---
    let log2 = LockIsolated<[Seen]>([])
    let store2 = launchStore(db, identity: me, tunnel: .live(ops: keychain.ops), log: log2)
    await launch(store2)
    let setAt = try #require(log2.value.firstIndex(of: .setTunnelIdentity(sent1)),
                             "the relaunch must hand over the same tunnel identity, got \(log2.value)")
    let startAt = try #require(log2.value.firstIndex(of: .start))
    #expect(setAt < startAt, "the tunnel identity must reach Transport before any interface can connect")
    #expect(store2.state.node.client.endpoint.transport.tunnelIdentity?.privateKey == sent1.privateKey)
    #expect(keychain.addCount == addsAfterFirst, "nothing minted on relaunch")
    #expect(keychain.item(at: TunnelIdentityStore.location) == saved)
}

/// A Keychain read that fails (a prewarm launch before first unlock) leaves the tunnel identity
/// unset for the run and mints nothing, so the next launch still finds the saved one.
@MainActor @Test func unreadableTunnelIdentityIsNeverReplaced() async throws {
    let db = try AppDatabase.makeInMemory()
    let existing = Identity()
    let keychain = InMemoryKeychain([TunnelIdentityStore.location: existing.privateKey!])
    keychain.failRead(at: TunnelIdentityStore.location, status: errSecInteractionNotAllowed)
    let log = LockIsolated<[Seen]>([])
    let store = launchStore(db, identity: Identity(), tunnel: .live(ops: keychain.ops), log: log)
    await launch(store)
    #expect(!log.value.contains { if case .setTunnelIdentity = $0 { return true }; return false })
    #expect(store.state.node.client.endpoint.transport.tunnelIdentity == nil)
    #expect(keychain.addCount == 0)
    #expect(keychain.item(at: TunnelIdentityStore.location) == existing.privateKey)
}
