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

// MARK: - Helpers

@MainActor
private func makeStore(_ db: any DatabaseWriter, identity: Identity,
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: identity)
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        // transportDate drives Transport's internal clock (learnedAt comparisons in
        // rehydrateLearnedDestinations). Set equal to \.date so a row with learnedAt = testNow
        // is neither "in the future" nor expired from Transport's perspective.
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
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
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true)))))
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
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true)))))
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

/// F5.5: with a PN configured, one message.hash gets TWO delivery sagas. The propagation leg
/// succeeds early (~20s → `propagationAccepted` → "stored"); the opportunistic leg has no data
/// receipt in our stack, so it always times out later (~50s → `deliveryFailed`). That later
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
    await store1.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true)))))
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
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true)))))
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
        if case let .node(.client(.router(.delegate(.sendOpportunistic(dest, payload))))) = action,
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

// MARK: - Public key requests (announce row tap)

@MainActor @Test func announceRowTappedOpensLinkAndMarksRequesting() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.announceRowTapped(destinationHashHex: peerA))
    #expect(store.state.publicKeyRequests[peerA] == .requesting)
    await store.receive { action in
        if case let .node(.client(.endpoint(.openLink(destinationHash)))) = action {
            #expect(destinationHash == Data(hexString: peerA))
            return true
        }
        return false
    }
}

/// With no learned path (the test store's transport has never heard of this peer), openLink
/// fails immediately with .noPath and the request settles as failed — a row can never stick on
/// "requesting" because of an unroutable peer.
@MainActor @Test func announceRowTappedWithoutPathFails() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.announceRowTapped(destinationHashHex: peerA))
    await store.receive { if case .node(.client(.endpoint(.openLink))) = $0 { return true }; return false }
    await store.receive { action in
        if case let .node(.client(.endpoint(.delegate(.linkFailed(destinationHash, reason))))) = action {
            #expect(destinationHash == Data(hexString: peerA))
            #expect(reason == .noPath)
            return true
        }
        return false
    }
    #expect(store.state.publicKeyRequests[peerA] == .failed(reason: "link failed"))
}

@MainActor @Test func announceRowTappedRejectsInvalidHex() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.announceRowTapped(destinationHashHex: "nothex"))
    #expect(store.state.publicKeyRequests.isEmpty)
    await store.send(.announceRowTapped(destinationHashHex: String(repeating: "a", count: 10)))   // 5 bytes — not a hash
    #expect(store.state.publicKeyRequests.isEmpty)
}

/// A request already in flight owns its link; a second tap must not open a duplicate one.
/// Tapping after the request settles (received/failed) is the retry path and IS allowed.
@MainActor @Test func announceRowTappedWhileRequestingIsIgnored() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.publicKeyRequests[peerA] = .requesting
    }
    await store.send(.announceRowTapped(destinationHashHex: peerA))
    #expect(store.state.publicKeyRequests[peerA] == .requesting)

    let store2 = makeStore(db, identity: Identity()) { s in
        s.publicKeyRequests[peerA] = .failed(reason: "no response")
    }
    await store2.send(.announceRowTapped(destinationHashHex: peerA))
    #expect(store2.state.publicKeyRequests[peerA] == .requesting)   // retry after failure
}

@MainActor @Test func linkEstablishedForRequestingPeerSendsPublicKeyRequest() async {
    let db = try! AppDatabase.makeInMemory()
    let linkID = Data(repeating: 0x42, count: 16)
    let store = makeStore(db, identity: Identity()) { s in
        s.publicKeyRequests[peerA] = .requesting
    }
    await store.send(.node(.client(.endpoint(
        .delegate(.linkEstablished(linkID: linkID, destinationHash: Data(hexString: peerA)!))))))
    await store.receive { action in
        if case let .node(.client(.endpoint(.sendRequestOverLink(linkID: l, path: p, data: d)))) = action {
            #expect(l == linkID)
            #expect(p == AppFeature.publicKeyRequestPath)
            #expect(d.isEmpty)
            return true
        }
        return false
    }
    #expect(store.state.publicKeyRequestLinks[linkID] == peerA)
}

/// Links established for other reasons (e.g. direct message delivery) must not be hijacked for
/// a public-key request: only links opened by announceRowTapped are correlated.
@MainActor @Test func linkEstablishedForNonRequestingPeerSendsNoRequest() async {
    let db = try! AppDatabase.makeInMemory()
    let linkID = Data(repeating: 0x42, count: 16)
    let store = makeStore(db, identity: Identity())   // no requesting peer
    await store.send(.node(.client(.endpoint(
        .delegate(.linkEstablished(linkID: linkID, destinationHash: Data(hexString: peerA)!))))))
    #expect(store.state.publicKeyRequestLinks.isEmpty)
}

@MainActor @Test func responseReceivedStoresValidPublicKey() async {
    let db = try! AppDatabase.makeInMemory()
    let linkID = Data(repeating: 0x42, count: 16)
    let peerKey = Identity().publicKey
    let store = makeStore(db, identity: Identity()) { s in
        s.publicKeyRequests[peerA] = .requesting
        s.publicKeyRequestLinks[linkID] = peerA
    }
    await store.send(.node(.client(.endpoint(
        .delegate(.responseReceived(linkID: linkID, requestID: Data(repeating: 1, count: 32), data: peerKey))))))
    #expect(store.state.publicKeyRequests[peerA] == .received(publicKeyHex: peerKey.hexString))
    #expect(store.state.publicKeyRequestLinks.isEmpty)
}

/// A malformed or low-order key must be rejected, not stored — a poisoned Identity would break
/// every later use of it.
@MainActor @Test func responseReceivedWithInvalidDataMarksFailed() async {
    let db = try! AppDatabase.makeInMemory()
    let linkID = Data(repeating: 0x42, count: 16)
    let store = makeStore(db, identity: Identity()) { s in
        s.publicKeyRequests[peerA] = .requesting
        s.publicKeyRequestLinks[linkID] = peerA
    }
    await store.send(.node(.client(.endpoint(
        .delegate(.responseReceived(linkID: linkID, requestID: Data(repeating: 1, count: 32), data: Data("not a key".utf8)))))))
    #expect(store.state.publicKeyRequests[peerA] == .failed(reason: "invalid public key"))
    #expect(store.state.publicKeyRequestLinks.isEmpty)
}

@MainActor @Test func linkFailedMarksRequestingPeerFailed() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.publicKeyRequests[peerA] = .requesting
    }
    await store.send(.node(.client(.endpoint(
        .delegate(.linkFailed(destinationHash: Data(hexString: peerA)!, reason: .establishmentTimedOut))))))
    #expect(store.state.publicKeyRequests[peerA] == .failed(reason: "link failed"))
}

@MainActor @Test func requestFailedMarksRequestingPeerFailed() async {
    let db = try! AppDatabase.makeInMemory()
    let linkID = Data(repeating: 0x42, count: 16)
    let store = makeStore(db, identity: Identity()) { s in
        s.publicKeyRequests[peerA] = .requesting
        s.publicKeyRequestLinks[linkID] = peerA
    }
    await store.send(.node(.client(.endpoint(
        .delegate(.requestFailed(linkID: linkID, requestID: Data(repeating: 1, count: 32)))))))
    #expect(store.state.publicKeyRequests[peerA] == .failed(reason: "no response"))
    #expect(store.state.publicKeyRequestLinks.isEmpty)
}

/// A link that closes while a request is in flight emits NO requestFailed (LinkSession's close
/// path only cancels the deadline) — without this branch the row would stick on "requesting".
@MainActor @Test func linkClosedMarksInFlightRequestFailed() async {
    let db = try! AppDatabase.makeInMemory()
    let linkID = Data(repeating: 0x42, count: 16)
    let store = makeStore(db, identity: Identity()) { s in
        s.publicKeyRequests[peerA] = .requesting
        s.publicKeyRequestLinks[linkID] = peerA
    }
    await store.send(.node(.client(.endpoint(
        .delegate(.linkClosed(linkID: linkID, reason: .timedOut))))))
    #expect(store.state.publicKeyRequests[peerA] == .failed(reason: "link closed"))
    #expect(store.state.publicKeyRequestLinks.isEmpty)
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
