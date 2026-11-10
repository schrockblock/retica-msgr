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
@testable import ReTiCAMsgrCore

let blockPeerA = String(repeating: "a", count: 32)
let blockPeerB = String(repeating: "b", count: 32)
let blockT0 = Date(timeIntervalSince1970: 1_700_000_000)

/// Same hermetic store as `makeStore` in AppFeatureTests (private there), with a unique temporary
/// `PushStorage` so the mirror can be read back from its suite.
@MainActor
func makeBlockStore(_ db: any DatabaseWriter, identity: Identity = Identity(),
                    configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: identity, pushStorage: .temporary())
    initial.autoInterfaceAvailable = false   // hermetic: no AutoInterface slot
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.badge = .ignored
        $0.defaultDatabase = db
        $0.attachmentStore = AttachmentStore.testValue
        $0.date = .constant(blockT0)
        $0.transportDate = .constant(blockT0)
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
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

func blockedRows(_ db: any DatabaseWriter) throws -> [BlockedPeer] {
    try db.read { try BlockedPeer.all($0) }
}

func mirror(_ store: TestStoreOf<AppFeature>) -> Set<String> {
    store.state.push.storage.blockedSenders.load()
}

@MainActor @Test func blockPeerWritesRowMirrorAndNode() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeBlockStore(db)
    store.exhaustivity = .on
    await store.send(.blockPeer(blockPeerA)) {
        $0.blockedPeers = [blockPeerA]
        $0.blockedPeerRows = [BlockedPeer(peerHex: blockPeerA, blockedAt: blockT0)]
    }
    await store.receive(.node(.client(.ignoreDestination(Data(hexString: blockPeerA)!)))) {
        $0.node.client.ignoredDestinations = [Data(hexString: blockPeerA)!]
    }
    #expect(store.state.isBlocked(blockPeerA))
    await store.finish()
    #expect(try blockedRows(db).map(\.peerHex) == [blockPeerA])
    #expect(mirror(store) == [blockPeerA])
}

@MainActor @Test func blockPeerLowercasesAndIsIdempotent() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeBlockStore(db)
    await store.send(.blockPeer(blockPeerA.uppercased()))
    await store.receive { if case .node(.client(.ignoreDestination)) = $0 { return true }; return false }
    await store.send(.blockPeer(blockPeerA))
    #expect(store.state.blockedPeers == [blockPeerA])
    #expect(store.state.blockedPeerRows.count == 1)
    #expect(store.state.isBlocked(blockPeerA.uppercased()))
    await store.finish()
    #expect(try blockedRows(db).count == 1)
}

@MainActor @Test func blockPeerMalformedHexDoesNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeBlockStore(db)
    store.exhaustivity = .on
    await store.send(.blockPeer("zz"))
    await store.send(.blockPeer(String(repeating: "a", count: 30)))
    #expect(try blockedRows(db).isEmpty)
    #expect(mirror(store).isEmpty)
    await store.finish()
}

@MainActor @Test func unblockPeerDeletesRowMirrorAndNode() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { db in
        try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: blockPeerA, blockedAt: blockT0), db)
        try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: blockPeerB, blockedAt: blockT0), db)
    }
    let store = makeBlockStore(db)
    await store.send(.blockedPeersLoaded(try blockedRows(db)))
    await store.send(.unblockPeer(blockPeerA)) {
        $0.blockedPeers = [blockPeerB]
        $0.blockedPeerRows = [BlockedPeer(peerHex: blockPeerB, blockedAt: blockT0)]
    }
    await store.receive { action in
        if case let .node(.client(.unignoreDestination(hash))) = action {
            #expect(hash == Data(hexString: blockPeerA))
            return true
        }
        return false
    }
    await store.finish()
    #expect(try blockedRows(db).map(\.peerHex) == [blockPeerB])
    #expect(mirror(store) == [blockPeerB])
}

@MainActor @Test func unblockPeerWithNoRowStillTellsTheNode() async throws {
    // An older launch may have the hex in state but no row (or the reverse); unblock is total.
    let db = try AppDatabase.makeInMemory()
    let store = makeBlockStore(db) { $0.blockedPeers = [blockPeerA] }
    await store.send(.unblockPeer(blockPeerA)) { $0.blockedPeers = [] }
    await store.receive { if case .node(.client(.unignoreDestination)) = $0 { return true }; return false }
    await store.finish()
    #expect(mirror(store).isEmpty)
}

@MainActor @Test func blockPeerSelfIsRefused() async throws {
    let db = try AppDatabase.makeInMemory()
    let identity = Identity()
    let store = makeBlockStore(db, identity: identity)
    store.exhaustivity = .on
    await store.send(.blockPeer(store.state.myAddressHex))
    #expect(try blockedRows(db).isEmpty)
    await store.finish()
}

@MainActor @Test func reportAndBlockBlocksEvenWhenTheDraftIsDismissed() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeBlockStore(db)
    await store.send(.blockPeer(blockPeerA))
    await store.send(.reportPeer(blockPeerA))
    await store.receive { if case .reportDraftReady = $0 { return true }; return false }
    await store.send(.reportDismissed) { $0.reportDraft = nil }
    await store.finish()
    #expect(store.state.isBlocked(blockPeerA))
    #expect(try blockedRows(db).map(\.peerHex) == [blockPeerA])
}

@MainActor @Test func blockedPeersLoadedSetsStateAndMirror() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeBlockStore(db) { $0.blockedPeers = [blockPeerB] }
    store.state.push.storage.blockedSenders.save([blockPeerB])   // a stale mirror
    let rows = [BlockedPeer(peerHex: blockPeerA, blockedAt: blockT0)]
    store.exhaustivity = .on
    await store.send(.blockedPeersLoaded(rows)) {
        $0.blockedPeers = [blockPeerA]
        $0.blockedPeerRows = rows
    }
    await store.finish()
    #expect(mirror(store) == [blockPeerA])
}

/// Spec A5: the blocked-peer load runs ahead of everything else at launch, and the node learns
/// the set from the same effect, right after `blockedPeersLoaded`, before the node starts or the
/// push inbox drains.
@MainActor @Test func launchLoadsBlockedPeersBeforeAnythingElse() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: blockPeerA, blockedAt: blockT0), $0) }
    let store = makeBlockStore(db)
    await store.send(.onLaunch)
    // The three receives are the assertion: in .off mode an early .endpoint(.start) is skipped while looking for .blockedPeersLoaded, and the third receive then times out.
    await store.receive { action in
        if case let .blockedPeersLoaded(rows) = action {
            #expect(rows.map(\.peerHex) == [blockPeerA])
            return true
        }
        return false
    }
    await store.receive { action in
        if case let .node(.client(.rehydrateIgnoredDestinations(set))) = action {
            #expect(set == [Data(hexString: blockPeerA)!])
            return true
        }
        return false
    }
    // The first launch effect that is NOT ours: the node start. It must come after both.
    await store.receive { action in
        if case .node(.client(.endpoint(.start))) = action {
            return true
        }
        return false
    }
    #expect(store.state.blockedPeers == [blockPeerA])
    #expect(mirror(store) == [blockPeerA])
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func reportDraftReadyAndDismissed() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeBlockStore(db)
    let draft = ReportDraft(peerHex: blockPeerA, recipient: "", subject: "s", body: "b")
    await store.send(.reportDraftReady(draft)) { $0.reportDraft = draft }
    await store.send(.reportDismissed) { $0.reportDraft = nil }
}

private func blockUUID(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
}

@MainActor @Test func blockedPeerSendTappedSendsNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeBlockStore(db) { s in
        s.openPeerHex = blockPeerA
        s.blockedPeers = [blockPeerA]
        s.draft = "hello"
    }
    store.exhaustivity = .on
    await store.send(.sendTapped)
    #expect(store.state.draft == "hello")
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    await store.finish()
}

@MainActor @Test func blockedPeerDraftTypedBeforeBlockIsNotSent() async throws {
    // Review Focus 1: the block lands first, then the queued tap.
    let db = try AppDatabase.makeInMemory()
    let store = makeBlockStore(db) { s in
        s.openPeerHex = blockPeerA
        s.draft = "hello"
    }
    await store.send(.blockPeer(blockPeerA))
    await store.receive { if case .node(.client(.ignoreDestination)) = $0 { return true }; return false }
    await store.send(.sendTapped)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    await store.finish()
}

@MainActor @Test func blockedPeerReactionSendsNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let hash = String(repeating: "1", count: 64)
    let row = Message(id: blockUUID(1), peerHex: blockPeerA, isOutgoing: false, body: "hi",
                      timestamp: blockT0, status: MessageStatus.received, validated: true, messageHash: hash)
    try await db.write { try Message.insert { row }.execute($0) }
    let store = makeBlockStore(db) { s in
        s.openPeerHex = blockPeerA
        s.blockedPeers = [blockPeerA]
        s.threadMessages = [row]
    }
    store.exhaustivity = .on
    await store.send(.reactionSelected(messageHash: hash, emoji: "👍"))
    #expect(try await db.read { try Reaction.all.fetchAll($0) }.isEmpty)
    await store.finish()
}

@MainActor @Test func blockedPeerExpiryChangeSendsNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeBlockStore(db) { s in
        s.openPeerHex = blockPeerA
        s.blockedPeers = [blockPeerA]
        s.openConversationExpiryLoaded = true
    }
    store.exhaustivity = .on
    await store.send(.expirySelected(seconds: 3600))
    #expect(store.state.openConversationExpiry == nil)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    await store.finish()
}

@MainActor @Test func unblockedPeerSendTappedStillSends() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeBlockStore(db) { s in
        s.openPeerHex = blockPeerA
        s.blockedPeers = [blockPeerB]
        s.draft = "hello"
    }
    await store.send(.sendTapped)
    await store.receive { if case .node(.client(.sendMessage)) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Message.all.fetchAll($0) }.count == 1)
}

@MainActor @Test func reportPeerBuildsADraftFromInboundRowsAndAttachments() async throws {
    let db = try AppDatabase.makeInMemory()
    let theirs = Message(id: blockUUID(1), peerHex: blockPeerA, isOutgoing: false, body: "threat",
                         timestamp: blockT0, status: MessageStatus.received, validated: true,
                         messageHash: String(repeating: "1", count: 64))
    let mine = Message(id: blockUUID(2), peerHex: blockPeerA, isOutgoing: true, body: "mine",
                       timestamp: blockT0 + 1, status: MessageStatus.sent, validated: false,
                       messageHash: String(repeating: "2", count: 64))
    let photo = Message(id: blockUUID(3), peerHex: blockPeerA, isOutgoing: false, body: "",
                        timestamp: blockT0 + 2, status: MessageStatus.received, validated: true,
                        messageHash: String(repeating: "3", count: 64))
    let other = Message(id: blockUUID(4), peerHex: blockPeerB, isOutgoing: false, body: "elsewhere",
                        timestamp: blockT0 + 3, status: MessageStatus.received, validated: true,
                        messageHash: String(repeating: "4", count: 64))
    try await db.write { db in
        for row in [theirs, mine, photo, other] { try Message.insert { row }.execute(db) }
        try Attachment.insert {
            Attachment(id: blockUUID(9), messageId: photo.id, kind: AttachmentKind.image, name: "photo.jpg",
                       format: "jpeg", size: 10, width: 1, height: 1, path: "x")
        }.execute(db)
    }
    let store = makeBlockStore(db) { s in
        s.node.client.learnedPeers[Data(hexString: blockPeerA)!] = LXMFNode.LearnedPeer(
            displayName: "Mallory", stampCost: nil, supportsCompression: false, learnedAt: blockT0)
    }
    await store.send(.reportPeer(blockPeerA))
    await store.receive { action in
        if case let .reportDraftReady(draft) = action {
            #expect(draft.peerHex == blockPeerA)
            #expect(draft.body.contains("Announced name: Mallory"))
            #expect(draft.body.contains("] (attachment: photo.jpg)"))
            #expect(draft.body.contains("] threat"))
            #expect(!draft.body.contains("mine"))
            #expect(!draft.body.contains("elsewhere"))
            return true
        }
        return false
    }
    #expect(store.state.reportDraft?.peerHex == blockPeerA)
    await store.finish()
}
