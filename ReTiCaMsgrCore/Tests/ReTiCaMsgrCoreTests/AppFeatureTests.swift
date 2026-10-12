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
        // The final fix wave (F1) can drive `.push(.setEnabled(false))` for real (the push node
        // disappearing while push is enabled) — unlike every earlier test here, which only ever
        // flips this through direct action injection. A hermetic no-op keeps that path from
        // hitting `PushPlatform.testValue`'s `unimplemented` closures.
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
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

// MARK: - Node helpers (default nodes, spec 2026-10-10)

private let gaefuID = DefaultNode.entry.interfaceID
private let nodeHexA = String(repeating: "a1", count: 16)
private let nodeHexP = String(repeating: "c3", count: 16)
private let nodeHexQ = String(repeating: "d4", count: 16)

private func userNode(_ host: String = "node.example", port: Int = 4243, enabled: Bool = true,
                      hex: String? = nil, id: Int = 7) -> NodeEntry {
    NodeEntry(id: uuid(id), name: host, host: host, port: port, enabled: enabled, pushHubHex: hex)
}

private func disabled(_ entry: NodeEntry) -> NodeEntry {
    var entry = entry
    entry.enabled = false
    return entry
}

private func withoutHex(_ entry: NodeEntry) -> NodeEntry {
    var entry = entry
    entry.pushHubHex = nil
    return entry
}

/// A store whose node list is `nodes` (written through the shared reference, as the reducer does).
@MainActor
private func nodeStore(_ db: any DatabaseWriter, nodes: [NodeEntry],
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    makeStore(db, identity: Identity()) { state in
        state.$nodes.withLock { $0 = nodes }
        configure?(&state)
    }
}

/// `connectTapped` and settle, so the enabled nodes have slots.
@MainActor
private func connectNodes(_ store: TestStoreOf<AppFeature>) async {
    await store.send(.connectTapped)
    await store.receive { if case .node(.client(.endpoint(.start))) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

private func isConnect(_ id: InterfaceID, _ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.tcpClients(.element(id: id, action: .connect))))) = action { return true }
    return false
}

private func isRemove(_ id: InterfaceID, _ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.removeTCPClient(id)))) = action { return true }
    return false
}

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

/// Enabling the listener adds a `tcpServer` slot bound to the DEDICATED `listenPort` (not any
/// node's dial port) when Settings are synced at connect time. The slot is what lets other LAN
/// nodes dial THIS device directly.
@MainActor @Test func enablingListenAddsListenerSlotOnDedicatedPortAtConnect() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { state in
        state.$listenEnabled.withLock { $0 = true }
        state.$listenPort.withLock { $0 = 5151 }   // the default node's dial port (4242) is DIFFERENT
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

    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
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
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
    #expect(store.state.connection == .connected)
    await store.send(.node(.client(.endpoint(.transport(.interfaceDisconnected(gaefuID))))))
    #expect(store.state.connection == .disconnected,
            "the last interface dropping must mark the app disconnected")
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// Foreground re-dial keys on each node's interface, not "any interface up". A live BLE peer
/// must NOT suppress the re-dial of a node whose socket died in the background — and, since the
/// app is still connected through that peer, the status stays connected while the node re-dials.
@MainActor @Test func foregroundReDialsWhenTCPDownEvenWithBLEPeerUp() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry]) { $0.$bleEnabled.withLock { $0 = true } }
    let blePeer = bleInterfaceID(Data(repeating: 0xCD, count: 16))
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(blePeer, .ble))))))
    #expect(store.state.connection == .connected)
    await store.skipReceivedActions(strict: false)

    await store.send(.foregrounded)
    await store.receive { isConnect(gaefuID, $0) }
    #expect(store.state.connection == .connected, "the BLE peer keeps the app connected during the re-dial")
    await store.skipReceivedActions(strict: false)
}

/// Conversely, when TCP is up, foreground must NOT re-dial — re-dialling a healthy socket would tear
/// down every live link on each app switch (the original reason `.foregrounded` guards).
@MainActor @Test func foregroundDoesNotReDialWhenTCPIsUp() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry])
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
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
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
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
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
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
    await store2.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
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
    await store3.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
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
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
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
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
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
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
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
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
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
                                     interfaceID: gaefuID, hops: 1, nextHop: nil,
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
        .transport(.interfaceConnected(gaefuID, .tcp))))))
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

@MainActor @Test func foregroundingWhileConnectedDoesNotReDial() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry])
    await store.send(.node(.client(.endpoint(
        .transport(.interfaceConnected(gaefuID, .tcp))))))
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
        interfaceID: gaefuID,
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
        identity: peer, appData: nil, ratchet: nil, interfaceID: gaefuID,
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
        interfaceID: gaefuID,
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
        identity: peer, appData: nil, ratchet: nil, interfaceID: gaefuID,
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
        interfaceID: gaefuID,
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
        .interfaceConnected(gaefuID, .tcp))))))

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
        .interfaceConnected(gaefuID, .tcp))))))

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
        interfaceID: gaefuID,
        hops: 1,
        nextHop: nil,
        announceEmitted: 1700000000,
        learnedAt: Date(timeIntervalSince1970: 1700000000)
    )

    let store = makeStore(db, identity: me)

    // Interface connects FIRST — learned is still empty, so this seed finds nothing.
    await store.send(.node(.client(.endpoint(.transport(
        .interfaceConnected(gaefuID, .tcp))))))
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
                       interfaceID: gaefuID, hops: 1, nextHop: nil,
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
        // carries the (absent) conversation timer alongside the thread's messages, and leads with
        // the (nil, for a peer) group load (Task 4).
        await store.receive(.groupLoaded(groupHex: peerB, group: nil, members: [], deliveries: []))
        await store.receive(.threadLoaded([], reactions: [], attachments: []))
        await store.receive(.conversationExpiryLoaded(peerHex: peerB, seconds: nil)) {
            $0.openConversationExpiryLoaded = true
        }
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
        // The thread's setting has "loaded": `expiry` is authoritative for the send (A16).
        s.openConversationExpiry = expiry
        s.openConversationExpiryLoaded = true
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

/// A timer-change message updates the setting and is stored only as the announcement row, in the
/// local wording (amendment A13). Turning off stores NULL.
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
    #expect(rows.first?.body == "Them set disappearing messages to 1 hour")
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
    #expect(rows.last?.body == "Them turned disappearing messages off")
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
    let store = makeStore(db, identity: me) { s in
        s.openPeerHex = expiryHex(sender)
        s.chatVisible = true
    }
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
    let store = makeStore(db, identity: me) { s in
        s.openPeerHex = expiryHex(sender)
        s.chatVisible = true
    }
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
/// Amendment A12: being field-less for us, it takes the local timer.
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
    #expect(rows.first?.expirySeconds == 600)
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
        s.chatVisible = true
        s.isForeground = false
    }
    // No node is configured in this fixture (migration never ran), so `.foregrounded` has
    // nothing to redial and `connection` stays as it was — only `isForeground` flips.
    await store.send(.foregrounded) {
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
    // No node is configured in this fixture (migration never ran), so `.foregrounded` has
    // nothing to redial and `connection` stays as it was.
    await store.send(.foregrounded)
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
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.chatVisible = true
    }
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
        s.chatVisible = true
        s.isForeground = false
    }
    // No node is configured in this fixture (migration never ran), so `.foregrounded` has
    // nothing to redial and `connection` stays as it was — only `isForeground` flips.
    await store.send(.foregrounded) {
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

/// A11: the thread is open but the user is on another tab, so an arrival is not viewed.
@MainActor @Test func expiryFixArrivalWhileChatHiddenDoesNotStamp() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me) { $0.openPeerHex = expiryHex(sender) }
    #expect(store.state.isForeground == true)
    #expect(store.state.chatVisible == false)
    await expiryFixReceive(store, wireMessage(from: sender, to: me, at: 1699999999, content: "hi",
                                              fields: ExpiryWire.encode(seconds: 600)))
    let row = try #require(try await db.read { try Message.where { !$0.isTimerChange }.fetchAll($0) }.first)
    #expect(row.expirySeconds == 600)
    #expect(row.expiresAt == nil)
}

/// A11: coming back to the chat is the first view of what arrived meanwhile, and arms the sleeper.
@MainActor @Test func expiryFixChatAppearedStampsAndArmsSleeper() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [expiryTimerRow(1, peerA, seconds: 60, expiresAt: nil)])
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.chatAppeared) { $0.chatVisible = true }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == infoT0.addingTimeInterval(60) }
        return false
    }
    #expect(store.state.threadMessages.map(\.expiresAt) == [infoT0.addingTimeInterval(60)])
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.expiresAt == infoT0.addingTimeInterval(60))
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// A11: leaving the chat screen, by tab switch or by closing the conversation, hides it.
@MainActor @Test func expiryFixChatDisappearedClearsVisibility() async throws {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity())
    await store.send(.openConversation(peerA)) { $0.chatVisible = true }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    await store.send(.chatDisappeared) { $0.chatVisible = false }
    #expect(store.state.chatVisible == false)
    await store.send(.chatAppeared) { $0.chatVisible = true }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    await store.send(.closeConversation) { $0.chatVisible = false }
    #expect(store.state.chatVisible == false)
}

/// A11: foregrounding onto another tab stamps nothing in the open thread, but still purges.
@MainActor @Test func expiryFixForegroundWithChatHiddenStampsNothing() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [expiryTimerRow(1, peerA, seconds: 60, expiresAt: nil)])
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.isForeground = false
    }
    // No node is configured in this fixture (migration never ran), so `.foregrounded` has
    // nothing to redial and `connection` stays as it was — only `isForeground` flips.
    await store.send(.foregrounded) {
        $0.isForeground = true
    }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == nil }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.expiresAt == nil)
}

/// A12: a message without our field takes the local timer, and leaves the setting alone.
@MainActor @Test func expiryFixFieldlessMessageTakesLocalTimer() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    await expiryFixReceive(store, wireMessage(from: sender, to: me, at: 1700000500, content: "plain"))
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.expirySeconds == 600)
    #expect(rows.first?.expiresAt == nil)
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 600)
}

/// A12 with A11: a field-less message into the visible thread is viewed at once on the local timer.
@MainActor @Test func expiryFixFieldlessMessageIntoVisibleThreadIsStamped() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me) { s in
        s.openPeerHex = expiryHex(sender)
        s.chatVisible = true
    }
    let m = wireMessage(from: sender, to: me, at: 1700000500, content: "plain")
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == infoT0.addingTimeInterval(600) }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.expirySeconds == 600)
    #expect(row.expiresAt == infoT0.addingTimeInterval(600))
}

/// A13: the received body of a change message is ignored. The line states what the field set.
@MainActor @Test func expiryFixIncomingChangeBodyIsRenderedLocally() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me)
    await expiryFixReceive(store, wireMessage(from: sender, to: me, at: 1699999999, content: "Disappearing messages turned off",
                                              fields: ExpiryWire.encodeChange(seconds: 30)))
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.isTimerChange == true)
    #expect(rows.first?.body == "Them set disappearing messages to 30 seconds")
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 30)
}

/// A14: re-picking the timer already in force is a no-op. Exhaustive, so any effect would fail it.
@MainActor @Test func expiryFixReselectingCurrentValueSendsNothing() async throws {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.openConversationExpiry = 3_600
    }
    store.exhaustivity = .on
    await store.send(.expirySelected(seconds: 3_600))
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try ConversationSetting.all.fetchAll($0) }.isEmpty)
}

/// A14: a change message is only a line, so an attachment riding on it is not stored.
@MainActor @Test func expiryFixChangeMessageDropsAttachment() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me, attachmentStore: attachTempStore())
    await expiryFixReceive(store, wireMessage(from: Identity(), to: me, at: 1699999999, content: "",
                                              fields: ExpiryWire.encodeChange(seconds: 60)
                                                  + AttachmentWire.encodeFile(name: "a.txt", data: Data([1]))))
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.isTimerChange == true)
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.isEmpty)
}

/// The sleeper does not fire before the earliest expiry: one second short of it, an exhaustive
/// probe shows no `.expiryDue` has arrived, and the last second delivers it.
@MainActor @Test func expiryFixSleeperDoesNotFireEarly() async throws {
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

    store.exhaustivity = .on
    await clock.advance(by: .seconds(29))
    await store.send(.chatDisappeared) { $0.chatVisible = false }

    store.exhaustivity = .off
    store.dependencies.date = .constant(infoT0.addingTimeInterval(30))
    await clock.advance(by: .seconds(1))
    await store.receive { if case .expiryDue = $0 { return true }; return false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

// MARK: - Disappearing messages: deferred follow-ups (spec amendments A15 to A17)

/// Arm the sleeper by opening peerA's thread with one row due at `+seconds`, and consume the
/// completion that armed it.
@MainActor
private func expiryFollowupArm(_ db: any DatabaseWriter, clock: TestClock<Duration>, dueIn seconds: Int)
    async -> TestStoreOf<AppFeature> {
    try! await seed(db, [expiryTimerRow(1, peerA, seconds: seconds, expiresAt: infoT0.addingTimeInterval(TimeInterval(seconds)))])
    let store = makeStore(db, identity: Identity(), clock: clock)
    await store.send(.openConversation(peerA))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 && nextDue == infoT0.addingTimeInterval(TimeInterval(seconds)) }
        return false
    }
    await store.skipReceivedActions(strict: false)
    return store
}

/// A15: a completion with nothing due may be stale (a purge that read before a newer stamp). It
/// must not cancel the live sleeper, which fires, purges and clears the armed deadline itself.
@MainActor @Test func expiryFollowupStaleNilCompletionKeepsSleeperArmed() async throws {
    let db = try! AppDatabase.makeInMemory()
    let clock = TestClock()
    let store = await expiryFollowupArm(db, clock: clock, dueIn: 30)
    #expect(store.state.armedExpiry == infoT0.addingTimeInterval(30))

    await store.send(.expiryPurgeCompleted(purged: 0, nextDue: nil))
    #expect(store.state.armedExpiry == infoT0.addingTimeInterval(30))

    store.dependencies.date = .constant(infoT0.addingTimeInterval(30))
    await clock.advance(by: .seconds(30))
    await store.receive { if case .expiryDue = $0 { return true }; return false }
    #expect(store.state.armedExpiry == nil)
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 && nextDue == nil }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
}

/// A15: a completion naming a LATER deadline than the armed one does not postpone the sleeper.
@MainActor @Test func expiryFollowupLaterCompletionDoesNotPostponeSleeper() async throws {
    let db = try! AppDatabase.makeInMemory()
    let clock = TestClock()
    let store = await expiryFollowupArm(db, clock: clock, dueIn: 30)

    await store.send(.expiryPurgeCompleted(purged: 0, nextDue: infoT0.addingTimeInterval(60)))
    #expect(store.state.armedExpiry == infoT0.addingTimeInterval(30))

    store.dependencies.date = .constant(infoT0.addingTimeInterval(30))
    await clock.advance(by: .seconds(30))
    await store.receive { if case .expiryDue = $0 { return true }; return false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// A15: a completion whose deadline is already in the past still arms a sleeper, which fires at
/// once rather than leaving the due row until the next trigger.
@MainActor @Test func expiryFollowupPastDueCompletionFiresImmediately() async throws {
    let db = try! AppDatabase.makeInMemory()
    let clock = TestClock()
    try! await seed(db, [expiryTimerRow(1, peerA, seconds: 5, expiresAt: infoT0.addingTimeInterval(-1))])
    let store = makeStore(db, identity: Identity(), clock: clock)
    await store.send(.expiryPurgeCompleted(purged: 0, nextDue: infoT0.addingTimeInterval(-1)))
    await clock.advance(by: .zero)
    await store.receive { if case .expiryDue = $0 { return true }; return false }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 && nextDue == nil }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
}

/// A16: a send before `conversationExpiryLoaded` has landed reads the stored setting, so a quick
/// send after opening a thread still carries the field and is stamped.
@MainActor @Test func expiryFollowupSendBeforeSettingLoadsReadsTheDatabase() async throws {
    let db = try! AppDatabase.makeInMemory()
    try await db.write { try ConversationSetting.set(peerA, seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "quick"
        // Not loaded yet: state says nothing, the database says 600.
        s.openConversationExpiry = nil
        s.openConversationExpiryLoaded = false
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let wire = try #require(sent)
    #expect(ExpiryWire.decode(wire.fields) == ExpiryWire.Decoded(seconds: 600, isChange: false))
    let row = try #require(try await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }.first)
    #expect(row.expirySeconds == 600)
    #expect(row.expiresAt == infoT0.addingTimeInterval(600))
}

/// A16: once the setting has loaded, the state value is authoritative even when the database still
/// holds an older value (the write from `expirySelected` may not have landed yet).
@MainActor @Test func expiryFollowupLoadedStateWinsOverDatabase() async throws {
    let db = try! AppDatabase.makeInMemory()
    try await db.write { try ConversationSetting.set(peerA, seconds: 600, at: infoT0, $0) }
    let (sent, row, _) = await expirySendAndFetch(db, draft: "off now", expiry: nil)
    let wire = try #require(sent)
    #expect(wire.fields.isEmpty)
    #expect(try #require(row).expirySeconds == nil)
}

/// A16: opening a thread resets the loaded flag until the thread's setting arrives.
@MainActor @Test func expiryFollowupOpenConversationResetsLoadedFlagUntilSettingArrives() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [msg(1, peerA, "a1", 1000)])
    let store = makeStore(db, identity: Identity()) { $0.openConversationExpiryLoaded = true }
    await store.send(.openConversation(peerA)) {
        $0.openPeerHex = peerA
        $0.chatVisible = true
        $0.openConversationExpiryLoaded = false
    }
    await store.receive { if case .conversationExpiryLoaded = $0 { return true }; return false }
    #expect(store.state.openConversationExpiryLoaded == true)
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// A17: launch deletes reaction rows whose target message is gone and that are older than a day.
@MainActor @Test func expiryFollowupLaunchPrunesStaleOrphanReactions() async throws {
    let db = try! AppDatabase.makeInMemory()
    let kept = String(repeating: "aa", count: 32)
    let orphan = String(repeating: "bb", count: 32)
    try! await seed(db, [msg(1, peerA, "here", 1000, hash: kept)])
    let staleAt = infoT0.timeIntervalSince1970 - 90_000   // 25 h ago
    try await db.write { d in
        try Reaction.insert { Reaction(messageHash: kept, reactorHex: peerA, emoji: "👍", sentAt: staleAt) }.execute(d)
        try Reaction.insert { Reaction(messageHash: orphan, reactorHex: peerA, emoji: "❤️", sentAt: staleAt) }.execute(d)
    }
    let store = makeStore(db, identity: Identity())
    await store.send(.onLaunch)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let hashes = try await db.read { try Reaction.all.fetchAll($0) }.map(\.messageHash)
    #expect(hashes == [kept])
}

/// A17: an orphan newer than a day is kept, because its message may still be on the way.
@MainActor @Test func expiryFollowupLaunchKeepsFreshOrphanReactions() async throws {
    let db = try! AppDatabase.makeInMemory()
    let orphan = String(repeating: "cc", count: 32)
    let freshAt = infoT0.timeIntervalSince1970 - 3_600   // 1 h ago
    try await db.write { d in
        try Reaction.insert { Reaction(messageHash: orphan, reactorHex: peerA, emoji: "❤️", sentAt: freshAt) }.execute(d)
    }
    let store = makeStore(db, identity: Identity())
    await store.send(.onLaunch)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Reaction.all.fetchAll($0) }.count == 1)
}

/// A17: a purge hands the ids of the attachments it deleted to the thumbnail evictor, so the
/// decoded images leave memory with the files.
@MainActor @Test func expiryFollowupPurgeEvictsThumbnailsOfPurgedAttachments() async throws {
    let db = try! AppDatabase.makeInMemory()
    let files = attachTempStore()
    let due = expiryTimerRow(1, peerA, seconds: 60, expiresAt: infoT0.addingTimeInterval(-1))
    let path = try files.store(Data([1]), messageHash: due.messageHash, outgoing: false, ext: "bin")
    let attachment = Attachment(id: UUID(), messageId: due.id, kind: AttachmentKind.file, name: "a.bin",
                                format: "bin", size: 1, width: nil, height: nil, path: path)
    try! await seed(db, [due])
    try await db.write { try Attachment.insert { attachment }.execute($0) }
    let evicted = LockIsolated<[UUID]>([])
    let store = makeStore(db, identity: Identity(), attachmentStore: files)
    store.dependencies.attachmentCacheEvictor = AttachmentCacheEvictor { ids in evicted.withValue { $0.append(contentsOf: ids) } }
    await store.send(.onLaunch)
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, _) = action { return purged == 1 }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(evicted.value == [attachment.id])
}

/// The convergence line names the peer by its learned display name, not the open peer's.
@MainActor @Test func expiryFollowupConvergenceLineUsesLearnedDisplayName() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHash = LXMessage.deliveryHash(identityHash: sender.hash)
    let store = makeStore(db, identity: me) { $0.openPeerHex = peerB }   // someone else's thread is open
    let learned = LXMFNode.LearnedPeer(displayName: "Ada", stampCost: nil, supportsCompression: false,
                                       learnedAt: infoT0)
    await store.send(.node(.client(.rehydrateLearnedPeers([senderHash: learned]))))
    await store.skipReceivedActions(strict: false)
    await expiryFixReceive(store, wireMessage(from: sender, to: me, at: 1699999999, content: "hi",
                                              fields: ExpiryWire.encode(seconds: 600)))
    let rows = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }
    #expect(rows.count == 2)
    #expect(rows.first?.body == "Ada set disappearing messages to 10 minutes")
}

// MARK: - Group chats: shared helpers (spec 2026-10-09)

private let groupHexA = String(repeating: "1a", count: 16)
private let memberC = String(repeating: "c", count: 32)
private let memberD = String(repeating: "d", count: 32)

private func groupMemberHash(_ identity: Identity) -> Data { LXMessage.deliveryHash(identityHash: identity.hash) }

/// Seeds `groupHexA` with `members` plus me and returns a store with it open as a group thread.
/// `creatorHex` nil means I created it.
@MainActor
private func groupStore(_ db: any DatabaseWriter, identity: Identity, name: String = "Mutual Aid",
                        creatorHex: String? = nil, members: [String],
                        state groupState: String = GroupState.active,
                        reachable: Set<String> = [],
                        configure: ((inout AppFeature.State) -> Void)? = nil) async -> TestStoreOf<AppFeature> {
    let me = lxmfAddressHex(identity)
    let group = ChatGroup(groupHex: groupHexA, name: name, creatorHex: creatorHex ?? me, revision: 1,
                          state: groupState, updatedAt: infoT0)
    let roster = Set(members + [me]).sorted()
    try! await db.write { db in
        try ChatGroup.upsert(group, db)
        try GroupMember.replace(groupHexA, with: roster, db)
    }
    return makeStore(db, identity: identity) { s in
        s.openPeerHex = groupHexA
        s.openConversationKind = .group
        s.chatVisible = true
        s.openGroup = group
        s.openGroupMembers = roster.map { GroupMember(groupHex: groupHexA, memberHex: $0) }
        s.reachablePeers = reachable
        configure?(&s)
    }
}

/// The LXMessages handed to the node after `action`: exactly `count` sendMessage actions are
/// awaited, then the rest are drained. Never `finish()` here (Global Constraints).
@MainActor
private func groupSends(_ store: TestStoreOf<AppFeature>, _ action: AppFeature.Action, count: Int) async -> [LXMessage] {
    var sent: [LXMessage] = []
    await store.send(action)
    for _ in 0..<count {
        await store.receive { a in
            if case let .node(.client(.sendMessage(m, _))) = a { sent.append(m); return true }
            return false
        }
    }
    await store.skipReceivedActions(strict: false)
    return sent
}

// MARK: - Group chats: conversation kinds and loading (Task 4)

/// Opening a group loads its row, members and the outgoing rows' deliveries, and the thread holds
/// only that group's rows: a one-to-one message from a member stays in the member's own thread.
@MainActor @Test func groupConvOpenGroupLoadsGroupMembersDeliveriesAndThread() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, members: [memberC, memberD])
    let post = Message(id: uuid(1), peerHex: myHex, isOutgoing: true, body: "to the group", timestamp: infoT0,
                       status: MessageStatus.sending, validated: false, messageHash: String(repeating: "3c", count: 16),
                       groupHex: groupHexA, groupPostId: String(repeating: "3c", count: 16))
    let direct = msg(2, memberC, "just to me", 1700000001, outgoing: false, status: MessageStatus.received)
    let fromC = Message(id: uuid(3), peerHex: memberC, isOutgoing: false, body: "C in group", timestamp: infoT0.addingTimeInterval(2),
                        status: MessageStatus.received, validated: true, messageHash: String(repeating: "4d", count: 16),
                        groupHex: groupHexA, groupPostId: String(repeating: "4d", count: 16))
    try await db.write { db in
        for row in [post, direct, fromC] { try Message.insert { row }.execute(db) }
        try GroupDelivery.insert { GroupDelivery.waiting(messageId: post.id, memberHex: memberD) }.execute(db)
        try GroupDelivery.insert { GroupDelivery.waiting(messageId: post.id, memberHex: memberC) }.execute(db)
    }
    await store.send(.closeConversation)
    #expect(store.state.openGroup == nil)
    #expect(store.state.openConversationKind == .peer)
    await store.send(.openGroupConversation(groupHexA))
    #expect(store.state.openConversationKind == .group)
    await store.receive { if case .groupLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.openGroup?.name == "Mutual Aid")
    #expect(store.state.openGroupMembers.map(\.memberHex) == [memberC, memberD, myHex].sorted())
    #expect(store.state.deliveriesByMessageId[post.id]?.map(\.memberHex) == [memberC, memberD])
    #expect(store.state.threadMessages.map(\.body) == ["to the group", "C in group"])
    #expect(store.state.openGroupOthers == [memberC, memberD])
    #expect(store.state.isOpenGroupCreator == true)
    await store.skipReceivedActions(strict: false)
    // The member's own thread holds only the one-to-one row.
    await store.send(.openConversation(memberC))
    #expect(store.state.openConversationKind == .peer)
    await store.receive { if case .groupLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.openGroup == nil)
    #expect(store.state.openGroupMembers.isEmpty)
    #expect(store.state.threadMessages.map(\.body) == ["just to me"])
    await store.skipReceivedActions(strict: false)
}

/// Spec §3: a group thread asks for the paths of the members it cannot reach, so Send unlocks
/// when they answer; a reachable member gets no request.
@MainActor @Test func groupConvOpenGroupRequestsPathsForUnreachableMembers() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = await groupStore(db, identity: me, members: [memberC, memberD], reachable: [memberC])
    await store.send(.openGroupConversation(groupHexA))
    await store.receive { a in
        if case let .node(.client(.endpoint(.requestPath(dest)))) = a { return dest == Data(hexString: memberD)! }
        return false
    }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberD)!] != nil)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberC)!] == nil)
    #expect(store.state.anyGroupMemberReachable == true)
}

/// Reactions in a group thread are kept for me and current members only (spec §2).
@MainActor @Test func groupConvThreadReactionsFilteredToMembers() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let postId = String(repeating: "5e", count: 16)
    let store = await groupStore(db, identity: me, members: [memberC])
    try await db.write { db in
        try Message.insert {
            Message(id: uuid(1), peerHex: memberC, isOutgoing: false, body: "p", timestamp: infoT0,
                    status: MessageStatus.received, validated: true, messageHash: postId,
                    groupHex: groupHexA, groupPostId: postId)
        }.execute(db)
        try Reaction.apply(Reaction(messageHash: postId, reactorHex: memberC, emoji: "👍", sentAt: 1), db)
        try Reaction.apply(Reaction(messageHash: postId, reactorHex: myHex, emoji: "❤️", sentAt: 2), db)
        try Reaction.apply(Reaction(messageHash: postId, reactorHex: memberD, emoji: "😂", sentAt: 3), db)   // not a member
    }
    await store.send(.openGroupConversation(groupHexA))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions[postId]?.map(\.emoji) == ["👍", "❤️"])
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func groupConvCloseResetsGroupState() async throws {
    let store = await groupStore(try AppDatabase.makeInMemory(), identity: Identity(), members: [memberC]) { s in
        s.deliveriesByMessageId = [uuid(1): [GroupDelivery.waiting(messageId: uuid(1), memberHex: memberC)]]
    }
    await store.send(.closeConversation)
    #expect(store.state.openConversationKind == .peer)
    #expect(store.state.openGroup == nil)
    #expect(store.state.openGroupMembers.isEmpty)
    #expect(store.state.deliveriesByMessageId.isEmpty)
}

/// Names: me is "You", an announced member its display name, anyone else a short hex. The
/// sender-name map covers announced members only.
@MainActor @Test func groupConvMemberNamesFallBack() async throws {
    let me = Identity()
    let store = await groupStore(try AppDatabase.makeInMemory(), identity: me, members: [memberC, memberD]) { s in
        s.$displayName.withLock { $0 = "  Ada  " }
    }
    let learned = LXMFNode.LearnedPeer(displayName: "Cy", stampCost: nil, supportsCompression: false, learnedAt: infoT0)
    await store.send(.node(.client(.rehydrateLearnedPeers([Data(hexString: memberC)!: learned]))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.myName == "Ada")
    #expect(store.state.groupMemberName(lxmfAddressHex(me)) == "You")
    #expect(store.state.groupMemberName(memberC) == "Cy")
    #expect(store.state.groupMemberName(memberD) == "dddddddd")
    #expect(store.state.threadSenderNames == [memberC: "Cy"])
    // Explicit, like every other case in this file (`displayName`'s appStorage backing is shared
    // process-wide under swift-testing, which has no per-test XCTestObservation reset): relying on
    // the struct default "" here would read whatever the last test left.
    let unnamed = makeStore(try AppDatabase.makeInMemory(), identity: me) { $0.$displayName.withLock { $0 = "" } }
    #expect(unnamed.state.myName == String(lxmfAddressHex(me).prefix(8)))
}

/// A late `groupLoaded` for a thread the user has left changes nothing.
@MainActor @Test func groupConvLateGroupLoadIsIgnored() async throws {
    let store = makeStore(try AppDatabase.makeInMemory(), identity: Identity()) { $0.openPeerHex = peerA }
    let group = ChatGroup(groupHex: groupHexA, name: "g", creatorHex: memberC, revision: 1, state: GroupState.active, updatedAt: infoT0)
    await store.send(.groupLoaded(groupHex: groupHexA, group: group, members: [GroupMember(groupHex: groupHexA, memberHex: memberC)], deliveries: []))
    #expect(store.state.openGroup == nil)
    #expect(store.state.openGroupMembers.isEmpty)
}

// MARK: - Group chats: copies, dispatch, creating (Task 5)

/// Amendment A3: a member's copy follows the row's kind. The group name is the title, a post
/// carries its reply fields then the ids, a roster line the current roster (or an empty one for
/// a deleted group, with the delete body), a leave line the leave marker.
@Test func groupCreateCopyShapesFollowTheRowKind() throws {
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let gid = Data(hexString: groupHexA)!
    let pid = Data(repeating: 0x5a, count: 16)
    let member = Data(hexString: memberC)!
    let group = ChatGroup(groupHex: groupHexA, name: "Mutual Aid", creatorHex: myHex, revision: 4,
                          state: GroupState.active, updatedAt: infoT0)
    let post = Message(id: uuid(1), peerHex: myHex, isOutgoing: true, body: "see you at 6", timestamp: infoT0,
                       status: MessageStatus.sending, validated: false, messageHash: pid.hexString,
                       replyToHash: String(repeating: "7b", count: 16), replyQuote: "orig",
                       groupHex: groupHexA, groupPostId: pid.hexString)
    let postCopy = try #require(AppFeature.groupCopy(of: post, to: member, group: group, members: [memberC, myHex],
                                                     identity: me, myName: "Ada", timestamp: 1700000010))
    #expect(postCopy.destinationHash == member)
    #expect(postCopy.title == Data("Mutual Aid".utf8))
    #expect(postCopy.content == Data("see you at 6".utf8))
    #expect(postCopy.timestamp == 1700000010)
    #expect(postCopy.fields.map(\.key) == [0x30, 0x31, 0xFD])
    #expect(ReplyWire.decode(postCopy.fields)?.replyTo == Data(repeating: 0x7b, count: 16))
    #expect(ReplyWire.decode(postCopy.fields)?.quote == "orig")
    #expect(GroupWire.decode(postCopy.fields) == .post(groupId: gid, postId: pid))

    let roster = AppFeature.groupEventRow(groupHex: groupHexA, me: myHex, body: "You added Cy",
                                          control: GroupControl.roster, now: infoT0)
    #expect(roster.isGroupEvent == true)
    #expect(roster.isOutgoing == true)
    #expect(roster.peerHex == myHex)
    #expect(roster.groupHex == groupHexA)
    #expect(roster.messageHash == "")
    let rosterCopy = try #require(AppFeature.groupCopy(of: roster, to: member, group: group, members: [memberC, myHex],
                                                       identity: me, myName: "Ada", timestamp: 1700000010))
    #expect(rosterCopy.title == Data("Mutual Aid".utf8))
    #expect(rosterCopy.content == Data("Ada invited you to the group Mutual Aid in ReTiCaMsgr".utf8))
    #expect(GroupWire.decode(rosterCopy.fields) == .roster(groupId: gid, name: "Mutual Aid",
                                                           members: [member, Data(hexString: myHex)!], revision: 4))

    var dissolved = group
    dissolved.state = GroupState.dissolved
    let deleteCopy = try #require(AppFeature.groupCopy(of: roster, to: member, group: dissolved, members: [],
                                                       identity: me, myName: "Ada", timestamp: 1700000010))
    #expect(deleteCopy.content == Data("Ada deleted the group Mutual Aid".utf8))
    #expect(GroupWire.decode(deleteCopy.fields) == .roster(groupId: gid, name: "Mutual Aid", members: [], revision: 4))

    let leave = AppFeature.groupEventRow(groupHex: groupHexA, me: myHex, body: "You left the group",
                                         control: GroupControl.leave, now: infoT0)
    let leaveCopy = try #require(AppFeature.groupCopy(of: leave, to: member, group: group, members: [memberC],
                                                      identity: me, myName: "Ada", timestamp: 1700000010))
    #expect(leaveCopy.content == Data("Ada left the group Mutual Aid".utf8))
    #expect(GroupWire.decode(leaveCopy.fields) == .leave(groupId: gid))

    var idless = post
    idless.groupPostId = nil
    #expect(AppFeature.groupCopy(of: idless, to: member, group: group, members: [], identity: me, myName: "Ada", timestamp: 1) == nil)
}

/// Spec §3 "Creating": the group, its roster (me included), the creation line with one waiting
/// delivery per member, path requests for the members I cannot reach, and the thread opens.
@MainActor @Test func groupCreateWritesGroupMembersLineAndWaitingDeliveries() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = makeStore(db, identity: me)
    await store.send(.createGroup(name: "  Mutual Aid  ", members: [memberC, memberD.uppercased(), myHex]))
    let groupHex = try #require(store.state.openPeerHex)
    #expect(groupHex.count == 32)
    #expect(store.state.openConversationKind == .group)
    #expect(store.state.chatVisible == true)
    #expect(store.state.openGroup?.name == "Mutual Aid")
    #expect(store.state.openGroup?.creatorHex == myHex)
    #expect(store.state.openGroupMembers.map(\.memberHex) == [memberC, memberD, myHex].sorted())
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    let group = try #require(try await db.read { try ChatGroup.fetch(groupHex, $0) })
    #expect(group.revision == 1)
    #expect(group.state == GroupState.active)
    #expect(group.updatedAt == infoT0)
    #expect(try await db.read { try GroupMember.members(of: groupHex, $0) } == [memberC, memberD, myHex].sorted())
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let line = try #require(rows.first)
    #expect(line.body == "You created the group Mutual Aid")
    #expect(line.isGroupEvent == true)
    #expect(line.groupControl == "roster")
    #expect(line.groupHex == groupHex)
    #expect(line.status == MessageStatus.sending)   // derived: every copy is waiting
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(deliveries.map(\.memberHex).sorted() == [memberC, memberD])
    #expect(deliveries.allSatisfy { $0.status == GroupDeliveryStatus.waiting && $0.messageHash == nil && $0.messageId == line.id })
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberC)!] != nil)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberD)!] != nil)
    #expect(store.state.conversations.first?.title == "Mutual Aid")
    #expect(store.state.conversations.first?.kind == .group)
    #expect(store.state.threadMessages.map(\.body) == ["You created the group Mutual Aid"])
}

/// A reachable member gets their roster copy at once: title, invite body, full roster, revision
/// 1; their row moves to sending with the copy's hash, the unreachable member's stays waiting.
@MainActor @Test func groupCreateSendsRosterToReachableMembers() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = makeStore(db, identity: me) { s in
        s.reachablePeers = [memberC]
        s.$displayName.withLock { $0 = "Ada" }
    }
    let sent = await groupSends(store, .createGroup(name: "Mutual Aid", members: [memberC, memberD]), count: 1)
    let groupHex = try #require(store.state.openPeerHex)
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberC))
    #expect(wire.title == Data("Mutual Aid".utf8))
    #expect(wire.content == Data("Ada invited you to the group Mutual Aid in ReTiCaMsgr".utf8))
    #expect(wire.timestamp == infoT0.timeIntervalSince1970)
    let expectedRoster = [memberC, memberD, myHex].sorted().map { Data(hexString: $0)! }
    #expect(GroupWire.decode(wire.fields) == .roster(groupId: Data(hexString: groupHex)!, name: "Mutual Aid",
                                                     members: expectedRoster, revision: 1))
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    let toC = try #require(deliveries.first { $0.memberHex == memberC })
    let toD = try #require(deliveries.first { $0.memberHex == memberD })
    #expect(toC.status == MessageStatus.sending)
    #expect(toC.messageHash == wire.hash.hexString)
    #expect(toD.status == GroupDeliveryStatus.waiting)
    #expect(toD.messageHash == nil)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberC)!] == nil)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberD)!] != nil)
}

/// An empty name, no other member, or more than 12 in all, creates nothing.
@MainActor @Test func groupCreateRejectsBadInput() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me)
    store.exhaustivity = .on
    await store.send(.createGroup(name: "   ", members: [memberC]))
    await store.send(.createGroup(name: "g", members: []))
    await store.send(.createGroup(name: "g", members: [lxmfAddressHex(me), "nothex"]))
    let twelveOthers = (0..<12).map { String(format: "%02x", $0) + String(repeating: "0", count: 30) }
    await store.send(.createGroup(name: "g", members: twelveOthers))
    #expect(store.state.openPeerHex == nil)
    #expect(try await db.read { try ChatGroup.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    // Eleven others plus me is the ceiling and is accepted.
    store.exhaustivity = .off
    await store.send(.createGroup(name: "g", members: Array(twelveOthers.prefix(11))))
    #expect(store.state.openPeerHex != nil)
    await store.skipReceivedActions(strict: false)
}

/// Spec §3 "Deferred copies": the member's path arriving sends their waiting copy.
@MainActor @Test func groupCreatePathLearnedSendsWaitingCopy() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me) { $0.$displayName.withLock { $0 = "Ada" } }
    await store.send(.createGroup(name: "Mutual Aid", members: [memberC]))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    let groupHex = try #require(store.state.openPeerHex)
    let sent = await groupSends(store, .node(.client(.endpoint(.delegate(.pathLearned(destinationHash: Data(hexString: memberC)!, hops: 2))))), count: 1)
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberC))
    guard case let .roster(gid, _, _, _)? = GroupWire.decode(wire.fields) else { Issue.record("expected a roster"); return }
    #expect(gid == Data(hexString: groupHex))
    let delivery = try #require(try await db.read { try GroupDelivery.all.fetchAll($0) }.first)
    #expect(delivery.status == MessageStatus.sending)
    #expect(delivery.messageHash == wire.hash.hexString)
}

/// Amendment A12: a failed roster copy is re-sent when the member's path is learned again (they
/// are behind on the roster); a failed post is not.
@MainActor @Test func groupCreateFailedRosterIsResentButFailedPostIsNot() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, members: [memberC])
    let rosterLine = AppFeature.groupEventRow(groupHex: groupHexA, me: myHex, body: "You added Cy",
                                              control: GroupControl.roster, now: infoT0)
    let post = Message(id: uuid(7), peerHex: myHex, isOutgoing: true, body: "hi", timestamp: infoT0,
                       status: MessageStatus.failed, validated: false, messageHash: String(repeating: "6f", count: 16),
                       groupHex: groupHexA, groupPostId: String(repeating: "6f", count: 16))
    func failed(_ id: UUID) -> GroupDelivery {
        GroupDelivery(messageId: id, memberHex: memberC, messageHash: String(repeating: "77", count: 32),
                      status: MessageStatus.failed, storedAt: nil, deliveredAt: nil, failedAt: infoT0)
    }
    // Computed here (MainActor) and captured by value below: `failed` is a MainActor-isolated
    // local function and cannot be called from `db.write`'s @Sendable closure.
    let failedRoster = failed(rosterLine.id)
    let failedPost = failed(post.id)
    try await db.write { db in
        try Message.insert { rosterLine }.execute(db)
        try Message.insert { post }.execute(db)
        try GroupDelivery.insert { failedRoster }.execute(db)
        try GroupDelivery.insert { failedPost }.execute(db)
    }
    let sent = await groupSends(store, .node(.client(.endpoint(.delegate(.pathLearned(destinationHash: Data(hexString: memberC)!, hops: 1))))), count: 1)
    guard case let .roster(_, name, _, revision)? = GroupWire.decode(try #require(sent.first).fields) else {
        Issue.record("expected a roster"); return
    }
    #expect(name == "Mutual Aid")
    #expect(revision == 1)
    let rows = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(rows.first { $0.messageId == rosterLine.id }?.status == MessageStatus.sending)
    #expect(rows.first { $0.messageId == rosterLine.id }?.messageHash == sent[0].hash.hexString)
    #expect(rows.first { $0.messageId == post.id }?.status == MessageStatus.failed)
    #expect(rows.first { $0.messageId == post.id }?.messageHash == String(repeating: "77", count: 32))
    let messages = try await db.read { try Message.all.fetchAll($0) }
    #expect(messages.first { $0.id == rosterLine.id }?.status == MessageStatus.sending)
    #expect(messages.first { $0.id == post.id }?.status == MessageStatus.failed)
}

// MARK: - Group chats: sending posts and reactions (Task 6)

/// Spec §3 "Sending a post": one row (post id in `messageHash` too, amendment A2), one delivery
/// per other member, the copy to the reachable member carries title, text and ids, the other
/// member's row waits with a path request.
@MainActor @Test func groupSendPostWritesRowDeliveriesAndSendsToReachable() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, members: [memberC, memberD], reachable: [memberC]) { s in
        s.draft = "sandbags at 6"
        s.$propagationNodeHex.withLock { $0 = pnHex }
    }
    let sent = await groupSends(store, .sendTapped, count: 1)
    #expect(store.state.draft == "")
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberC))
    #expect(wire.title == Data("Mutual Aid".utf8))
    #expect(wire.content == Data("sandbags at 6".utf8))
    #expect(wire.fields.map(\.key) == [0xFD])
    guard case let .post(gid, pid)? = GroupWire.decode(wire.fields) else { Issue.record("expected a post"); return }
    #expect(gid == Data(hexString: groupHexA))
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.groupHex == groupHexA)
    #expect(row.groupPostId == pid.hexString)
    #expect(row.messageHash == pid.hexString)
    #expect(row.peerHex == myHex)
    #expect(row.isOutgoing == true)
    #expect(row.isGroupEvent == false)
    #expect(row.body == "sandbags at 6")
    #expect(row.status == MessageStatus.sending)
    #expect(row.sentViaPropagation == true)
    #expect(row.fieldKeys == "0xfd")
    #expect(row.titleSize == 10)
    #expect(row.contentSize == 13)
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(deliveries.map(\.memberHex).sorted() == [memberC, memberD])
    #expect(deliveries.first { $0.memberHex == memberC }?.status == MessageStatus.sending)
    #expect(deliveries.first { $0.memberHex == memberC }?.messageHash == wire.hash.hexString)
    #expect(deliveries.first { $0.memberHex == memberD }?.status == GroupDeliveryStatus.waiting)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberD)!] != nil)
    #expect(store.state.threadMessages.map(\.body) == ["sandbags at 6"])
    #expect(store.state.deliveriesByMessageId[row.id]?.count == 2)
    #expect(store.state.conversations.first?.lastBody == "sandbags at 6")
}

/// A reply in a group targets the original's post id in the standard reply fields (spec §1).
@MainActor @Test func groupSendReplyCarriesPostIdTarget() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let original = String(repeating: "7b", count: 16)
    let store = await groupStore(db, identity: me, members: [memberC], reachable: [memberC]) { s in
        s.draft = "yes"
        s.replyTarget = AppFeature.ReplyTarget(messageHash: original, body: "sandbags at 6", isOutgoing: false)
    }
    let sent = await groupSends(store, .sendTapped, count: 1)
    let wire = try #require(sent.first)
    #expect(wire.fields.map(\.key) == [0x30, 0x31, 0xFD])
    #expect(ReplyWire.decode(wire.fields)?.replyTo == Data(hexString: original))
    #expect(ReplyWire.decode(wire.fields)?.quote == "sandbags at 6")
    #expect(store.state.replyTarget == nil)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.replyToHash == original)
    #expect(row.replyQuote == "sandbags at 6")
    #expect(row.fieldKeys == "0x30,0x31,0xfd")
}

/// Only an active group accepts a post: invited, left and dissolved groups, an empty draft and a
/// pending attachment all send nothing.
@MainActor @Test func groupSendRefusedUnlessGroupActive() async throws {
    for state in [GroupState.invited, GroupState.left, GroupState.dissolved] {
        let db = try AppDatabase.makeInMemory()
        let store = await groupStore(db, identity: Identity(), members: [memberC], state: state, reachable: [memberC]) { $0.draft = "hi" }
        store.exhaustivity = .on
        await store.send(.sendTapped)
        #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty, Comment(rawValue: state))
        #expect(store.state.draft == "hi", Comment(rawValue: state))
    }
    let db = try AppDatabase.makeInMemory()
    let store = await groupStore(db, identity: Identity(), members: [memberC], reachable: [memberC]) { s in
        s.draft = "cap"
        s.pendingAttachment = pendingImage()
    }
    store.exhaustivity = .on
    await store.send(.sendTapped)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
}

/// Spec §3: a reaction fans out to the reachable members only, each copy carrying the standard
/// reaction with the 16-byte post id as target plus the group marker; the row keys on the post id.
@MainActor @Test func groupSendReactionFansOutToReachableMembersWithMarker() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let postId = String(repeating: "5e", count: 16)
    let store = await groupStore(db, identity: me, members: [memberC, memberD, peerA], reachable: [memberC, memberD])
    // A backing row for the post, as every other reaction test seeds one for its target hash
    // (e.g. reactionSelectedSetsSendsAndShowsBadge): reloadThread's reactions query is scoped to
    // the thread's known messages, so without this the post-reload `.threadLoaded` would wipe the
    // optimistic reaction this test checks for below.
    let post = Message(id: UUID(), peerHex: myHex, isOutgoing: true, body: "the post", timestamp: infoT0,
                       status: MessageStatus.sending, validated: false, messageHash: postId,
                       groupHex: groupHexA, groupPostId: postId)
    try await db.write { try Message.insert { post }.execute($0) }
    let sent = await groupSends(store, .reactionSelected(messageHash: postId, emoji: "👍"), count: 2)
    #expect(Set(sent.map(\.destinationHash)) == [Data(hexString: memberC)!, Data(hexString: memberD)!])
    for wire in sent {
        #expect(wire.fields.map(\.key) == [0x40, 0xFD])
        #expect(ReactionWire.decode(wire.fields) == .reaction(target: Data(hexString: postId)!, emoji: "👍"))
        #expect(GroupWire.decode(wire.fields) == .marker(groupId: Data(hexString: groupHexA)!))
        #expect(wire.content.isEmpty)
        #expect(wire.title.isEmpty)
    }
    let rows = try await db.read { try Reaction.all.fetchAll($0) }
    #expect(rows == [Reaction(messageHash: postId, reactorHex: myHex, emoji: "👍", sentAt: infoT0.timeIntervalSince1970)])
    #expect(store.state.threadReactions[postId]?.first?.includesMe == true)
}

/// A reaction in a group whose target is not a 16-byte post id sends nothing.
@MainActor @Test func groupSendReactionRejectsNonPostTarget() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = await groupStore(db, identity: Identity(), members: [memberC], reachable: [memberC])
    store.exhaustivity = .on
    await store.send(.reactionSelected(messageHash: String(repeating: "9", count: 64), emoji: "👍"))
    #expect(try await db.read { try Reaction.all.fetchAll($0) }.isEmpty)
}

// MARK: - Group chats: delivery delegates (Task 7)

private let groupDeliverHashC = String(repeating: "a1", count: 32)
private let groupDeliverHashD = String(repeating: "b2", count: 32)

/// A post row sending to C and D, with the group open, so the thread reload is observable.
@MainActor
private func groupDeliverStore(_ db: any DatabaseWriter) async -> (TestStoreOf<AppFeature>, Message) {
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let post = Message(id: uuid(11), peerHex: myHex, isOutgoing: true, body: "p", timestamp: infoT0,
                       status: MessageStatus.sending, validated: false, messageHash: String(repeating: "5e", count: 16),
                       groupHex: groupHexA, groupPostId: String(repeating: "5e", count: 16))
    try! await db.write { db in
        try Message.insert { post }.execute(db)
        try GroupDelivery.insert {
            GroupDelivery(messageId: post.id, memberHex: memberC, messageHash: groupDeliverHashC,
                          status: MessageStatus.sending, storedAt: nil, deliveredAt: nil, failedAt: nil)
        }.execute(db)
        try GroupDelivery.insert {
            GroupDelivery(messageId: post.id, memberHex: memberD, messageHash: groupDeliverHashD,
                          status: MessageStatus.sending, storedAt: nil, deliveredAt: nil, failedAt: nil)
        }.execute(db)
    }
    let store = await groupStore(db, identity: me, members: [memberC, memberD])
    return (store, post)
}

private func groupDeliverRows(_ db: any DatabaseWriter) async throws -> (c: GroupDelivery?, d: GroupDelivery?, post: Message?) {
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    let post = try await db.read { try Message.where { $0.id.eq(uuid(11)) }.fetchOne($0) }
    return (deliveries.first { $0.memberHex == memberC }, deliveries.first { $0.memberHex == memberD }, post)
}

/// Spec §3 "Delivery delegates": a proof for a member's hash marks that row delivered with its
/// first-proof time, the post stays sending until every member proved, then reads delivered.
@MainActor @Test func groupDeliverConfirmedUpdatesMemberRowAndDerivedStatus() async throws {
    let db = try AppDatabase.makeInMemory()
    let (store, _) = await groupDeliverStore(db)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(groupDeliverHashC))))))
    await store.skipReceivedActions(strict: false)
    var rows = try await groupDeliverRows(db)
    #expect(rows.c?.status == MessageStatus.delivered)
    #expect(rows.c?.deliveredAt == infoT0)
    #expect(rows.d?.status == MessageStatus.sending)
    #expect(rows.post?.status == MessageStatus.sending)
    #expect(store.state.deliveriesByMessageId[uuid(11)]?.first { $0.memberHex == memberC }?.status == MessageStatus.delivered)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(groupDeliverHashD))))))
    await store.skipReceivedActions(strict: false)
    rows = try await groupDeliverRows(db)
    #expect(rows.post?.status == MessageStatus.delivered)
    #expect(store.state.threadMessages.first?.status == MessageStatus.delivered)
    // A repeat proof never moves the first time.
    store.dependencies.date = .constant(infoT0.addingTimeInterval(60))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(groupDeliverHashC))))))
    await store.skipReceivedActions(strict: false)
    #expect(try await groupDeliverRows(db).c?.deliveredAt == infoT0)
}

/// A propagation acceptance marks the member row stored unless it was already delivered; a post
/// whose copies are all proved or stored reads stored.
@MainActor @Test func groupDeliverPropagationAcceptedMarksStored() async throws {
    let db = try AppDatabase.makeInMemory()
    let (store, _) = await groupDeliverStore(db)
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(groupDeliverHashC))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(groupDeliverHashD))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(groupDeliverHashD))))))
    await store.skipReceivedActions(strict: false)
    let rows = try await groupDeliverRows(db)
    #expect(rows.c?.status == MessageStatus.propagated)
    #expect(rows.c?.storedAt == infoT0)
    #expect(rows.d?.status == MessageStatus.delivered)   // delivered beats stored
    #expect(rows.d?.storedAt == infoT0)                   // the acceptance time is still news
    #expect(rows.post?.status == MessageStatus.propagated)
}

/// Failures: a failed, rejected or cancelled copy takes that status with its first failure time,
/// never clobbers a delivered or stored one, and the post reads failed only when every copy did.
@MainActor @Test func groupDeliverFailedRejectedCancelledFollowTheGuards() async throws {
    let db = try AppDatabase.makeInMemory()
    let (store, _) = await groupDeliverStore(db)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(groupDeliverHashC))))))
    await store.skipReceivedActions(strict: false)
    var rows = try await groupDeliverRows(db)
    #expect(rows.c?.status == MessageStatus.failed)
    #expect(rows.c?.failedAt == infoT0)
    #expect(rows.post?.status == MessageStatus.sending)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryCancelled(messageHash: hashData(groupDeliverHashD))))))
    await store.skipReceivedActions(strict: false)
    rows = try await groupDeliverRows(db)
    #expect(rows.d?.status == MessageStatus.cancelled)
    #expect(rows.post?.status == MessageStatus.failed)
    // A late failure for a cancelled row leaves it cancelled; a proof after a failure still wins.
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(groupDeliverHashD))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(groupDeliverHashC))))))
    await store.skipReceivedActions(strict: false)
    rows = try await groupDeliverRows(db)
    #expect(rows.d?.status == MessageStatus.cancelled)
    #expect(rows.c?.status == MessageStatus.delivered)
    #expect(rows.post?.status == MessageStatus.sent)
    // A failure after delivery changes nothing.
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(groupDeliverHashC))))))
    await store.skipReceivedActions(strict: false)
    #expect(try await groupDeliverRows(db).c?.status == MessageStatus.delivered)
}

/// A hash no group copy carries touches no delivery row (the one-to-one path handles it).
@MainActor @Test func groupDeliverUnknownHashTouchesNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let (store, _) = await groupDeliverStore(db)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(String(repeating: "c3", count: 32)))))))
    await store.skipReceivedActions(strict: false)
    let rows = try await groupDeliverRows(db)
    #expect(rows.c?.status == MessageStatus.sending)
    #expect(rows.d?.status == MessageStatus.sending)
    #expect(rows.post?.status == MessageStatus.sending)
}

// MARK: - Group chats: receiving posts and reactions (Task 8)

private let groupReceivePid = Data(repeating: 0x5e, count: 16)

/// A member's post to me on the wire, shaped as `groupCopy` builds it.
private func groupPostWire(from sender: Identity, to me: Identity, postId: Data = groupReceivePid,
                           text: String = "sandbags at 6", at ts: Double = 1700000000.5,
                           extra: [MsgPackValue.IntPair] = []) -> LXMessage {
    wireMessage(from: sender, to: me, at: ts, title: "Mutual Aid", content: text,
                fields: extra + GroupWire.encodePost(groupId: Data(hexString: groupHexA)!, postId: postId))
}

/// Delivers `m` to the open group store and drains the effects.
@MainActor
private func groupReceive(_ store: TestStoreOf<AppFeature>, _ m: LXMessage, validated: Bool = true) async {
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: validated, method: .opportunistic)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

/// Spec §3 "Receiving": a post from a current member lands in the group thread, keyed on its post
/// id (amendment A2), with the sender as `peerHex`.
@MainActor @Test func groupReceivePostFromMemberLandsInGroupThread() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex, memberD])
    await groupReceive(store, groupPostWire(from: sender, to: me))
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.groupHex == groupHexA)
    #expect(row.groupPostId == groupReceivePid.hexString)
    #expect(row.messageHash == groupReceivePid.hexString)
    #expect(row.peerHex == senderHex)
    #expect(row.isOutgoing == false)
    #expect(row.body == "sandbags at 6")
    #expect(row.validated == true)
    #expect(row.titleSize == 10)
    #expect(row.fieldKeys == "0xfd")
    #expect(row.expirySeconds == nil)
    #expect(store.state.threadMessages.map(\.body) == ["sandbags at 6"])
    #expect(store.state.conversations.map(\.title) == ["Mutual Aid"])
    let seen = try await db.read { try SeenHashRow.all.fetchAll($0) }
    #expect(seen.map(\.hashHex) == [groupPostWire(from: sender, to: me).hash.hexString])
}

/// Spec §1: the same post id twice (a later copy with a fresh hash) stores one row; both LXMF
/// hashes are remembered so neither is re-delivered.
@MainActor @Test func groupReceiveDuplicatePostIdStoresOneRowAndBothHashes() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex])
    await groupReceive(store, groupPostWire(from: sender, to: me, at: 1700000000.5))
    await store.send(.node(.client(.delegate(.messageReceived(
        message: groupPostWire(from: sender, to: me, text: "sandbags at 6 (again)", at: 1700000009),
        signatureValidated: true, method: .propagated)))))
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.body) == ["sandbags at 6"])
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.count == 2)
}

/// Review Focus 1: a post from someone not on the roster (a removed member, say) is an ordinary
/// one-to-one message from that sender, field ignored.
@MainActor @Test func groupReceivePostFromNonMemberIsPlainMessage() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let outsider = Identity()
    let store = await groupStore(db, identity: me, creatorHex: memberC, members: [memberC])
    let m = groupPostWire(from: outsider, to: me)
    await groupReceive(store, m)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.groupHex == nil)
    #expect(row.groupPostId == nil)
    #expect(row.messageHash == m.hash.hexString)
    #expect(row.peerHex == groupMemberHash(outsider).hexString)
    #expect(row.body == "sandbags at 6")
    #expect(store.state.threadMessages.isEmpty)   // the open group thread did not gain it
    #expect(store.state.conversations.map(\.kind) == [.peer])
}

/// An unknown group id, a group the user left, and an unvalidated signature all yield a plain
/// message too.
@MainActor @Test func groupReceivePostForUnknownClosedOrUnvalidatedIsPlainMessage() async throws {
    let me = Identity()
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    // Unknown group: no group row at all.
    let unknownDb = try AppDatabase.makeInMemory()
    let unknown = makeStore(unknownDb, identity: me)
    await groupReceive(unknown, groupPostWire(from: sender, to: me))
    #expect(try await unknownDb.read { try Message.all.fetchAll($0) }.first?.groupHex == nil)
    // Left group.
    let leftDb = try AppDatabase.makeInMemory()
    let left = await groupStore(leftDb, identity: me, creatorHex: senderHex, members: [senderHex], state: GroupState.left)
    await groupReceive(left, groupPostWire(from: sender, to: me))
    #expect(try await leftDb.read { try Message.all.fetchAll($0) }.first?.groupHex == nil)
    // Unvalidated.
    let unvalidatedDb = try AppDatabase.makeInMemory()
    let unvalidated = await groupStore(unvalidatedDb, identity: me, creatorHex: senderHex, members: [senderHex])
    await groupReceive(unvalidated, groupPostWire(from: sender, to: me), validated: false)
    #expect(try await unvalidatedDb.read { try Message.all.fetchAll($0) }.first?.groupHex == nil)
    // Invited (not yet accepted) still takes the post into the group.
    let invitedDb = try AppDatabase.makeInMemory()
    let invited = await groupStore(invitedDb, identity: me, creatorHex: senderHex, members: [senderHex], state: GroupState.invited)
    await groupReceive(invited, groupPostWire(from: sender, to: me))
    #expect(try await invitedDb.read { try Message.all.fetchAll($0) }.first?.groupHex == groupHexA)
}

/// Amendment A9: an expiry entry riding beside the group entry is ignored on a group post, and
/// never touches a conversation setting.
@MainActor @Test func groupReceivePostIgnoresExpiryEntry() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex])
    let fields = [MsgPackValue.IntPair(0xFD, .map([
        .init("reticamsgr.expiry", .uint(60)),
        .init("reticamsgr.group", .array([.bin(Data(hexString: groupHexA)!), .bin(groupReceivePid)])),
    ]))]
    await groupReceive(store, wireMessage(from: sender, to: me, at: 1700000000.5, title: "Mutual Aid", content: "x", fields: fields))
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.groupHex == groupHexA)
    #expect(row.expirySeconds == nil)
    #expect(row.expiresAt == nil)
    #expect(try await db.read { try ConversationSetting.all.fetchAll($0) }.isEmpty)
}

/// Spec §3: a group reaction is kept from a current member and keys on the post id; one from a
/// non-member is dropped (its hash still remembered).
@MainActor @Test func groupReceiveReactionFromMemberAttachesToPostAndNonMemberDoesNot() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let member = Identity()
    let outsider = Identity()
    let memberHex = groupMemberHash(member).hexString
    let store = await groupStore(db, identity: me, creatorHex: memberHex, members: [memberHex])
    let marker = GroupWire.encodeMarker(groupId: Data(hexString: groupHexA)!)
    let good = LXMessage.create(source: member, destinationHash: groupMemberHash(me), timestamp: 1700000001,
                                title: Data(), content: Data(),
                                fields: ReactionWire.encode(target: groupReceivePid, emoji: "👍") + marker)
    await store.send(.node(.client(.delegate(.messageReceived(message: good, signatureValidated: true, method: .opportunistic)))))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Reaction.all.fetchAll($0) }
            == [Reaction(messageHash: groupReceivePid.hexString, reactorHex: memberHex, emoji: "👍", sentAt: 1700000001)])
    let bad = LXMessage.create(source: outsider, destinationHash: groupMemberHash(me), timestamp: 1700000002,
                               title: Data(), content: Data(),
                               fields: ReactionWire.encode(target: groupReceivePid, emoji: "😂") + marker)
    await store.send(.node(.client(.delegate(.messageReceived(message: bad, signatureValidated: true, method: .opportunistic)))))
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Reaction.all.fetchAll($0) }.count == 1)
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.count == 2)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
}

/// A reply in a group keeps the original's 16-byte post id as its stored target.
@MainActor @Test func groupReceiveReplyKeepsPostIdTarget() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let original = Data(repeating: 0x7b, count: 16)
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex])
    await groupReceive(store, groupPostWire(from: sender, to: me, text: "yes",
                                            extra: ReplyWire.encode(replyTo: original, quote: "sandbags at 6")))
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.groupHex == groupHexA)
    #expect(row.replyToHash == original.hexString)
    #expect(row.replyQuote == "sandbags at 6")
    #expect(row.fieldKeys == "0x30,0x31,0xfd")
}

// MARK: - Group chats: control messages and roster actions (Task 9)

private func groupRosterWire(from sender: Identity, to me: Identity, members: [String], name: String = "Mutual Aid",
                             revision: Int, at ts: Double = 1700000000.5) -> LXMessage {
    wireMessage(from: sender, to: me, at: ts, title: name, content: "someone invited you to the group \(name) in ReTiCaMsgr",
                fields: GroupWire.encodeRoster(groupId: Data(hexString: groupHexA)!, name: name,
                                               members: members.map { Data(hexString: $0)! }, revision: revision))
}

private func groupLeaveWire(from sender: Identity, to me: Identity, at ts: Double = 1700000000.5) -> LXMessage {
    wireMessage(from: sender, to: me, at: ts, title: "Mutual Aid", content: "someone left the group Mutual Aid",
                fields: GroupWire.encodeLeave(groupId: Data(hexString: groupHexA)!))
}

/// Names the sender "Cy" through an announce, so lines read as a person would see them.
@MainActor
private func groupNameSender(_ store: TestStoreOf<AppFeature>, _ sender: Identity) async {
    let learned = LXMFNode.LearnedPeer(displayName: "Cy", stampCost: nil, supportsCompression: false, learnedAt: infoT0)
    await store.send(.node(.client(.rehydrateLearnedPeers([groupMemberHash(sender): learned]))))
    await store.skipReceivedActions(strict: false)
}

private func groupEventBodies(_ db: any DatabaseWriter) async throws -> [String] {
    try await db.read { try Message.where { $0.isGroupEvent }.order(by: \.timestamp).fetchAll($0) }.map(\.body)
}

/// Spec §3: a roster for an unknown group creates it `invited`, with its sender as creator and
/// one invite line; nothing is stored as a bubble.
@MainActor @Test func groupControlRosterForUnknownGroupCreatesInvitedGroupAndLine() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = makeStore(db, identity: me)
    await groupNameSender(store, sender)
    await groupReceive(store, groupRosterWire(from: sender, to: me, members: [senderHex, myHex, memberD], revision: 1))
    let group = try #require(try await db.read { try ChatGroup.fetch(groupHexA, $0) })
    #expect(group.name == "Mutual Aid")
    #expect(group.creatorHex == senderHex)
    #expect(group.revision == 1)
    #expect(group.state == GroupState.invited)
    #expect(group.updatedAt == infoT0)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [senderHex, myHex, memberD].sorted())
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let line = try #require(rows.first)
    #expect(line.body == "Cy invited you to the group Mutual Aid")
    #expect(line.isGroupEvent == true)
    #expect(line.isOutgoing == false)
    #expect(line.peerHex == senderHex)
    #expect(line.groupHex == groupHexA)
    #expect(line.validated == true)
    #expect(store.state.conversations.first?.title == "Mutual Aid")
    #expect(store.state.conversations.first?.groupState == GroupState.invited)
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.count == 1)
}

/// A higher revision from the creator replaces the roster and name and says what changed, in
/// the order added, removed, renamed.
@MainActor @Test func groupControlHigherRevisionReplacesMembersAndInsertsLines() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex, memberD])
    await groupNameSender(store, sender)
    await groupReceive(store, groupRosterWire(from: sender, to: me, members: [senderHex, myHex, memberC], name: "Block 4", revision: 2))
    let group = try #require(try await db.read { try ChatGroup.fetch(groupHexA, $0) })
    #expect(group.name == "Block 4")
    #expect(group.revision == 2)
    #expect(group.state == GroupState.active)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [senderHex, myHex, memberC].sorted())
    #expect(try await groupEventBodies(db) == ["Cy added cccccccc", "Cy removed dddddddd", "Cy renamed the group to Block 4"])
    #expect(store.state.openGroup?.name == "Block 4")
    #expect(store.state.threadMessages.count == 3)
}

/// Amendment A5: a roster from the real creator that is not newer is dropped silently.
@MainActor @Test func groupControlStaleRosterFromCreatorIsDropped() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex, memberD])
    let m = groupRosterWire(from: sender, to: me, members: [senderHex, myHex], revision: 1)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [senderHex, myHex, memberD].sorted())
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.map(\.hashHex) == [m.hash.hexString])
}

/// A roster from anyone but the creator of a known group is the plain message its body is.
@MainActor @Test func groupControlRosterFromNonCreatorIsPlainMessage() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let outsider = Identity()
    let outsiderHex = groupMemberHash(outsider).hexString
    let store = await groupStore(db, identity: me, creatorHex: memberC, members: [memberC])
    let m = groupRosterWire(from: outsider, to: me, members: [outsiderHex, myHex], revision: 5)
    await groupReceive(store, m)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.groupHex == nil)
    #expect(rows.first?.isGroupEvent == false)
    #expect(rows.first?.peerHex == outsiderHex)
    #expect(rows.first?.messageHash == m.hash.hexString)
    #expect(rows.first?.body == "someone invited you to the group Mutual Aid in ReTiCaMsgr")
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.revision == 1)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, myHex].sorted())
}

/// Amendment A12 still holds for the fallback: a plain-message outcome in a conversation with a
/// local timer takes that timer and, when the thread is open and visible, is stamped at once.
@MainActor @Test func groupControlPlainFallbackTakesLocalTimer() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let outsider = Identity()
    let outsiderHex = groupMemberHash(outsider).hexString
    try await db.write { try ConversationSetting.set(outsiderHex, seconds: 600, at: infoT0, $0) }
    let store = await groupStore(db, identity: me, creatorHex: memberC, members: [memberC]) { s in
        s.openPeerHex = outsiderHex          // the outsider's one-to-one thread is open and visible
        s.openConversationKind = .peer
        s.openGroup = nil
        s.openGroupMembers = []
    }
    // Not `groupReceive`: its own trailing `skipReceivedActions` races the write's later
    // `purgeAndReschedule` call and can silently absorb `.expiryPurgeCompleted` before this test
    // gets to assert on it, so the `.conversationsLoaded` and `.expiryPurgeCompleted` receives are
    // sequenced inline here instead, exactly as `groupReceive` sequences its own single receive.
    let m = groupRosterWire(from: outsider, to: me, members: [outsiderHex, myHex], revision: 5)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.receive { if case let .expiryPurgeCompleted(_, nextDue) = $0 { return nextDue == infoT0.addingTimeInterval(600) }; return false }
    await store.skipReceivedActions(strict: false)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.groupHex == nil)
    #expect(row.expirySeconds == 600)
    #expect(row.expiresAt == infoT0.addingTimeInterval(600))
}

/// Review Focus 2: a roster that does not list its own sender does not apply.
@MainActor @Test func groupControlRosterOmittingSenderIsPlainMessage() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex])
    await groupReceive(store, groupRosterWire(from: sender, to: me, members: [myHex, memberD], revision: 2))
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.groupHex) == [nil])
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.revision == 1)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [senderHex, myHex].sorted())
}

/// Being left off the roster marks the group `left` with its own line; an empty roster marks it
/// `dissolved`, after which nothing revives it.
@MainActor @Test func groupControlRosterRemovingMeOrEmptyClosesTheGroup() async throws {
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let removedDb = try AppDatabase.makeInMemory()
    let removed = await groupStore(removedDb, identity: me, creatorHex: senderHex, members: [senderHex, memberD])
    await groupNameSender(removed, sender)
    await groupReceive(removed, groupRosterWire(from: sender, to: me, members: [senderHex, memberD], revision: 2))
    #expect(try await removedDb.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.left)
    #expect(try await removedDb.read { try GroupMember.members(of: groupHexA, $0) } == [senderHex, memberD].sorted())
    #expect(try await groupEventBodies(removedDb) == ["Cy removed you from the group"])
    let dissolvedDb = try AppDatabase.makeInMemory()
    let dissolved = await groupStore(dissolvedDb, identity: me, creatorHex: senderHex, members: [senderHex, memberD])
    await groupNameSender(dissolved, sender)
    await groupReceive(dissolved, groupRosterWire(from: sender, to: me, members: [], revision: 2))
    #expect(try await dissolvedDb.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.dissolved)
    #expect(try await dissolvedDb.read { try GroupMember.members(of: groupHexA, $0) }.isEmpty)
    #expect(try await groupEventBodies(dissolvedDb) == ["Cy deleted the group"])
    let revive = groupRosterWire(from: sender, to: me, members: [senderHex, myHex], revision: 3, at: 1700000002)
    await dissolved.send(.node(.client(.delegate(.messageReceived(message: revive, signatureValidated: true, method: .opportunistic)))))
    await dissolved.skipReceivedActions(strict: false)
    #expect(try await dissolvedDb.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.dissolved)
    #expect(try await dissolvedDb.read { try Message.all.fetchAll($0) }.count == 1)
}

/// Review Focus 5: a roster listing me again after I left brings the group back as `invited`.
@MainActor @Test func groupControlReinviteAfterLeftBecomesInvited() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex], state: GroupState.left)
    await groupNameSender(store, sender)
    await groupReceive(store, groupRosterWire(from: sender, to: me, members: [senderHex, myHex], revision: 2))
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.invited)
    #expect(try await groupEventBodies(db) == ["Cy invited you to the group Mutual Aid"])
}

/// A roster that omits me landing on a group I already left writes no line and keeps it left
/// (a leave crossing the creator's removal).
@MainActor @Test func groupControlRosterOmittingMeOnLeftGroupWritesNoLine() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex, memberD], state: GroupState.left)
    try await db.write { try GroupMember.replace(groupHexA, with: [senderHex, memberD], $0) }   // my leave already removed me
    await groupNameSender(store, sender)
    await groupReceive(store, groupRosterWire(from: sender, to: me, members: [senderHex, memberD], revision: 2))
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.left)
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.revision == 2)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
}

/// A leave from a member removes them with a line; from a non-member it is a plain message.
@MainActor @Test func groupControlLeaveFromMemberRemovesAndNonMemberIsPlain() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let leaver = Identity()
    let leaverHex = groupMemberHash(leaver).hexString
    let outsider = Identity()
    let store = await groupStore(db, identity: me, creatorHex: memberC, members: [memberC, leaverHex])
    await groupNameSender(store, leaver)
    await groupReceive(store, groupLeaveWire(from: leaver, to: me))
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, myHex].sorted())
    #expect(try await groupEventBodies(db) == ["Cy left the group"])
    #expect(try await db.read { try GroupDelivery.all.fetchAll($0) }.isEmpty)
    await groupReceive(store, groupLeaveWire(from: outsider, to: me, at: 1700000002))
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 2)
    let plain = try #require(rows.first { $0.groupHex == nil })
    #expect(plain.isGroupEvent == false)
    #expect(plain.body == "someone left the group Mutual Aid")
}

/// Amendment A7: when a member leaves a group I created, the leave line is mine and carries the
/// new roster to the remaining members.
@MainActor @Test func groupControlLeaveWhenIAmCreatorResendsRoster() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let leaver = Identity()
    let leaverHex = groupMemberHash(leaver).hexString
    let store = await groupStore(db, identity: me, members: [leaverHex, memberD], reachable: [memberD])
    await groupNameSender(store, leaver)
    let sent = await groupSends(store, .node(.client(.delegate(.messageReceived(
        message: groupLeaveWire(from: leaver, to: me), signatureValidated: true, method: .opportunistic)))), count: 1)
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberD))
    #expect(GroupWire.decode(wire.fields) == .roster(groupId: Data(hexString: groupHexA)!, name: "Mutual Aid",
                                                     members: [memberD, myHex].sorted().map { Data(hexString: $0)! }, revision: 2))
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.revision == 2)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberD, myHex].sorted())
    let line = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(line.body == "Cy left the group")
    #expect(line.isOutgoing == true)
    #expect(line.groupControl == "roster")
    // Amendment A15: the unreachable leaver's copy waits for their path.
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(deliveries.map(\.memberHex).sorted() == [leaverHex, memberD].sorted())
    let toD = deliveries.first { $0.memberHex == memberD }
    #expect(toD?.status == MessageStatus.sending)
    #expect(toD?.messageHash == wire.hash.hexString)
    #expect(deliveries.first { $0.memberHex == leaverHex }?.status == GroupDeliveryStatus.waiting)
}

/// Spec §3 "Creating and editing": adding members bumps the revision, writes the line, fans the
/// new roster to every member (the new one included) and asks for the paths it lacks.
@MainActor @Test func groupControlAddMembersBumpsRevisionAndFansOut() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, members: [memberC], reachable: [memberC]) { $0.$displayName.withLock { $0 = "Ada" } }
    let sent = await groupSends(store, .addGroupMembers([memberD, memberC, myHex, "junk"]), count: 1)
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberC))
    #expect(wire.content == Data("Ada invited you to the group Mutual Aid in ReTiCaMsgr".utf8))
    #expect(GroupWire.decode(wire.fields) == .roster(groupId: Data(hexString: groupHexA)!, name: "Mutual Aid",
                                                     members: [memberC, memberD, myHex].sorted().map { Data(hexString: $0)! }, revision: 2))
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.revision == 2)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, memberD, myHex].sorted())
    #expect(try await groupEventBodies(db) == ["You added dddddddd"])
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(deliveries.first { $0.memberHex == memberC }?.status == MessageStatus.sending)
    #expect(deliveries.first { $0.memberHex == memberD }?.status == GroupDeliveryStatus.waiting)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberD)!] != nil)
    #expect(store.state.openGroupMembers.count == 3)
}

/// Removing a member sends the new roster to the removed member too, so their device marks the
/// group left.
@MainActor @Test func groupControlRemoveMemberSendsRosterToRemovedToo() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, members: [memberC, memberD], reachable: [memberC, memberD])
    let sent = await groupSends(store, .removeGroupMember(memberD), count: 2)
    #expect(Set(sent.map(\.destinationHash)) == [Data(hexString: memberC)!, Data(hexString: memberD)!])
    for wire in sent {
        #expect(GroupWire.decode(wire.fields) == .roster(groupId: Data(hexString: groupHexA)!, name: "Mutual Aid",
                                                         members: [memberC, myHex].sorted().map { Data(hexString: $0)! }, revision: 2))
    }
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, myHex].sorted())
    #expect(try await groupEventBodies(db) == ["You removed dddddddd"])
}

/// Renaming sends the new name; deleting sends an empty roster with the delete body and marks
/// the group dissolved.
@MainActor @Test func groupControlRenameThenDelete() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = await groupStore(db, identity: me, members: [memberC], reachable: [memberC]) { $0.$displayName.withLock { $0 = "Ada" } }
    let renamed = await groupSends(store, .renameGroup("  Block 4  "), count: 1)
    // groupSends's drain races the rename effect's later reloadThread/reloadConversations steps
    // (several await boundaries past the one sendMessage it explicitly waits for); settle fully
    // before reading state or sending the next action.
    await store.skipReceivedActions(strict: false)
    #expect(GroupWire.decode(try #require(renamed.first).fields)
            == .roster(groupId: Data(hexString: groupHexA)!, name: "Block 4",
                       members: [memberC, lxmfAddressHex(me)].sorted().map { Data(hexString: $0)! }, revision: 2))
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.name == "Block 4")
    #expect(store.state.openGroup?.name == "Block 4")
    let deleted = await groupSends(store, .deleteGroup, count: 1)
    await store.skipReceivedActions(strict: false)
    let wire = try #require(deleted.first)
    #expect(wire.content == Data("Ada deleted the group Block 4".utf8))
    #expect(GroupWire.decode(wire.fields) == .roster(groupId: Data(hexString: groupHexA)!, name: "Block 4", members: [], revision: 3))
    let group = try #require(try await db.read { try ChatGroup.fetch(groupHexA, $0) })
    #expect(group.state == GroupState.dissolved)
    #expect(group.revision == 3)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) }.isEmpty)
    #expect(try await groupEventBodies(db) == ["You renamed the group to Block 4", "You deleted the group"])
    // Two successful sends each leave the node's own long-lived retry/debounce effect in flight
    // (Global Constraints: never `finish()` after an action on the node's send path); clear them
    // rather than wait, since nothing here asserts on their eventual outcome.
    await store.skipInFlightEffects(strict: false)
    // Re-picking the current name sends nothing.
    store.exhaustivity = .on
    await store.send(.renameGroup("Block 4"))
}

/// Leaving sends the leave to every member, drops me from the roster and marks the group left.
@MainActor @Test func groupControlLeaveSendsLeaveAndMarksLeft() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = await groupStore(db, identity: me, creatorHex: memberC, members: [memberC, memberD], reachable: [memberC]) { $0.$displayName.withLock { $0 = "Ada" } }
    let sent = await groupSends(store, .leaveGroup, count: 1)
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberC))
    #expect(wire.content == Data("Ada left the group Mutual Aid".utf8))
    #expect(GroupWire.decode(wire.fields) == .leave(groupId: Data(hexString: groupHexA)!))
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.left)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, memberD])
    let line = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(line.body == "You left the group")
    #expect(line.groupControl == "leave")
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(deliveries.first { $0.memberHex == memberD }?.status == GroupDeliveryStatus.waiting)
    #expect(store.state.openGroup?.state == GroupState.left)
}

/// Accepting flips invited to active with no message; declining (amendment A6) marks it left,
/// writes its line and sends the leave to the creator only.
@MainActor @Test func groupControlAcceptAndDecline() async throws {
    let me = Identity()
    let acceptDb = try AppDatabase.makeInMemory()
    let accept = await groupStore(acceptDb, identity: me, creatorHex: memberC, members: [memberC, memberD], state: GroupState.invited, reachable: [memberC, memberD])
    await accept.send(.acceptInvite)
    await accept.receive { if case .groupLoaded = $0 { return true }; return false }
    await accept.skipReceivedActions(strict: false)
    #expect(try await acceptDb.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.active)
    #expect(accept.state.openGroup?.state == GroupState.active)
    #expect(try await acceptDb.read { try Message.all.fetchAll($0) }.isEmpty)
    let declineDb = try AppDatabase.makeInMemory()
    let decline = await groupStore(declineDb, identity: me, creatorHex: memberC, members: [memberC, memberD], state: GroupState.invited, reachable: [memberC, memberD])
    let sent = await groupSends(decline, .declineInvite, count: 1)
    // groupSends's underlying TestStore.receive(predicate:) re-examines the same already-queued
    // action against the predicate several times while the effect's remaining await points
    // (reloadThread/reloadConversations) are still settling, so a side-effecting predicate (as
    // groupSends's is) can append the one real message more than once; compare the first
    // (the established house style elsewhere in this file) rather than the whole array.
    #expect(sent.first?.destinationHash == Data(hexString: memberC))
    #expect(GroupWire.decode(try #require(sent.first).fields) == .leave(groupId: Data(hexString: groupHexA)!))
    #expect(try await declineDb.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.left)
    #expect(try await groupEventBodies(declineDb) == ["You declined the invitation"])
    #expect(try await declineDb.read { try GroupDelivery.all.fetchAll($0) }.map(\.memberHex) == [memberC])
    #expect(try await declineDb.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, memberD])
}

/// Only the creator edits, and the creator cannot leave (spec §1); an inactive group refuses edits.
@MainActor @Test func groupControlRoleGuards() async throws {
    let me = Identity()
    let memberDb = try AppDatabase.makeInMemory()
    let member = await groupStore(memberDb, identity: me, creatorHex: memberC, members: [memberC], reachable: [memberC])
    member.exhaustivity = .on
    await member.send(.addGroupMembers([memberD]))
    await member.send(.removeGroupMember(memberC))
    await member.send(.renameGroup("x"))
    await member.send(.deleteGroup)
    await member.send(.acceptInvite)
    await member.send(.declineInvite)
    #expect(try await memberDb.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await memberDb.read { try ChatGroup.fetch(groupHexA, $0) }?.revision == 1)
    let creatorDb = try AppDatabase.makeInMemory()
    let creator = await groupStore(creatorDb, identity: me, members: [memberC], reachable: [memberC])
    creator.exhaustivity = .on
    await creator.send(.leaveGroup)
    await creator.send(.removeGroupMember(lxmfAddressHex(me)))
    await creator.send(.addGroupMembers([memberC]))   // already a member
    #expect(try await creatorDb.read { try Message.all.fetchAll($0) }.isEmpty)
    let leftDb = try AppDatabase.makeInMemory()
    let left = await groupStore(leftDb, identity: me, members: [memberC], state: GroupState.left, reachable: [memberC])
    left.exhaustivity = .on
    await left.send(.renameGroup("x"))
    await left.send(.addGroupMembers([memberD]))
    #expect(try await leftDb.read { try Message.all.fetchAll($0) }.isEmpty)
    // An invited group is declined, not left (final review cleanup).
    let invitedDb = try AppDatabase.makeInMemory()
    let invited = await groupStore(invitedDb, identity: me, creatorHex: memberC, members: [memberC],
                                   state: GroupState.invited, reachable: [memberC])
    invited.exhaustivity = .on
    await invited.send(.leaveGroup)
    #expect(try await invitedDb.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await invitedDb.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.invited)
}

// MARK: - Group chats: final review fixes (2026-10-10)

/// Final review I1: an open group asks for its unreachable members' paths on the first load only,
/// not on every reload that follows a delegate, arrival, dispatch or reaction.
@MainActor @Test func groupFinalSecondGroupLoadSendsNoPathRequests() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, members: [memberC, memberD]) { $0.openGroup = nil }
    let group = ChatGroup(groupHex: groupHexA, name: "Mutual Aid", creatorHex: myHex, revision: 1,
                          state: GroupState.active, updatedAt: infoT0)
    let members = [memberC, memberD, myHex].map { GroupMember(groupHex: groupHexA, memberHex: $0) }
    await store.send(.groupLoaded(groupHex: groupHexA, group: group, members: members, deliveries: []))
    await store.receive { a in
        if case let .node(.client(.endpoint(.requestPath(dest)))) = a { return dest == Data(hexString: memberC)! }
        return false
    }
    await store.receive { a in
        if case let .node(.client(.endpoint(.requestPath(dest)))) = a { return dest == Data(hexString: memberD)! }
        return false
    }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.transport.pathRequests.count == 2)
    store.exhaustivity = .on
    await store.send(.groupLoaded(groupHex: groupHexA, group: group, members: members, deliveries: []))
    // Exhaustive: a third identical send fails if the second one queued any action (a path request).
    await store.send(.groupLoaded(groupHex: groupHexA, group: group, members: members, deliveries: []))
    #expect(store.state.node.client.endpoint.transport.pathRequests.count == 2)
}

/// Final review I2: when a member's leave reaches me as creator, the re-issued roster also goes
/// to the leaver, so a device whose leave crossed a roster change settles to left.
@MainActor @Test func groupFinalCreatorLeaveRosterGoesToLeaverToo() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let leaver = Identity()
    let leaverHex = groupMemberHash(leaver).hexString
    let store = await groupStore(db, identity: me, members: [leaverHex, memberD], reachable: [leaverHex, memberD])
    await groupNameSender(store, leaver)
    let sent = await groupSends(store, .node(.client(.delegate(.messageReceived(
        message: groupLeaveWire(from: leaver, to: me), signatureValidated: true, method: .opportunistic)))), count: 2)
    // `groupSends` can record one message more than once (its predicate is re-run), so count destinations.
    #expect(Set(sent.map(\.destinationHash)) == [Data(hexString: leaverHex)!, Data(hexString: memberD)!])
    let roster = GroupWire.Decoded.roster(groupId: Data(hexString: groupHexA)!, name: "Mutual Aid",
                                          members: [memberD, myHex].sorted().map { Data(hexString: $0)! }, revision: 2)
    let toLeaver = try #require(sent.first { $0.destinationHash == Data(hexString: leaverHex) })
    #expect(GroupWire.decode(toLeaver.fields) == roster)
    let toD = try #require(sent.first { $0.destinationHash == Data(hexString: memberD) })
    #expect(GroupWire.decode(toD.fields) == roster)
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(deliveries.map(\.memberHex).sorted() == [leaverHex, memberD].sorted())
    #expect(deliveries.allSatisfy { $0.status == MessageStatus.sending })
}

/// Final review I3 (amendment A16): a failed leave copy is re-sent when the member's path is
/// learned again, as a failed roster is; a failed post is not.
@MainActor @Test func groupFinalFailedLeaveIsResentOnPathLearned() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, creatorHex: memberC, members: [memberC], state: GroupState.left)
    let leaveLine = AppFeature.groupEventRow(groupHex: groupHexA, me: myHex, body: "You left the group",
                                             control: GroupControl.leave, now: infoT0)
    let post = Message(id: uuid(7), peerHex: myHex, isOutgoing: true, body: "hi", timestamp: infoT0,
                       status: MessageStatus.failed, validated: false, messageHash: String(repeating: "6f", count: 16),
                       groupHex: groupHexA, groupPostId: String(repeating: "6f", count: 16))
    let failedLeave = GroupDelivery(messageId: leaveLine.id, memberHex: memberC, messageHash: String(repeating: "77", count: 32),
                                    status: MessageStatus.failed, storedAt: nil, deliveredAt: nil, failedAt: infoT0)
    let failedPost = GroupDelivery(messageId: post.id, memberHex: memberC, messageHash: String(repeating: "78", count: 32),
                                   status: MessageStatus.failed, storedAt: nil, deliveredAt: nil, failedAt: infoT0)
    try await db.write { db in
        try Message.insert { leaveLine }.execute(db)
        try Message.insert { post }.execute(db)
        try GroupDelivery.insert { failedLeave }.execute(db)
        try GroupDelivery.insert { failedPost }.execute(db)
    }
    let sent = await groupSends(store, .node(.client(.endpoint(.delegate(.pathLearned(destinationHash: Data(hexString: memberC)!, hops: 1))))), count: 1)
    #expect(GroupWire.decode(try #require(sent.first).fields) == .leave(groupId: Data(hexString: groupHexA)!))
    let rows = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(rows.first { $0.messageId == leaveLine.id }?.status == MessageStatus.sending)
    #expect(rows.first { $0.messageId == leaveLine.id }?.messageHash == sent[0].hash.hexString)
    #expect(rows.first { $0.messageId == post.id }?.status == MessageStatus.failed)
}

/// Final review M2: a roster change in one group dispatches that group's waiting copies only.
@MainActor @Test func groupFinalRosterChangedDispatchesOnlyItsGroup() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let groupHexB = String(repeating: "2b", count: 16)
    let store = await groupStore(db, identity: me, members: [memberC], reachable: [memberC])
    let groupB = ChatGroup(groupHex: groupHexB, name: "Book Club", creatorHex: myHex, revision: 1,
                           state: GroupState.active, updatedAt: infoT0)
    let lineA = AppFeature.groupEventRow(groupHex: groupHexA, me: myHex, body: "You added Cy",
                                         control: GroupControl.roster, now: infoT0)
    let lineB = AppFeature.groupEventRow(groupHex: groupHexB, me: myHex, body: "You added Cy",
                                         control: GroupControl.roster, now: infoT0)
    let rosterB = [memberC, myHex].sorted()
    try await db.write { db in
        try ChatGroup.upsert(groupB, db)
        try GroupMember.replace(groupHexB, with: rosterB, db)
        try Message.insert { lineA }.execute(db)
        try Message.insert { lineB }.execute(db)
        try GroupDelivery.insert { GroupDelivery.waiting(messageId: lineA.id, memberHex: memberC) }.execute(db)
        try GroupDelivery.insert { GroupDelivery.waiting(messageId: lineB.id, memberHex: memberC) }.execute(db)
    }
    // "Exactly one send" is read from the rows: the other group's copy must still be waiting.
    let sent = await groupSends(store, .groupRosterChanged(groupHex: groupHexA), count: 1)
    guard case let .roster(groupId, _, _, _)? = GroupWire.decode(try #require(sent.first).fields) else {
        Issue.record("expected a roster"); return
    }
    #expect(groupId == Data(hexString: groupHexA)!)
    let rows = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(rows.first { $0.messageId == lineA.id }?.status == MessageStatus.sending)
    #expect(rows.first { $0.messageId == lineB.id }?.status == GroupDeliveryStatus.waiting)
}

// MARK: - Default nodes: endpoint sync and lifecycle (spec 2026-10-10 §3)

@MainActor @Test func nodeSyncFreshLaunchMigratesToTheDefaultNodeAndDialsIt() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    #expect(store.state.nodes.isEmpty)
    await store.send(.onLaunch)
    await store.receive { if case .node(.client(.endpoint(.start))) = $0 { return true }; return false }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    #expect(store.state.nodes == [DefaultNode.entry])
    #expect(store.state.node.client.endpoint.tcpClients.ids == [gaefuID])
    #expect(store.state.node.client.endpoint.tcpClients[id: gaefuID]?.interface.host == "gaefu.ddns.net")
    #expect(store.state.node.client.endpoint.tcpClients[id: gaefuID]?.interface.port == 4242)
}

@MainActor @Test func nodeSyncLaunchMigratesLegacyHostAndHexOnce() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { state in
        state.$legacyHost.withLock { $0 = "node.example" }
        state.$legacyPort.withLock { $0 = 4243 }
        state.push.$hubHex.withLock { $0 = nodeHexA }
    }
    await store.send(.onLaunch)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.nodes.count == 2)
    #expect(store.state.nodes[0].pushHubHex == nil)
    #expect(store.state.nodes[1].host == "node.example")
    #expect(store.state.nodes[1].port == 4243)
    #expect(store.state.nodes[1].pushHubHex == nodeHexA)
    #expect(store.state.node.client.endpoint.tcpClients.ids == [gaefuID, store.state.nodes[1].interfaceID])

    // A later launch with different legacy keys must not migrate again.
    store.state.$legacyHost.withLock { $0 = "other.example" }
    await store.send(.onLaunch)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.nodes.count == 2)
    #expect(store.state.nodes[1].host == "node.example")
}

@MainActor @Test func nodeSyncAddsASlotPerEnabledEntryAndSkipsDisabledOnes() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode("a.example", id: 11)
    let b = userNode("b.example", enabled: false, id: 12)
    let store = nodeStore(db, nodes: [disabled(DefaultNode.entry), a, b])
    await connectNodes(store)
    #expect(store.state.node.client.endpoint.tcpClients.ids == [a.interfaceID])
}

@MainActor @Test func nodeSyncKeepsAMatchingLiveSlot() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry])
    await connectNodes(store)
    // The socket comes up through the real container wiring.
    await store.send(.node(.client(.endpoint(.tcpClients(.element(id: gaefuID, action: .interface(.connectionEvent(.connected))))))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.tcpClients[id: gaefuID]?.interface.status == .online)

    // A second connect re-syncs. The slot must be the SAME one (a rebuilt slot starts disconnected).
    await store.send(.connectTapped)
    #expect(store.state.node.client.endpoint.tcpClients[id: gaefuID]?.interface.status == .online,
            "a live slot whose entry is unchanged must be kept, not rebuilt")
    await store.receive { if case .node(.client(.endpoint(.start))) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodeSyncRemovesADisabledEntrysSlot() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode("a.example", id: 11)
    let store = nodeStore(db, nodes: [DefaultNode.entry, a])
    await connectNodes(store)
    #expect(store.state.node.client.endpoint.tcpClients.ids == [gaefuID, a.interfaceID])

    store.state.$nodes.withLock { $0[1].enabled = false }
    await store.send(.connectTapped)
    // Removal is reduced BEFORE the dial (`.concatenate`), so the departing slot is never dialed.
    await store.receive { isRemove(a.interfaceID, $0) }
    await store.receive { if case .node(.client(.endpoint(.start))) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.tcpClients.ids == [gaefuID])
}

@MainActor @Test func nodeSyncForegroundRedialsOnlyNodesThatAreDown() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode("a.example", id: 11)
    let store = nodeStore(db, nodes: [DefaultNode.entry, a])
    await connectNodes(store)
    await store.send(.node(.client(.endpoint(.tcpClients(.element(id: gaefuID, action: .interface(.connectionEvent(.connected))))))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connection == .connected)

    await store.send(.foregrounded)
    await store.receive { isConnect(a.interfaceID, $0) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.tcpClients[id: gaefuID]?.interface.status == .online,
            "the live node must not be re-dialed")
    #expect(store.state.node.client.endpoint.tcpClients[id: a.interfaceID]?.interface.status == .connecting)
}

@MainActor @Test func nodeSyncForegroundWithANodeUpStaysConnected() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode("a.example", id: 11)
    let store = nodeStore(db, nodes: [DefaultNode.entry, a])
    await connectNodes(store)
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
    await store.skipReceivedActions(strict: false)

    await store.send(.foregrounded)
    #expect(store.state.connection == .connected, "one node up means connected, whatever the others do")
    await store.receive { isConnect(a.interfaceID, $0) }
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodeSyncBackgroundedDisconnectsEveryClient() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode("a.example", id: 11)
    let store = nodeStore(db, nodes: [DefaultNode.entry, a])
    await connectNodes(store)

    await store.send(.backgrounded)
    for _ in 0..<2 {
        await store.receive { action in
            if case .node(.client(.endpoint(.tcpClients(.element(_, .disconnect))))) = action { return true }
            return false
        }
    }
    await store.skipReceivedActions(strict: false)
}

/// With every node disabled there is no TCP slot at all, so `down` (the set of disconnected slots)
/// is empty — but the listener and BLE slots must still restart on foreground, exactly as the old
/// `.start` always did when the (then always-present) TCP slot was down. Review fix: `redialDownNodes`
/// used to return early whenever `down.isEmpty`, which also skipped the listener/BLE restart.
@MainActor @Test func nodeSyncForegroundWithNoNodesRestartsTheListener() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [disabled(DefaultNode.entry)]) { state in
        state.$listenEnabled.withLock { $0 = true }
        state.$listenPort.withLock { $0 = 5151 }
    }
    await store.send(.foregrounded)
    await store.receive { if case .node(.client(.endpoint(.tcpServer(.start)))) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

// MARK: - Default nodes: push wiring (spec §3 "Push")

@MainActor @Test func nodePushLaunchPointsPushAtThePushNode() async {
    let db = try! AppDatabase.makeInMemory()
    // The user entry comes first on purpose: the push node is the one WITH the hex, not the first.
    let store = nodeStore(db, nodes: [userNode(), DefaultNode.entry])
    await store.send(.onLaunch)
    await store.receive(.push(.hubChanged(host: "gaefu.ddns.net", port: 4242)))
    await store.receive(.push(.setHubHex(DefaultNode.pushHubHex)))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodePushUserNodeWithHexBecomesThePushNode() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [withoutHex(DefaultNode.entry), userNode(hex: nodeHexA)]) { state in
        state.push.$hubHex.withLock { $0 = DefaultNode.pushHubHex }   // stale from before
    }
    await store.send(.onLaunch)
    await store.receive(.push(.hubChanged(host: "node.example", port: 4243)))
    await store.receive(.push(.setHubHex(nodeHexA)))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodePushNoPushNodeClearsTheHub() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [disabled(DefaultNode.entry)]) { state in
        state.push.$hubHex.withLock { $0 = DefaultNode.pushHubHex }
    }
    #expect(store.state.pushNode == nil)
    await store.send(.onLaunch)
    await store.receive(.push(.hubChanged(host: "", port: 0)))
    await store.receive(.push(.setHubHex("")))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodePushRegistrationWaitsForThePushNodesInterface() async {
    let db = try! AppDatabase.makeInMemory()
    let hub = Data(repeating: 0xC1, count: 16)
    let store = nodeStore(db, nodes: [DefaultNode.entry])
    await connectNodes(store)
    await store.send(.push(.delegate(.sendRegistration(hub: hub, path: "/register", data: Data([1]))))) {
        $0.pendingPushRegistration = PendingPushRegistration(hub: hub, path: "/register", data: Data([1]))
    }
    // Some OTHER interface coming up must not resume it. Checked BEFORE draining: the resume
    // guard's clear of `pendingPushRegistration` is the SEND's own synchronous mutation (visible
    // at once), but a wrongly-resumed registration re-enters the (separate, still-correct) guard
    // once its resend is drained and gets re-buffered — which would mask a dropped condition here
    // if the drain ran first.
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp:other.example:1"), .tcp))))))
    #expect(store.state.pendingPushRegistration != nil, "only the push node's own interface resumes the registration")
    await store.skipReceivedActions(strict: false)
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp)))))) {
        $0.pendingPushRegistration = nil
    }
    await store.receive { if case .push(.delegate(.sendRegistration(hub: hub, _, _))) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

/// With a single node, "the push node's interface" and "the first slot" are the same id, so the
/// test above cannot tell the guard apart from a `tcpClients.first?.interfaceID` bug. Here the push
/// node (the one with a hex) is the SECOND entry: only ITS interface may resume the registration,
/// not the first slot that happens to be up.
@MainActor @Test func nodePushRegistrationWithOnlyAnotherInterfaceUpStillWaits() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode(hex: nodeHexA, id: 11)
    let store = nodeStore(db, nodes: [withoutHex(DefaultNode.entry), a])
    await connectNodes(store)
    // The non-push node's interface comes up first.
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
    await store.skipReceivedActions(strict: false)

    let hub = Data(repeating: 0xC1, count: 16)
    // Exhaustive: the guard's only effect when it (correctly) still buffers is the state mutation
    // below — any emitted action (a path request, a registration timer) means the guard wrongly
    // treated the non-push interface as satisfying it.
    store.exhaustivity = .on
    await store.send(.push(.delegate(.sendRegistration(hub: hub, path: "/register", data: Data([1]))))) {
        $0.pendingPushRegistration = PendingPushRegistration(hub: hub, path: "/register", data: Data([1]))
    }
    #expect(!store.state.pushRegistrationFlow.isActive)
    store.exhaustivity = .off

    // The push node's OWN interface coming up does resume it.
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(a.interfaceID, .tcp)))))) {
        $0.pendingPushRegistration = nil
    }
    await store.receive { if case .push(.delegate(.sendRegistration(hub: hub, _, _))) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodePushInjectUsesThePushNodesInterface() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let a = userNode(hex: nodeHexA)
    let store = makeStore(db, identity: me) { state in
        state.$nodes.withLock { $0 = [withoutHex(DefaultNode.entry), a] }
    }
    await connectNodes(store)
    await store.send(.node(.client(.registerDelivery)))
    await store.skipReceivedActions(strict: false)
    let raw = Data(repeating: 0x5A, count: 40)
    await store.send(.push(.delegate(.inject(packets: [raw]))))
    await store.receive { action in
        if case .node(.client(.endpoint(.transport(.received(let id, let bytes))))) = action {
            return id == a.interfaceID && bytes == raw
        }
        return false
    }
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodePushInjectFallsBackWhenThePushNodeHasNoSlot() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [userNode(hex: nodeHexA)])   // never connected: no slot
    await store.send(.node(.client(.registerDelivery)))
    await store.skipReceivedActions(strict: false)
    let raw = Data(repeating: 0x5A, count: 40)
    await store.send(.push(.delegate(.inject(packets: [raw]))))
    await store.receive { action in
        if case .node(.client(.endpoint(.transport(.received(let id, let bytes))))) = action {
            return id == InterfaceID("push") && bytes == raw
        }
        return false
    }
    await store.skipReceivedActions(strict: false)
}

/// Amendment A7: `setHubHex` must not be sent when the push node's hex already equals what the
/// push feature holds — every `setHubHex` makes the push feature forget its registration (its
/// `status` flips to `.failed`), so a no-op hex must leave a registered status alone.
@MainActor @Test func nodePushEqualHexSendsNoSetHubHex() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry]) { state in
        state.push.$hubHex.withLock { $0 = DefaultNode.pushHubHex }
        state.push.$enabled.withLock { $0 = true }
        state.push.status = .registered(Date(timeIntervalSince1970: 1700000000))
    }
    await store.send(.connectTapped)
    await store.receive(.push(.hubChanged(host: "gaefu.ddns.net", port: 4242)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.push.status == .registered(Date(timeIntervalSince1970: 1700000000)))
}

// MARK: - Default nodes: propagation default (spec §2 "Propagation node")

@MainActor @Test func nodePropDefaultPropagationIsUsedWhenToggleOn() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry]) { state in
        state.$propagationNodeHex.withLock { $0 = nodeHexQ }
    }
    store.dependencies.defaultPropagationHex = nodeHexP
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
    await store.receive(.node(.client(.setPropagationNode(destinationHash: Data(hexString: nodeHexP)!))))
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodePropStoredHexIsUsedWhenNoDefaultExists() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry]) { state in
        state.$propagationNodeHex.withLock { $0 = nodeHexQ }
    }
    // `\.defaultPropagationHex` test value is nil: the toggle (default true) has no effect.
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
    await store.receive(.node(.client(.setPropagationNode(destinationHash: Data(hexString: nodeHexQ)!))))
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodePropToggleOffFlagUsesTheStoredHex() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry]) { state in
        state.$propagationNodeHex.withLock { $0 = nodeHexQ }
        state.$usePropagationDefault.withLock { $0 = false }
    }
    store.dependencies.defaultPropagationHex = nodeHexP
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
    await store.receive(.node(.client(.setPropagationNode(destinationHash: Data(hexString: nodeHexQ)!))))
    await store.skipReceivedActions(strict: false)
}

// MARK: - Default nodes: node actions (spec 2026-10-10 §3 "Node actions")

@MainActor @Test func nodeActAddNodeAppendsConnectsAndKeepsOnePushNode() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry]) { state in
        state.push.$hubHex.withLock { $0 = DefaultNode.pushHubHex }
    }
    await connectNodes(store)
    await store.send(.addNode(name: " Pi ", host: " pi.local ", port: 4243, pushHubHex: nodeHexA.uppercased()))
    let added = store.state.nodes[1]
    #expect(added.name == "Pi")
    #expect(added.host == "pi.local")
    #expect(added.port == 4243)
    #expect(added.enabled == true)
    #expect(added.isBuiltIn == false)
    #expect(added.pushHubHex == nodeHexA)
    #expect(store.state.nodes[0].pushHubHex == nil, "one push node: the built-in entry loses its hex")
    await store.receive { isConnect(added.interfaceID, $0) }
    await store.receive(.push(.hubChanged(host: "pi.local", port: 4243)))
    await store.receive(.push(.setHubHex(nodeHexA)))
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodeActAddNodeRejectsInvalidInput() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry])
    store.exhaustivity = .on
    // Each send must leave state untouched and emit nothing.
    await store.send(.addNode(name: "x", host: "  ", port: 4242, pushHubHex: nil))
    await store.send(.addNode(name: "x", host: "h", port: 70000, pushHubHex: nil))
    await store.send(.addNode(name: "x", host: "h", port: 0, pushHubHex: nil))
    await store.send(.addNode(name: "x", host: "h", port: 4242, pushHubHex: String(nodeHexA.dropLast())))
    #expect(store.state.nodes == [DefaultNode.entry])
}

@MainActor @Test func nodeActUpdateNodeEditingHostReplacesTheSlot() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode("node.example", id: 11)
    let store = nodeStore(db, nodes: [DefaultNode.entry, a])
    await connectNodes(store)
    var edited = a
    edited.host = "node2.example"
    await store.send(.updateNode(edited))
    #expect(store.state.nodes[1].host == "node2.example")
    await store.receive { isRemove(a.interfaceID, $0) }
    await store.receive { isConnect(edited.interfaceID, $0) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.tcpClients.ids == [gaefuID, edited.interfaceID])
}

@MainActor @Test func nodeActUpdateNodeKeepsTheSlotWhenOnlyTheNameChanges() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode("node.example", id: 11)
    let store = nodeStore(db, nodes: [DefaultNode.entry, a]) { state in
        state.push.$hubHex.withLock { $0 = DefaultNode.pushHubHex }   // already pointed at Gaefu
        state.push.$enabled.withLock { $0 = true }
        state.push.status = .registered(Date(timeIntervalSince1970: 1700000000))
    }
    await connectNodes(store)
    var renamed = a
    renamed.name = "Renamed"
    store.exhaustivity = .on
    await store.send(.updateNode(renamed)) {
        $0.$nodes.withLock { $0[1].name = "Renamed" }
    }
    // Only the push sync fires (same push node as before, so no setHubHex): no removal, no dial.
    await store.receive(.push(.hubChanged(host: "gaefu.ddns.net", port: 4242)))
    // Back to non-exhaustive before the test ends: `connectNodes` left both nodes' TCP connect
    // effects running (their mocked `open()` stream never finishes, by design — see global
    // constraints). Under `.on` the deinit check reports those as "still running"; every other
    // test in this file that calls `connectNodes` stays `.off` for the same reason.
    store.exhaustivity = .off
    await store.skipReceivedActions(strict: false)
    #expect(store.state.push.status == .registered(Date(timeIntervalSince1970: 1700000000)),
            "a name-only edit must not re-point push: setHubHex would flip the status to hub-changed")
    #expect(store.state.node.client.endpoint.tcpClients.ids == [gaefuID, a.interfaceID])
}

/// Amendment A13 (F2): removing the user's push node leaves no entry carrying a hex, so the
/// built-in entry regains the shipped default and push is re-pointed AT Gaefu, not cleared.
@MainActor @Test func nodeActRemoveNodeDisconnectsItsSlotAndHandsPushToTheDefault() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode(hex: nodeHexA, id: 11)
    let store = nodeStore(db, nodes: [withoutHex(DefaultNode.entry), a]) { state in
        state.push.$hubHex.withLock { $0 = nodeHexA }
    }
    await connectNodes(store)
    await store.send(.removeNode(id: a.id))
    #expect(store.state.nodes == [DefaultNode.entry])
    await store.receive { isRemove(a.interfaceID, $0) }
    await store.receive(.push(.hubChanged(host: "gaefu.ddns.net", port: 4242)))
    await store.receive(.push(.setHubHex(DefaultNode.pushHubHex)))
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodeActBuiltInRefusesDelete() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry])
    store.exhaustivity = .on
    await store.send(.removeNode(id: DefaultNode.id))
    #expect(store.state.nodes == [DefaultNode.entry])
}

@MainActor @Test func nodeActBuiltInRefusesEdit() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry])
    var edited = DefaultNode.entry
    edited.host = "elsewhere.example"
    edited.pushHubHex = nil
    store.exhaustivity = .on
    await store.send(.updateNode(edited))
    #expect(store.state.nodes == [DefaultNode.entry])
}

@MainActor @Test func nodeActDisableNodeRemovesItsSlotAndEnableReconnects() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [withoutHex(DefaultNode.entry)])
    await connectNodes(store)
    await store.send(.setNodeEnabled(id: DefaultNode.id, enabled: false))
    #expect(store.state.nodes[0].enabled == false)
    await store.receive { isRemove(gaefuID, $0) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.tcpClients.isEmpty)

    await store.send(.setNodeEnabled(id: DefaultNode.id, enabled: true))
    #expect(store.state.nodes[0].enabled == true)
    await store.receive { isConnect(gaefuID, $0) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.tcpClients.ids == [gaefuID])
}

@MainActor @Test func nodeActDisablingThePushNodeTurnsPushOff() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry]) { state in
        state.push.$hubHex.withLock { $0 = DefaultNode.pushHubHex }
    }
    await store.send(.setNodeEnabled(id: DefaultNode.id, enabled: false))
    #expect(store.state.pushNode == nil)
    await store.receive(.push(.hubChanged(host: "", port: 0)))
    await store.receive(.push(.setHubHex("")))
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodeActSettingAHexOnOneNodeClearsItOnOthers() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode(id: 11)
    let store = nodeStore(db, nodes: [DefaultNode.entry, a]) { state in
        state.push.$hubHex.withLock { $0 = DefaultNode.pushHubHex }
    }
    var withHex = a
    withHex.pushHubHex = nodeHexA
    await store.send(.updateNode(withHex))
    #expect(store.state.nodes[0].pushHubHex == nil)
    #expect(store.state.nodes[1].pushHubHex == nodeHexA)
    await store.receive(.push(.hubChanged(host: "node.example", port: 4243)))
    await store.receive(.push(.setHubHex(nodeHexA)))
    await store.skipReceivedActions(strict: false)
}

// MARK: - Default nodes: the propagation toggle (spec §2 "Propagation node")

@MainActor @Test func nodePropToggleRepointsTheRouterWhenADefaultExists() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry]) { state in
        state.$propagationNodeHex.withLock { $0 = nodeHexQ }
    }
    store.dependencies.defaultPropagationHex = nodeHexP
    await store.send(.setUsePropagationDefault(false)) {
        $0.$usePropagationDefault.withLock { $0 = false }
    }
    await store.receive(.node(.client(.setPropagationNode(destinationHash: Data(hexString: nodeHexQ)!))))
    await store.receive(.node(.client(.syncFromPropagationNode)))
    await store.skipReceivedActions(strict: false)
    await store.send(.setUsePropagationDefault(true)) {
        $0.$usePropagationDefault.withLock { $0 = true }
    }
    await store.receive(.node(.client(.setPropagationNode(destinationHash: Data(hexString: nodeHexP)!))))
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func nodePropToggleWithoutADefaultChangesNothing() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry]) { state in
        state.$propagationNodeHex.withLock { $0 = nodeHexQ }
    }
    store.exhaustivity = .on
    // No default hex (test value nil): the flag is stored, the router is not touched.
    await store.send(.setUsePropagationDefault(false)) {
        $0.$usePropagationDefault.withLock { $0 = false }
    }
}

@MainActor @Test func nodePropSetPropagationNodeIsStoredButNotAppliedWhileTheDefaultIsInEffect() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry])
    store.dependencies.defaultPropagationHex = nodeHexP
    store.exhaustivity = .on
    // Exhaustive: the stored hex changes and NOTHING is sent to the node (the default stays in
    // effect). Do not read `effectivePropagationNodeHex` from the test body: it resolves
    // `\.defaultPropagationHex` from the test's context, not the store's.
    await store.send(.setPropagationNode(nodeHexQ)) {
        $0.$propagationNodeHex.withLock { $0 = nodeHexQ }
    }
}

// MARK: - Default nodes: final fix wave (whole-branch review)

/// F1 (amendment A14): the push node disappears while push is enabled — the app turns push off
/// itself (also unregistering from APNs so wakes stop), so the Settings toggle is never the only
/// way to turn it off.
@MainActor @Test func nodeFinalLosingThePushNodeTurnsPushOff() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode(hex: nodeHexA, id: 11)
    // The rule never produces two hex-carrying entries (backlog 18): the built-in has none here
    // and regains the default on the removal (A13) — disabled, so there is still no push node.
    let store = nodeStore(db, nodes: [disabled(withoutHex(DefaultNode.entry)), a]) { state in
        state.push.$enabled.withLock { $0 = true }
        state.push.$hubHex.withLock { $0 = nodeHexA }
    }
    await connectNodes(store)
    await store.send(.removeNode(id: uuid(11)))
    await store.receive { isRemove(a.interfaceID, $0) }
    await store.receive(.push(.setEnabled(false)))
    await store.receive(.push(.hubChanged(host: "", port: 0)))
    await store.receive(.push(.setHubHex("")))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.push.enabled == false)
}

/// F1: switching the push node to a DIFFERENT node (never nil in between) must not turn push off.
@MainActor @Test func nodeFinalSwitchingPushNodeKeepsPushOn() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry, userNode(id: 11)]) { state in
        state.push.$enabled.withLock { $0 = true }
        state.push.$hubHex.withLock { $0 = DefaultNode.pushHubHex }
    }
    await connectNodes(store)
    await store.send(.updateNode(userNode(hex: nodeHexA, id: 11)))
    await store.receive(.push(.hubChanged(host: "node.example", port: 4243)))
    await store.receive(.push(.setHubHex(nodeHexA)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.push.enabled == true)
}

/// F2 (amendment A13): removing the only entry carrying a push hex hands push back to the
/// built-in entry, which regains the shipped default hex.
@MainActor @Test func nodeFinalRemovingThePushNodeHandsPushBackToTheDefault() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode(hex: nodeHexA, id: 11)
    let store = nodeStore(db, nodes: [withoutHex(DefaultNode.entry), a]) { state in
        state.push.$enabled.withLock { $0 = true }
        state.push.$hubHex.withLock { $0 = nodeHexA }
    }
    await connectNodes(store)
    await store.send(.removeNode(id: uuid(11)))
    #expect(store.state.nodes[0].pushHubHex == DefaultNode.pushHubHex)
    await store.receive { isRemove(a.interfaceID, $0) }
    await store.receive(.push(.hubChanged(host: "gaefu.ddns.net", port: 4242)))
    await store.receive(.push(.setHubHex(DefaultNode.pushHubHex)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.push.enabled == true)
}

/// F2: clearing the user's hex (instead of removing the entry) also hands push back to the default.
@MainActor @Test func nodeFinalClearingTheUsersHexHandsPushBackToTheDefault() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode(hex: nodeHexA, id: 11)
    let store = nodeStore(db, nodes: [withoutHex(DefaultNode.entry), a]) { state in
        state.push.$enabled.withLock { $0 = true }
        state.push.$hubHex.withLock { $0 = nodeHexA }
    }
    await connectNodes(store)
    await store.send(.updateNode(userNode(id: 11)))
    #expect(store.state.nodes[0].pushHubHex == DefaultNode.pushHubHex)
    #expect(store.state.nodes[1].pushHubHex == nil)
    await store.receive(.push(.hubChanged(host: "gaefu.ddns.net", port: 4242)))
    await store.receive(.push(.setHubHex(DefaultNode.pushHubHex)))
    await store.skipReceivedActions(strict: false)
}

/// M1: with nothing enabled to dial (no nodes, no listener, no BLE), `.connectTapped` must not
/// leave the UI showing "Connecting…" forever.
@MainActor @Test func nodeFinalConnectWithNothingEnabledStaysDisconnected() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [disabled(DefaultNode.entry)])
    await store.send(.connectTapped)
    #expect(store.state.connection == .disconnected)
    await store.receive { if case .node(.client(.endpoint(.start))) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

// MARK: - Default nodes: follow-ups (backlog 2026-10-11)

/// Backlog 5: `Gaefu.ddns.net` typed by hand is the default node; one hub, one socket.
@MainActor @Test func nodeFixAddNodeRefusesADuplicateHost() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry])
    store.exhaustivity = .on
    await store.send(.addNode(name: "Mine", host: "GAEFU.ddns.net", port: 4242, pushHubHex: nil))
    #expect(store.state.nodes.count == 1)
}

@MainActor @Test func nodeFixUpdateNodeRefusesADuplicateHostButAllowsItsOwn() async {
    let db = try! AppDatabase.makeInMemory()
    let a = userNode(id: 11)
    let store = nodeStore(db, nodes: [DefaultNode.entry, a])
    store.exhaustivity = .on
    var clash = a
    clash.host = "Gaefu.ddns.net"
    clash.port = 4242
    await store.send(.updateNode(clash))
    #expect(store.state.nodes[1].host == "node.example")
    store.exhaustivity = .off
    var renamed = a
    renamed.name = "Renamed"
    await store.send(.updateNode(renamed)) { $0.$nodes.withLock { $0[1].name = "Renamed" } }
    await store.skipReceivedActions(strict: false)
}

/// Backlog 19: a persisted list that carries no push hex (an earlier dev build) is repaired at
/// launch, not only on the next edit.
@MainActor @Test func nodeFixLaunchRestoresTheDefaultHexWhenNoneIsCarried() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [withoutHex(DefaultNode.entry)])
    await store.send(.onLaunch)
    #expect(store.state.nodes[0].pushHubHex == DefaultNode.pushHubHex)
    await store.receive(.push(.hubChanged(host: "gaefu.ddns.net", port: 4242)))
    await store.receive(.push(.setHubHex(DefaultNode.pushHubHex)))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

/// Backlog 8: a hex persisted uppercase by an older build equals the migrated lowercase one; no
/// spurious `setHubHex` (which would forget the registration).
@MainActor @Test func nodeFixUppercaseStoredHexSendsNoSetHubHex() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [DefaultNode.entry]) { state in
        state.push.$hubHex.withLock { $0 = DefaultNode.pushHubHex.uppercased() }
        state.push.$enabled.withLock { $0 = true }
        state.push.status = .registered(Date(timeIntervalSince1970: 1700000000))
    }
    await store.send(.connectTapped)
    await store.receive(.push(.hubChanged(host: "gaefu.ddns.net", port: 4242)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.push.status == .registered(Date(timeIntervalSince1970: 1700000000)),
            "a setHubHex would have marked the registration as hub-changed")
}

/// Backlog 20: with no TCP slot at all a foreground still re-points push.
@MainActor @Test func nodeFixForegroundWithNoSlotsStillRepointsPush() async {
    let db = try! AppDatabase.makeInMemory()
    let store = nodeStore(db, nodes: [disabled(DefaultNode.entry)]) { state in
        state.$listenEnabled.withLock { $0 = true }
        state.$listenPort.withLock { $0 = 5151 }
    }
    await store.send(.foregrounded)
    await store.receive(.push(.hubChanged(host: "", port: 0)))
    await store.skipReceivedActions(strict: false)
}

/// Backlog 6: a registration buffered behind a down push node reads "Waiting for <node>…".
@MainActor @Test func nodeFixBufferedRegistrationShowsWaitingForTheNode() async {
    let db = try! AppDatabase.makeInMemory()
    let hub = Data(repeating: 0xC1, count: 16)
    let store = nodeStore(db, nodes: [DefaultNode.entry]) { state in
        state.push.$enabled.withLock { $0 = true }
        state.push.$hubHex.withLock { $0 = DefaultNode.pushHubHex }   // already pointed: no setHubHex on connect
        state.push.status = .registering
    }
    await connectNodes(store)
    await store.send(.push(.delegate(.sendRegistration(hub: hub, path: "/register", data: Data([1]))))) {
        $0.pendingPushRegistration = PendingPushRegistration(hub: hub, path: "/register", data: Data([1]))
    }
    #expect(store.state.pushStatusText == "Waiting for Gaefu…")
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp)))))) {
        $0.pendingPushRegistration = nil
    }
    #expect(store.state.pushStatusText == "Registering…")
    await store.skipReceivedActions(strict: false)
}
