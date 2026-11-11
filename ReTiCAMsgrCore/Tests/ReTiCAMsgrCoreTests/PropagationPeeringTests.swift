import ComposableArchitecture
import Foundation
import GRDB
import SQLiteData
import Testing
@testable import ReTiCAMsgrCore
import ReTiCA
import ReTiCANode
import ReTiCAInterfaces
import ReTiCAPush
import ReTiCATransport

// Propagation-node peering in the app: the settings that configure it, the rows that persist the
// peer table, and the launch order that restores it. TestStores are `.off`: they assert outcomes
// (what the library was told, what is on disk), not the path an effect took.

private func makeStore(_ db: any DatabaseWriter,
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: Identity())
    initial.autoInterfaceAvailable = false
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.badge = .ignored
        $0.defaultDatabase = db
        $0.attachmentStore = AttachmentStore.testValue
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in },
                                     close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(
            start: { _ in AsyncStream { _ in } },
            readIdentity: { _ in }, openChannel: { _ in }, send: { _, _ in },
            closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
    }
    store.exhaustivity = .off
    return store
}

private func peer(_ byte: UInt8, handled: Set<Data> = [], key: Data? = nil) -> PNPeerTable.Peer {
    PNPeerTable.Peer(destinationHash: Data(repeating: byte, count: 16), alive: true, peeringKey: key,
                     handled: handled)
}

private func storedPeerRows(_ db: any DatabaseWriter) throws -> [PNPeerRow] {
    try db.read { try PNPeerRow.all.order(by: \.position).fetchAll($0) }
}

@MainActor
@Suite("Propagation peering", .serialized)
struct PropagationPeeringTests {

    // MARK: Launch order

    /// A launch with three persisted peers and a stored entry hands BOTH to the library in the one
    /// rehydrate action, and node mode starts after it (Review Focus 3 at the app seam).
    @Test func launchRehydratesStoreAndPeersBeforeNodeMode() async throws {
        let db = try AppDatabase.makeInMemory()
        let peers = [peer(0x01, handled: [Data(repeating: 0xEE, count: 32)]), peer(0x02), peer(0x03)]
        let entry = Data(repeating: 0xAA, count: 16) + Data("stored".utf8)
        try await db.write { db in
            for row in PNPeerRow.rows(for: peers) { try PNPeerRow.insert { row }.execute(db) }
            try PropagationEntryRow.insert {
                PropagationEntryRow(transientIdHex: Data(repeating: 0x11, count: 32).hexString,
                                    destinationHashHex: Data(repeating: 0xAA, count: 16).hexString,
                                    lxmfData: entry, storedAt: Date(timeIntervalSince1970: 1700000000))
            }.execute(db)
        }
        let store = makeStore(db) {
            $0.$nodeModeEnabled.withLock { $0 = true }
            $0.$autopeerEnabled.withLock { $0 = true }
            $0.$staticPeerHexes.withLock { $0 = [] }
        }

        await store.send(.onLaunch)
        #expect(store.state.awaitingPeeringRehydrate)
        // `receive` consumes in order, so each of these only matches AFTER the one before it.
        await store.receive { action in
            if case let .node(.rehydrate(entries, got)) = action { return entries == [entry] && got == peers }
            return false
        }
        await store.receive { if case .node(.setAutopeer(true)) = $0 { return true }; return false }
        await store.receive { if case .node(.setStaticPeers(let s)) = $0 { return s.isEmpty }; return false }
        await store.receive { if case .node(.delegate(.peersChanged)) = $0 { return true }; return false }
        #expect(store.state.pnPeerCount == 3)
        #expect(!store.state.awaitingPeeringRehydrate)
        // The interface comes up after the rehydrate: node mode starts then.
        await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(DefaultNode.entry.interfaceID, .tcp))))))
        await store.receive { if case .node(.setNodeMode(true)) = $0 { return true }; return false }
    }

    /// The race: the interface connects BEFORE the launch read returns. Node mode must wait, then
    /// start from the rehydrate chain, after the settings, exactly once.
    @Test func interfaceConnectingBeforeRehydrateStillStartsNodeModeLast() async throws {
        let db = try AppDatabase.makeInMemory()
        let store = makeStore(db) {
            $0.$nodeModeEnabled.withLock { $0 = true }
            $0.$autopeerEnabled.withLock { $0 = true }
            $0.$staticPeerHexes.withLock { $0 = [] }
            $0.awaitingPeeringRehydrate = true      // what onLaunch sets while the read is out
        }
        await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(DefaultNode.entry.interfaceID, .tcp))))))
        #expect(store.state.awaitingPeeringRehydrate)
        // Let anything the connect sent reach the library, then ask it: node mode must not be on yet.
        try await Task.sleep(nanoseconds: 100_000_000)
        await store.skipReceivedActions(strict: false)
        #expect(!store.state.node.nodeModeEnabled)
        let peers = [peer(0x01)]
        await store.send(.rehydratePropagationStore(entries: [], peers: peers))

        // Ordered receives: the chain ends with node mode, after the settings.
        await store.receive { if case let .node(.rehydrate(_, got)) = $0 { return got == peers }; return false }
        await store.receive { if case .node(.setAutopeer(true)) = $0 { return true }; return false }
        await store.receive { if case .node(.setStaticPeers) = $0 { return true }; return false }
        await store.receive { if case .node(.setNodeMode(true)) = $0 { return true }; return false }
        await store.skipReceivedActions(strict: false)
        #expect(!store.state.awaitingPeeringRehydrate)
    }

    /// A stored "off" is the library's setting from the first announce: no default-on window.
    @Test func storedAutopeerOffIsHonouredFromTheFirstAnnounce() async throws {
        let db = try AppDatabase.makeInMemory()
        let store = makeStore(db) {
            $0.$autopeerEnabled.withLock { $0 = false }
            $0.$staticPeerHexes.withLock { $0 = [] }
        }
        await store.send(.onLaunch)    // seeds synchronously; the DB read is not awaited
        let announce = PNAnnounce(timebase: 1, nodeState: true, perTransferLimit: 1, perSyncLimit: 1,
                                  targetStampCost: 16, stampCostFlexibility: 3, peeringCost: 18)
        let dest = Data(repeating: 0x42, count: 16)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        var table = store.state.node.peering
        _ = table.announceHeard(dest, announce: announce, hops: 1, isPathResponse: false, now: now)
        #expect(table.peers.isEmpty)
        // Control: the same announce does peer when autopeer is on, so the check can fail.
        var on = table
        on.config.autopeer = true
        _ = on.announceHeard(dest, announce: announce, hops: 1, isPathResponse: false, now: now)
        #expect(on.peers.count == 1)
    }

    /// A corrupt peer row is skipped; the others load and launch is not blocked.
    @Test func corruptPeerRowIsSkippedAtLaunch() async throws {
        let db = try AppDatabase.makeInMemory()
        let good = [peer(0x01), peer(0x03)]
        try await db.write { db in
            var rows = PNPeerRow.rows(for: good)
            rows.insert(PNPeerRow(peerHex: Data(repeating: 0x02, count: 16).hexString, position: 1,
                                  blob: Data([0xC1, 0x00, 0xFF])), at: 1)
            rows[2].position = 2
            for row in rows { try PNPeerRow.insert { row }.execute(db) }
        }
        let store = makeStore(db) { $0.$nodeModeEnabled.withLock { $0 = false } }
        await store.send(.onLaunch)
        await store.receive { action in
            if case let .node(.rehydrate(_, got)) = action { return got == good }
            return false
        }
        #expect(!store.state.awaitingPeeringRehydrate)
    }

    // MARK: Persistence

    @Test func peersChangedUpsertsAndRemovesRows() async throws {
        let db = try AppDatabase.makeInMemory()
        let store = makeStore(db)
        let a = peer(0x0A), b = peer(0x0B), c = peer(0x0C)

        await store.send(.node(.delegate(.peersChanged([a, b, c]))))
        await store.finish()
        #expect(try storedPeerRows(db).map(\.peerHex) == [a, b, c].map { $0.destinationHash.hexString })
        #expect(store.state.pnPeerCount == 3)

        // b changes, a is gone, d arrives.
        let b2 = peer(0x0B, handled: [Data(repeating: 1, count: 32)])
        let d = peer(0x0D)
        await store.send(.node(.delegate(.peersChanged([b2, c, d]))))
        await store.finish()
        let rows = try storedPeerRows(db)
        #expect(rows.map(\.peerHex) == [b2, c, d].map { $0.destinationHash.hexString })
        #expect(rows.compactMap { PNPeerCodec.decode($0.blob) } == [b2, c, d])
        #expect(store.state.pnPeerCount == 3)

        await store.send(.node(.delegate(.peersChanged([]))))
        await store.finish()
        #expect(try storedPeerRows(db).isEmpty)
        #expect(store.state.pnPeerCount == 0)
    }

    /// An unchanged row is not rewritten. `sync` rewrites a changed row as delete + insert, so an
    /// INSERT trigger counts the rewrites; if `sync` ever moves to UPDATE, add an UPDATE trigger.
    @Test func syncDoesNotRewriteUnchangedRows() async throws {
        let db = try AppDatabase.makeInMemory()
        let a = peer(0x0A), b = peer(0x0B)
        try await db.write { db in
            try db.execute(sql: "CREATE TABLE writes (peerHex TEXT)")
            try db.execute(sql: "CREATE TRIGGER pnw AFTER INSERT ON pnPeerRows BEGIN INSERT INTO writes VALUES (NEW.peerHex); END")
            try PNPeerRow.sync(PNPeerRow.rows(for: [a, b]), in: db)
            try db.execute(sql: "DELETE FROM writes")
            let b2 = peer(0x0B, key: Data([1, 2, 3]))
            try PNPeerRow.sync(PNPeerRow.rows(for: [a, b2]), in: db)
        }
        let written = try await db.read { try String.fetchAll($0, sql: "SELECT peerHex FROM writes") }
        #expect(written == [Data(repeating: 0x0B, count: 16).hexString])
    }

    @Test func peerRoundTripsThroughTheRowBlob() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_123.456)
        let announce = PNAnnounce(timebase: 1_700_000_000, nodeState: true, perTransferLimit: 256_000,
                                  perSyncLimit: 10_240_000, targetStampCost: 16, stampCostFlexibility: 3,
                                  peeringCost: 18.5,
                                  metadata: .intMap([.init(1, .bin(Data("name".utf8)))]))
        let full = PNPeerTable.Peer(
            destinationHash: Data((0..<16).map { UInt8($0) }), peeringTimebase: 1_700_000_001, alive: true,
            lastHeard: when, lastSyncAttempt: when.addingTimeInterval(5), nextSyncAttempt: when.addingTimeInterval(720),
            syncBackoff: 720, syncTransferRate: 12_345.678, announce: announce,
            peeringKey: Data(repeating: 0x5A, count: 64), peeringKeyValue: 21.25,
            state: .transferring, linkID: Data(repeating: 0x77, count: 16),
            handled: [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)],
            unhandled: [Data(repeating: 3, count: 32)],
            lastOffer: [Data(repeating: 4, count: 32), Data(repeating: 5, count: 32)],
            transferring: [Data(repeating: 6, count: 32)], offered: 7, outgoing: 8, incoming: 9)
        let decoded = try #require(PNPeerCodec.decode(PNPeerCodec.encode(full)))
        #expect(decoded == full)
        #expect(decoded.peeringKey == Data(repeating: 0x5A, count: 64))
        #expect(decoded.handled == full.handled && decoded.unhandled == full.unhandled)
        #expect(decoded.lastHeard == when && decoded.nextSyncAttempt == full.nextSyncAttempt)

        // The empty shape (a static peer never heard): every optional nil, every default.
        let bare = PNPeerTable.Peer(destinationHash: Data(repeating: 9, count: 16))
        #expect(PNPeerCodec.decode(PNPeerCodec.encode(bare)) == bare)

        // Every state survives, and bytes are deterministic (set order cannot change them).
        for state in [PNPeerTable.PeerState.idle, .keyPending, .linkEstablishing, .linkReady, .requestSent, .transferring] {
            var p = bare; p.state = state
            #expect(PNPeerCodec.decode(PNPeerCodec.encode(p))?.state == state)
        }
        #expect(PNPeerCodec.encode(full) == PNPeerCodec.encode(full))
        #expect(PNPeerCodec.decode(Data([0xC1, 0x00])) == nil)
    }

    // MARK: Settings

    @Test func autopeerToggleSendsSetAutopeer() async throws {
        let db = try AppDatabase.makeInMemory()
        let store = makeStore(db) { $0.$autopeerEnabled.withLock { $0 = true } }

        await store.send(.setAutopeer(false))
        await store.receive { if case .node(.setAutopeer(false)) = $0 { return true }; return false }
        #expect(store.state.autopeerEnabled == false)
        #expect(store.state.node.peering.config.autopeer == false)

        await store.send(.setAutopeer(true))
        await store.receive { if case .node(.setAutopeer(true)) = $0 { return true }; return false }
        #expect(store.state.node.peering.config.autopeer == true)
    }

    @Test func staticPeerEditsSendSetStaticPeers() async throws {
        let db = try AppDatabase.makeInMemory()
        let store = makeStore(db) { $0.$staticPeerHexes.withLock { $0 = [] } }
        let one = String(repeating: "ab", count: 16)
        let two = String(repeating: "cd", count: 16)

        await store.send(.addStaticPeer("  " + one.uppercased() + " "))
        await store.receive { if case let .node(.setStaticPeers(s)) = $0 { return s == [Data(hexString: one)!] }; return false }
        #expect(store.state.staticPeerHexes == [one])

        await store.send(.addStaticPeer(two))
        await store.receive { if case let .node(.setStaticPeers(s)) = $0 { return s.count == 2 }; return false }
        #expect(store.state.node.peering.config.staticPeers == [Data(hexString: one)!, Data(hexString: two)!])

        // Invalid and duplicate addresses change nothing.
        await store.send(.addStaticPeer("not hex"))
        await store.send(.addStaticPeer(String(repeating: "ab", count: 15)))
        await store.send(.addStaticPeer(one))
        #expect(store.state.staticPeerHexes == [one, two])

        await store.send(.removeStaticPeer(one))
        await store.receive { if case let .node(.setStaticPeers(s)) = $0 { return s == [Data(hexString: two)!] }; return false }
        #expect(store.state.staticPeerHexes == [two])
        #expect(store.state.node.peering.config.staticPeers == [Data(hexString: two)!])
    }

    @Test func diagnosticsShowsPeerCount() async throws {
        var state = AppFeature.State(identity: Identity())
        state.pnPeerCount = 4
        let layer = DiagnosticsSnapshot.identityLayer(state)
        #expect(layer.rows.contains { $0.label == "pn peers" && $0.value == "4" })
    }
}
