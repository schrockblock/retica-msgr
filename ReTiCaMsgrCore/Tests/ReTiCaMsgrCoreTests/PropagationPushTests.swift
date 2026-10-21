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

// Direct-first sends (spec 2026-10-21 propagation push): the in-flight set, the fallback flag and
// the meaning of `sentViaPropagation`.

// MARK: - Helpers (mirrors AppFeatureTests.makeStore)

@MainActor
private func makeStore(_ db: any DatabaseWriter, configure: ((inout AppFeature.State) -> Void)? = nil)
    -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: Identity())
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.attachmentStore = AttachmentStore.testValue
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
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

private let peer = String(repeating: "a", count: 32)
private let pnHex = String(repeating: "c", count: 32)

/// Send "hi" to `peer` and return the handed-over message plus the fallback flag it carried.
@MainActor
private func sendHi(_ store: TestStoreOf<AppFeature>) async -> (hash: Data, fallback: Bool) {
    await store.send(.sendTapped)
    var sent: (Data, Bool)?
    await store.receive { action in
        if case let .node(.client(.sendMessage(message, fallback))) = action {
            sent = (message.hash, fallback)
            return true
        }
        return false
    }
    await store.skipReceivedActions(strict: false)
    return (sent?.0 ?? Data(), sent?.1 ?? false)
}

@MainActor
private func sendingStore(_ db: any DatabaseWriter, propagationNode: String = "") -> TestStoreOf<AppFeature> {
    makeStore(db) { s in
        s.openPeerHex = peer
        s.draft = "hi"
        s.$propagationNodeHex.withLock { $0 = propagationNode }
    }
}

private func firstRow(_ db: any DatabaseWriter) async throws -> Message {
    let rows = try await db.read { try Message.where { $0.peerHex.eq(peer) }.fetchAll($0) }
    return try #require(rows.first)
}

// MARK: - Tests

@MainActor @Test func sendTracksInFlightUntilConfirmed() async throws {
    let store = sendingStore(try AppDatabase.makeInMemory())
    let (hash, _) = await sendHi(store)
    #expect(store.state.inFlightSends == [hash])
    await store.send(.node(.client(.delegate(.deliveryConfirmed(messageHash: hash)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.inFlightSends.isEmpty)
}

/// Failed, rejected, cancelled and accepted-by-the-node each settle a send.
@MainActor @Test(arguments: [0, 1, 2, 3]) func inFlightClearedByEveryTerminalOutcome(outcome: Int) async throws {
    let store = sendingStore(try AppDatabase.makeInMemory())
    let (hash, _) = await sendHi(store)
    #expect(store.state.inFlightSends == [hash])
    let terminal: AppFeature.Action
    switch outcome {
    case 0: terminal = .node(.client(.delegate(.deliveryFailed(messageHash: hash))))
    case 1: terminal = .node(.client(.delegate(.deliveryRejected(messageHash: hash))))
    case 2: terminal = .node(.client(.delegate(.deliveryCancelled(messageHash: hash))))
    default: terminal = .node(.client(.delegate(.propagationAccepted(messageHash: hash))))
    }
    await store.send(terminal)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.inFlightSends.isEmpty)
}

@MainActor @Test func terminalForUnknownHashIsANoOp() async throws {
    let store = sendingStore(try AppDatabase.makeInMemory())
    let (hash, _) = await sendHi(store)
    await store.send(.node(.client(.delegate(.deliveryFailed(messageHash: Data(repeating: 9, count: 32))))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.inFlightSends == [hash])
}

@MainActor @Test func sendUsesFallbackFlagFromThePropagationNode() async throws {
    let withNode = await sendHi(sendingStore(try AppDatabase.makeInMemory(), propagationNode: pnHex))
    #expect(withNode.fallback == true)
    let without = await sendHi(sendingStore(try AppDatabase.makeInMemory()))
    #expect(without.fallback == false)
}

@MainActor @Test func sentViaPropagationSetOnlyWhenAccepted() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = sendingStore(db, propagationNode: pnHex)
    let (hash, _) = await sendHi(store)
    #expect(try await firstRow(db).sentViaPropagation == false)
    await store.send(.node(.client(.delegate(.propagationAccepted(messageHash: hash)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try await firstRow(db)
    #expect(row.sentViaPropagation == true)
    #expect(row.status == MessageStatus.propagated)
}

@MainActor @Test func bothSuccessesKeepDeliveredAndClearOnce() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = sendingStore(db, propagationNode: pnHex)
    let (hash, _) = await sendHi(store)
    await store.send(.node(.client(.delegate(.deliveryConfirmed(messageHash: hash)))))
    await store.finish()
    await store.send(.node(.client(.delegate(.propagationAccepted(messageHash: hash)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try await firstRow(db)
    #expect(row.status == MessageStatus.delivered)
    #expect(row.sentViaPropagation == true)
    #expect(store.state.inFlightSends.isEmpty)
}
