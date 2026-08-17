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
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { }
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
    await store.send(.node(.client(.endpoint(.tcp(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp)))))))
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
/// The name itself is asserted too. It is a PROVISIONAL constant — the same string for every user
/// (see `AppFeature.swift:102-104`), so it names the *app*, not the person; two ReTiCaMsgr users are
/// indistinguishable in a Sideband contact list. This test pins that a name is sent, not that it is
/// a good one.
@MainActor @Test func interfaceConnectedSetsTheDisplayNameBeforeRegisteringDelivery() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.endpoint(.tcp(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp)))))))
    await store.receive { action in
        if case let .node(.client(.setDisplayName(name, stampCost))) = action {
            #expect(name == "ReTiCaMsgr")
            #expect(stampCost == nil)      // no inbound cost is advertised today
            return true
        }
        return false
    }
    await store.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    #expect(store.state.node.client.displayName == "ReTiCaMsgr")
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func interfaceConnectedWithoutPNDoesNotConfigure() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.client(.endpoint(.tcp(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp)))))))
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
    await store.send(.node(.client(.endpoint(.tcp(.transport(.interfaceConnected(InterfaceID("tcp"), .tcp)))))))
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
