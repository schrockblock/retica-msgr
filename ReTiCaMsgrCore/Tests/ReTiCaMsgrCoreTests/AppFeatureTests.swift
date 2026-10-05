import Testing
import Foundation
import ComposableArchitecture
import Sharing
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCaMsgrCore
// `Testing` exports its own `Attachment`; this file means the model.
import struct ReTiCaMsgrCore.Attachment

// MARK: - Helpers

@MainActor
private func makeStore(_ db: any DatabaseWriter, identity: Identity,
                       attachmentStore: AttachmentStore? = nil,
                       clock: TestClock<Duration>? = nil,
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: identity)
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.attachmentStore = attachmentStore ?? AttachmentStore.testValue
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        // transportDate drives Transport's internal clock (learnedAt comparisons in
        // rehydrateLearnedDestinations). Set equal to \.date so a row with learnedAt = testNow
        // is neither "in the future" nor expired from Transport's perspective.
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = clock ?? TestClock()
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { }
        )
        // The opt-in listener, when enabled, starts a TCPListener. A never-emitting stream keeps
        // the test hermetic (no real socket) while letting the listen effect start harmlessly.
        $0.tcpListener = TCPListener(
            listen: { _ in AsyncStream { _ in } },
            send: { _, _ in },
            close: { _ in },
            stop: { }
        )
        // A hermetic BLE driver: a never-emitting event stream and no-op verbs. The live value is
        // FCB/CoreBluetooth; the unimplemented testValue would flag an issue the moment `.ble(.start)`
        // fires. Peers are injected in-test via the peerOnline action, not this stream.
        $0.bleDriver = BLEDriver(
            start: { _ in AsyncStream { _ in } },
            readIdentity: { _ in },
            openChannel: { _ in },
            send: { _, _ in },
            closeChannel: { _ in },
            stop: { }
        )
    }
    store.exhaustivity = .off
    return store
}

private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
}

private func seed(_ db: any DatabaseWriter, _ rows: [Message]) async throws {
    try await db.write { d in
        for r in rows { try Message.insert { r }.execute(d) }
    }
}

private func msg(_ id: Int, _ peer: String, _ body: String, _ ts: TimeInterval,
                 outgoing: Bool = true, status: String = MessageStatus.sent,
                 hash: String = "") -> Message {
    Message(id: uuid(id), peerHex: peer, isOutgoing: outgoing, body: body,
            timestamp: Date(timeIntervalSince1970: ts), status: status,
            validated: false, messageHash: hash)
}

private let peerA = String(repeating: "a", count: 32)   // 16-byte hex
private let peerB = String(repeating: "b", count: 32)

// MARK: - Tests

@MainActor
@Test func onLaunchLoadsConversations() async {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [msg(1, peerA, "to-a", 1000), msg(2, peerB, "to-b", 2000)])
    let store = makeStore(db, identity: Identity())
    await store.send(.onLaunch)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    #expect(store.state.connection == .connecting)
    #expect(store.state.conversations.count == 2)
    #expect(store.state.conversations.first?.peerHex == peerB)   // ts 2000 newest
}

/// The TCP endpoint is built once at init with the host/port passed to State.init (defaults to
/// 127.0.0.1:4242). The Settings fields bind to separate @Shared values, so without the sync the
/// app would always dial those init defaults regardless of what the user configured. This pins the
/// fix: on launch, the current Settings host/port are copied into the endpoint before dialing.
@MainActor @Test func onLaunchSyncsSettingsHostPortIntoEndpoint() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { state in
        state.$host.withLock { $0 = "gaefu.ddns.net" }
        state.$port.withLock { $0 = 4243 }
    }
    await store.send(.onLaunch)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    #expect(store.state.connection == .connecting)
    guard let tcp = store.state.node.client.endpoint.tcpClient else {
        Issue.record("expected a TCP-client endpoint slot")
        return
    }
    #expect(tcp.interface.host == "gaefu.ddns.net")
    #expect(tcp.interface.port == 4243)
}

/// The listener is OPT-IN and OFF by default: a fresh state that has never toggled it must not
/// grow a `tcpServer` slot on connect. The dialling-only client never listened, and that default
/// is the mitigation for the unbounded-listener LAN surface (no admission control yet — Tier 7).
@MainActor @Test func onLaunchDoesNotAddListenerSlotWhenListenDisabled() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())   // listenEnabled defaults false
    await store.send(.onLaunch)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    #expect(store.state.node.client.endpoint.tcpServer == nil)
}

/// Enabling the listener adds a `tcpServer` slot bound to the DEDICATED `listenPort` (not the dial
/// `port`) when Settings are synced at connect time. The slot is what lets other LAN nodes dial
/// THIS device directly.
@MainActor @Test func enablingListenAddsListenerSlotOnDedicatedPortAtConnect() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { state in
        state.$listenEnabled.withLock { $0 = true }
        state.$listenPort.withLock { $0 = 5151 }
        state.$port.withLock { $0 = 4243 }   // dial port is DIFFERENT — must not be reused
    }
    await store.send(.onLaunch)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    guard let server = store.state.node.client.endpoint.tcpServer else {
        Issue.record("expected a tcpServer slot when listening is enabled")
        return
    }
    #expect(server.interface.port == 5151)   // the LISTEN port, not the dial port 4243
}

// MARK: - BLE endpoint slot (A1)

/// BLE is OPT-IN and OFF by default: a fresh state that has never toggled it must not grow a `ble`
/// slot on connect. Nothing constructs the driver until the user asks for it.
@MainActor @Test func onLaunchDoesNotAddBLESlotWhenBLEDisabled() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())   // bleEnabled defaults false
    await store.send(.onLaunch)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    #expect(store.state.node.client.endpoint.ble == nil)
}

/// Enabling BLE constructs the `ble` slot at connect time (Settings synced), so the container's
/// `.start` brings the interface up. The live FCB/CoreBluetooth driver is auto-wired via the
/// `\.bleDriver` dependency — nothing to inject here.
@MainActor @Test func enablingBLEAddsSlotAtConnect() async {
    let db = try! AppDatabase.makeInMemory()
    let identity = Identity()
    let store = makeStore(db, identity: identity) { $0.$bleEnabled.withLock { $0 = true } }
    await store.send(.onLaunch)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    #expect(store.state.node.client.endpoint.ble != nil)
    // ble v2.2: the slot announces the node's own 16-byte identity hash to BLE peers.
    #expect(store.state.node.client.endpoint.ble?.ble.localIdentity == identity.hash)
}

/// A re-sync (foreground / reconnect) must PRESERVE an already-running BLE slot rather than rebuild
/// it — rebuilding would reset `peerInterfaces` and drop every live peer. We seed a fake peer into
/// the slot and confirm it survives a second sync-triggering connect.
@MainActor @Test func reconnectPreservesRunningBLESlotAndItsPeers() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { $0.$bleEnabled.withLock { $0 = true } }
    // First connect builds the slot; a peer then comes online and is registered into it (via the
    // real container wiring — `peerInterfaces` has an inaccessible setter, and this exercises the
    // production path anyway).
    await store.send(.connectTapped)
    let token = Data(repeating: 0xAB, count: 16)
    await store.send(.node(.client(.endpoint(.ble(.ble(.delegate(.peerOnline(token))))))))
    #expect(store.state.node.client.endpoint.ble?.peerInterfaces[bleInterfaceID(token)] == token)

    // A second connect re-runs syncEndpointHostPort. The slot (and its peer) must survive — a
    // rebuild would reset peerInterfaces and drop the peer.
    await store.send(.connectTapped)
    let peers = store.state.node.client.endpoint.ble?.peerInterfaces ?? [:]
    #expect(peers.count == 1, "a running BLE slot must be preserved across reconnect, not rebuilt")
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// Toggling BLE OFF removes the slot on the next connect, so the interface stops.
@MainActor @Test func disablingBLERemovesSlotAtConnect() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { state in
        state.$bleEnabled.withLock { $0 = false }
        // a leftover slot from a previous run
        state.node.client.endpoint.ble = BLEEndpoint.State(localIdentity: state.identity.hash)
    }
    await store.send(.connectTapped)
    #expect(store.state.node.client.endpoint.ble == nil)
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

// MARK: - Bluetooth permission / adapter alert (A5)

/// A terminal `unauthorized` from the BLE adapter (permission denied) surfaces as a
/// permission-denied alert the UI turns into an "Open Settings" prompt. The signal arrives on the
/// BLE-only hatch — `.ble(.delegate(.adapterUnavailable))` — which nothing consumed before S6/A5.
@MainActor @Test func bleUnauthorizedSurfacesPermissionDeniedAlert() async {
    let db = try! AppDatabase.makeInMemory()
    // A BLE slot must be present for the .ble delegate to route (in production the slot is what
    // emitted the delegate); without it TransportEndpoint's ifLet warns on a child action to nil.
    let store = makeStore(db, identity: Identity()) {
        $0.node.client.endpoint.ble = BLEEndpoint.State(localIdentity: $0.identity.hash)
    }
    await store.send(.node(.client(.endpoint(.ble(.delegate(.adapterUnavailable(.unauthorized)))))))
    #expect(store.state.bluetoothAlert == .permissionDenied)
}

/// A terminal `unsupported` (no BLE LE radio) surfaces as a distinct alert — a different message,
/// not an "Open Settings" prompt (there is nothing to grant).
@MainActor @Test func bleUnsupportedSurfacesUnsupportedAlert() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) {
        $0.node.client.endpoint.ble = BLEEndpoint.State(localIdentity: $0.identity.hash)
    }
    await store.send(.node(.client(.endpoint(.ble(.delegate(.adapterUnavailable(.unsupported)))))))
    #expect(store.state.bluetoothAlert == .unsupported)
}

/// A fresh connect attempt clears a stale alert — the user may have granted permission and is
/// retrying, so the denial must not stick on screen past the next attempt (it re-fires if still
/// denied). Without this, a one-time denial would be shown forever.
@MainActor @Test func connectClearsStaleBluetoothAlert() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.$bleEnabled.withLock { $0 = true }
        s.bluetoothAlert = .permissionDenied
    }
    await store.send(.connectTapped)
    #expect(store.state.bluetoothAlert == nil)
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

// MARK: - Per-interface connection model (A4)

/// The headline A4 fix: with BLE and TCP both up, a BLE peer dropping must NOT mark the whole app
/// offline. Before this, ANY `interfaceDisconnected` set `connection = .disconnected`, so one BLE
/// peer walking away would flip the status to Disconnected while the TCP node stayed healthy.
@MainActor @Test func bleDropKeepsConnectedWhileTCPIsUp() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    let blePeer = bleInterfaceID(Data(repeating: 0xAB, count: 16))

    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(blePeer, .ble))))))
    #expect(store.state.connection == .connected)

    // The BLE peer drops — TCP is still up, so the app stays connected.
    await store.send(.node(.client(.endpoint(.transport(.interfaceDisconnected(blePeer))))))
    #expect(store.state.connection == .connected,
            "a BLE peer dropping must not mark the app offline while TCP is healthy")

    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// When the LAST connected interface drops, the app is disconnected. This is the other half of the
/// per-interface model: status is "any interface up", so emptying the set flips to disconnected.
@MainActor @Test func lastInterfaceDropMarksDisconnected() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    #expect(store.state.connection == .connected)
    await store.send(.node(.client(.endpoint(.transport(.interfaceDisconnected(InterfaceID("tcp")))))))
    #expect(store.state.connection == .disconnected,
            "the last interface dropping must mark the app disconnected")
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// Foreground re-dial keys on the TCP interface specifically, not "any interface up". A live BLE
/// peer must NOT suppress the TCP re-dial: iOS tears the TCP socket down while suspended, and if a
/// BLE peer held `connection == .connected` the socket would never be rebuilt.
@MainActor @Test func foregroundReDialsWhenTCPDownEvenWithBLEPeerUp() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { $0.$bleEnabled.withLock { $0 = true } }
    let blePeer = bleInterfaceID(Data(repeating: 0xCD, count: 16))
    // Only a BLE peer is up; TCP is not in the connected set.
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(blePeer, .ble))))))
    #expect(store.state.connection == .connected)
    await store.skipReceivedActions(strict: false)

    await store.send(.foregrounded) { $0.connection = .connecting }
    await store.receive { if case .node(.client(.endpoint(.start))) = $0 { return true }; return false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// Conversely, when TCP is up, foreground must NOT re-dial — re-dialling a healthy socket would tear
/// down every live link on each app switch (the original reason `.foregrounded` guards).
@MainActor @Test func foregroundDoesNotReDialWhenTCPIsUp() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    #expect(store.state.connection == .connected)
    await store.skipReceivedActions(strict: false)

    await store.send(.foregrounded)   // no state change, no start effect
    #expect(store.state.connection == .connected)
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

@MainActor
@Test func openConversationLoadsThatPeersThread() async {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [msg(1, peerA, "a1", 1000), msg(2, peerA, "a2", 1500), msg(3, peerB, "b1", 2000)])
    let store = makeStore(db, identity: Identity())
    await store.send(.openConversation(peerA))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.openPeerHex == peerA)
    #expect(store.state.threadMessages.count == 2)
    #expect(store.state.threadMessages.allSatisfy { $0.peerHex == peerA })
    #expect(store.state.threadMessages.map(\.body) == ["a1", "a2"])   // timestamp order
}

@MainActor
@Test func sendPersistsToOpenPeerAndReloadsBoth() async {
    let db = try! AppDatabase.makeInMemory()
    let identity = Identity()
    let store = makeStore(db, identity: identity) { state in
        state.openPeerHex = peerA
        state.draft = "hello"
    }
    await store.send(.sendTapped)
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, alsoViaPropagation))) = action {
            #expect(msg.destinationHash == Data(hexString: peerA))
            #expect(msg.content == Data("hello".utf8))
            #expect(alsoViaPropagation == false)
            return true
        }
        return false
    }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let rows = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.isOutgoing == true)
    #expect(rows.first?.body == "hello")
    #expect(store.state.threadMessages.contains { $0.body == "hello" })
    #expect(store.state.conversations.first?.peerHex == peerA)
    #expect(store.state.draft == "")
}

@MainActor
@Test func receivedFromOpenPeerReloadsThread() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderDeliveryHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let store = makeStore(db, identity: me) { state in
        state.openPeerHex = senderDeliveryHex
    }
    let m = LXMessage.create(
        source: sender,
        destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1700000000.5,
        title: Data(),
        content: Data("hi".utf8)
    )
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadMessages.contains { $0.body == "hi" })
}

@MainActor
@Test func receivedFromOtherPeerDoesNotReloadThread() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    // A different peer's thread is open, with a sentinel already loaded.
    let sentinel = [msg(1, peerA, "sentinel", 1000)]
    let store = makeStore(db, identity: me) { state in
        state.openPeerHex = peerA
        state.threadMessages = sentinel
    }
    let m = LXMessage.create(
        source: sender,
        destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1700000000.5,
        title: Data(),
        content: Data("elsewhere".utf8)
    )
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    // Drain any remaining in-flight effects and pending received actions (non-strict: ok if none).
    await store.finish()
    await store.skipReceivedActions(strict: false)
    // No threadLoaded should arrive; the open thread is untouched.
    #expect(store.state.threadMessages == sentinel)
}

@MainActor
@Test func deliveryFailedMarksFailedAndReloads() async {
    let db = try! AppDatabase.makeInMemory()
    let identity = Identity()
    let store = makeStore(db, identity: identity) { state in
        state.openPeerHex = peerA
        state.draft = "hello"
    }
    await store.send(.sendTapped)
    await store.receive { if case .node(.client(.sendMessage)) = $0 { return true }; return false }
    let sent = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }
    let hashHex = sent.first!.messageHash
    let hashData = Data(hexString: hashHex)!
    await store.send(.node(.client(.delegate(.deliveryFailed(messageHash: hashData)))))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    let failed = store.state.threadMessages.first { $0.messageHash == hashHex }
    #expect(failed?.status == MessageStatus.failed)
}

@MainActor
@Test func pathLearnedMarksPeerReachable() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    let h = Data(repeating: 0xAB, count: 16)
    await store.send(.node(.client(.endpoint(.delegate(.pathLearned(destinationHash: h, hops: 1))))))
    #expect(store.state.reachablePeers.contains(h.hexString))
}

@MainActor
@Test func startConversationRejectsInvalidHex() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.startConversation("nothex"))
    #expect(store.state.openPeerHex == nil)
    await store.send(.startConversation(String(repeating: "a", count: 10)))   // 5 bytes, too short
    #expect(store.state.openPeerHex == nil)
    // A valid 16-byte hex is accepted.
    await store.send(.startConversation(peerA))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.openPeerHex == peerA)
}

private let pnHex = String(repeating: "c", count: 32)   // valid 16-byte hex

@MainActor @Test func sendWithPropagationNodeUsesSendMessageBoth() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "hi"
        s.$propagationNodeHex.withLock { $0 = pnHex }
    }
    await store.send(.sendTapped)
    await store.receive { action in
        if case let .node(.client(.sendMessage(_, alsoViaPropagation))) = action { return alsoViaPropagation }
        return false
    }
}

@MainActor @Test func sendWithoutPropagationNodeUsesSendMessageDirectOnly() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "hi"
    }
    await store.send(.sendTapped)
    await store.receive { action in
        if case let .node(.client(.sendMessage(_, alsoViaPropagation))) = action { return !alsoViaPropagation }
        return false
    }
}

@MainActor @Test func interfaceConnectedWithPNConfiguresAndSyncs() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.$propagationNodeHex.withLock { $0 = pnHex }
    }
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    await store.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    await store.receive { if case .node(.client(.setPropagationNode)) = $0 { return true }; return false }
    await store.receive { if case .node(.client(.syncFromPropagationNode)) = $0 { return true }; return false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.router.outboundPropagationNode == Data(hexString: pnHex))
}

/// On connect, the app sets its delivery display name **before** registering the delivery
/// destination — so the registration announce carries the name and reference clients (Sideband,
/// NomadNet) show something other than an unnamed node.
///
/// **Nothing pinned this line.** Before this test, `grep displayName AppFeatureTests.swift` returned
/// zero hits, and both `interfaceConnected…` tests above use predicate-`receive`, which *skips*
/// non-matching actions — so deleting the `.setDisplayName` call from `AppFeature` left the entire
/// suite green while every ReTiCA node on the network went back to being anonymous.
///
/// The ORDER is asserted, not just the presence: `receive(predicate:)` resumes after the previous
/// match, so matching `.setDisplayName` first and `.registerDelivery` second fails if the two are
/// swapped. `registerDelivery` packs the app-data from `State.displayName` at call time, so a
/// name set afterwards would not be in the announce that actually goes out.
///
/// Three cases are tested, all on the LAUNCH path (`interfaceConnected`): an empty displayName
/// sends nil — the correct "no name" signal, since LXMFAnnounceData.pack encodes non-nil as msgpack
/// bin and "" would advertise a zero-length name; a WHITESPACE-ONLY name is empty for that same
/// purpose (nothing on the emit path trims, and the receiver's strip turns "   " into exactly the
/// empty label the rule exists to prevent); and a real name is sent as-is.
///
/// Scope note: this test covers the launch path ONLY. The app-level `.setDisplayName` SETTER — which
/// re-announces via `.announceDelivery` so running nodes see a change without reconnecting, and which
/// applies the same trim — is NOT exercised here and, as of this test, is covered by nothing. An
/// earlier version of this docstring asserted that re-announce behaviour as though it were tested,
/// which is the "claims two, asserts one" shape in prose rather than in a name.
///
/// Each case sets `$displayName` explicitly rather than relying on the default, because all three
/// stores share one `.appStorage("displayName")` backing store — a default-valued store would
/// otherwise inherit the previous case's name and pass for the wrong reason.
@MainActor @Test func interfaceConnectedSetsTheDisplayNameBeforeRegisteringDelivery() async {
    let db = try! AppDatabase.makeInMemory()

    // Case 1: empty displayName → nil is sent (not "")
    let store = makeStore(db, identity: Identity()) { state in
        state.$displayName.withLock { $0 = "" }
    }
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    await store.receive { action in
        if case let .node(.client(.setDisplayName(name, stampCost))) = action {
            #expect(name == nil)           // empty displayName → nil, not ""
            #expect(stampCost == nil)      // no inbound cost is advertised today
            return true
        }
        return false
    }
    await store.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    #expect(store.state.node.client.displayName == nil)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    // Case 2: non-empty displayName → the name string is sent
    let store2 = makeStore(db, identity: Identity()) { state in
        state.$displayName.withLock { $0 = "Alice" }
    }
    await store2.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    await store2.receive { action in
        if case let .node(.client(.setDisplayName(name, stampCost))) = action {
            #expect(name == "Alice")
            #expect(stampCost == nil)
            return true
        }
        return false
    }
    await store2.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    #expect(store2.state.node.client.displayName == "Alice")
    await store2.finish()
    await store2.skipReceivedActions(strict: false)

    // Case 3: whitespace-only displayName → nil, exactly as if it were empty. Without the trim this
    // announces "   ", which the reference strips to "" — an empty label, not an absent one.
    let store3 = makeStore(db, identity: Identity()) { state in
        state.$displayName.withLock { $0 = "   " }
    }
    await store3.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    await store3.receive { action in
        if case let .node(.client(.setDisplayName(name, stampCost))) = action {
            #expect(name == nil)
            #expect(stampCost == nil)
            return true
        }
        return false
    }
    await store3.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    #expect(store3.state.node.client.displayName == nil)
    await store3.finish()
    await store3.skipReceivedActions(strict: false)
}

/// Setting a name from Settings persists it AND re-announces, and **clearing it does the same**.
///
/// The clearing half is the one that matters. The first version of the `.setDisplayName` handler
/// read `guard !name.isEmpty else { return .none }`, so clearing your name updated local state and
/// told the network nothing — every peer kept showing the old name forever. That is precisely the
/// defect this whole feature exists to fix (state changed locally, announce never updated), and it
/// survived because the only display-name coverage was the *launch* path above, not this setter.
///
/// Anti-vacuity: each case asserts on the emitted `.setDisplayName` **payload** and on
/// `.announceDelivery` actually being sent. A state-only assertion (`store.state.displayName`)
/// would pass even if nothing reached the network, which is the exact bug being pinned.
@MainActor @Test func setDisplayNameReAnnounces_includingWhenCleared() async {
    let db = try! AppDatabase.makeInMemory()

    // Set a name → the name is advertised, and an announce is emitted.
    let store = makeStore(db, identity: Identity())
    await store.send(.setDisplayName("Bob"))
    #expect(store.state.displayName == "Bob")
    await store.receive { action in
        if case let .node(.client(.setDisplayName(name, _))) = action {
            #expect(name == "Bob")
            return true
        }
        return false
    }
    await store.receive { if case .node(.client(.announceDelivery)) = $0 { return true }; return false }
    await store.finish()
    await store.skipReceivedActions(strict: false)

    // Clear it → nil is advertised, and an announce is STILL emitted so peers stop showing "Bob".
    let store2 = makeStore(db, identity: Identity()) { state in
        state.$displayName.withLock { $0 = "Bob" }
    }
    await store2.send(.setDisplayName(""))
    #expect(store2.state.displayName == "")
    await store2.receive { action in
        if case let .node(.client(.setDisplayName(name, _))) = action {
            #expect(name == nil)           // cleared → nil, not ""
            return true
        }
        return false
    }
    await store2.receive { if case .node(.client(.announceDelivery)) = $0 { return true }; return false }
    await store2.finish()
    await store2.skipReceivedActions(strict: false)

    // A whitespace-only name is a CLEAR, not a name. The trimmed value is what gets persisted, so
    // `displayName.isEmpty` stays a correct "no name set" test for the UI and state matches the wire.
    let store3 = makeStore(db, identity: Identity()) { state in
        state.$displayName.withLock { $0 = "Bob" }
    }
    await store3.send(.setDisplayName("   "))
    #expect(store3.state.displayName == "")     // persisted TRIMMED, not "   "
    await store3.receive { action in
        if case let .node(.client(.setDisplayName(name, _))) = action {
            #expect(name == nil)                // whitespace-only → nil, not "   "
            return true
        }
        return false
    }
    await store3.receive { if case .node(.client(.announceDelivery)) = $0 { return true }; return false }
    await store3.finish()
    await store3.skipReceivedActions(strict: false)
}

@MainActor @Test func interfaceConnectedWithoutPNDoesNotConfigure() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    await store.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.router.outboundPropagationNode == nil)
}

@MainActor @Test func setPropagationNodePersistsAndConfigures() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.setPropagationNode(pnHex))
    await store.receive { if case .node(.client(.syncFromPropagationNode)) = $0 { return true }; return false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.propagationNodeHex == pnHex)
    #expect(store.state.node.client.router.outboundPropagationNode == Data(hexString: pnHex))
}

/// The app's initial minStampCost equals the LXMF library default — not a development shortcut.
/// This pins advertised-equals-enforced: the same constant feeds both the announce app-data and
/// the inbound-offer validator (see LXMFServiceNode.State.init comment).
/// `LXMFServiceNode.State.minStampCost` was removed in `08f1931` (single source of truth lives at
/// `pn.store.minStampCost`); test updated accordingly (`AppFeatureTests`, `defaultStampCostIsProductionDefault`).
@MainActor @Test func defaultStampCostIsProductionDefault() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    #expect(store.state.node.pn.store.minStampCost == LXMFPropagation.defaultPropagationStampCost)
}

/// Turning node-mode on enables serving and registers/announces lxmf.propagation.
@MainActor @Test func nodeModeToggleEnablesServing() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.setNodeMode(true))
    await store.receive { if case .node(.setNodeMode(true)) = $0 { return true }; return false }
    #expect(store.state.nodeModeEnabled == true)
    #expect(store.state.node.nodeModeEnabled == true)
}

/// On connect, a persisted node-mode setting is applied — the node serves again after relaunch.
@MainActor @Test func persistedNodeModeIsAppliedOnConnect() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { $0.$nodeModeEnabled.withLock { $0 = true } }
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    await store.receive { if case .node(.setNodeMode(true)) = $0 { return true }; return false }
}

// MARK: - Relay mode (R1)

/// Turning relay mode ON installs this device's identity as the transport identity (the value every
/// relay branch in `Transport` gates on) AND enables recursive path requests, so the node can both
/// forward transit traffic and answer path requests for destinations it hasn't heard directly. The
/// identity is asserted to be THIS device's, not just "some identity" — passing the wrong identity
/// would sign relayed packets as someone else.
@MainActor @Test func relayModeToggleEnablesRelayAndRecursivePaths() async throws {
    let db = try AppDatabase.makeInMemory()
    let identity = Identity()
    let store = makeStore(db, identity: identity) { $0.$relayEnabled.withLock { $0 = false } }
    await store.send(.setRelayMode(true))
    #expect(store.state.relayEnabled == true)
    await store.receive { action in
        if case let .node(.client(.endpoint(.enableRelay(id)))) = action {
            #expect(id == identity)   // OUR identity — a relay signs transit with it
            return true
        }
        return false
    }
    await store.receive { action in
        if case .node(.client(.endpoint(.transport(.setRecursivePathRequests(true))))) = action { return true }
        return false
    }
}

/// Turning relay mode OFF clears the transport identity (relaying goes back to dead) and disables
/// recursive path requests, so the device stops answering path requests for third parties. Clearing
/// is the half that matters: leaving the identity installed would keep the node relaying after the
/// user opted out.
@MainActor @Test func relayModeToggleOffClearsTransportIdentityAndRecursivePaths() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { $0.$relayEnabled.withLock { $0 = true } }
    await store.send(.setRelayMode(false))
    #expect(store.state.relayEnabled == false)
    await store.receive { action in
        if case let .node(.client(.endpoint(.transport(.setTransportIdentity(id))))) = action {
            #expect(id == nil)   // cleared, not left installed
            return true
        }
        return false
    }
    await store.receive { action in
        if case .node(.client(.endpoint(.transport(.setRecursivePathRequests(false))))) = action { return true }
        return false
    }
}

/// On connect, a persisted relay-mode setting is applied — the node relays again after relaunch.
/// Without this, `relayEnabled` would survive in @Shared storage but never reach `Transport`, so a
/// user who turned relay on once would silently stop relaying on the next launch.
@MainActor @Test func persistedRelayModeIsAppliedOnConnect() async throws {
    let db = try AppDatabase.makeInMemory()
    let identity = Identity()
    let store = makeStore(db, identity: identity) { $0.$relayEnabled.withLock { $0 = true } }
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    await store.receive { action in
        if case let .node(.client(.endpoint(.enableRelay(id)))) = action {
            #expect(id == identity)
            return true
        }
        return false
    }
    await store.receive { action in
        if case .node(.client(.endpoint(.transport(.setRecursivePathRequests(true))))) = action { return true }
        return false
    }
}

/// With relay mode OFF (the default), connecting must NOT install a transport identity or enable
/// recursive path requests — relaying stays dead code until the user opts in. This is the
/// anti-vacuity guard for the connect path: without it, `persistedRelayModeIsAppliedOnConnect` could
/// pass simply because the app always enables relay.
@MainActor @Test func relayNotAppliedOnConnectWhenDisabled() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { $0.$relayEnabled.withLock { $0 = false } }
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    await store.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.transport.transportIdentity == nil)
    #expect(store.state.node.client.endpoint.transport.recursivePathRequests == false)
}

@MainActor @Test func setPropagationNodeInvalidDoesNotConfigure() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.setPropagationNode("nothex"))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.router.outboundPropagationNode == nil)
}

@MainActor @Test func syncTappedRequestsSync() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.syncTapped)
    await store.receive { if case .node(.client(.syncFromPropagationNode)) = $0 { return true }; return false }
}

@MainActor @Test func announceTappedReAnnouncesDelivery() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.announceTapped)
    await store.receive { if case .node(.client(.announceDelivery)) = $0 { return true }; return false }
}

@MainActor @Test func propagationAcceptedMarksStored() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "hi"
    }
    await store.send(.sendTapped)
    await store.receive { if case .node(.client(.sendMessage)) = $0 { return true }; return false }
    let sent = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }
    let hashHex = sent.first!.messageHash
    let hashData = Data(hexString: hashHex)!
    await store.send(.node(.client(.delegate(.propagationAccepted(messageHash: hashData)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadMessages.first { $0.messageHash == hashHex }?.status == MessageStatus.propagated)
}

/// F5.5: with a PN configured, one message.hash gets TWO copies. The propagated copy can succeed
/// (`propagationAccepted` → "stored"). ReTiCA now proves opportunistic sends and never reports
/// `deliveryFailed` after a success, but the app keeps the guard as a defensive check: a late
/// failure must NOT clobber the propagation success, or a message that was in fact stored on the
/// PN is shown as failed.
@MainActor @Test func deliveryFailedDoesNotOverwriteAPropagationSuccess() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "hi"
    }
    await store.send(.sendTapped)
    await store.receive { if case .node(.client(.sendMessage)) = $0 { return true }; return false }
    let sent = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }
    let hashHex = sent.first!.messageHash
    let hashData = Data(hexString: hashHex)!
    // Propagation leg accepts first. Drain conversationsLoaded first so the stale "sending"
    // threadLoaded from the sendTapped saga is dropped before we read the updated one.
    await store.send(.node(.client(.delegate(.propagationAccepted(messageHash: hashData)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadMessages.first { $0.messageHash == hashHex }?.status == MessageStatus.propagated)
    // Opportunistic leg times out afterwards — the success must survive.
    await store.send(.node(.client(.delegate(.deliveryFailed(messageHash: hashData)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadMessages.first { $0.messageHash == hashHex }?.status == MessageStatus.propagated,
            "a propagated message must not be marked failed when the opportunistic leg times out")
}

// MARK: - Hash-keyed status updates scoped to outgoing rows (final-review Fix A)

/// `messageHash` alone is not unique: an incoming row and an outgoing row can share a hash (a
/// conversation with your own address). `deliveryFailed` must only rewrite the outgoing row's
/// status, not the incoming row that happens to share the same hash.
@MainActor @Test func deliveryFailedOnlyTouchesOutgoingRow() async {
    let db = try! AppDatabase.makeInMemory()
    let sharedHash = String(repeating: "d", count: 32)
    try! await seed(db, [
        msg(1, peerA, "outgoing", 1000, outgoing: true, status: MessageStatus.sending, hash: sharedHash),
        msg(2, peerA, "incoming", 1000, outgoing: false, status: MessageStatus.received, hash: sharedHash),
    ])
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.delegate(.deliveryFailed(messageHash: Data(hexString: sharedHash)!)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try! await db.read { try Message.where { $0.messageHash.eq(sharedHash) }.fetchAll($0) }
    #expect(rows.first { $0.isOutgoing }?.status == MessageStatus.failed)
    #expect(rows.first { !$0.isOutgoing }?.status == MessageStatus.received)
}

/// Same hash-collision hazard for `propagationAccepted`.
@MainActor @Test func propagationAcceptedOnlyTouchesOutgoingRow() async {
    let db = try! AppDatabase.makeInMemory()
    let sharedHash = String(repeating: "e", count: 32)
    try! await seed(db, [
        msg(1, peerA, "outgoing", 1000, outgoing: true, status: MessageStatus.sending, hash: sharedHash),
        msg(2, peerA, "incoming", 1000, outgoing: false, status: MessageStatus.received, hash: sharedHash),
    ])
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.delegate(.propagationAccepted(messageHash: Data(hexString: sharedHash)!)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try! await db.read { try Message.where { $0.messageHash.eq(sharedHash) }.fetchAll($0) }
    #expect(rows.first { $0.isOutgoing }?.status == MessageStatus.propagated)
    #expect(rows.first { !$0.isOutgoing }?.status == MessageStatus.received)
}

// MARK: - Delivery proofs (ReTiCA single-packet proofs final-review F1)

/// ReTiCA now proves opportunistic sends, so a proving peer yields `deliveryConfirmed` and never
/// a later `deliveryFailed`. The outgoing row must move off "sending" to "delivered" and the
/// thread must reload, or a delivered message reads "sending" forever.
@MainActor @Test func deliveryConfirmedMarksDeliveredAndReloads() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "hi"
    }
    await store.send(.sendTapped)
    await store.receive { if case .node(.client(.sendMessage)) = $0 { return true }; return false }
    let sent = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }
    let hashHex = sent.first!.messageHash
    let hashData = Data(hexString: hashHex)!
    // Drain conversationsLoaded first so the stale "sending" threadLoaded from the sendTapped
    // saga is dropped before we read the updated one.
    await store.send(.node(.client(.delegate(.deliveryConfirmed(messageHash: hashData)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadMessages.first { $0.messageHash == hashHex }?.status == MessageStatus.delivered)
}

/// Same hash-collision hazard as `deliveryFailed`/`propagationAccepted`: only the outgoing row
/// sharing the hash may be marked delivered. The incoming row must keep "received".
@MainActor @Test func deliveryConfirmedOnlyTouchesOutgoingRow() async {
    let db = try! AppDatabase.makeInMemory()
    let sharedHash = String(repeating: "f", count: 32)
    try! await seed(db, [
        msg(1, peerA, "outgoing", 1000, outgoing: true, status: MessageStatus.sending, hash: sharedHash),
        msg(2, peerA, "incoming", 1000, outgoing: false, status: MessageStatus.received, hash: sharedHash),
    ])
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.delegate(.deliveryConfirmed(messageHash: Data(hexString: sharedHash)!)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try! await db.read { try Message.where { $0.messageHash.eq(sharedHash) }.fetchAll($0) }
    #expect(rows.first { $0.isOutgoing }?.status == MessageStatus.delivered)
    #expect(rows.first { !$0.isOutgoing }?.status == MessageStatus.received)
}

/// With a PN configured, the propagated copy can be accepted after the delivery copy was
/// already proved. Delivered beats stored: the row must stay "delivered".
@MainActor @Test func propagationAcceptedDoesNotOverwriteADelivery() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "1", count: 32)
    try! await seed(db, [msg(1, peerA, "outgoing", 1000, outgoing: true, status: MessageStatus.delivered, hash: hash)])
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.delegate(.propagationAccepted(messageHash: Data(hexString: hash)!)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try! await db.read { try Message.where { $0.messageHash.eq(hash) }.fetchAll($0) }
    #expect(rows.first?.status == MessageStatus.delivered,
            "a late propagationAccepted must not downgrade a delivered message to stored")
}

/// The router never reports failure after a success, but the app guards anyway: a
/// `deliveryFailed` arriving for a delivered row must leave it "delivered".
@MainActor @Test func deliveryFailedDoesNotOverwriteADelivery() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "2", count: 32)
    try! await seed(db, [msg(1, peerA, "outgoing", 1000, outgoing: true, status: MessageStatus.delivered, hash: hash)])
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.delegate(.deliveryFailed(messageHash: Data(hexString: hash)!)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try! await db.read { try Message.where { $0.messageHash.eq(hash) }.fetchAll($0) }
    #expect(rows.first?.status == MessageStatus.delivered,
            "a deliveryFailed must not mark a delivered message failed")
}

// MARK: - Propagation persistence (Task 7)

/// Ingested entries are mirrored to the database so they survive relaunch.
@MainActor @Test func storedPropagationEntriesArePersisted() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    let tid = Data(repeating: 0x11, count: 32)
    let dest = Data(repeating: 0xAA, count: 16)
    let bytes = dest + Data("payload".utf8)
    let entry = PropagationStore.Entry(transientId: tid, destinationHash: dest, lxmfData: bytes)

    await store.send(.node(.delegate(.messagesStored(entries: [entry]))))
    try await Task.sleep(nanoseconds: 50_000_000)

    let rows = try await db.read { try PropagationEntryRow.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows[0].transientIdHex == tid.hexString)
    #expect(rows[0].lxmfData == bytes)
}

/// Purged entries are deleted from the mirror, so the database cannot drift from the store.
@MainActor @Test func purgedPropagationEntriesAreDeleted() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    let tid = Data(repeating: 0x22, count: 32)
    let dest = Data(repeating: 0xBB, count: 16)
    let entry = PropagationStore.Entry(transientId: tid, destinationHash: dest,
                                       lxmfData: dest + Data("gone".utf8))

    await store.send(.node(.delegate(.messagesStored(entries: [entry]))))
    try await Task.sleep(nanoseconds: 50_000_000)
    await store.send(.node(.delegate(.messagesPurged(transientIds: [tid]))))
    try await Task.sleep(nanoseconds: 50_000_000)

    let rows = try await db.read { try PropagationEntryRow.all.fetchAll($0) }
    #expect(rows.isEmpty)
}

/// The `onLaunch` rehydration fetch orders by `storedAt` (Important-1) so that when the store evicts
/// over its cap it removes the oldest entries deterministically — the same entries each launch.
/// Verification: seed two entries with different `storedAt`, confirm the `rehydratePropagationStore`
/// action carries them oldest-first.
@MainActor @Test func propagationRehydrateUsesStoredAtOrder() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())

    let destA = Data(repeating: 0xAA, count: 16)
    let destB = Data(repeating: 0xBB, count: 16)
    let bytesA = destA + Data("older".utf8)
    let bytesB = destB + Data("newer".utf8)
    let tidA = Data(repeating: 0x11, count: 32)
    let tidB = Data(repeating: 0x22, count: 32)

    // Seed in reverse order (B first / newer storedAt, A second / older storedAt) so a naive
    // "fetch all, no ORDER BY" would return B before A and the test would catch the regression.
    try await db.write { db in
        try PropagationEntryRow.insert {
            PropagationEntryRow(transientIdHex: tidB.hexString,
                                destinationHashHex: destB.hexString,
                                lxmfData: bytesB,
                                storedAt: Date(timeIntervalSince1970: 1700000002.0))  // newer
        }.execute(db)
        try PropagationEntryRow.insert {
            PropagationEntryRow(transientIdHex: tidA.hexString,
                                destinationHashHex: destA.hexString,
                                lxmfData: bytesA,
                                storedAt: Date(timeIntervalSince1970: 1700000001.0))  // older
        }.execute(db)
    }

    await store.send(.onLaunch)
    var receivedData: [Data] = []
    await store.receive { action in
        if case let .rehydratePropagationStore(data) = action { receivedData = data; return true }
        return false
    }
    // Oldest first (storedAt=1700000001 < 1700000002), so bytesA must precede bytesB.
    #expect(receivedData.first == bytesA, "Expected older entry first")
    #expect(receivedData.last == bytesB, "Expected newer entry last")
}

/// On launch the persisted backlog is restored into the in-memory store, so the node serves it again.
/// This test is about REHYDRATION MECHANICS (entries survive relaunch), not the stamp-cost policy.
/// minStampCost is lowered to 4 in the configure closure so the cheap test fixture is accepted
/// without running expensive production-cost PoW, keeping the suite fast.
@MainActor @Test func propagationStoreRehydratesOnLaunch() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) {
        $0.$nodeModeEnabled.withLock { $0 = true }
        // Lower enforcement to match the cheap fixture stamp — this test is about rehydrate
        // mechanics, not the stamp cost policy (see defaultStampCostIsProductionDefault for that).
        // `LXMFServiceNode.State.minStampCost` was removed in `08f1931`; the single source of
        // truth is `pn.store.minStampCost` (`propagationStoreRehydratesOnLaunch`).
        $0.node.pn.store.minStampCost = 4
    }
    await store.send(.setNodeMode(true))

    // A real stamped entry so it survives the store's stamp enforcement.
    let recipient = Identity()
    let sender = Identity()
    let msg = LXMessage.create(source: sender,
                               destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("kept".utf8))
    // `pack` became `async` and Optional in ReTiCA `3e919ed`: the stamp search now yields so it
    // can be cancelled, and it returns nil when a peer's advertised cost exceeds our ceiling.
    // A cost of 4 is far below that ceiling, so the force-unwrap cannot fire here.
    let (container, tid) = await LXMFPropagation.pack(message: msg, recipientIdentity: recipient,
                                                      timestamp: 1700000000.5, stampCost: 4)!
    let entryBytes = LXMFPropagation.parseContainer(container)!.entries[0]

    try await db.write {
        try PropagationEntryRow.insert {
            PropagationEntryRow(transientIdHex: tid.hexString,
                                destinationHashHex: LXMFPropagation.destinationHash(lxmfData: entryBytes)!.hexString,
                                lxmfData: entryBytes,
                                storedAt: Date(timeIntervalSince1970: 1700000000.5))
        }.execute($0)
    }

    await store.send(.onLaunch)
    // Wait for the rehydration action to be dispatched and processed.
    await store.receive { if case .rehydratePropagationStore = $0 { return true }; return false }
    // Drain any remaining in-flight effects from the ingestContainer dispatch.
    try await Task.sleep(nanoseconds: 50_000_000)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.pn.store.contains(transientId: tid))
}

// MARK: - Dedup durability (Task 3)

/// A message delivered in a previous session is NOT re-delivered after restart.
///
/// Mechanism: `.messageReceived` writes the message hash to `seenHashRows`; on the next launch
/// `.onLaunch` reads those rows and sends `.rehydrateDedup`, which fills the router's `seen`
/// ring BEFORE any network traffic arrives. When the same message arrives again, the router
/// deduplicates it — the app's `messageReceived` delegate is NOT raised and the DB stays at
/// one row, not two.
///
/// The "restart" is a new TestStore over the same database — the canonical pattern established by
/// `propagationStoreRehydratesOnLaunch`. Each clause of the compound test name has its own
/// assertion and its own mutation that kills it.
///
/// Anti-vacuity (three clauses):
///   "hash is persisted": `seenHashRows` has the row after session 1 (mutation: remove write).
///   "rehydrateDedup carries the hash": the action's payload contains the hash (mutation: remove
///     the read from `.onLaunch`).
///   "not re-delivered": the DB has 1 message row after the same message arrives again in
///     session 2 (mutation: remove the rehydrateDedup forward to the library reducer — the ring
///     starts empty and the message re-delivers, adding a second DB row).
@MainActor @Test func deliveredMessageIsNotReDeliveredAfterRestart() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()

    // --- Session 1: receive a message (writes hash to seenHashRows) ---
    let store1 = makeStore(db, identity: me)
    let m = LXMessage.create(
        source: sender,
        destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1700000000.5,
        title: Data(),
        content: Data("hello".utf8)
    )
    await store1.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store1.receive { if case .conversationsLoaded = $0 { return true }; return false }
    try await Task.sleep(nanoseconds: 50_000_000)

    // Clause 1: hash must be persisted. Mutation: remove SeenHashRow write → count == 0.
    let seenRows = try await db.read { try SeenHashRow.all.fetchAll($0) }
    #expect(seenRows.count == 1, "Hash must be persisted before restart")
    #expect(seenRows.first?.hashHex == m.hash.hexString)

    // Also persist a downloaded transient id, so the restart can assert BOTH halves of the dedup
    // state. Driven through the real action rather than inserted directly, so the write path is
    // exercised too.
    let storedTransientId = Data(repeating: 0xC7, count: 32)
    await store1.send(.node(.client(.router(.messagesDownloaded(transientIds: [storedTransientId])))))
    try await Task.sleep(nanoseconds: 50_000_000)
    let tidRows = try await db.read { try DownloadedTransientIdRow.all.fetchAll($0) }
    #expect(tidRows.contains { $0.transientIdHex == storedTransientId.hexString },
            "transient id must be persisted before restart")
    await store1.finish()
    await store1.skipReceivedActions(strict: false)

    // --- Session 2: restart — new store, same DB ---
    let store2 = makeStore(db, identity: me)
    await store2.send(.onLaunch)
    // Clause 2: rehydrateDedup must carry the persisted hash.
    // Mutation: remove the seenHashRow read from onLaunch → the action has an empty hashes array.
    var capturedSeenHashes: [Data] = []
    var capturedTransientIds: [Data] = []
    await store2.receive { action in
        if case let .rehydrateDedup(hashes, tids) = action {
            capturedSeenHashes = hashes
            capturedTransientIds = tids
            return true
        }
        return false
    }
    #expect(capturedSeenHashes.contains(m.hash),
            "rehydrateDedup must carry the persisted hash")
    // The transient-id half was previously discarded here, and a review proved the omission
    // mattered: stubbing the launch read to `[]` left ALL 49 tests green. That is half the
    // duplicate-delivery problem this slice exists to solve — the seen ring stops a message being
    // re-DELIVERED, while the transient-id set is what stops the propagation node re-SENDING it in
    // the first place. Asserting only the first is the name-claims-two-asserts-one shape.
    #expect(capturedTransientIds.contains(storedTransientId),
            "rehydrateDedup must carry the persisted transient id, not just the message hash")
    try await Task.sleep(nanoseconds: 50_000_000)
    await store2.skipReceivedActions(strict: false)

    // Clause 3: the same message arriving again must NOT produce a second DB row.
    // We replay the message via the router's `.received` action (bypassing LXMFNode so we test
    // the ring directly). The router's seen ring — pre-filled by rehydrateDedup — deduplicates
    // it; no `.messageDelivered` delegate fires; `messageReceived` is not dispatched; the DB
    // stays at 1 message row.
    // Mutation: remove the forward of `.rehydrateDedup` to the library (the `case .rehydrateDedup`
    // handler) → ring starts empty → message re-delivers → count becomes 2.
    await store2.send(.node(.client(.router(.received(
        method: .opportunistic,
        destinationHash: m.destinationHash,
        data: m.opportunisticPayload
    )))))
    await store2.finish()
    await store2.skipReceivedActions(strict: false)
    let allMessages = try await db.read { try Message.fetchAll($0) }
    #expect(allMessages.count == 1, "Message must not be re-delivered (router dedup prevented it)")
}

/// Persisted seen-hash rows are pruned to `RingSet.capacity` (10 000).
/// The transient-id table is NOT pruned (unbounded by ruling).
///
/// The test inserts (capacity + 2) hashes and confirms the table is trimmed to exactly capacity.
/// It also inserts 3 transient IDs and confirms all 3 survive (no pruning).
///
/// Anti-vacuity: the count assertion fails if `pruneSeenHashes` is never called (table grows
/// to capacity+2). Mutation: removing the prune call leaves the count at capacity+2 and fails the
/// first `#expect`.
@MainActor @Test func seenHashRowsArePrunedToRingCapacity() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me)

    // Insert (capacity + 2) seen-hash rows directly to avoid stamping 10_002 real messages.
    // storedAt is set so ordering is well-defined: row i has storedAt = epoch + i seconds.
    let capacity = 10_000
    try await db.write { database in
        for i in 0..<(capacity + 2) {
            let hashHex = Data(repeating: UInt8(i & 0xFF), count: 31) + Data([UInt8((i >> 8) & 0xFF)])
            try SeenHashRow.insert {
                SeenHashRow(hashHex: hashHex.hexString,
                            storedAt: Date(timeIntervalSince1970: Double(i)))
            }.execute(database)
        }
    }

    // Deliver one real message — its write path calls pruneSeenHashes.
    let sender = Identity()
    let m = LXMessage.create(source: sender,
                              destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                              timestamp: 1700000000.5, title: Data(), content: Data("x".utf8))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    try await Task.sleep(nanoseconds: 50_000_000)

    // After the prune the table must have exactly `capacity` rows (the real message takes one slot,
    // so the pre-seeded rows are cut to capacity-1, and total = capacity).
    let seenCount = try await db.read { try SeenHashRow.all.fetchAll($0) }.count
    #expect(seenCount == capacity, "Table must be pruned to RingSet.capacity")

    // Now insert 3 transient IDs and confirm none are pruned.
    let tid1 = Data(repeating: 0xA1, count: 32)
    let tid2 = Data(repeating: 0xA2, count: 32)
    let tid3 = Data(repeating: 0xA3, count: 32)
    await store.send(.node(.client(.router(.messagesDownloaded(transientIds: [tid1, tid2, tid3])))))
    try await Task.sleep(nanoseconds: 50_000_000)
    let tidCount = try await db.read { try DownloadedTransientIdRow.all.fetchAll($0) }.count
    #expect(tidCount == 3, "Transient-ID table must NOT be pruned")
}

/// A peer's stamp cost survives a restart and the post-restart send carries a stamp.
///
/// Mechanism: `.pathLearned` for a delivery-destination announce writes `LearnedPeerRow`; on the
/// next launch `.rehydrateLearnedPeers` restores `LXMFNode.State.learnedPeers`; when a message
/// is sent to that peer `LXMFNode.deliverySend` finds the entry and generates a stamp.
///
/// Stamp generation at cost ≤ 10 is fast (expected ~2^10 = 1024 hash rounds vs ~2^20 for cost 20).
/// We verify the stamp is present on the SENT message by reconstructing it from the
/// `.sendOpportunistic` delegate payload: `opportunisticPayload = message.packed.dropFirst(16)`,
/// so `LXMessage.fromOpportunistic(destinationHash:payload:)` returns the stamped message.
///
/// Anti-vacuity (two clauses, each with its own mutation):
///   "stamp cost survives restart": the `LearnedPeerRow` exists after session 1.
///     Mutation 1: remove the LearnedPeerRow write → peerRows is empty → first #expect fails.
///   "send carries a stamp": the reconstructed message in session 2 has a non-nil stamp.
///     Mutation 2: remove the rehydrateLearnedPeers forward to the library → learnedPeers is
///     empty after restart → deliverySend finds no cost → message is sent without a stamp →
///     reconstructed.stamp is nil → second #expect fails.
///   These mutations kill different assertions, confirming there is no shared vacuity.
@MainActor @Test func peerStampCostSurvivesRestartAndIsSpent() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let peer = Identity()
    let peerDeliveryHash = LXMessage.deliveryHash(identityHash: peer.hash)
    let peerDeliveryHex = peerDeliveryHash.hexString
    let stampCost = 8    // low cost — fast generation, well below the 20-round ceiling

    // --- Session 1: simulate an announce from peer (writes LearnedPeerRow) ---
    let store1 = makeStore(db, identity: me)
    // Prime the LXMFNode state with the peer's stamp cost by sending the library action first
    // (this does NOT write to the DB — it only updates in-memory state), then fire `pathLearned`
    // so the AppFeature handler reads the entry and writes it to the DB.
    let learnedPeer = LXMFNode.LearnedPeer(
        displayName: "Peer",
        stampCost: stampCost,
        supportsCompression: false,
        learnedAt: Date(timeIntervalSince1970: 1700000000)
    )
    await store1.send(.node(.client(.rehydrateLearnedPeers([peerDeliveryHash: learnedPeer]))))
    await store1.send(.node(.client(.endpoint(.delegate(.pathLearned(destinationHash: peerDeliveryHash, hops: 1))))))
    try await Task.sleep(nanoseconds: 50_000_000)
    await store1.skipReceivedActions(strict: false)

    // Clause 1: verify the row was written.
    // Mutation 1: remove the LearnedPeerRow write from the pathLearned handler → count == 0.
    let peerRows = try await db.read { try LearnedPeerRow.all.fetchAll($0) }
    #expect(peerRows.count == 1, "LearnedPeerRow must be written on pathLearned")
    let savedRow = try #require(peerRows.first)
    #expect(savedRow.destinationHashHex == peerDeliveryHex)
    #expect(savedRow.stampCost == stampCost)

    // --- Session 2: restart — new store, same DB ---
    let store2 = makeStore(db, identity: me) { s in
        s.openPeerHex = peerDeliveryHex
        s.draft = "hi"
        s.reachablePeers.insert(peerDeliveryHex)
    }
    await store2.send(.onLaunch)
    await store2.receive { if case .rehydrateLearnedPeers = $0 { return true }; return false }
    try await Task.sleep(nanoseconds: 50_000_000)
    await store2.skipReceivedActions(strict: false)
    #expect(store2.state.node.client.learnedPeers[peerDeliveryHash]?.stampCost == stampCost,
            "learnedPeers must carry the persisted stamp cost after rehydration")

    // Send a message to the peer. With a stamp cost of 8, generation takes ~milliseconds.
    // `.sendTapped` → `deliverySend` starts an async stamp search → completes → `.router(.send)`
    // → `.sendOpportunistic` delegate fires.
    await store2.send(.sendTapped)
    var opportunisticPayload: Data?
    await store2.receive { action in
        if case let .node(.client(.router(.delegate(.sendOpportunistic(dest, payload, _))))) = action,
           dest == peerDeliveryHash {
            opportunisticPayload = payload
            return true
        }
        return false
    }
    await store2.finish()
    await store2.skipReceivedActions(strict: false)

    // Clause 2: reconstruct the message from the opportunistic payload and check the stamp.
    // `opportunisticPayload = message.packed.dropFirst(16)`, so:
    //   LXMessage.fromOpportunistic(destinationHash: peerDeliveryHash, payload: opportunisticPayload)
    //   = LXMessage.unpack(peerDeliveryHash + opportunisticPayload)
    //   = LXMessage.unpack(message.packed)   — which carries the stamp.
    //
    // Mutation 2: remove the rehydrateLearnedPeers forward to the library (case .rehydrateLearnedPeers
    // handler returns .none instead of .send(.node(.client(.rehydrateLearnedPeers(...))))) →
    // learnedPeers is empty after restart → deliverySend finds no cost → message is sent unstamped →
    // reconstructed.stamp == nil → assertion fails.
    let payload = try #require(opportunisticPayload, "sendOpportunistic must have fired")
    let reconstructed = try #require(LXMessage.fromOpportunistic(destinationHash: peerDeliveryHash, payload: payload),
                                     "Opportunistic payload must unpack to a valid LXMessage")
    #expect(reconstructed.stamp != nil, "Sent message must carry a delivery stamp (cost \(stampCost) was persisted and rehydrated)")
}

// MARK: - Public keys (announce row tap)
//
// The tap reads the key from the peer's announce in the learned table; it sends nothing. The former
// link + `/publicKey` request could only run when that entry already existed, and reference LXMF
// peers never answer it (the NomadNet "no response" report, 2026-09-29).

/// Known identity: the key from the learned announce, and no link or any other action.
@MainActor @Test func announceRowTappedWithKnownIdentityUsesLearnedKeyWithoutALink() async {
    let db = try! AppDatabase.makeInMemory()
    let peer = Identity()
    let peerHash = LXMessage.deliveryHash(identityHash: peer.hash)
    let peerHex = peerHash.hexString
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations([
        peerHash: LearnedDestination(identity: peer, appData: nil, ratchet: nil,
                                     interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil,
                                     announceEmitted: 1700000000,
                                     learnedAt: Date(timeIntervalSince1970: 1700000000))
    ]))))))
    // Exhaustive from here: any openLink (or other action) the tap produces fails the test.
    store.exhaustivity = .on
    await store.send(.announceRowTapped(destinationHashHex: peerHex)) {
        $0.publicKeyRequests[peerHex] = .received(publicKeyHex: peer.publicKey.hexString)
    }
    await store.finish()
}

/// Unknown identity: fails at once with the reason, and no link or any other action.
@MainActor @Test func announceRowTappedWithUnknownIdentityFailsWithoutALink() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    store.exhaustivity = .on
    await store.send(.announceRowTapped(destinationHashHex: peerA)) {
        $0.publicKeyRequests[peerA] = .failed(reason: "key unknown (no announce heard)")
    }
    await store.finish()
}

@MainActor @Test func announceRowTappedRejectsInvalidHex() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.announceRowTapped(destinationHashHex: "nothex"))
    #expect(store.state.publicKeyRequests.isEmpty)
    await store.send(.announceRowTapped(destinationHashHex: String(repeating: "a", count: 10)))   // 5 bytes — not a hash
    #expect(store.state.publicKeyRequests.isEmpty)
}

@MainActor @Test func interfaceConnectedRegistersPublicKeyRequestHandler() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.endpoint(
        .transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    await store.receive { action in
        if case let .node(.client(.endpoint(.registerRequestHandler(path: p, policy: pol)))) = action {
            #expect(p == AppFeature.publicKeyRequestPath)
            #expect(pol == .all)
            return true
        }
        return false
    }
}

// MARK: - Foreground re-dial
//
// iOS suspends the app in the background and the TCP socket does not survive it. Nothing else
// re-dials: `.task` fires once per view lifetime, and the interface's reconnect backoff cannot run
// while the process is suspended. Before `.foregrounded` existed, the only recovery from a
// background/foreground cycle was killing the app.

@MainActor @Test func foregroundingWhileDisconnectedReDialsTheEndpoint() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { state in
        state.$host.withLock { $0 = "node.example" }
        state.$port.withLock { $0 = 4243 }
    }
    #expect(store.state.connection == .disconnected)

    await store.send(.foregrounded) { $0.connection = .connecting }
    await store.receive { action in
        if case .node(.client(.endpoint(.start))) = action { return true }
        return false
    }
    // The dial must use the CURRENT settings, not whatever State.init was built with — the same
    // reason `.onLaunch` and `.connectTapped` sync them.
    guard let tcp = store.state.node.client.endpoint.tcpClient else {
        Issue.record("expected a TCP-client endpoint slot")
        return
    }
    #expect(tcp.interface.host == "node.example")
    #expect(tcp.interface.port == 4243)
}

@MainActor @Test func foregroundingWhileConnectedDoesNotReDial() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.endpoint(
        .transport(.interfaceConnected(InterfaceID("tcp"), .tcp))))))
    #expect(store.state.connection == .connected)

    // Re-dialling a healthy connection would tear down every live link on each app switch.
    await store.send(.foregrounded)
    #expect(store.state.connection == .connected)
}

// MARK: - Transport path persistence (Task 2)

/// A destination learned before restart is reachable immediately after, with no announce in
/// between. This is the headline test: without it, Task 1's `rehydrateLearnedDestinations` action
/// is dead code and the cold-start dead window exists on every launch.
///
/// Mechanism: a `.pathLearned` event in session 1 arms the debounce timer; the timer fires
/// (`._flushLearnedDestinations`) and writes to `learnedDestinationRows`; session 2's `.onLaunch`
/// reads the table and dispatches `.rehydrateLearnedDestinations`; Transport restores `learned`;
/// a subsequent `.send` to the destination succeeds without a fresh announce.
///
/// The restart is a **new TestStore over the same database**, mirroring the pattern from
/// `deliveredMessageIsNotReDeliveredAfterRestart`.
///
/// Anti-vacuity (three clauses, individually mutated):
///   "row is written": the DB has a `learnedDestinationRows` entry after flush (mutation: remove
///     the `writeLearnedDestinations` call → table is empty → first `#expect` fails).
///   "rehydrateLearnedDestinations carries the destination": the action's payload contains the
///     hash (mutation: remove the DB read from `.onLaunch` → empty payload → second `#expect`
///     fails).
///   "destination is reachable": `Transport.learned` contains the entry after rehydration, so a
///     `.send` to it does NOT produce `.sendFailed(.notLearned)` (mutation: remove the forward
///     of `.rehydrateLearnedDestinations` to Transport in `AppFeature` → learned table stays empty
///     → `.send` fails → third `#expect` fails).
@MainActor @Test func learnedPathSurvivesRestartAndIsReachableWithoutAnnounce() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let peer = Identity()
    let peerDeliveryHash = LXMessage.deliveryHash(identityHash: peer.hash)
    let peerDeliveryHex = peerDeliveryHash.hexString

    // --- Session 1: simulate a pathLearned event then flush ---

    // The TestClock is needed so we can advance it to fire the debounce.
    let clock = TestClock()
    let initial1 = AppFeature.State(identity: me)
    let store1 = TestStore(initialState: initial1) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { }
        )
    }
    store1.exhaustivity = .off

    // Fire a pathLearned event so Transport.learned and the debounce timer are both armed.
    // We inject the destination directly into the transport's learned table via the
    // rehydrateLearnedDestinations action (the same mechanism tested elsewhere), then fire
    // pathLearned to trigger the debounce — this avoids constructing a live TCP session.
    let destination = LearnedDestination(
        identity: peer,
        appData: nil,
        ratchet: nil,
        interfaceID: InterfaceID("tcp"),
        hops: 1,
        nextHop: nil,
        announceEmitted: 1700000000,
        learnedAt: Date(timeIntervalSince1970: 1700000000)
    )
    // Put the destination into Transport.learned via the rehydrate action, then fire pathLearned
    // to arm the debounce. (pathLearned alone does NOT put anything in Transport.learned in the
    // test environment — that requires a real announce over the wire. The rehydrate is used only
    // to pre-seed the learned table so the flush has something to write.)
    await store1.send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations([peerDeliveryHash: destination]))))))
    await store1.send(.node(.client(.endpoint(.delegate(.pathLearned(destinationHash: peerDeliveryHash, hops: 1))))))

    // Advance the clock 30 s to fire the debounce.
    await clock.advance(by: .seconds(30))
    // Allow the flush effect to run.
    await store1.receive { if case ._flushLearnedDestinations = $0 { return true }; return false }
    try await Task.sleep(nanoseconds: 50_000_000)
    await store1.finish()
    await store1.skipReceivedActions(strict: false)

    // Clause 1: verify the row was written.
    // Mutation 1: remove writeLearnedDestinations from ._flushLearnedDestinations → table is empty.
    let destRows = try await db.read { try LearnedDestinationRow.all.fetchAll($0) }
    #expect(destRows.count == 1, "learnedDestinationRow must be written after debounce flush")
    let savedRow = try #require(destRows.first)
    #expect(savedRow.destinationHashHex == peerDeliveryHex)

    // --- Session 2: restart — new store, same DB ---
    let store2 = makeStore(db, identity: me)
    await store2.send(.onLaunch)

    // Clause 2: rehydrateLearnedDestinations must carry the persisted destination.
    // Mutation 2: remove the LearnedDestinationRow read from .onLaunch → empty payload.
    var capturedDestinations: [Data: LearnedDestination] = [:]
    await store2.receive { action in
        if case let .rehydrateLearnedDestinations(dests) = action {
            capturedDestinations = dests
            return true
        }
        return false
    }
    #expect(capturedDestinations[peerDeliveryHash] != nil,
            "rehydrateLearnedDestinations must carry the persisted destination")
    try await Task.sleep(nanoseconds: 50_000_000)
    await store2.skipReceivedActions(strict: false)

    // Clause 3: the destination is now reachable — a send to it does NOT fail with .notLearned.
    // Mutation 3: remove the forward of .rehydrateLearnedDestinations to Transport → learned
    //   stays empty → .send fails → we would receive a sendFailed(.notLearned) delegate.
    //
    // We send the plaintext directly through Transport (bypassing LXMF stamping etc.) and check
    // that the send SUCCEEDS — meaning Transport.learned contains the entry and forwarded it.
    // In the test environment (no real TCP) the send succeeds routing-wise but fails at
    // interfaceUnavailable (no physical connection). We check for NOT notLearned.
    let sentPlaintext = Data("hello from session 2".utf8)
    await store2.send(.node(.client(.endpoint(.transport(.send(destinationHash: peerDeliveryHash, plaintext: sentPlaintext))))))
    var gotNotLearned = false
    var gotReachable = false
    await store2.receive { action in
        if case let .node(.client(.endpoint(.transport(.delegate(.sendFailed(dest, reason)))))) = action,
           dest == peerDeliveryHash {
            if reason == .notLearned { gotNotLearned = true }
            if reason == .interfaceUnavailable { gotReachable = true }
            return true
        }
        return false
    }
    await store2.finish()
    await store2.skipReceivedActions(strict: false)

    #expect(!gotNotLearned,
            "destination must not be .notLearned — rehydrateLearnedDestinations must restore the path")
    // .interfaceUnavailable means the route was found but no live TCP connection exists (expected
    // in the test environment). It proves the entry IS in Transport.learned.
    #expect(gotReachable,
            "send must fail with .interfaceUnavailable (routed but no live connection), not .notLearned")
}

/// Rapid pathLearned events are coalesced: the debounce resets on each event, so the write only
/// fires after the LAST event's 30 s window closes.
///
/// Timing scenario: send event A at t=0, advance 25 s, send event B at t=25s. With a correct
/// debounce (cancelInFlight: true), event A's timer is cancelled when B arrives. No write at
/// t=25 s or t=30 s. The write fires at t=55 s (25 s + 30 s from B's timer).
///
/// Anti-vacuity: Mutation = remove `cancelInFlight: true`. Without cancellation, A's timer
/// survives and fires at t=30 s. The test asserts no DB write happened at t=30 s (only 5 s into
/// B's window), so the assertion at t=30 s fails with the mutation, proving the cancellation is
/// load-bearing.
@MainActor @Test func rapidPathLearnedEventsAreCoalesced() async throws {
    let db = try AppDatabase.makeInMemory()
    let clock = TestClock()
    let initial = AppFeature.State(identity: Identity())
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { }
        )
    }
    store.exhaustivity = .off

    // Pre-seed Transport.learned so the flush writes a real row (not an empty table replace).
    let peer = Identity()
    let peerHash = LXMessage.deliveryHash(identityHash: peer.hash)
    let destination = LearnedDestination(
        identity: peer, appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
        hops: 1, nextHop: nil, announceEmitted: 0,
        learnedAt: Date(timeIntervalSince1970: 1700000000)
    )
    await store.send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations([peerHash: destination]))))))

    // t=0: send event A — starts a 30 s debounce timer.
    let hashA = Data(repeating: 0xAA, count: 16)
    await store.send(.node(.client(.endpoint(.delegate(.pathLearned(destinationHash: hashA, hops: 1))))))

    // Advance 25 s. A's timer has not fired yet (needs 30 s from t=0 = t=30).
    await clock.advance(by: .seconds(25))
    await store.skipReceivedActions(strict: false)

    // t=25s: send event B — with correct debounce, cancels A's timer and starts a fresh 30 s.
    // With the mutation (cancelInFlight: false), A's timer keeps running and fires at t=30.
    let hashB = Data(repeating: 0xBB, count: 16)
    await store.send(.node(.client(.endpoint(.delegate(.pathLearned(destinationHash: hashB, hops: 2))))))

    // Advance 5 more seconds (total 30 s from A's start). With the mutation, A's timer fires
    // HERE and the DB gets a row. With correct code, A's timer was cancelled; only B's timer
    // is running (25 s remaining). No DB write should happen yet.
    await clock.advance(by: .seconds(5))
    try await Task.sleep(nanoseconds: 50_000_000)
    await store.skipReceivedActions(strict: false)

    let rowsAtT30 = try await db.read { try LearnedDestinationRow.all.fetchAll($0) }
    #expect(rowsAtT30.isEmpty,
            "No flush at t=30 s: B reset the debounce so only B's timer is running (25 s left). Mutation (cancelInFlight:false) fires A's timer here.")

    // Advance the remaining 25 s (total 55 s from start = 30 s from B's start). B's timer fires.
    await clock.advance(by: .seconds(25))
    await store.receive { if case ._flushLearnedDestinations = $0 { return true }; return false }
    try await Task.sleep(nanoseconds: 50_000_000)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    let rowsAtT55 = try await db.read { try LearnedDestinationRow.all.fetchAll($0) }
    #expect(rowsAtT55.count == 1, "Exactly one flush must write the learned destination at t=55 s")
}

/// The `.backgrounded` flush writes immediately without waiting for the debounce timer.
///
/// Anti-vacuity: if `.backgrounded` only cancelled the timer without writing, the DB would still
/// be empty and the `#expect(destRows.count == 1)` would fail.
/// Mutation: remove `writeLearnedDestinations` from the `.backgrounded` case → the DB row is
/// never written → the assertion fails.
@MainActor @Test func backgroundedFlushesLearnedDestinationsImmediately() async throws {
    let db = try AppDatabase.makeInMemory()
    let clock = TestClock()
    let peer = Identity()
    let peerHash = LXMessage.deliveryHash(identityHash: peer.hash)
    let initial = AppFeature.State(identity: Identity())
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { }
        )
    }
    store.exhaustivity = .off

    // Pre-seed Transport.learned with a destination.
    let destination = LearnedDestination(
        identity: peer,
        appData: nil,
        ratchet: nil,
        interfaceID: InterfaceID("tcp"),
        hops: 1,
        nextHop: nil,
        announceEmitted: 1700000000,
        learnedAt: Date(timeIntervalSince1970: 1700000000)
    )
    await store.send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations([peerHash: destination]))))))
    // Arm the debounce (30 s timer running).
    await store.send(.node(.client(.endpoint(.delegate(.pathLearned(destinationHash: peerHash, hops: 1))))))

    // Background the app: flush fires immediately without advancing the clock.
    await store.send(.backgrounded)
    try await Task.sleep(nanoseconds: 50_000_000)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    // The DB must have the row despite the clock not having advanced 30 s.
    let destRows = try await db.read { try LearnedDestinationRow.all.fetchAll($0) }
    #expect(destRows.count == 1,
            "backgrounded must flush learned destinations immediately, before the debounce timer fires")

    // Confirm the debounce timer was cancelled by advancing 30 s and verifying no further flush.
    await clock.advance(by: .seconds(30))
    await store.skipReceivedActions(strict: false)
}

/// Backgrounding closes the hub socket. A suspended app's socket stays open from the hub's side,
/// so the push hub keeps writing into it and never goes dormant (no pushes) until the socket dies
/// on its own — minutes, on cellular. A deliberate close while the process still runs makes the
/// hub dormant at once.
///
/// Mutation: remove `closeHubSocket` from the `.backgrounded` case → `.tcpClient(.disconnect)` is
/// never received → the `receive` below times out and the test fails.
@MainActor @Test func backgroundedClosesTheHubSocket() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { state in
        state.$host.withLock { $0 = "node.example" }
        state.$port.withLock { $0 = 4243 }
    }
    // Dial first so the TCP slot exists, exactly as a real foreground does.
    await store.send(.foregrounded) { $0.connection = .connecting }
    await store.receive { if case .node(.client(.endpoint(.start))) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.tcpClient != nil)

    await store.send(.backgrounded)
    await store.receive { action in
        if case .node(.client(.endpoint(.tcpClient(.disconnect)))) = action { return true }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// Expired rows are pruned at launch before the read, so destinations older than 7 days are
/// never rehydrated. Without this prune a destination heard once, 8+ days ago, would be re-read
/// and re-skipped at every launch forever — disk grows while the in-memory table stays bounded.
///
/// Anti-vacuity: the assertion is on what `.rehydrateLearnedDestinations` carries. If the prune
/// were absent, the expired row would be read and included in the payload, then dropped by
/// `Transport.rehydrateLearnedDestinations` — but the DB row would persist forever.
/// The mutation we care about is "what if the DB read returns the expired row" — which we verify
/// by asserting the row is ABSENT from the DB after `.onLaunch` (the prune deleted it).
/// Mutation: remove the `LearnedDestinationRow.where { learnedAt < cutoff }.delete()` from
/// `.onLaunch` → the expired row survives the launch → `deletedRows.count == 1` fails.
@MainActor @Test func expiredLearnedDestinationsArePrunedAtLaunch() async throws {
    let db = try AppDatabase.makeInMemory()
    let peer = Identity()
    let peerHash = LXMessage.deliveryHash(identityHash: peer.hash)

    // Seed an expired row directly (learnedAt = 8 days ago relative to the fixed test date).
    let testNow = Date(timeIntervalSince1970: 1700000000)
    let expiredAt = testNow.addingTimeInterval(-(AppFeature.pathExpiry + 24 * 3600)) // 8 days ago
    let row = LearnedDestinationRow(
        destinationHashHex: peerHash.hexString,
        publicKeyHex: peer.publicKey.hexString,
        appDataHex: nil,
        ratchetHex: nil,
        interfaceId: "tcp",
        hops: 1,
        nextHopHex: nil,
        announceEmitted: 0,
        learnedAt: expiredAt
    )
    try await db.write { try LearnedDestinationRow.insert { row }.execute($0) }

    // Confirm the row is seeded.
    let seeded = try await db.read { try LearnedDestinationRow.all.fetchAll($0) }
    #expect(seeded.count == 1, "Expired row must be seeded before onLaunch")

    // Launch: the prune runs before the read.
    let store = makeStore(db, identity: Identity())
    await store.send(.onLaunch)

    // The rehydrateLearnedDestinations action fires, but must carry an empty payload (the
    // expired row was pruned, not delivered).
    var capturedDestinations: [Data: LearnedDestination] = [peerHash: LearnedDestination(
        identity: peer, appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
        hops: 1, nextHop: nil, announceEmitted: 0,
        learnedAt: expiredAt
    )]  // pre-populated to make sure we actually receive the action
    await store.receive { action in
        if case let .rehydrateLearnedDestinations(dests) = action {
            capturedDestinations = dests
            return true
        }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)

    // The expired row must have been deleted from the DB.
    // Mutation: remove the delete from .onLaunch → row survives → count == 1 → fails.
    let remainingRows = try await db.read { try LearnedDestinationRow.all.fetchAll($0) }
    #expect(remainingRows.count == 0,
            "Expired rows must be pruned from the DB at launch, not just skipped by the library")

    // And the action must not carry the expired destination.
    #expect(capturedDestinations[peerHash] == nil,
            "Expired destination must not appear in rehydrateLearnedDestinations payload")
}

/// After restart, a persisted path that is now reachable (interface registered) must unlock Send —
/// i.e. land in `reachablePeers` — WITHOUT any inbound announce. This is the UI-gate assertion the
/// sibling test `learnedPathSurvivesRestartAndIsReachableWithoutAnnounce` deliberately does NOT make
/// (that one proves only transport-level routability).
@MainActor @Test func persistedPathUnlocksSendOnInterfaceConnect() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let peer = Identity()
    let peerDeliveryHash = LXMessage.deliveryHash(identityHash: peer.hash)
    let peerDeliveryHex = peerDeliveryHash.hexString

    let destination = LearnedDestination(
        identity: peer,
        appData: nil,
        ratchet: nil,
        interfaceID: InterfaceID("tcp"),
        hops: 1,
        nextHop: nil,
        announceEmitted: 1700000000,
        learnedAt: Date(timeIntervalSince1970: 1700000000)
    )

    let store = makeStore(db, identity: me)

    // Rehydrate the persisted path into Transport.learned (no inbound announce, no interface yet).
    await store.send(.node(.client(.endpoint(.transport(
        .rehydrateLearnedDestinations([peerDeliveryHash: destination]))))))

    // Precondition: the path is in learned but Send is still gated (interface not registered).
    #expect(!store.state.reachablePeers.contains(peerDeliveryHex),
            "before an interface registers, the rehydrated path is not yet reachable")

    // The interface registers → paths become usable → seed runs inside the interfaceConnected handler.
    await store.send(.node(.client(.endpoint(.transport(
        .interfaceConnected(InterfaceID("tcp"), .tcp))))))

    #expect(store.state.reachablePeers.contains(peerDeliveryHex),
            "a persisted, now-reachable path must unlock Send without an inbound announce")

    await store.skipReceivedActions(strict: false)
    await store.finish()
}

/// With no persisted path, connecting must NOT seed any phantom peer — Send stays gated.
@MainActor @Test func noPersistedPathLeavesSendGatedOnConnect() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())

    await store.send(.node(.client(.endpoint(.transport(
        .interfaceConnected(InterfaceID("tcp"), .tcp))))))

    #expect(store.state.reachablePeers.isEmpty,
            "no persisted path → nothing to seed → Send stays gated after connect")

    await store.skipReceivedActions(strict: false)
    await store.finish()
}

/// Launch race: rehydration and the TCP connect are both dispatched from onLaunch. If the interface
/// registers BEFORE the DB read lands, interfaceConnected's seed found an empty learned table. The
/// rehydrate handler must then seed from its own payload so Send still unlocks.
@MainActor @Test func rehydrationAfterConnectStillUnlocksSend() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let peer = Identity()
    let peerDeliveryHash = LXMessage.deliveryHash(identityHash: peer.hash)
    let peerDeliveryHex = peerDeliveryHash.hexString

    let destination = LearnedDestination(
        identity: peer,
        appData: nil,
        ratchet: nil,
        interfaceID: InterfaceID("tcp"),
        hops: 1,
        nextHop: nil,
        announceEmitted: 1700000000,
        learnedAt: Date(timeIntervalSince1970: 1700000000)
    )

    let store = makeStore(db, identity: me)

    // Interface connects FIRST — learned is still empty, so this seed finds nothing.
    await store.send(.node(.client(.endpoint(.transport(
        .interfaceConnected(InterfaceID("tcp"), .tcp))))))
    #expect(!store.state.reachablePeers.contains(peerDeliveryHex),
            "connect-before-rehydrate: nothing to seed yet")

    // Rehydration lands AFTER connect — the app-level handler seeds from the payload.
    await store.send(.rehydrateLearnedDestinations([peerDeliveryHash: destination]))

    #expect(store.state.reachablePeers.contains(peerDeliveryHex),
            "rehydration after connect must unlock Send via the launch-race guard")

    await store.skipReceivedActions(strict: false)
    await store.finish()
}

// MARK: - Send gate: replying to a sender we have no path to (NomadNet report, 2026-09-29)
//
// The gate keeps its 2026-08-22 meaning ("a send would route right now"). What changes is that the
// app now ASKS for the missing path when it learns a peer exists: a received message, or opening
// the conversation. `Transport.State.pathRequests` records every `.requestPath` that reached the
// router, even with no interface up, so it is the observable for "a path was requested".

private func learnedEntry(_ identity: Identity) -> LearnedDestination {
    LearnedDestination(identity: identity, appData: nil, ratchet: nil,
                       interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil,
                       announceEmitted: 1700000000,
                       learnedAt: Date(timeIntervalSince1970: 1700000000))
}

/// The phone's state in the report: a message from a peer (NomadNet) arrived, but the phone has no
/// live path to the sender's delivery destination — its announce was never heard (identity unknown,
/// unvalidated) or only a persisted path exists on an interface that is not up — with or without a
/// propagation node. The receipt must request the sender's path, and the path's arrival must unlock
/// Send through the existing gate.
@MainActor @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
func receivedMessageFromPathlessSenderRequestsItsPath(announceHeard: Bool, propagationNode: Bool) async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHash = LXMessage.deliveryHash(identityHash: sender.hash)
    let senderHex = senderHash.hexString
    let store = makeStore(db, identity: me) { s in
        s.openPeerHex = senderHex
        if propagationNode {
            s.$propagationNodeHex.withLock { $0 = String(repeating: "cd", count: 16) }
        }
    }
    if announceHeard {
        // Identity known from an earlier announce, but its interface is not registered: no live path.
        await store.send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations([
            senderHash: learnedEntry(sender)
        ]))))))
    }
    #expect(!store.state.reachablePeers.contains(senderHex), "precondition: Send is gated")

    let m = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                             timestamp: 1700000000.5, title: Data(), content: Data("hello from nomadnet".utf8))
    await store.send(.node(.client(.delegate(.messageReceived(
        message: m, signatureValidated: announceHeard, method: .propagated)))))
    await store.receive { action in
        if case let .node(.client(.endpoint(.requestPath(dest)))) = action { return dest == senderHash }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.transport.pathRequests[senderHash] != nil)
    #expect(!store.state.reachablePeers.contains(senderHex), "the gate itself is not widened")

    // The path response (an announce) arrives → the existing gate unlocks.
    await store.send(.node(.client(.endpoint(.delegate(.pathLearned(destinationHash: senderHash, hops: 1))))))
    #expect(store.state.reachablePeers.contains(senderHex))
}

/// A sender already admitted by the gate needs no path request.
@MainActor @Test func receivedMessageFromReachableSenderRequestsNoPath() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHash = LXMessage.deliveryHash(identityHash: sender.hash)
    let store = makeStore(db, identity: me) { s in
        s.reachablePeers.insert(senderHash.hexString)
    }
    let m = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                             timestamp: 1700000000.5, title: Data(), content: Data("hi".utf8))
    await store.send(.node(.client(.delegate(.messageReceived(
        message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.transport.pathRequests.isEmpty)
}

/// After a relaunch `reachablePeers` is empty and the peer may have no persisted path: opening the
/// conversation requests it, so Send unlocks once the peer answers instead of on its next announce.
@MainActor @Test func openingConversationWithUnreachablePeerRequestsItsPath() async throws {
    let db = try AppDatabase.makeInMemory()
    try await seed(db, [msg(1, peerA, "from them", 1000, outgoing: false, status: MessageStatus.received)])
    let store = makeStore(db, identity: Identity())
    await store.send(.openConversation(peerA))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: peerA)!] != nil)
}

@MainActor @Test func openingConversationWithReachablePeerRequestsNoPath() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.reachablePeers.insert(peerA)
    }
    await store.send(.openConversation(peerA))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.transport.pathRequests.isEmpty)
}

/// Starting a conversation by address is the same "this peer exists" moment.
@MainActor @Test func startingConversationWithUnreachablePeerRequestsItsPath() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.startConversation(peerB))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: peerB)!] != nil)
}

// MARK: - Reactions: receive path (ReactionWire.encode = standard 0x40 format)

private func reactionMessage(from sender: Identity, to me: Identity, target: Data, emoji: String,
                             at ts: Double, content: String = "") -> LXMessage {
    LXMessage.create(
        source: sender,
        destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: ts,
        title: Data(),
        content: Data(content.utf8),
        fields: ReactionWire.encode(target: target, emoji: emoji)
    )
}

@MainActor @Test func incomingTextMessageStoresItsHash() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me)
    let m = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                             timestamp: 1700000000.5, title: Data(), content: Data("hi".utf8))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let rows = try! await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.messageHash) == [m.hash.hexString])
}

@MainActor @Test func incomingReactionIsStoredAndNotABubble() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let target = Data(repeating: 0x42, count: 32)
    let store = makeStore(db, identity: me)
    let m = reactionMessage(from: sender, to: me, target: target, emoji: "😂", at: 1700000001)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    let seen = try! await db.read { try SeenHashRow.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions == [Reaction(messageHash: target.hexString, reactorHex: senderHex, emoji: "😂", sentAt: 1700000001)])
    #expect(seen.map(\.hashHex) == [m.hash.hexString])
    #expect(store.state.conversations.isEmpty)
}

@MainActor @Test func reactionWithFallbackContentIsNotABubble() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me)
    let m = reactionMessage(from: sender, to: me, target: Data(repeating: 1, count: 32), emoji: "❤️",
                            at: 1700000001, content: "Reacted ❤️ to \"hi\"")
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions.count == 1)
}

@MainActor @Test func unvalidatedReactionIsDropped() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me)
    let m = reactionMessage(from: Identity(), to: me, target: Data(repeating: 1, count: 32), emoji: "❤️", at: 1)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: false, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    let seen = try! await db.read { try SeenHashRow.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions.isEmpty)
    #expect(seen.count == 1)
}

@MainActor @Test func malformedReactionIsDroppedNotABubble() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me)
    let m = LXMessage.create(source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                             timestamp: 1, title: Data(), content: Data(),
                             fields: [.init(0xFB, .string("reticamsgr.reaction"))])
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    let seen = try! await db.read { try SeenHashRow.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions.isEmpty)
    #expect(seen.count == 1)
}

// MARK: - Reactions: thread state + reactionSelected

@MainActor
private func sentReaction(_ store: TestStoreOf<AppFeature>) async -> (target: Data, emoji: String)? {
    var out: (Data, String)?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action,
           case let .reaction(t, e) = ReactionWire.decode(msg.fields) {
            out = (t, e)
            return true
        }
        return false
    }
    return out
}

@MainActor @Test func reactionSelectedSetsSendsAndShowsBadge() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    let store = makeStore(db, identity: me) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    let sent = await sentReaction(store)
    #expect(sent?.target == Data(hexString: hash))
    #expect(sent?.emoji == "❤️")
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions[hash] == [.init(emoji: "❤️", count: 1, includesMe: true)])
    let rows = try! await db.read { try Reaction.all.fetchAll($0) }
    #expect(rows.map(\.reactorHex) == [store.state.myAddressHex])
}

@MainActor @Test func reactionSelectedReplacesMyEmoji() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    _ = await sentReaction(store)
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.send(.reactionSelected(messageHash: hash, emoji: "😂"))
    let sent = await sentReaction(store)
    #expect(sent?.emoji == "😂")
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions[hash] == [.init(emoji: "😂", count: 1, includesMe: true)])
}

/// Review Focus 1: the test clock is frozen, so both taps see the same `date.now`. The second
/// (toggle-off) must still win — own sentAt is forced strictly monotonic.
@MainActor @Test func reactionSelectedTogglesOffWithFrozenClock() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    _ = await sentReaction(store)
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    let sent = await sentReaction(store)
    #expect(sent?.emoji == "")
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions[hash] == nil)
    let rows = try! await db.read { try Reaction.all.fetchAll($0) }
    #expect(rows.map(\.emoji) == [""])
}

@MainActor @Test func reactionSelectedWithEmptyHashIsNoOp() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: "", emoji: "❤️"))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try! await db.read { try Reaction.all.fetchAll($0) }
    #expect(rows.isEmpty)
}

@MainActor @Test func reactionFromThirdPartyIsNotShownInThread() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    try! await db.write { try Reaction.apply(Reaction(messageHash: hash, reactorHex: peerB, emoji: "👎", sentAt: 1), $0) }
    let store = makeStore(db, identity: Identity())
    await store.send(.openConversation(peerA))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions.isEmpty)
    #expect(store.state.threadReactionRows.isEmpty)
}

/// Review Focus 3.
@MainActor @Test func peerReactionOnMyOutgoingMessageShows() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let hash = String(repeating: "d", count: 64)
    try! await seed(db, [msg(1, senderHex, "mine", 1000, outgoing: true, hash: hash)])
    let store = makeStore(db, identity: me)
    await store.send(.openConversation(senderHex))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    let m = reactionMessage(from: sender, to: me, target: Data(hexString: hash)!, emoji: "👍", at: 1700000002)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions[hash] == [.init(emoji: "👍", count: 1, includesMe: false)])
}

/// Review Focus 2.
@MainActor @Test func reactionBeforeTargetShowsOnceTargetArrives() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let text = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                timestamp: 1700000000, title: Data(), content: Data("late".utf8))
    let reaction = reactionMessage(from: sender, to: me, target: text.hash, emoji: "😮", at: 1700000001)
    let store = makeStore(db, identity: me) { $0.openPeerHex = senderHex }
    await store.send(.node(.client(.delegate(.messageReceived(message: reaction, signatureValidated: true, method: .opportunistic)))))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.send(.node(.client(.delegate(.messageReceived(message: text, signatureValidated: true, method: .opportunistic)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadMessages.map(\.body) == ["late"])
    #expect(store.state.threadReactions[text.hash.hexString] == [.init(emoji: "😮", count: 1, includesMe: false)])
}

@MainActor @Test func closeConversationClearsReactions() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    _ = await sentReaction(store)
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.send(.closeConversation)
    #expect(store.state.threadReactions.isEmpty)
    #expect(store.state.threadReactionRows.isEmpty)
}

// MARK: - Reactions: standard FIELD_REACTION (0x40)

@MainActor @Test func stdReactionWithFallbackContentIsNotABubble() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let target = Data(repeating: 0x43, count: 32)
    let store = makeStore(db, identity: me)
    // Built by hand, not via ReactionWire.encode, so this pins the wire shape a foreign client sends.
    let m = LXMessage.create(
        source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1700000001, title: Data(), content: Data("Reacted ❤️ to a message".utf8),
        fields: [.init(0x40, .intMap([.init(0x00, .bin(target)), .init(0x01, .bin(Data("❤️".utf8)))]))]
    )
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions == [Reaction(messageHash: target.hexString, reactorHex: senderHex, emoji: "❤️", sentAt: 1700000001)])
}

@MainActor @Test func stdReactionMalformedIsDroppedNotABubble() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me)
    let m = LXMessage.create(
        source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1, title: Data(), content: Data("fallback text".utf8),
        fields: [.init(0x40, .intMap([.init(0x00, .bin(Data(repeating: 1, count: 8))),
                                      .init(0x01, .bin(Data("❤️".utf8)))]))]
    )
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    let seen = try! await db.read { try SeenHashRow.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions.isEmpty)
    #expect(seen.count == 1)
}

@MainActor @Test func stdReactionSelectedSendsTheStandardFormat() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    var fields: [MsgPackValue.IntPair]?
    await store.receive { action in
        if case let .node(.client(.sendMessage(sent, _))) = action { fields = sent.fields; return true }
        return false
    }
    #expect(fields == [.init(0x40, .intMap([.init(0x00, .bin(Data(hexString: hash)!)),
                                            .init(0x01, .bin(Data("❤️".utf8)))]))])
}

// MARK: - Message Info: receive path

/// An incoming message exactly as it arrives off the wire. It is packed then unpacked, so
/// `receivedBytes` is set as in production.
private func wireMessage(from sender: Identity, to me: Identity, at ts: Double, title: String = "",
                         content: String = "hi", fields: [MsgPackValue.IntPair] = []) -> LXMessage {
    let built = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                 timestamp: ts, title: Data(title.utf8), content: Data(content.utf8),
                                 fields: fields)
    return LXMessage.unpack(built.packed)!
}

/// Deliver one message to a fresh store and database, and return every stored row once all
/// effects have finished. The read uses `try await` (not `try?` falling back to `[]`) so that a
/// broken row fails the test with a thrown error instead of silently reading as "no rows".
@MainActor
private func receiveAndFetch(_ m: LXMessage, me: Identity,
                             method: LXMFRouter.DeliveryMethod = .opportunistic) async throws -> [Message] {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: me)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: method)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    return try await db.read { try Message.all.fetchAll($0) }
}

@MainActor @Test func infoReceiveStoresSenderTimestampSizesAndEmptyFieldKeys() async throws {
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me, at: 1699999900.5, title: "T", content: "hello")
    let rows = try await receiveAndFetch(m, me: me)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.senderTimestamp == Date(timeIntervalSince1970: 1699999900.5))
    #expect(row.timestamp == Date(timeIntervalSince1970: 1700000000))   // still our clock
    #expect(row.wireSize != nil)
    #expect(row.wireSize == m.receivedBytes?.count)
    #expect(row.titleSize == 1)
    #expect(row.contentSize == 5)
    #expect(row.fieldKeys == "")
    #expect(row.stampState == StampState.none)
    #expect(row.sentViaPropagation == nil)
    #expect(row.storedAt == nil)
    #expect(row.deliveredAt == nil)
    #expect(row.failedAt == nil)
}

@MainActor @Test func infoReceiveRecordsEachArrivalMethod() async throws {
    let me = Identity()
    let cases: [(LXMFRouter.DeliveryMethod, String)] = [
        (.opportunistic, ArrivalMethod.opportunistic),
        (.direct, ArrivalMethod.direct),
        (.propagated, ArrivalMethod.propagated),
    ]
    for (method, expected) in cases {
        let rows = try await receiveAndFetch(wireMessage(from: Identity(), to: me, at: 1699999999), me: me, method: method)
        #expect(rows.map(\.arrivalMethod) == [expected], "\(method)")
    }
}

@MainActor @Test func infoReceiveRecordsFieldKeysInWireOrder() async throws {
    let me = Identity()
    // 0xFB first, so a sorted encoding would differ. A foreign custom type is not a reaction.
    let m = wireMessage(from: Identity(), to: me, at: 1699999999, fields: [
        .init(0xFB, .string("someone.else")),
        .init(0x02, .bin(Data([1]))),
    ])
    let rows = try await receiveAndFetch(m, me: me)
    #expect(rows.map(\.fieldKeys) == ["0xfb,0x02"])
}

@MainActor @Test func infoReceiveRecordsStampState() async throws {
    let me = Identity()
    let sender = Identity()
    let stamp = Data(repeating: 0xFF, count: LXStamper.stampSize)
    let plain = wireMessage(from: sender, to: me, at: 1699999999, content: "none")
    let stampedBuilt = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                        timestamp: 1699999999, title: Data(), content: Data("stamped".utf8))
    let stamped = LXMessage.unpack(stampedBuilt.withStamp(stamp).packed)!
    let cases: [(LXMessage, String)] = [
        (plain, StampState.none),
        (stamped, StampState.unchecked),
        (stamped.withStampValidation(valid: true), StampState.valid),
        (stamped.withStampValidation(valid: false), StampState.invalid),
    ]
    for (m, expected) in cases {
        let rows = try await receiveAndFetch(m, me: me)
        #expect(rows.map(\.stampState) == [expected], "\(expected)")
    }
}

@MainActor @Test func infoReceiveReactionStillCreatesNoRow() async throws {
    let me = Identity()
    let m = reactionMessage(from: Identity(), to: me, target: Data(repeating: 9, count: 32), emoji: "👍",
                            at: 1700000001)
    let rows = try await receiveAndFetch(LXMessage.unpack(m.packed)!, me: me)
    #expect(rows.isEmpty)
}

/// Review Focus 1, end to end: a broken sender clock still produces a bubble that loads.
@MainActor @Test func infoReceiveOutOfRangeSenderTimestampStillStoresTheMessage() async throws {
    let me = Identity()
    let rows = try await receiveAndFetch(wireMessage(from: Identity(), to: me, at: 1e18, content: "broken clock"), me: me)
    #expect(rows.map(\.body) == ["broken clock"])
    #expect(rows.first?.senderTimestamp == nil)
}

// MARK: - Message Info: send path

/// Send "hello" and return the LXMessage handed to the node plus the stored row. The test waits for
/// `conversationsLoaded`, the last action of the send saga, so the insert has happened. It does not
/// call `finish()`: `sendMessage` starts node effects that are not this test's business.
@MainActor
private func sendAndFetch(propagationNode: String) async -> (LXMessage?, Message?) {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "hello"
        s.$propagationNodeHex.withLock { $0 = propagationNode }
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let row = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }.first
    return (sent, row)
}

@MainActor @Test func infoSendStoresSizesFieldKeysAndSendTime() async throws {
    let (sent, row) = await sendAndFetch(propagationNode: "")
    let wire = try #require(sent)
    let stored = try #require(row)
    #expect(stored.senderTimestamp == Date(timeIntervalSince1970: 1700000000))
    #expect(stored.senderTimestamp == stored.timestamp)
    #expect(stored.wireSize == wire.packed.count)
    #expect(stored.titleSize == 0)
    #expect(stored.contentSize == 5)
    #expect(stored.fieldKeys == "")
    #expect(stored.sentViaPropagation == false)
    #expect(stored.arrivalMethod == nil)
    #expect(stored.stampState == nil)
}

@MainActor @Test func infoSendRecordsPropagationNodeCopy() async throws {
    let (_, row) = await sendAndFetch(propagationNode: String(repeating: "c", count: 32))
    #expect(try #require(row).sentViaPropagation == true)
}

// MARK: - Message Info: milestone timestamps

private let infoT0 = Date(timeIntervalSince1970: 1700000000)   // makeStore's frozen \.date

@MainActor
private func sendAndSettle(_ store: TestStoreOf<AppFeature>, _ action: AppFeature.Action) async {
    await store.send(action)
    await store.finish()
}

private func hashData(_ hex: String) -> Data { Data(hexString: hex)! }

private func rowsByHashAndDirection(_ db: any DatabaseWriter) async -> [String: Message] {
    let rows = try! await db.read { try Message.all.fetchAll($0) }
    return Dictionary(uniqueKeysWithValues: rows.map { ("\($0.messageHash)/\($0.isOutgoing ? "out" : "in")", $0) })
}

@MainActor @Test func infoMilestoneFirstEventsSetTheirColumns() async {
    let db = try! AppDatabase.makeInMemory()
    let hD = String(repeating: "31", count: 16)
    let hS = String(repeating: "32", count: 16)
    let hF = String(repeating: "33", count: 16)
    try! await seed(db, [
        msg(1, peerA, "d", 1000, status: MessageStatus.sending, hash: hD),
        msg(2, peerA, "s", 1000, status: MessageStatus.sending, hash: hS),
        msg(3, peerA, "f", 1000, status: MessageStatus.sending, hash: hF),
    ])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(hD))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(hS))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(hF))))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(hD)/out"]?.deliveredAt == infoT0)
    #expect(rows["\(hD)/out"]?.storedAt == nil)
    #expect(rows["\(hD)/out"]?.failedAt == nil)
    #expect(rows["\(hS)/out"]?.storedAt == infoT0)
    #expect(rows["\(hS)/out"]?.deliveredAt == nil)
    #expect(rows["\(hS)/out"]?.failedAt == nil)
    #expect(rows["\(hF)/out"]?.failedAt == infoT0)
    #expect(rows["\(hF)/out"]?.storedAt == nil)
    #expect(rows["\(hF)/out"]?.deliveredAt == nil)
}

@MainActor @Test func infoMilestoneRepeatEventDoesNotMoveTheTime() async {
    let db = try! AppDatabase.makeInMemory()
    let hD = String(repeating: "41", count: 16)
    let hS = String(repeating: "42", count: 16)
    let hF = String(repeating: "43", count: 16)
    try! await seed(db, [
        msg(1, peerA, "d", 1000, status: MessageStatus.sending, hash: hD),
        msg(2, peerA, "s", 1000, status: MessageStatus.sending, hash: hS),
        msg(3, peerA, "f", 1000, status: MessageStatus.sending, hash: hF),
    ])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(hD))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(hS))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(hF))))))
    store.dependencies.date = .constant(infoT0.addingTimeInterval(60))   // the clock moves on
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(hD))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(hS))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(hF))))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(hD)/out"]?.deliveredAt == infoT0)
    #expect(rows["\(hS)/out"]?.storedAt == infoT0)
    #expect(rows["\(hF)/out"]?.failedAt == infoT0)
}

@MainActor @Test func infoMilestoneLateStoredAfterDeliveredIsStillRecorded() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "51", count: 16)
    try! await seed(db, [msg(1, peerA, "x", 1000, status: MessageStatus.delivered, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.delivered)
    #expect(row?.storedAt == infoT0)
}

/// Review Focus 3: the status guard keeps "delivered", but Info still learns the failure time.
@MainActor @Test func infoMilestoneFailureAfterDeliveredKeepsStatusButRecordsTime() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "52", count: 16)
    try! await seed(db, [msg(1, peerA, "x", 1000, status: MessageStatus.delivered, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.delivered)
    #expect(row?.failedAt == infoT0)
}

@MainActor @Test func infoMilestoneFalseFailureThenStoredRecordsBoth() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "53", count: 16)
    try! await seed(db, [msg(1, peerA, "x", 1000, status: MessageStatus.sending, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(h))))))
    store.dependencies.date = .constant(infoT0.addingTimeInterval(45))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.propagated)
    #expect(row?.failedAt == infoT0)
    #expect(row?.storedAt == infoT0.addingTimeInterval(45))
}

@MainActor @Test func infoMilestoneIncomingRowsSharingTheHashAreUntouched() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "54", count: 16)
    try! await seed(db, [
        msg(1, peerA, "out", 1000, outgoing: true, status: MessageStatus.sending, hash: h),
        msg(2, peerA, "in", 1000, outgoing: false, status: MessageStatus.received, hash: h),
    ])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(h))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(h))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(h)/out"]?.failedAt == infoT0)
    #expect(rows["\(h)/out"]?.storedAt == infoT0)
    #expect(rows["\(h)/out"]?.deliveredAt == infoT0)
    #expect(rows["\(h)/in"]?.failedAt == nil)
    #expect(rows["\(h)/in"]?.storedAt == nil)
    #expect(rows["\(h)/in"]?.deliveredAt == nil)
    #expect(rows["\(h)/in"]?.status == MessageStatus.received)
}

// MARK: - Replies: target and send

/// Non-uniform, so a byte-order bug in hex handling changes the value.
private let replyTargetHash = "00112233445566778899aabbccddeeff0123456789abcdeffedcba9876543210"

/// Send `draft` with `target` set, and return the LXMessage handed to the node, the stored row and
/// the reply target afterwards. Waits for `conversationsLoaded`, the last action of the send saga.
@MainActor
private func replySendAndFetch(draft: String, target: AppFeature.ReplyTarget?)
    async -> (sent: LXMessage?, row: Message?, targetAfter: AppFeature.ReplyTarget?) {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = draft
        s.replyTarget = target
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let row = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }.first
    return (sent, row, store.state.replyTarget)
}

@MainActor @Test func replyTargetTappedSetsTarget() async {
    let original = msg(1, peerA, "see you at 6", 1000, outgoing: false, status: MessageStatus.received,
                       hash: replyTargetHash)
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.threadMessages = [original]
    }
    await store.send(.replyTapped(uuid(1)))
    #expect(store.state.replyTarget
            == AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "see you at 6", isOutgoing: false))
}

/// Review Focus 3: a hashless bubble, or an id from a menu that outlived a reload, changes nothing.
@MainActor @Test func replyTargetTappedIgnoresHashlessAndUnknownMessages() async {
    let existing = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "earlier", isOutgoing: true)
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.threadMessages = [msg(1, peerA, "legacy", 1000, outgoing: false, status: MessageStatus.received, hash: "")]
        s.replyTarget = existing
    }
    await store.send(.replyTapped(uuid(1)))    // hashless: cannot be replied to
    #expect(store.state.replyTarget == existing)
    await store.send(.replyTapped(uuid(99)))   // not in the thread
    #expect(store.state.replyTarget == existing)
}

@MainActor @Test func replyTargetCancelledClearsTarget() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.replyTarget = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "x", isOutgoing: false)
    }
    await store.send(.replyCancelled)
    #expect(store.state.replyTarget == nil)
}

@MainActor @Test func replyTargetClearedOnCloseConversation() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.replyTarget = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "x", isOutgoing: false)
    }
    await store.send(.closeConversation)
    #expect(store.state.replyTarget == nil)
}

@MainActor @Test func replyTargetSendCarriesReplyFieldsAndStoresColumns() async throws {
    // Padded and over 100 characters, so the test fails unless trimQuote is applied.
    let longBody = "  " + String(repeating: "x", count: 120) + "\n"
    let expectedQuote = String(repeating: "x", count: 100) + "…"
    let (sent, row, after) = await replySendAndFetch(
        draft: "sure",
        target: AppFeature.ReplyTarget(messageHash: replyTargetHash, body: longBody, isOutgoing: false)
    )
    let wire = try #require(sent)
    #expect(wire.content == Data("sure".utf8))
    let decoded = try #require(ReplyWire.decode(wire.fields))
    #expect(decoded.replyTo == Data(hexString: replyTargetHash))
    #expect(decoded.quote == expectedQuote)
    let stored = try #require(row)
    #expect(stored.body == "sure")
    #expect(stored.replyToHash == replyTargetHash)
    #expect(stored.replyQuote == expectedQuote)
    #expect(stored.fieldKeys == "0x30,0x31")
    #expect(after == nil)
}

@MainActor @Test func replyTargetAbsentSendsNoReplyFields() async throws {
    let (sent, row, _) = await replySendAndFetch(draft: "plain", target: nil)
    let wire = try #require(sent)
    #expect(wire.fields.isEmpty)
    #expect(ReplyWire.decode(wire.fields) == nil)
    let stored = try #require(row)
    #expect(stored.replyToHash == nil)
    #expect(stored.replyQuote == nil)
}

/// Review Focus 2: nothing was sent, so the reply bar stays.
@MainActor @Test func replyTargetKeptWhenSendIsRejected() async {
    let target = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "x", isOutgoing: false)
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = ""
        s.replyTarget = target
    }
    await store.send(.sendTapped)
    #expect(store.state.replyTarget == target)
}

// MARK: - Replies: review fixes

/// Controller ruling F1, fix 1: opening a different conversation, whether via `.openConversation`
/// or `.startConversation`, must not leave a stale target pointed at a message the new thread
/// doesn't even contain.
@MainActor @Test func replyFixTargetClearedWhenConversationChanges() async {
    let db = try! AppDatabase.makeInMemory()
    let target = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "x", isOutgoing: false)
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.replyTarget = target
    }
    await store.send(.openConversation(peerB))
    #expect(store.state.replyTarget == nil)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    let store2 = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.replyTarget = target
    }
    await store2.send(.startConversation(peerB))
    #expect(store2.state.replyTarget == nil)
    await store2.finish()
    await store2.skipReceivedActions(strict: false)
}

/// Controller ruling F1, fix 3: a blank reply target (whitespace-only body trims to "") must not
/// leave a `0x31` field on the wire, nor an empty-string `replyQuote` in the stored row.
@MainActor @Test func replyFixSendBlankTargetOmitsQuote() async throws {
    let (sent, row, _) = await replySendAndFetch(
        draft: "ok",
        target: AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "   \n\t  ", isOutgoing: false)
    )
    let wire = try #require(sent)
    #expect(wire.fields.map(\.key) == [0x30])
    #expect(ReplyWire.decode(wire.fields)?.quote == nil)
    let stored = try #require(row)
    #expect(stored.replyToHash == replyTargetHash)
    #expect(stored.replyQuote == nil)
}

// MARK: - Replies: receive path

/// Non-uniform 32-byte original hash.
private let replyOriginalHash = Data((0..<32).map { UInt8(($0 * 37 + 11) & 0xFF) })

@MainActor @Test func replyReceiveStoresBothColumns() async throws {
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me, at: 1699999999, content: "yes!",
                        fields: ReplyWire.encode(replyTo: replyOriginalHash, quote: "are you coming?"))
    let rows = try await receiveAndFetch(m, me: me)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.body == "yes!")
    #expect(row.replyToHash == replyOriginalHash.hexString)
    #expect(row.replyQuote == "are you coming?")
    #expect(row.fieldKeys == "0x30,0x31")
}

@MainActor @Test func replyReceiveInvalidQuoteStoresHashOnly() async throws {
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me, at: 1699999999, content: "yes!", fields: [
        .init(0x30, .bin(replyOriginalHash)),
        .init(0x31, .bin(Data([0xFF, 0xFE]))),   // invalid UTF-8
    ])
    let rows = try await receiveAndFetch(m, me: me)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.replyToHash == replyOriginalHash.hexString)
    #expect(row.replyQuote == nil)
}

/// A reaction wins over reply fields: no bubble, reply fields ignored. A malformed reaction beside
/// reply fields is still dropped.
@MainActor @Test func replyReceiveReactionWithReplyFieldsIsOnlyAReaction() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let target = Data(repeating: 0x44, count: 32)
    let store = makeStore(db, identity: me)
    let m = LXMessage.create(
        source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1700000001, title: Data(), content: Data("Reacted 👍".utf8),
        fields: ReactionWire.encode(target: target, emoji: "👍")
            + ReplyWire.encode(replyTo: replyOriginalHash, quote: "hi")
    )
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try await db.read { try Message.all.fetchAll($0) }
    let reactions = try await db.read { try Reaction.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions == [Reaction(messageHash: target.hexString, reactorHex: senderHex, emoji: "👍", sentAt: 1700000001)])

    let malformed = wireMessage(from: sender, to: me, at: 1700000002, content: "fallback",
                                fields: [.init(0x40, .bin(Data([1])))]
                                    + ReplyWire.encode(replyTo: replyOriginalHash, quote: "hi"))
    #expect(try await receiveAndFetch(malformed, me: me).isEmpty)
}

// MARK: - Transfer-aware delivery (ReTiCA): rejected and cancelled messages

/// A message the recipient refused will never go out: it must leave "sending" for "failed" and
/// record when, exactly like `deliveryFailed`. (A cancelled one leaves it for "cancelled" — next.)
@MainActor @Test func tadCompatDeliveryRejectedMarksFailedAndRecordsFailedAt() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "61", count: 16)
    try! await seed(db, [msg(1, peerA, "x", 1000, status: MessageStatus.sending, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.failed)
    #expect(row?.failedAt == infoT0)
}

/// A message the user cancelled will never go out either: it must leave "sending" for its own
/// "cancelled" status and still record `failedAt`, like `deliveryFailed`.
@MainActor @Test func tadCompatDeliveryCancelledMarksCancelledAndRecordsFailedAt() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "62", count: 16)
    try! await seed(db, [msg(1, peerA, "x", 1000, status: MessageStatus.sending, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryCancelled(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.cancelled)
    #expect(row?.failedAt == infoT0)
}

/// Dispatches `deliveryRejected` (on an already-delivered message) and `deliveryCancelled` (on a
/// message that shares its hash with an incoming row) back to back, and pins that the second
/// dispatch still lands: the outgoing "sending" row flips to "cancelled". The delivered-row and
/// incoming-row guards are NOT re-asserted here — they are the same guarded update `deliveryFailed`
/// already exercises (see the hash-collision tests above, e.g. around line 855), and rejected/
/// cancelled share that exact code path, so a mutation that only removes one of the two new case
/// patterns never touches those checks; they passed unchanged under the Step 6 mutation batch and
/// were dropped per Ruling P9 rather than kept as untested weight.
@MainActor @Test func tadCompatRejectedThenCancelledBothReachTheFailureMarkingCode() async {
    let db = try! AppDatabase.makeInMemory()
    let delivered = String(repeating: "63", count: 16)
    let shared = String(repeating: "64", count: 16)
    try! await seed(db, [
        msg(1, peerA, "done", 1000, status: MessageStatus.delivered, hash: delivered),
        msg(2, peerA, "out", 1000, outgoing: true, status: MessageStatus.sending, hash: shared),
        msg(3, peerA, "in", 1000, outgoing: false, status: MessageStatus.received, hash: shared),
    ])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(delivered))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryCancelled(messageHash: hashData(shared))))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(shared)/out"]?.status == MessageStatus.cancelled)
}

// MARK: - Attachments: receiving (spec 2026-09-28 §4)

private func attachTempStore() -> AttachmentStore {
    AttachmentStore(baseDirectory: FileManager.default.temporaryDirectory
        .appending(path: "attachReceive-\(UUID().uuidString)"))
}

/// Deliver one message and return the stored message rows and attachment rows.
@MainActor
private func attachReceiveAndFetch(_ m: LXMessage, me: Identity, store attachmentStore: AttachmentStore)
    async throws -> (messages: [Message], attachments: [Attachment], state: AppFeature.State) {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: me, attachmentStore: attachmentStore) { s in
        s.openPeerHex = nil
    }
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .direct)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try await db.read { try Message.all.fetchAll($0) }
    let attachments = try await db.read { try Attachment.all.fetchAll($0) }
    return (messages, attachments, store.state)
}

@MainActor @Test func attachReceiveStoresAnImageOnDiskAndInTheTable() async throws {
    let me = Identity()
    let files = attachTempStore()
    let png = TestImages.png(width: 640, height: 480)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "look",
                        fields: [.init(0x06, .array([.string("png"), .bin(png)]))])
    let (messages, attachments, _) = try await attachReceiveAndFetch(m, me: me, store: files)
    let row = try #require(messages.first)
    #expect(row.body == "look")
    #expect(row.fieldKeys == "0x06")
    let a = try #require(attachments.first)
    #expect(a.messageId == row.id)
    #expect(a.kind == "image")
    #expect(a.name == "image.png")
    #expect(a.format == "png")
    #expect(a.size == png.count)
    #expect(a.width == 640)
    #expect(a.height == 480)
    #expect(a.path == "\(m.hash.hexString)-in.png")
    #expect(try Data(contentsOf: files.url(forRelativePath: a.path)) == png)
}

@MainActor @Test func attachReceiveStoresAFileWithAnEmptyCaption() async throws {
    let me = Identity()
    let files = attachTempStore()
    let pdf = Data("%PDF-1.4 fake".utf8)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "",
                        fields: [.init(0x05, .array([.array([.string("Trail map.pdf"), .bin(pdf)])]))])
    let (messages, attachments, _) = try await attachReceiveAndFetch(m, me: me, store: files)
    #expect(messages.first?.body == "")
    let a = try #require(attachments.first)
    #expect(a.kind == "file")
    #expect(a.name == "Trail map.pdf")
    #expect(a.format == "pdf")
    #expect(a.width == nil && a.height == nil)
    #expect(a.path == "\(m.hash.hexString)-in.pdf")
    #expect(try Data(contentsOf: files.url(forRelativePath: a.path)) == pdf)
}

/// Review Focus 3: a bad field never loses the message.
@MainActor @Test func attachReceiveMalformedFieldKeepsTheText() async throws {
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "still here",
                        fields: [.init(0x06, .array([.string("jpeg")]))])   // one element: malformed
    let (messages, attachments, _) = try await attachReceiveAndFetch(m, me: me, store: attachTempStore())
    #expect(messages.count == 1)
    #expect(messages.first?.body == "still here")
    #expect(messages.first?.fieldKeys == "0x06")
    #expect(attachments.isEmpty)
}

/// An image the decoder cannot read (a jpeg field carrying junk) is kept as a file row, so the
/// bytes can still be opened or shared.
@MainActor @Test func attachReceiveUndecodableImageBecomesAFile() async throws {
    let me = Identity()
    let junk = Data("not really a jpeg".utf8)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "",
                        fields: [.init(0x06, .array([.string("jpeg"), .bin(junk)]))])
    let (_, attachments, _) = try await attachReceiveAndFetch(m, me: me, store: attachTempStore())
    let a = try #require(attachments.first)
    #expect(a.kind == "file")
    #expect(a.name == "image.jpeg")
    #expect(a.format == "jpeg")
    #expect(a.width == nil)
}

/// Review Focus 4: a store that cannot write keeps the message and marks the bytes unavailable.
@MainActor @Test func attachReceiveStoreFailureKeepsTheMessageWithoutBytes() async throws {
    let me = Identity()
    let blocker = FileManager.default.temporaryDirectory.appending(path: "attachReceiveBlocker-\(UUID().uuidString)")
    try Data([0]).write(to: blocker)
    let broken = AttachmentStore(baseDirectory: blocker.appending(path: "Attachments"))
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "photo!",
                        fields: [.init(0x06, .array([.string("png"), .bin(TestImages.png(width: 8, height: 8))]))])
    let (messages, attachments, _) = try await attachReceiveAndFetch(m, me: me, store: broken)
    #expect(messages.first?.body == "photo!")
    let a = try #require(attachments.first)
    #expect(a.kind == "image")
    #expect(a.path == "")
    #expect(!a.hasBytes)
    #expect(a.width == 8)
}

@MainActor @Test func attachReceiveThreadLoadExposesAttachmentsByMessageId() async throws {
    let me = Identity()
    let sender = Identity()
    let files = attachTempStore()
    let db = try! AppDatabase.makeInMemory()
    let peerHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let store = makeStore(db, identity: me, attachmentStore: files) { s in s.openPeerHex = peerHex }
    let m = wireMessage(from: sender, to: me, at: 1699999900, content: "",
                        fields: [.init(0x05, .array([.array([.string("a.txt"), .bin(Data("x".utf8))])]))])
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .direct)))))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    let row = try #require(store.state.threadMessages.first)
    let a = try #require(store.state.attachmentsByMessageId[row.id])
    #expect(a.name == "a.txt")
    // The conversation preview shows the placeholder for the empty caption.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.conversations.first?.lastBody == "📎 a.txt")
    // Closing the conversation clears the map.
    await store.send(.closeConversation)
    #expect(store.state.attachmentsByMessageId.isEmpty)
}

/// A reply to a photo quotes the placeholder, not an empty line.
@MainActor @Test func attachReceiveReplyToAPhotoQuotesThePlaceholder() async {
    let hash = String(repeating: "7a", count: 32)
    let original = msg(1, peerA, "", 1000, outgoing: false, status: MessageStatus.received, hash: hash)
    let photo = Attachment(id: UUID(), messageId: original.id, kind: AttachmentKind.image, name: "image.jpeg",
                           format: "jpeg", size: 10, width: 4, height: 4, path: "x")
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.threadMessages = [original]
        s.attachmentsByMessageId = [original.id: photo]
    }
    await store.send(.replyTapped(uuid(1)))
    #expect(store.state.replyTarget == AppFeature.ReplyTarget(messageHash: hash, body: "📷 Photo", isOutgoing: false))
}

// MARK: - Attachments: sending (spec 2026-09-28 §3)

/// 1600×1200: above the 1280 standard edge (so the standard preset scales it to 1280×960) but
/// small enough that the PNG decode + JPEG encode inside `store.receive` stays well under the
/// TestStore's 1 s receive timeout in a parallel full suite.
private let attachPNG = TestImages.png(width: 1600, height: 1200)

private func pendingImage(_ data: Data = TestImages.jpeg(width: 40, height: 30)) -> PendingAttachment {
    PendingAttachment(kind: AttachmentKind.image, name: "IMG_20231114_221320.jpg", format: "jpeg", data: data,
                      width: 40, height: 30, originalSource: data, isOriginal: false)
}

private func pendingFile(name: String = "Trail map.pdf", data: Data = Data("%PDF fake".utf8)) -> PendingAttachment {
    PendingAttachment(kind: AttachmentKind.file, name: name, format: "pdf", data: data,
                      width: nil, height: nil, originalSource: nil, isOriginal: false)
}

@MainActor @Test func attachSendPickingAnImagePreparesAStandardJPEG() async {
    let clock = TestClock()
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock) { s in s.openPeerHex = peerA }
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: attachPNG, peerHex: peerA)))
    #expect(store.state.attachmentPreparing)
    await clock.advance(by: .milliseconds(1))
    await store.receive { if case .attachmentPrepared = $0 { return true }; return false }
    let p = try! #require(store.state.pendingAttachment)
    #expect(p.kind == "image")
    #expect(p.format == "jpeg")
    #expect(p.name == "IMG_20231114_221320.jpg")   // the frozen \.date, UTC
    #expect(p.width == 1280)
    #expect(p.height == 960)
    #expect(p.originalSource == attachPNG)
    #expect(p.isOriginal == false)
    #expect(ImageEncoder.containerType(of: p.data) == "public.jpeg")
    #expect(!store.state.attachmentPreparing)
    #expect(store.state.attachmentError == nil)
}

@MainActor @Test func attachSendOriginalToggleReencodesFromTheSource() async {
    let clock = TestClock()
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock) { s in s.openPeerHex = peerA }
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: attachPNG, peerHex: peerA)))
    await clock.advance(by: .milliseconds(1))
    await store.receive { if case .attachmentPrepared = $0 { return true }; return false }
    await store.send(.attachmentOriginalToggled(true))
    #expect(store.state.attachmentPreparing)
    await clock.advance(by: .milliseconds(1))
    await store.receive { if case .attachmentPrepared = $0 { return true }; return false }
    #expect(store.state.pendingAttachment?.width == 1600)
    #expect(store.state.pendingAttachment?.height == 1200)
    #expect(store.state.pendingAttachment?.isOriginal == true)
    #expect(store.state.pendingAttachment?.name == "IMG_20231114_221320.jpg")   // the name is kept
    await store.send(.attachmentOriginalToggled(false))
    await clock.advance(by: .milliseconds(1))
    await store.receive { if case .attachmentPrepared = $0 { return true }; return false }
    #expect(store.state.pendingAttachment?.width == 1280)
    #expect(store.state.pendingAttachment?.height == 960)
    // Toggling to the state it is already in, or with a file pending, does nothing.
    store.exhaustivity = .on
    await store.send(.attachmentOriginalToggled(false))
    await store.send(.attachmentRemoved) {
        $0.pendingAttachment = nil
        $0.attachmentPreparing = false
        $0.attachmentError = nil
    }
    store.exhaustivity = .off
}

@MainActor @Test func attachSendPickingAFilePassesThrough() async {
    let clock = TestClock()
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock) { s in s.openPeerHex = peerA }
    let bytes = Data("%PDF fake".utf8)
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.file, name: "Trail map.pdf", data: bytes, peerHex: peerA)))
    await clock.advance(by: .milliseconds(1))
    await store.receive { if case .attachmentPrepared = $0 { return true }; return false }
    let p = try! #require(store.state.pendingAttachment)
    #expect(p.kind == "file")
    #expect(p.name == "Trail map.pdf")
    #expect(p.format == "pdf")
    #expect(p.data == bytes)
    #expect(p.width == nil && p.height == nil)
    #expect(p.originalSource == nil)
    #expect(p.size == bytes.count)
}

/// A late preparation result must not resurrect an attachment the user removed: Remove cancels
/// the encode in flight.
@MainActor @Test func attachSendRemoveCancelsAPendingPreparation() async {
    let clock = TestClock()
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock) { s in s.openPeerHex = peerA }
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: attachPNG, peerHex: peerA)))
    await store.send(.attachmentRemoved)
    // Only now does the preparation's `clock.sleep` checkpoint resolve — deterministically AFTER
    // Remove's `.cancel(id:)` already ran, so a correctly-cancelled effect never wakes at all.
    await clock.advance(by: .milliseconds(1))
    // Exhaustive from here: once every effect has finished, a late `attachmentPrepared` would be
    // an unhandled received action and the probe send fails.
    store.exhaustivity = .on
    await store.finish()
    await store.send(.replyCancelled)   // probe
    store.exhaustivity = .off
    #expect(store.state.pendingAttachment == nil)
}

@MainActor @Test func attachSendUndecodableImageFails() async {
    let clock = TestClock()
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock) { s in
        s.openPeerHex = peerA
        s.pendingAttachment = pendingFile()   // replaced by the new pick, even when it fails
    }
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: Data("junk".utf8), peerHex: peerA)))
    #expect(store.state.pendingAttachment == nil)
    await clock.advance(by: .milliseconds(1))
    await store.receive(.attachmentFailed(AttachmentPreparation.undecodableImage))
    #expect(store.state.attachmentError == AttachmentPreparation.undecodableImage)
    #expect(!store.state.attachmentPreparing)
    #expect(store.state.pendingAttachment == nil)
}

@Test func attachSendSizeNotesAndFormatting() {
    #expect(AttachmentSizeNote.note(for: 100) == nil)
    #expect(AttachmentSizeNote.note(for: 256_000) == nil)
    #expect(AttachmentSizeNote.note(for: 256_001) == AttachmentSizeNote.overPropagation)
    #expect(AttachmentSizeNote.note(for: 1_000_000) == AttachmentSizeNote.overPropagation)
    #expect(AttachmentSizeNote.note(for: 1_000_001) == AttachmentSizeNote.overDelivery)
    #expect(AttachmentSizeNote.formattedSize(900) == "900 B")
    #expect(AttachmentSizeNote.formattedSize(34_211) == "34 KB")
    #expect(AttachmentSizeNote.formattedSize(1_234_567) == "1.2 MB")
    #expect(AttachmentSizeNote.formattedSize(10_500_000) == "10.5 MB")
}

/// The whole send saga for an image: bytes on disk, both rows, the 0x06 field, and the caption.
@MainActor @Test func attachSendImageWritesRowsFileAndFields() async throws {
    let db = try! AppDatabase.makeInMemory()
    let files = attachTempStore()
    let jpeg = TestImages.jpeg(width: 40, height: 30)
    let store = makeStore(db, identity: Identity(), attachmentStore: files) { s in
        s.openPeerHex = peerA
        s.draft = "cap"
        s.pendingAttachment = pendingImage(jpeg)
    }
    await store.send(.sendTapped)
    #expect(store.state.pendingAttachment == nil)
    #expect(store.state.draft == "")
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let msg = try #require(sent)
    #expect(msg.fields.map(\.key) == [0x06])
    #expect(AttachmentWire.decode(msg.fields)?.data == jpeg)
    #expect(msg.content == Data("cap".utf8))
    let row = try #require(try await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }.first)
    #expect(row.body == "cap")
    #expect(row.fieldKeys == "0x06")
    #expect(row.wireSize == msg.packed.count)
    #expect(row.status == MessageStatus.sending)
    let a = try #require(try await db.read { try Attachment.all.fetchAll($0) }.first)
    #expect(a.messageId == row.id)
    #expect(a.kind == "image")
    #expect(a.name == "IMG_20231114_221320.jpg")
    #expect(a.format == "jpeg")
    #expect(a.size == jpeg.count)
    #expect(a.width == 40 && a.height == 30)
    #expect(a.path == "\(msg.hash.hexString)-out.jpeg")
    #expect(try Data(contentsOf: files.url(forRelativePath: a.path)) == jpeg)
    #expect(store.state.attachmentsByMessageId[row.id] == a)
}

@MainActor @Test func attachSendFileWithNoTextIsAllowed() async throws {
    let db = try! AppDatabase.makeInMemory()
    let files = attachTempStore()
    let store = makeStore(db, identity: Identity(), attachmentStore: files) { s in
        s.openPeerHex = peerA
        s.draft = ""
        s.pendingAttachment = pendingFile()
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let msg = try #require(sent)
    #expect(msg.fields.map(\.key) == [0x05])
    #expect(AttachmentWire.decode(msg.fields)?.name == "Trail map.pdf")
    #expect(msg.content.isEmpty)
    let a = try #require(try await db.read { try Attachment.all.fetchAll($0) }.first)
    #expect(a.kind == "file")
    #expect(a.path == "\(msg.hash.hexString)-out.pdf")
    #expect(files.exists(a.path))
}

@MainActor @Test func attachSendWithReplyOrdersAttachmentFirst() async throws {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), attachmentStore: attachTempStore()) { s in
        s.openPeerHex = peerA
        s.draft = ""
        s.pendingAttachment = pendingImage()
        s.replyTarget = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "see you", isOutgoing: false)
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    #expect(sent?.fields.map(\.key) == [0x06, 0x30, 0x31])
    #expect(store.state.replyTarget == nil)
}

/// Review Focus 4 (send half): a store that cannot write sends NOTHING, says so inline, and gives
/// the caption back.
@MainActor @Test func attachSendStoreFailureSendsNothing() async throws {
    let db = try! AppDatabase.makeInMemory()
    let blocker = FileManager.default.temporaryDirectory.appending(path: "attachSendBlocker-\(UUID().uuidString)")
    try Data([0]).write(to: blocker)
    let broken = AttachmentStore(baseDirectory: blocker.appending(path: "Attachments"))
    let store = makeStore(db, identity: Identity(), attachmentStore: broken) { s in
        s.openPeerHex = peerA
        s.draft = "cap"
        s.pendingAttachment = pendingImage()
    }
    store.exhaustivity = .on
    await store.send(.sendTapped) {
        $0.draft = ""
        $0.pendingAttachment = nil
        $0.attachmentError = nil
    }
    await store.receive(.attachmentSendFailed(draft: "cap")) {
        $0.attachmentError = AttachmentPreparation.storeFailed
        $0.draft = "cap"
    }
    // Exhaustive probe: no sendMessage, no reload followed.
    await store.send(.replyCancelled)
    store.exhaustivity = .off
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.isEmpty)
}

@MainActor @Test func attachSendTextOnlyLeavesNoAttachmentRow() async throws {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "just text"
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    #expect(sent?.fields.isEmpty == true)
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.isEmpty)
}

@MainActor @Test func attachSendGuardsWhilePreparingAndClearsOnClose() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "x"
        s.attachmentPreparing = true
    }
    store.exhaustivity = .on
    await store.send(.sendTapped)            // nothing happens while a pick is being prepared
    await store.send(.replyCancelled)         // probe
    store.exhaustivity = .off
    #expect(store.state.draft == "x")
    // Empty draft and no attachment: nothing happens either.
    let empty = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in s.openPeerHex = peerA }
    empty.exhaustivity = .on
    await empty.send(.sendTapped)
    await empty.send(.replyCancelled)
    empty.exhaustivity = .off
    // Leaving the conversation drops a pending attachment and its error.
    let leaving = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.pendingAttachment = pendingFile()
        s.attachmentError = "old"
    }
    await leaving.send(.closeConversation)
    #expect(leaving.state.pendingAttachment == nil)
    #expect(leaving.state.attachmentError == nil)
}

/// T7-m1: the bytes are on disk but the rows cannot be written. Nothing is sent, the caption comes
/// back, and the stored file is removed. The failure is made deterministic with a trigger that
/// aborts every attachment insert, so the one transaction (message row included) rolls back after
/// the store step has already succeeded.
@MainActor @Test func attachSendDatabaseFailureRestoresTheDraftAndRemovesTheFile() async throws {
    let db = try! AppDatabase.makeInMemory()
    try await db.write { db in
        try db.execute(sql: """
            CREATE TRIGGER refuseAttachmentInsert BEFORE INSERT ON attachments
            BEGIN SELECT RAISE(ABORT, 'test: attachment insert refused'); END
            """)
    }
    let files = attachTempStore()
    let store = makeStore(db, identity: Identity(), attachmentStore: files) { s in
        s.openPeerHex = peerA
        s.draft = "cap"
        s.pendingAttachment = pendingImage()
    }
    store.exhaustivity = .on
    await store.send(.sendTapped) {
        $0.draft = ""
        $0.pendingAttachment = nil
        $0.attachmentError = nil
    }
    await store.receive(.attachmentSendFailed(draft: "cap")) {
        $0.attachmentError = AttachmentPreparation.storeFailed
        $0.draft = "cap"
    }
    // Exhaustive probe: no sendMessage, no reload followed.
    await store.send(.replyCancelled)
    store.exhaustivity = .off
    #expect(store.state.draft == "cap")
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.isEmpty)
    // The store step did run (the directory exists), and its file is gone again.
    #expect(FileManager.default.fileExists(atPath: files.baseDirectory.path()))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: files.baseDirectory.path())
    #expect(leftovers.isEmpty)
}

/// T7-m3: toggling back while the first toggle's re-encode is still in flight wins. The guard
/// compares with the value last asked for, not the stale pending one.
@MainActor @Test func attachSendToggleBackWhilePreparingWins() async {
    let clock = TestClock()
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock) { s in s.openPeerHex = peerA }
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: attachPNG, peerHex: peerA)))
    await clock.advance(by: .milliseconds(1))
    await store.receive { if case .attachmentPrepared = $0 { return true }; return false }
    await store.send(.attachmentOriginalToggled(true))    // not advanced: still preparing
    await store.send(.attachmentOriginalToggled(false))   // back again before it lands
    await clock.advance(by: .milliseconds(1))
    await store.receive {
        if case let .attachmentPrepared(p) = $0 { return p.isOriginal == false && p.width == 1280 }
        return false
    }
    // Exhaustive probe: nothing else arrives (the toggle-to-Original encode was cancelled).
    store.exhaustivity = .on
    await store.finish()
    await store.send(.replyCancelled)
    store.exhaustivity = .off
    #expect(store.state.pendingAttachment?.isOriginal == false)
    #expect(store.state.pendingAttachment?.width == 1280)
    #expect(store.state.attachmentOriginalRequested == nil)
}

/// I-1: a picker read that outlived conversation A's chat view must not land in B's composer,
/// and neither may its load-started spinner. The pending file in B stays exactly as it was.
@MainActor @Test func attachSendPickFromAnotherConversationIsDropped() async {
    let clock = TestClock()
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock) { s in
        s.openPeerHex = peerB
        s.pendingAttachment = pendingFile()
    }
    store.exhaustivity = .on
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: attachPNG, peerHex: peerA)))
    await store.send(.attachmentLoadStarted(peerHex: peerA))
    await clock.advance(by: .milliseconds(1))
    await store.finish()
    await store.send(.replyCancelled)   // probe: no preparation was started
    store.exhaustivity = .off
}

/// I-1: the view says a slow read began: the bar shows the spinner, a stale pending attachment and
/// error go, and a preparation still running for an earlier pick is cancelled.
@MainActor @Test func attachSendLoadStartedShowsPreparing() async {
    let clock = TestClock()
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock) { s in
        s.openPeerHex = peerA
        s.pendingAttachment = pendingFile()
        s.attachmentError = "old"
    }
    store.exhaustivity = .on
    await store.send(.attachmentLoadStarted(peerHex: peerA)) {
        $0.pendingAttachment = nil
        $0.attachmentError = nil
        $0.attachmentPreparing = true
    }
    await store.send(.replyCancelled)   // probe
    store.exhaustivity = .off
    // An earlier pick still encoding is cancelled by the next load.
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: attachPNG, peerHex: peerA)))
    await store.send(.attachmentLoadStarted(peerHex: peerA))
    await clock.advance(by: .milliseconds(1))
    store.exhaustivity = .on
    await store.finish()
    await store.send(.replyCancelled)   // probe: no late attachmentPrepared
    store.exhaustivity = .off
    #expect(store.state.attachmentPreparing)
    #expect(store.state.pendingAttachment == nil)
}

/// I-3: a view-sent failure (a picker read failed) stops an earlier pick still encoding, so its
/// late result cannot replace the error.
@MainActor @Test func attachSendFailureFromTheViewCancelsAPendingPreparation() async {
    let clock = TestClock()
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock) { s in s.openPeerHex = peerA }
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: attachPNG, peerHex: peerA)))
    await store.send(.attachmentFailed("y"))
    await clock.advance(by: .milliseconds(1))
    store.exhaustivity = .on
    await store.finish()
    await store.send(.replyCancelled)   // probe: no attachmentPrepared
    store.exhaustivity = .off
    #expect(store.state.attachmentError == "y")
    #expect(store.state.pendingAttachment == nil)
}

/// FR-9: opening or starting another conversation cancels a preparation still in flight. The
/// only action allowed to arrive is the new thread's load.
@MainActor @Test func attachSendOpenAndStartConversationCancelAPendingPreparation() async {
    for leave: AppFeature.Action in [.openConversation(peerB), .startConversation(peerB)] {
        let clock = TestClock()
        // peerB is reachable, so opening it issues no path request: this test is about the
        // preparation's cancellation, and the thread load stays the only action that may arrive.
        let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock) { s in
            s.openPeerHex = peerA
            s.reachablePeers.insert(peerB)
        }
        await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: attachPNG, peerHex: peerA)))
        await store.send(leave)
        store.exhaustivity = .on
        // The new thread's load is the one action allowed (the preparation's sleep has not been
        // advanced yet, so nothing else can have arrived before it). `reloadThread` now also
        // carries the (absent) conversation timer alongside the thread's messages.
        await store.receive(.threadLoaded([], reactions: [], attachments: []))
        await store.receive(.conversationExpiryLoaded(peerHex: peerB, seconds: nil))
        // Disappearing messages: opening/starting a thread also purges and arms the sleeper.
        await store.receive(.expiryPurgeCompleted(purged: 0, nextDue: nil))
        await clock.advance(by: .milliseconds(1))
        await store.finish()                // an uncancelled preparation's result fails here
        await store.send(.replyCancelled)   // probe: no attachmentPrepared
        store.exhaustivity = .off
        #expect(store.state.pendingAttachment == nil)
    }
}

// MARK: - Attachments: transfer state (spec 2026-09-28 §3–§4)

private let linkL = Data(repeating: 0x4C, count: 16)
private let linkM = Data(repeating: 0x4D, count: 16)

private func progress(_ hex: String, _ fraction: Double) -> AppFeature.Action {
    .node(.client(.delegate(.deliveryProgress(messageHash: hashData(hex), fraction: fraction))))
}

private func inbound(_ link: Data, _ fraction: Double, source: Data? = nil) -> AppFeature.Action {
    .node(.client(.delegate(.inboundTransferProgress(sourceHash: source, linkID: link, fraction: fraction))))
}

/// Review Focus 5: never backwards, and every terminal outcome clears the bar — including the two
/// new ones. `propagationAccepted` is not terminal for the delivery copy and leaves it alone.
@MainActor @Test func attachTransferProgressIsMonotonicAndClearedByEveryTerminal() async {
    let db = try! AppDatabase.makeInMemory()
    let h = (1...5).map { String(repeating: "7\($0)", count: 16) }
    try! await seed(db, h.enumerated().map { i, hash in msg(i + 1, peerA, "m", 1000, status: MessageStatus.sending, hash: hash) })
    let store = makeStore(db, identity: Identity())
    await store.send(progress(h[0], 0.05))
    await store.send(progress(h[0], 0.5))
    await store.send(progress(h[0], 0.3))    // late/lower: ignored
    #expect(store.state.outgoingProgress[h[0]] == 0.5)
    await store.send(progress(h[0], 1.7))    // clamped
    #expect(store.state.outgoingProgress[h[0]] == 1.0)
    for hash in h.dropFirst() { await store.send(progress(hash, 0.4)) }
    #expect(store.state.outgoingProgress.count == 5)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(h[0]))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(h[1]))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(h[2]))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryCancelled(messageHash: hashData(h[3]))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(h[4]))))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.outgoingProgress == [h[4]: 0.4])
}

@MainActor @Test func attachTransferCancelledStatusReasonAndGuards() async {
    let db = try! AppDatabase.makeInMemory()
    let sending = String(repeating: "81", count: 16)
    let delivered = String(repeating: "82", count: 16)
    let shared = String(repeating: "83", count: 16)
    try! await seed(db, [
        msg(1, peerA, "s", 1000, status: MessageStatus.sending, hash: sending),
        msg(2, peerA, "d", 1000, status: MessageStatus.delivered, hash: delivered),
        msg(3, peerA, "out", 1000, outgoing: true, status: MessageStatus.sending, hash: shared),
        msg(4, peerA, "in", 1000, outgoing: false, status: MessageStatus.received, hash: shared),
    ])
    let store = makeStore(db, identity: Identity())
    for hash in [sending, delivered, shared] {
        await sendAndSettle(store, .node(.client(.delegate(.deliveryCancelled(messageHash: hashData(hash))))))
    }
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(sending)/out"]?.status == MessageStatus.cancelled)
    #expect(rows["\(sending)/out"]?.failureReason == FailureReason.cancelled)
    #expect(rows["\(sending)/out"]?.failedAt == infoT0)
    #expect(rows["\(delivered)/out"]?.status == MessageStatus.delivered)     // never downgraded
    #expect(rows["\(delivered)/out"]?.failureReason == nil)
    #expect(rows["\(shared)/out"]?.status == MessageStatus.cancelled)
    #expect(rows["\(shared)/in"]?.status == MessageStatus.received)          // incoming untouched
    #expect(rows["\(shared)/in"]?.failureReason == nil)
}

@MainActor @Test func attachTransferRejectedAndFailedReasons() async {
    let db = try! AppDatabase.makeInMemory()
    let rejected = String(repeating: "84", count: 16)
    let failed = String(repeating: "85", count: 16)
    try! await seed(db, [
        msg(1, peerA, "r", 1000, status: MessageStatus.sending, hash: rejected),
        msg(2, peerA, "f", 1000, status: MessageStatus.sending, hash: failed),
    ])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(rejected))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(failed))))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(rejected)/out"]?.status == MessageStatus.failed)
    #expect(rows["\(rejected)/out"]?.failureReason == FailureReason.rejected)
    #expect(rows["\(failed)/out"]?.status == MessageStatus.failed)
    #expect(rows["\(failed)/out"]?.failureReason == nil)
}

@MainActor @Test func attachTransferPropagationRefusedRecordsTheReason() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "86", count: 16)
    try! await seed(db, [
        msg(1, peerA, "big", 1000, status: MessageStatus.sending, hash: h),
        msg(2, peerA, "in", 1000, outgoing: false, status: MessageStatus.received, hash: h),
    ])
    let store = makeStore(db, identity: Identity()) { s in s.openPeerHex = peerA }
    await sendAndSettle(store, .node(.client(.delegate(.propagationRefused(messageHash: hashData(h), reason: .tooLargeForNode)))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(h)/out"]?.propagationRefused == PropagationRefusal.tooLargeForNode)
    #expect(rows["\(h)/out"]?.status == MessageStatus.sending)   // the direct copy is still going
    #expect(rows["\(h)/in"]?.propagationRefused == nil)
    // The open thread reloaded so the Info sheet sees it.
    #expect(store.state.threadMessages.first { $0.isOutgoing }?.propagationRefused == PropagationRefusal.tooLargeForNode)
}

@MainActor @Test func attachTransferCancelSendsCancelOutbound() async {
    let h = String(repeating: "87", count: 16)
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.threadMessages = [msg(1, peerA, "big", 1000, status: MessageStatus.sending, hash: h)]
    }
    await store.send(.cancelSendTapped(uuid(1)))
    await store.receive(.node(.client(.cancelOutbound(messageHash: hashData(h)))))
}

/// Review Focus 6: only an outgoing message still sending, with a hash, can be cancelled.
@MainActor @Test func attachTransferCancelIsIgnoredUnlessSending() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.threadMessages = [
            msg(1, peerA, "done", 1000, status: MessageStatus.delivered, hash: String(repeating: "88", count: 16)),
            msg(2, peerA, "theirs", 1000, outgoing: false, status: MessageStatus.received, hash: String(repeating: "89", count: 16)),
            msg(3, peerA, "legacy", 1000, status: MessageStatus.sending, hash: ""),
            msg(4, peerA, "failed", 1000, status: MessageStatus.failed, hash: String(repeating: "8a", count: 16)),
        ]
    }
    store.exhaustivity = .on
    for id in [1, 2, 3, 4, 99] {
        await store.send(.cancelSendTapped(uuid(id)))
    }
    await store.send(.replyCancelled)   // probe: nothing was sent to the node
    store.exhaustivity = .off
}

@MainActor @Test func attachTransferInboundEntryTracksLinksAndAttribution() async {
    let peerHash = hashData(peerA)
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in s.openPeerHex = peerA }
    await store.send(inbound(linkL, 0.3))
    #expect(store.state.inboundTransfers[linkL] == AppFeature.InboundTransfer(sourceHash: nil, fraction: 0.3, updatedAt: infoT0))
    // Report times set apart (the frozen \.date would make them all equal) so the ORDER the UI
    // gets is pinned: oldest report first, then link ID hex for a tie. Neither matches the order
    // the reports were sent in, and a dictionary's own order is arbitrary.
    func at(_ seconds: TimeInterval) { store.dependencies.date = .constant(infoT0.addingTimeInterval(seconds)) }
    at(2); await store.send(inbound(linkL, 0.7))
    #expect(store.state.inboundTransfers[linkL]?.fraction == 0.7)
    at(1); await store.send(inbound(linkM, 0.1, source: peerHash))
    at(0); await store.send(inbound(Data(repeating: 0x4E, count: 16), 0.2, source: hashData(peerB)))
    at(3); await store.send(inbound(Data(repeating: 0x4A, count: 16), 0.5, source: peerHash))
    at(1); await store.send(inbound(Data(repeating: 0x4B, count: 16), 0.9))   // ties linkM, sorts first
    // The open thread shows the unattributed ones and those attributed to its peer, not peerB's.
    #expect(store.state.inboundTransfersForOpenThread.map(\.fraction) == [0.9, 0.1, 0.7, 0.5])
    #expect(store.state.unattributedInboundTransfers.map(\.fraction) == [0.9, 0.7])
    // Done: the entry goes away.
    await store.send(inbound(linkL, 1.0))
    #expect(store.state.inboundTransfers[linkL] == nil)
    #expect(store.state.inboundTransfers.count == 4)
    // A closed link clears its entry too.
    await store.send(.node(.client(.endpoint(.delegate(.linkClosed(linkID: linkM, reason: .timedOut))))))
    #expect(store.state.inboundTransfers[linkM] == nil)
    #expect(store.state.inboundTransfers.count == 3)
}

/// T8-m3: the stored fraction is clamped like `deliveryProgress` (NaN reads as 0), and a report at
/// or past 1 still ends the transfer.
@MainActor @Test func attachTransferInboundFractionIsClamped() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity())
    await store.send(inbound(linkL, -0.5))
    #expect(store.state.inboundTransfers[linkL]?.fraction == 0)
    await store.send(inbound(linkL, 0.4))
    await store.send(inbound(linkL, .nan))
    #expect(store.state.inboundTransfers[linkL]?.fraction == 0)
    await store.send(inbound(linkL, 1.7))
    #expect(store.state.inboundTransfers[linkL] == nil)
}

/// FR-1: the user's cancel is terminal: a failure or rejection reported afterwards for the same
/// message changes neither its status nor its reason.
@MainActor @Test func attachTransferCancelledIsTerminalAgainstLaterFailures() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "8b", count: 16)
    try! await seed(db, [msg(1, peerA, "big", 1000, status: MessageStatus.sending, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryCancelled(messageHash: hashData(h))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(h))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.cancelled)
    #expect(row?.failureReason == FailureReason.cancelled)
}

/// FR-1: a delivery proof that follows a failure report wins, and the failure's reason goes with it.
@MainActor @Test func attachTransferDeliveryConfirmedClearsAStaleReason() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "8c", count: 16)
    try! await seed(db, [msg(1, peerA, "big", 1000, status: MessageStatus.sending, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(h))))))
    #expect(await rowsByHashAndDirection(db)["\(h)/out"]?.failureReason == FailureReason.rejected)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.delivered)
    #expect(row?.failureReason == nil)
}

/// Review Focus 7: a transfer that stops reporting disappears after 60 s of silence; a report
/// restarts the clock.
@MainActor @Test func attachTransferInboundEntryExpiresAfterSilence() async {
    let clock = TestClock()
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock)
    await store.send(inbound(linkL, 0.3))
    await clock.advance(by: .seconds(59))
    await store.send(inbound(linkL, 0.4))          // restarts the 60 s
    // Exhaustive window: 59 s after the restart (118 s after the first report) nothing may fire.
    // A timer that was NOT restarted fires at 60 s from the first report, inside this window, and
    // its `inboundTransferTimedOut` fails the probe. (Under `.off`, a bare `store.state` check here
    // would assert nothing: state lags until a receive.)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(59))
    await store.send(.replyCancelled)              // probe
    store.exhaustivity = .off
    await clock.advance(by: .seconds(1))
    await store.receive(.inboundTransferTimedOut(linkID: linkL))
    #expect(store.state.inboundTransfers[linkL] == nil)
    // Completion cancels the timer: nothing fires later.
    await store.send(inbound(linkM, 0.5))
    await store.send(inbound(linkM, 1.0))
    store.exhaustivity = .on
    await clock.advance(by: .seconds(120))
    await store.send(.replyCancelled)   // probe
    store.exhaustivity = .off
}

// MARK: - Disappearing messages: setting the timer and sending (spec 2026-10-05 §3)

/// Send the current draft from a store whose conversation timer is `expiry`, returning the
/// LXMessage handed to the node and the stored row.
@MainActor
private func expirySendAndFetch(_ db: any DatabaseWriter, draft: String, expiry: Int?,
                                attachmentStore: AttachmentStore? = nil,
                                configure: ((inout AppFeature.State) -> Void)? = nil)
    async -> (sent: LXMessage?, row: Message?, store: TestStoreOf<AppFeature>) {
    let store = makeStore(db, identity: Identity(), attachmentStore: attachmentStore) { s in
        s.openPeerHex = peerA
        s.draft = draft
        s.openConversationExpiry = expiry
        configure?(&s)
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let row = try! await db.read { try Message.where { $0.peerHex.eq(peerA) && !$0.isTimerChange }.fetchAll($0) }.first
    return (sent, row, store)
}

@MainActor @Test func expirySendSelectingTimerWritesSettingAnnouncementAndSendsChange() async throws {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.expirySelected(seconds: 86_400))
    #expect(store.state.openConversationExpiry == 86_400)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let wire = try #require(sent)
    #expect(wire.content == Data("Disappearing messages set to 1 day".utf8))
    #expect(ExpiryWire.decode(wire.fields) == ExpiryWire.Decoded(seconds: 86_400, isChange: true))
    #expect(try await db.read { try ConversationSetting.expiry(for: peerA, $0) } == 86_400)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.isTimerChange == true)
    #expect(row.isOutgoing == true)
    #expect(row.body == "Disappearing messages set to 1 day")
    #expect(row.expirySeconds == nil)
    #expect(row.expiresAt == nil)
    #expect(row.messageHash == wire.hash.hexString)
    #expect(row.status == MessageStatus.sending)
    #expect(store.state.conversations.first?.lastBody == "Disappearing messages set to 1 day")
}

@MainActor @Test func expirySendTurningOffStoresNullAndAnnounces() async throws {
    let db = try! AppDatabase.makeInMemory()
    try await db.write { try ConversationSetting.set(peerA, seconds: 3_600, at: infoT0, $0) }
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.openConversationExpiry = 3_600
    }
    await store.send(.expirySelected(seconds: 0))
    #expect(store.state.openConversationExpiry == nil)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let wire = try #require(sent)
    #expect(wire.content == Data("Disappearing messages turned off".utf8))
    #expect(ExpiryWire.decode(wire.fields) == ExpiryWire.Decoded(seconds: 0, isChange: true))
    let settings = try await db.read { try ConversationSetting.all.fetchAll($0) }
    #expect(settings.count == 1)
    #expect(settings.first?.expirySeconds == nil)
}

@MainActor @Test func expirySendSelectedIgnoredWithoutOpenConversation() async throws {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    store.exhaustivity = .on
    await store.send(.expirySelected(seconds: 60))
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try ConversationSetting.all.fetchAll($0) }.isEmpty)
}

/// Spec §3 "Sending": the field goes on the wire and the sender's copy is stamped at send.
@MainActor @Test func expirySendMessageCarriesFieldAndStampsSenderCopy() async throws {
    let db = try! AppDatabase.makeInMemory()
    let (sent, row, store) = await expirySendAndFetch(db, draft: "hi", expiry: 300)
    let wire = try #require(sent)
    #expect(wire.fields.map(\.key) == [0xFD])
    #expect(ExpiryWire.decode(wire.fields) == ExpiryWire.Decoded(seconds: 300, isChange: false))
    let stored = try #require(row)
    #expect(stored.expirySeconds == 300)
    #expect(stored.expiresAt == infoT0.addingTimeInterval(300))
    #expect(stored.isTimerChange == false)
    #expect(stored.fieldKeys == "0xfd")
    // The send armed the sleeper for this row.
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == infoT0.addingTimeInterval(300) }
        return false
    }
}

@MainActor @Test func expirySendWithoutTimerCarriesNoFieldAndNoStamp() async throws {
    let db = try! AppDatabase.makeInMemory()
    let (sent, row, _) = await expirySendAndFetch(db, draft: "plain", expiry: nil)
    let wire = try #require(sent)
    #expect(wire.fields.isEmpty)
    let stored = try #require(row)
    #expect(stored.expirySeconds == nil)
    #expect(stored.expiresAt == nil)
}

/// Review Focus 4: the attachment field comes first, then the reply fields, then 0xFD.
@MainActor @Test func expirySendAttachmentCarriesFieldAfterAttachmentAndReply() async throws {
    let db = try! AppDatabase.makeInMemory()
    let files = attachTempStore()
    let jpeg = TestImages.jpeg(width: 40, height: 30)
    let (sent, row, store) = await expirySendAndFetch(db, draft: "cap", expiry: 3_600, attachmentStore: files) { s in
        s.pendingAttachment = pendingImage(jpeg)
        s.replyTarget = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "orig", isOutgoing: false)
    }
    let wire = try #require(sent)
    #expect(wire.fields.map(\.key) == [0x06, 0x30, 0x31, 0xFD])
    #expect(ExpiryWire.decode(wire.fields) == ExpiryWire.Decoded(seconds: 3_600, isChange: false))
    let stored = try #require(row)
    #expect(stored.expirySeconds == 3_600)
    #expect(stored.expiresAt == infoT0.addingTimeInterval(3_600))
    #expect(stored.fieldKeys == "0x06,0x30,0x31,0xfd")
    // The attachment path arms the sleeper too.
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == infoT0.addingTimeInterval(3_600) }
        return false
    }
}

@MainActor @Test func expirySendCloseConversationClearsOpenExpiry() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.openConversationExpiry = 60
    }
    await store.send(.closeConversation)
    #expect(store.state.openConversationExpiry == nil)
}

/// `reloadThread` carries the conversation's stored timer into state, and only for the open peer.
@MainActor @Test func expirySendThreadLoadCarriesConversationSetting() async throws {
    let db = try! AppDatabase.makeInMemory()
    try await db.write { try ConversationSetting.set(peerA, seconds: 600, at: infoT0, $0) }
    try! await seed(db, [msg(1, peerA, "a1", 1000)])
    let store = makeStore(db, identity: Identity())
    await store.send(.openConversation(peerA))
    await store.receive { if case let .conversationExpiryLoaded(peerHex, seconds) = $0 { return peerHex == peerA && seconds == 600 }; return false }
    #expect(store.state.openConversationExpiry == 600)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    // A late load for a conversation that is no longer open changes nothing.
    await store.send(.closeConversation)
    await store.send(.conversationExpiryLoaded(peerHex: peerA, seconds: 600))
    #expect(store.state.openConversationExpiry == nil)
}

// MARK: - Disappearing messages: receive path (spec 2026-10-05 §3)

private func expiryHex(_ identity: Identity) -> String {
    LXMessage.deliveryHash(identityHash: identity.hash).hexString
}

/// Spec §3 "Receiving": the duration is stored, the row is NOT stamped (not viewed), and since no
/// setting existed the convergence rule writes one and inserts a line above the message.
@MainActor @Test func expiryReceiveStoresDurationUnstampedAndConvergesSetting() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me)
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "hi", fields: ExpiryWire.encode(seconds: 600))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }
    #expect(rows.count == 2)
    let line = try #require(rows.first)
    let message = try #require(rows.last)
    #expect(line.isTimerChange == true)
    #expect(line.isOutgoing == false)
    #expect(line.body == "Them set disappearing messages to 10 minutes")
    #expect(line.messageHash == "")
    #expect(line.expirySeconds == nil)
    #expect(line.timestamp < message.timestamp)
    #expect(message.body == "hi")
    #expect(message.expirySeconds == 600)
    #expect(message.expiresAt == nil)
    #expect(message.isTimerChange == false)
    #expect(message.fieldKeys == "0xfd")
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 600)
}

@MainActor @Test func expiryReceiveEqualSettingAddsNoLine() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "hi", fields: ExpiryWire.encode(seconds: 600))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.expirySeconds == 600)
}

/// A timer-change message updates the setting and is stored only as the announcement row, body as
/// received. Turning off stores NULL.
@MainActor @Test func expiryReceiveTimerChangeUpdatesSettingAndStoresOnlyAnnouncement() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me)
    let on = wireMessage(from: sender, to: me, at: 1699999999, content: "Disappearing messages set to 1 hour",
                         fields: ExpiryWire.encodeChange(seconds: 3_600))
    await store.send(.node(.client(.delegate(.messageReceived(message: on, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    var rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.isTimerChange == true)
    #expect(rows.first?.body == "Disappearing messages set to 1 hour")
    #expect(rows.first?.expirySeconds == nil)
    #expect(rows.first?.expiresAt == nil)
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 3_600)

    let off = wireMessage(from: sender, to: me, at: 1700000001, content: "Disappearing messages turned off",
                          fields: ExpiryWire.encodeChange(seconds: 0))
    await store.send(.node(.client(.delegate(.messageReceived(message: off, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    rows = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }
    #expect(rows.count == 2)
    #expect(rows.last?.isTimerChange == true)
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == nil)
    #expect(try await db.read { try ConversationSetting.all.fetchAll($0) }.count == 1)
}

/// A change message with an empty body (a future client might send none) gets the local line text.
@MainActor @Test func expiryReceiveTimerChangeWithEmptyBodyGetsLocalText() async throws {
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me, at: 1699999999, content: "", fields: ExpiryWire.encodeChange(seconds: 86_400))
    let rows = try await receiveAndFetch(m, me: me)
    #expect(rows.count == 1)
    #expect(rows.first?.isTimerChange == true)
    #expect(rows.first?.body == "Them set disappearing messages to 1 day")
}

/// Spec §3: a message without the field never touches the setting (a non-honouring peer must not
/// keep switching it off), and amendment A4: an explicit 0 on an ordinary message does converge.
@MainActor @Test func expiryReceiveWithoutFieldLeavesSettingAloneButZeroConverges() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    let plain = wireMessage(from: sender, to: me, at: 1699999999, content: "no field")
    await store.send(.node(.client(.delegate(.messageReceived(message: plain, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 600)
    #expect(try await db.read { try Message.all.fetchAll($0) }.count == 1)

    // Move the frozen clock so the second message (and its convergence line, 1 ms before it)
    // sorts after the first by timestamp.
    store.dependencies.date = .constant(infoT0.addingTimeInterval(5))
    let zero = wireMessage(from: sender, to: me, at: 1700000001, content: "off now", fields: ExpiryWire.encode(seconds: 0))
    await store.send(.node(.client(.delegate(.messageReceived(message: zero, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == nil)
    let rows = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }
    #expect(rows.count == 3)
    #expect(rows[1].isTimerChange == true)
    #expect(rows[1].body == "Them turned disappearing messages off")
    #expect(rows[2].body == "off now")
    #expect(rows[2].expirySeconds == nil)
}

/// Spec §3 "First view": a message arriving into the open thread while the app is active is
/// viewed at once, so it is stamped on insert and the sleeper is armed.
@MainActor @Test func expiryReceiveIntoOpenForegroundThreadStampsAtOnce() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me) { $0.openPeerHex = expiryHex(sender) }
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "hi", fields: ExpiryWire.encode(seconds: 600))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == infoT0.addingTimeInterval(600) }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.expiresAt == infoT0.addingTimeInterval(600))
    #expect(store.state.threadMessages.first?.expiresAt == infoT0.addingTimeInterval(600))
}

/// Amendment A5: the open thread is not being looked at while the app is in the background.
@MainActor @Test func expiryReceiveIntoOpenThreadWhileBackgroundedDoesNotStamp() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me) { $0.openPeerHex = expiryHex(sender) }
    await store.send(.backgrounded)
    #expect(store.state.isForeground == false)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "hi", fields: ExpiryWire.encode(seconds: 600))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.expirySeconds == 600)
    #expect(row.expiresAt == nil)
}

/// Review Focus 2: a 0xFD that is not ours leaves an ordinary text message and the setting alone.
@MainActor @Test func expiryReceiveMalformedFieldIsPlainText() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "hub data",
                        fields: [.init(0xFD, .bin(Data([1, 2, 3])))])
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.body == "hub data")
    #expect(rows.first?.expirySeconds == nil)
    #expect(rows.first?.isTimerChange == false)
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 600)
}

/// Review Focus 1: an unvalidated sender cannot change the timer. The message is kept as text.
@MainActor @Test func expiryReceiveUnvalidatedChangeIsPlainText() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "Disappearing messages turned off",
                        fields: ExpiryWire.encodeChange(seconds: 0))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: false, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.isTimerChange == false)
    #expect(rows.first?.body == "Disappearing messages turned off")
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 600)
}

// MARK: - Disappearing messages: first view, lifecycle, sleeper (spec 2026-10-05 §3)

private func expiryTimerRow(_ id: Int, _ peer: String, seconds: Int?, expiresAt: Date?, outgoing: Bool = false,
                            hash: String? = nil) -> Message {
    Message(id: uuid(id), peerHex: peer, isOutgoing: outgoing, body: "r\(id)",
            timestamp: infoT0.addingTimeInterval(TimeInterval(id)),
            status: outgoing ? MessageStatus.delivered : MessageStatus.received, validated: !outgoing,
            messageHash: hash ?? String(repeating: String(format: "%02x", 0x50 + id), count: 32),
            expirySeconds: seconds, expiresAt: expiresAt)
}

/// Opening a thread is the first view of every unstamped row in it. A row already stamped keeps
/// its time, an ordinary row stays nil, and the sleeper is armed for the earliest stamp.
@MainActor @Test func expiryTimerOpeningThreadStampsUnstampedRowsOnly() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [
        expiryTimerRow(1, peerA, seconds: 60, expiresAt: nil),
        expiryTimerRow(2, peerA, seconds: 60, expiresAt: infoT0.addingTimeInterval(10)),
        expiryTimerRow(3, peerA, seconds: nil, expiresAt: nil),
        expiryTimerRow(4, peerB, seconds: 60, expiresAt: nil),   // another conversation: not viewed
    ])
    let store = makeStore(db, identity: Identity())
    await store.send(.openConversation(peerA))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == infoT0.addingTimeInterval(10) }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }
    #expect(rows[0].expiresAt == infoT0.addingTimeInterval(60))
    #expect(rows[1].expiresAt == infoT0.addingTimeInterval(10))
    #expect(rows[2].expiresAt == nil)
    #expect(rows[3].expiresAt == nil)
    #expect(store.state.threadMessages.map(\.expiresAt) == [infoT0.addingTimeInterval(60), infoT0.addingTimeInterval(10), nil])
}

/// `startConversation` is the other way into a thread and stamps too.
@MainActor @Test func expiryTimerStartConversationStampsToo() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [expiryTimerRow(1, peerA, seconds: 30, expiresAt: nil)])
    let store = makeStore(db, identity: Identity())
    await store.send(.startConversation(peerA))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.expiresAt == infoT0.addingTimeInterval(30))
}

/// The sleeper fires at the earliest `expiresAt`, the row is purged and the thread reloads. A
/// 30-second preset with the thread open therefore disappears on time.
@MainActor @Test func expiryTimerDueRowIsPurgedAndThreadReloads() async throws {
    let db = try! AppDatabase.makeInMemory()
    let clock = TestClock()
    try! await seed(db, [expiryTimerRow(1, peerA, seconds: 30, expiresAt: infoT0.addingTimeInterval(30))])
    let store = makeStore(db, identity: Identity(), clock: clock)
    await store.send(.openConversation(peerA))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == infoT0.addingTimeInterval(30) }
        return false
    }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.threadMessages.count == 1)

    store.dependencies.date = .constant(infoT0.addingTimeInterval(30))
    await clock.advance(by: .seconds(30))
    await store.receive { if case .expiryDue = $0 { return true }; return false }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 && nextDue == nil }
        return false
    }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadMessages.isEmpty)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// A nearer expiry re-arms the sleeper: after a 60 s row is armed, a message stamped for 10 s
/// arrives, and the sleeper fires at 10 s, not 60.
@MainActor @Test func expiryTimerNearerExpiryReschedulesSleeper() async throws {
    let db = try! AppDatabase.makeInMemory()
    let clock = TestClock()
    let me = Identity()
    let sender = Identity()
    let senderHex = expiryHex(sender)
    try! await seed(db, [expiryTimerRow(1, senderHex, seconds: 60, expiresAt: infoT0.addingTimeInterval(60))])
    try await db.write { try ConversationSetting.set(senderHex, seconds: 10, at: infoT0, $0) }
    let store = makeStore(db, identity: me, clock: clock)
    await store.send(.openConversation(senderHex))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == infoT0.addingTimeInterval(60) }
        return false
    }
    await store.skipReceivedActions(strict: false)

    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "quick", fields: ExpiryWire.encode(seconds: 10))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == infoT0.addingTimeInterval(10) }
        return false
    }
    await store.skipReceivedActions(strict: false)

    store.dependencies.date = .constant(infoT0.addingTimeInterval(10))
    await clock.advance(by: .seconds(10))
    await store.receive { if case .expiryDue = $0 { return true }; return false }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 && nextDue == infoT0.addingTimeInterval(60) }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let bodies = try await db.read { try Message.all.fetchAll($0) }.map(\.body)
    #expect(bodies == ["r1"])
}

/// Review Focus 5: nothing runs while suspended, so launch catches up on rows that fell due,
/// including the attachment file and reactions.
@MainActor @Test func expiryTimerLaunchPurgesRowsDueWhileSuspended() async throws {
    let db = try! AppDatabase.makeInMemory()
    let files = attachTempStore()
    let due = expiryTimerRow(1, peerA, seconds: 60, expiresAt: infoT0.addingTimeInterval(-1))
    let path = try files.store(Data([1]), messageHash: due.messageHash, outgoing: false, ext: "bin")
    let attachment = Attachment(id: UUID(), messageId: due.id, kind: AttachmentKind.file, name: "a.bin",
                                format: "bin", size: 1, width: nil, height: nil, path: path)
    try! await seed(db, [due, expiryTimerRow(2, peerA, seconds: nil, expiresAt: nil)])
    try await db.write { d in
        try Attachment.insert { attachment }.execute(d)
        try Reaction.insert { Reaction(messageHash: due.messageHash, reactorHex: peerA, emoji: "👍", sentAt: 1) }.execute(d)
    }
    let store = makeStore(db, identity: Identity(), attachmentStore: files)
    await store.send(.onLaunch)
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 && nextDue == nil }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Message.all.fetchAll($0) }.map(\.body) == ["r2"])
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Reaction.all.fetchAll($0) }.isEmpty)
    #expect(!files.exists(path))
    #expect(store.state.conversations.first?.lastBody == "r2")
}

/// Returning to the foreground with a thread open is a view of its unstamped rows, and a purge.
@MainActor @Test func expiryTimerForegroundStampsOpenThreadAndPurges() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [
        expiryTimerRow(1, peerA, seconds: 60, expiresAt: nil),
        expiryTimerRow(2, peerA, seconds: 5, expiresAt: infoT0.addingTimeInterval(-1)),
    ])
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.isForeground = false
    }
    await store.send(.foregrounded) {
        $0.connection = .connecting
        $0.isForeground = true
    }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 && nextDue == infoT0.addingTimeInterval(60) }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.body) == ["r1"])
    #expect(rows.first?.expiresAt == infoT0.addingTimeInterval(60))
    #expect(store.state.threadMessages.map(\.body) == ["r1"])
}

/// Foreground with no thread open still purges, and stamps nothing.
@MainActor @Test func expiryTimerForegroundWithoutThreadOnlyPurges() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [
        expiryTimerRow(1, peerA, seconds: 60, expiresAt: nil),
        expiryTimerRow(2, peerA, seconds: 5, expiresAt: infoT0.addingTimeInterval(-1)),
    ])
    let store = makeStore(db, identity: Identity())
    await store.send(.foregrounded) { $0.connection = .connecting }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 && nextDue == nil }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.body) == ["r1"])
    #expect(rows.first?.expiresAt == nil)
}

@MainActor @Test func expiryTimerBackgroundedClearsForegroundFlagAndStampsNothing() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [expiryTimerRow(1, peerA, seconds: 60, expiresAt: nil)])
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    #expect(store.state.isForeground == true)
    await store.send(.backgrounded) { $0.isForeground = false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.expiresAt == nil)
}

/// Foreground with nothing due still reloads the thread after stamping, so the stamped rows
/// reach the UI without waiting for a later purge or load.
@MainActor @Test func expiryTimerForegroundReloadsThreadAfterStampingWhenNothingIsDue() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [expiryTimerRow(1, peerA, seconds: 60, expiresAt: nil)])
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.isForeground = false
    }
    await store.send(.foregrounded) {
        $0.connection = .connecting
        $0.isForeground = true
    }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == infoT0.addingTimeInterval(60) }
        return false
    }
    #expect(store.state.threadMessages.map(\.expiresAt) == [infoT0.addingTimeInterval(60)])
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

// MARK: - Disappearing messages: final-review fixes (spec amendments A10 to A14)

/// Deliver `m` as a validated message and let every effect finish.
@MainActor
private func expiryFixReceive(_ store: TestStoreOf<AppFeature>, _ m: LXMessage) async {
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// A10: a message written before the stored timer was set does not move it, though the message
/// itself still honours the duration it carried.
@MainActor @Test func expiryFixOlderOrdinaryMessageLeavesSettingAlone() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    await expiryFixReceive(store, wireMessage(from: sender, to: me, at: 1699999000, content: "old",
                                              fields: ExpiryWire.encode(seconds: 86_400)))
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 600)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.expirySeconds == 86_400)
}

/// A10: a newer ordinary message converges, and the setting's time is the sender's timestamp.
@MainActor @Test func expiryFixNewerOrdinaryMessageConverges() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    store.dependencies.date = .constant(infoT0.addingTimeInterval(1_000))
    await expiryFixReceive(store, wireMessage(from: sender, to: me, at: 1700000500, content: "new",
                                              fields: ExpiryWire.encode(seconds: 86_400)))
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 86_400)
    let rows = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }
    #expect(rows.count == 2)
    #expect(rows.first?.isTimerChange == true)
    #expect(rows.first?.body == "Them set disappearing messages to 1 day")
    let setting = try await db.read { try ConversationSetting.current(for: expiryHex(sender), $0) }
    #expect(setting?.updatedAt == Date(timeIntervalSince1970: 1700000500))
}

/// A10: a change message that arrives after a newer setting is stored as its line, but the setting
/// does not move.
@MainActor @Test func expiryFixLateChangeMessageIsStoredButIgnored() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    await expiryFixReceive(store, wireMessage(from: sender, to: me, at: 1699999000, content: "Disappearing messages turned off",
                                              fields: ExpiryWire.encodeChange(seconds: 0)))
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 600)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.isTimerChange == true)
}

/// A10: a sender clock in the future is capped at arrival, so a later local pick still wins.
@MainActor @Test func expiryFixFutureDatedChangeIsCappedAtReceiveTime() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = expiryHex(sender)
    let store = makeStore(db, identity: me) { $0.openPeerHex = senderHex }
    await expiryFixReceive(store, wireMessage(from: sender, to: me, at: 1800000000, content: "Disappearing messages set to 1 hour",
                                              fields: ExpiryWire.encodeChange(seconds: 3_600)))
    let adopted = try await db.read { try ConversationSetting.current(for: senderHex, $0) }
    #expect(adopted?.expirySeconds == 3_600)
    #expect(adopted?.updatedAt == infoT0)
    #expect(store.state.openConversationExpiry == 3_600)

    store.dependencies.date = .constant(infoT0.addingTimeInterval(1))
    await store.send(.expirySelected(seconds: 0))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try ConversationSetting.expiry(for: senderHex, $0) } == nil)
}
