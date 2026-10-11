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
import ReTiCAPushCore
@testable import ReTiCaMsgrCore

// MARK: - Helpers (mirrors AppFeatureTests.makeStore, plus the push dependencies)

@MainActor
private func makePushStore(_ db: any DatabaseWriter, identity: Identity,
                           clock: TestClock<Duration>? = nil,
                           storage: PushStorage = .temporary(),
                           configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: identity, pushStorage: storage,
                                   bundleID: "co.example.app", pushEnvironment: .sandbox)
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.attachmentStore = AttachmentStore.testValue
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = clock ?? TestClock()
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

/// A HEADER_1 DATA packet carrying an opportunistic LXMF message from `sender` to `me`.
private func pushedPacket(from sender: Identity, to me: Identity, text: String) -> (raw: Data, message: LXMessage) {
    let message = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                   timestamp: 1700000000.5, title: Data(), content: Data(text.utf8))
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    let packet = Packet.data(to: dest, plaintext: Data(message.packed.dropFirst(16)))
    return (try! packet.packed(), message)
}

private let tcpID = InterfaceID("tcp")

// MARK: - Tests

@MainActor @Test func pushAppInjectDeliversAPacketThroughTheReceivePath() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makePushStore(db, identity: me)
    // Registering the delivery destination is what lets Transport decrypt for it. The app does
    // this on interfaceConnected; do it directly here.
    await store.send(.node(.client(.registerDelivery)))
    await store.skipReceivedActions(strict: false)
    let (raw, message) = pushedPacket(from: sender, to: me, text: "via push")
    await store.send(.push(.delegate(.inject(packets: [raw]))))
    await store.receive { action in
        if case .node(.client(.delegate(.messageReceived(let m, _, _)))) = action { return m.hash == message.hash }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.body) == ["via push"])
}

@MainActor @Test func pushAppInjectUsesTheTCPInterfaceID() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makePushStore(db, identity: me)
    // C1: inject now holds packets back until the delivery destination exists.
    await store.send(.node(.client(.registerDelivery)))
    await store.skipReceivedActions(strict: false)
    let (raw, _) = pushedPacket(from: Identity(), to: me, text: "x")
    await store.send(.push(.delegate(.inject(packets: [raw]))))
    await store.receive { action in
        if case .node(.client(.endpoint(.transport(.received(let id, let bytes))))) = action {
            return id == store.state.node.client.endpoint.tcpClients.first?.interfaceID && bytes == raw
        }
        return false
    }
}

@MainActor @Test func pushAppInjectForwardsEveryPacketInOrder() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makePushStore(db, identity: me)
    // C1: inject now holds packets back until the delivery destination exists.
    await store.send(.node(.client(.registerDelivery)))
    await store.skipReceivedActions(strict: false)
    let (a, _) = pushedPacket(from: Identity(), to: me, text: "a")
    let (b, _) = pushedPacket(from: Identity(), to: me, text: "b")
    await store.send(.push(.delegate(.inject(packets: [a, b]))))
    await store.receive { action in
        if case .node(.client(.endpoint(.transport(.received(_, let bytes))))) = action { return bytes == a }
        return false
    }
    await store.receive { action in
        if case .node(.client(.endpoint(.transport(.received(_, let bytes))))) = action { return bytes == b }
        return false
    }
}

@MainActor @Test func pushAppInjectDeliversWhileDisconnected() async throws {
    // No interfaceConnected ever happened: the socket is down, the proof is a no-op, but the
    // message must still land.
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makePushStore(db, identity: me)
    await store.send(.node(.client(.registerDelivery)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connection == .disconnected)
    let (raw, _) = pushedPacket(from: Identity(), to: me, text: "offline")
    await store.send(.push(.delegate(.inject(packets: [raw]))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.body) == ["offline"])
}

@MainActor @Test func pushAppDrainBeforeConnectKeepsPacketsForLater() async throws {
    // Cold launch: the drain runs before the delivery destination exists. The packet must survive
    // until interfaceConnected registers the destination and drains again.
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let storage = PushStorage.temporary()
    let (raw, _) = pushedPacket(from: Identity(), to: me, text: "cold")
    try storage.inbox.append(raw)
    let store = makePushStore(db, identity: me, storage: storage)
    await store.send(.push(.drainInbox))
    await store.receive { if case .push(.delegate(.inject)) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(try storage.inbox.count() == 1)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(tcpID, .tcp))))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    #expect(try await db.read { try Message.all.fetchAll($0) }.map(\.body) == ["cold"])
    #expect(try storage.inbox.count() == 0)
}

@MainActor @Test func pushAppWakeReDialsAndDrains() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makePushStore(db, identity: Identity()) { state in
        state.$host.withLock { $0 = "node.example" }
        state.$port.withLock { $0 = 4243 }
    }
    await store.send(.pushWake) { $0.connection = .connecting }
    await store.receive { if case .node(.client(.endpoint(.start))) = $0 { return true }; return false }
    await store.receive { if case .push(.hubChanged(host: "node.example", port: 4243)) = $0 { return true }; return false }
    await store.receive { if case .push(.drainInbox) = $0 { return true }; return false }
}

@MainActor @Test func pushAppWakeDrainsEvenWhenTCPIsUp() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makePushStore(db, identity: Identity())
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(tcpID, .tcp))))))
    await store.skipReceivedActions(strict: false)
    await store.send(.pushWake)
    await store.receive { if case .push(.drainInbox) = $0 { return true }; return false }
    #expect(store.state.connection == .connected)
}

@MainActor @Test func pushAppLaunchForegroundAndConnectForwardToPush() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makePushStore(db, identity: Identity()) { state in
        state.$host.withLock { $0 = "node.example" }
        state.$port.withLock { $0 = 4243 }
    }
    await store.send(.onLaunch)
    await store.receive { if case .push(.hubChanged(host: "node.example", port: 4243)) = $0 { return true }; return false }
    await store.receive { if case .push(.appLaunched) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)

    await store.send(.foregrounded)
    await store.receive { if case .push(.drainInbox) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)

    await store.send(.connectTapped)
    await store.receive { if case .push(.hubChanged(host: "node.example", port: 4243)) = $0 { return true }; return false }
}

// MARK: - Registration over the hub's link (spec amendment A2)

private let pushHub = Data(repeating: 0xC1, count: 16)
private let pushLink = Data(repeating: 0xD1, count: 16)
private let pushRequest = Data("register-request".utf8)
private let pushResponse = Data("register-response".utf8)

@MainActor @Test func pushAppRegistrationRunsTheLinkFlow() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makePushStore(db, identity: me)
    // I1: registration now waits for the TCP interface to be connected, so connect it first.
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(tcpID, .tcp))))))
    await store.skipReceivedActions(strict: false)
    // The hub is not in the learned table: the flow asks for a path first.
    await store.send(.push(.delegate(.sendRegistration(hub: pushHub, path: "/register", data: pushRequest))))
    await store.receive { if case .node(.client(.endpoint(.requestPath(destinationHash: pushHub)))) = $0 { return true }; return false }
    // In the real system, Transport mutates `transport.learned` SYNCHRONOUSLY with emitting the
    // `pathLearned` delegate (same reduce pass, see Transport.swift's announce handling) — both
    // happen together, there is no separate action that updates the table. Sending only the bare
    // notification would leave `transport.learned` empty, and the real `TransportEndpoint.openLink`
    // enforces a stale-path gate (TransportEndpoint.swift:170-175) that auto-fails with `.noPath`
    // when the destination isn't learned. So this seeds the real state via the real actions that
    // populate it (`rehydrateLearnedDestinations`) before sending the bare notification, matching
    // that invariant — a TestStore `send` trailing closure only ASSERTS an expected mutation the
    // reducer itself must perform; it cannot inject state the production code never touches.
    await store.send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations([
        pushHub: LearnedDestination(identity: Identity(), appData: nil, ratchet: nil, interfaceID: tcpID,
                                    hops: 1, nextHop: nil, announceEmitted: 0,
                                    learnedAt: Date(timeIntervalSince1970: 1700000000))
    ]))))))
    await store.skipReceivedActions(strict: false)
    await store.send(.node(.client(.endpoint(.delegate(.pathLearned(destinationHash: pushHub, hops: 1))))))
    await store.receive { if case .node(.client(.endpoint(.openLink(destinationHash: pushHub)))) = $0 { return true }; return false }
    await store.send(.node(.client(.endpoint(.delegate(.linkEstablished(linkID: pushLink, destinationHash: pushHub))))))
    await store.receive { action in
        if case .node(.client(.endpoint(.identifyOverLink(linkID: pushLink, identity: let identity)))) = action { return identity == me }
        return false
    }
    await store.receive { if case .node(.client(.endpoint(.sendRequestOverLink(linkID: pushLink, path: "/register", data: pushRequest)))) = $0 { return true }; return false }
    await store.send(.node(.client(.endpoint(.delegate(.responseReceived(linkID: pushLink, requestID: Data(), data: pushResponse))))))
    await store.receive { if case .node(.client(.endpoint(.closeLink(linkID: pushLink)))) = $0 { return true }; return false }
    await store.receive(.push(.registrationResponse(.success(pushResponse))))
    #expect(!store.state.pushRegistrationFlow.isActive)
}

@MainActor @Test func pushAppRegistrationTimesOut() async throws {
    let db = try AppDatabase.makeInMemory()
    let clock = TestClock()
    let store = makePushStore(db, identity: Identity(), clock: clock)
    // I1: registration now waits for the TCP interface to be connected, so connect it first.
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(tcpID, .tcp))))))
    await store.skipReceivedActions(strict: false)
    await store.send(.push(.delegate(.sendRegistration(hub: pushHub, path: "/register", data: pushRequest))))
    await store.skipReceivedActions(strict: false)
    await clock.advance(by: .seconds(20))
    await store.receive(.pushRegistrationTimedOut)
    await store.receive(.push(.registrationResponse(.failure(RegistrationFailure("Push hub not reachable")))))
    #expect(!store.state.pushRegistrationFlow.isActive)
}

@MainActor @Test func pushAppRegistrationLinkFailureIsReported() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makePushStore(db, identity: Identity())
    // I1: registration now waits for the TCP interface to be connected, so connect it first. Seed
    // `transport.learned`/`interfaces` via the real actions that populate them (see the comment in
    // pushAppRegistrationRunsTheLinkFlow): otherwise the real `openLink` gate auto-fails with
    // `.noPath` before this test's own simulated `.linkFailed` ever has a chance to run.
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(tcpID, .tcp))))))
    await store.send(.push(.delegate(.sendRegistration(hub: pushHub, path: "/register", data: pushRequest))))
    await store.send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations([
        pushHub: LearnedDestination(identity: Identity(), appData: nil, ratchet: nil, interfaceID: tcpID,
                                    hops: 1, nextHop: nil, announceEmitted: 0,
                                    learnedAt: Date(timeIntervalSince1970: 1700000000))
    ]))))))
    await store.skipReceivedActions(strict: false)
    await store.send(.node(.client(.endpoint(.delegate(.pathLearned(destinationHash: pushHub, hops: 1))))))
    await store.skipReceivedActions(strict: false)
    // Use whichever `LinkFailure` case the endpoint declares (read TransportEndpoint.swift / LinkPlane); any case will do.
    await store.send(.node(.client(.endpoint(.delegate(.linkFailed(destinationHash: pushHub, reason: .establishmentTimedOut))))))
    await store.receive(.push(.registrationResponse(.failure(RegistrationFailure("Push hub link failed")))))
}

@MainActor @Test func pushAppRegistrationRestartDoesNotReportCancellation() async throws {
    // A newer attempt supersedes an older one: the older one's cancellation must not land on the
    // newer attempt's status (which is `.registering` by the time the delegate fires).
    let db = try AppDatabase.makeInMemory()
    let store = makePushStore(db, identity: Identity()) { state in
        state.push.$enabled.withLock { $0 = true }
        state.push.status = .registering
    }
    // I1: registration now waits for the TCP interface to be connected, so connect it first. Seed
    // `transport.learned`/`interfaces` via the real actions that populate them (see the comment in
    // pushAppRegistrationRunsTheLinkFlow): otherwise the real `openLink` gate auto-fails with
    // `.noPath`, which would also mean the SECOND `sendRegistration` below sees `hubKnown:
    // false` and requests a path again instead of reaching `openLink` directly as this test expects.
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(tcpID, .tcp))))))
    await store.send(.push(.delegate(.sendRegistration(hub: pushHub, path: "/register", data: pushRequest))))
    await store.send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations([
        pushHub: LearnedDestination(identity: Identity(), appData: nil, ratchet: nil, interfaceID: tcpID,
                                    hops: 1, nextHop: nil, announceEmitted: 0,
                                    learnedAt: Date(timeIntervalSince1970: 1700000000))
    ]))))))
    await store.skipReceivedActions(strict: false)
    await store.send(.node(.client(.endpoint(.delegate(.pathLearned(destinationHash: pushHub, hops: 1))))))
    await store.skipReceivedActions(strict: false)
    await store.send(.push(.delegate(.sendRegistration(hub: pushHub, path: "/register", data: pushRequest))))
    await store.receive { if case .node(.client(.endpoint(.openLink(destinationHash: pushHub)))) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.push.status == .registering)
}

@MainActor @Test func pushAppRegistrationWaitsForTheHubConnection() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makePushStore(db, identity: Identity())
    await store.send(.push(.delegate(.sendRegistration(hub: pushHub, path: "/register", data: pushRequest)))) {
        $0.pendingPushRegistration = PendingPushRegistration(hub: pushHub, path: "/register", data: pushRequest)
    }
    await store.finish()
    #expect(!store.state.pushRegistrationFlow.isActive)
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(tcpID, .tcp)))))) {
        $0.pendingPushRegistration = nil
    }
    await store.receive { if case .push(.delegate(.sendRegistration(hub: pushHub, _, _))) = $0 { return true }; return false }
    await store.receive { if case .node(.client(.endpoint(.requestPath(destinationHash: pushHub)))) = $0 { return true }; return false }
}

@MainActor @Test func pushAppRegistrationRestartStillTimesOut() async throws {
    let db = try AppDatabase.makeInMemory()
    let clock = TestClock()
    let store = makePushStore(db, identity: Identity(), clock: clock)
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(tcpID, .tcp))))))
    await store.skipReceivedActions(strict: false)
    await store.send(.push(.delegate(.sendRegistration(hub: pushHub, path: "/register", data: pushRequest))))
    await store.send(.push(.delegate(.sendRegistration(hub: pushHub, path: "/register", data: pushRequest))))
    await store.skipReceivedActions(strict: false)
    await clock.advance(by: .seconds(20))
    await store.receive(.pushRegistrationTimedOut)
    await store.receive(.push(.registrationResponse(.failure(RegistrationFailure("Push hub not reachable")))))
}

@MainActor @Test func pushAppValidHubEntryRegistersImmediately() async throws {
    let db = try AppDatabase.makeInMemory()
    let token = Data([1, 2, 3, 4])
    let store = makePushStore(db, identity: Identity()) { state in
        state.push.$enabled.withLock { $0 = true }
        state.push.deviceToken = token
        state.push.status = .failed("Invalid push hub address")
    }
    await store.send(.push(.setHubHex(String(repeating: "c1", count: 16))))
    await store.receive(.push(.deviceTokenReceived(token)))
    #expect(store.state.push.status == .registering)
}
