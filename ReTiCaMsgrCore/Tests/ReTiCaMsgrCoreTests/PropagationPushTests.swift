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

/// `log`, when given, records each hold and TCP disconnect the store reduces, in order: a `.off`
/// TestStore cannot assert an action absent, nor the order of two it skipped past.
@MainActor
private func makeStore(_ db: any DatabaseWriter, backgroundTask: BackgroundTaskClient? = nil,
                       log: LockIsolated<[String]>? = nil,
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: Identity())
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        CombineReducers {
            AppFeature()
            Reduce<AppFeature.State, AppFeature.Action> { _, action in
                switch action {
                case let .node(.client(.holdOutbound(on))): log?.withValue { $0.append("hold(\(on))") }
                case .node(.client(.endpoint(.tcpClients(.element(_, .disconnect))))):
                    log?.withValue { $0.append("disconnect") }
                default: break
                }
                return .none
            }
        }
    } withDependencies: {
        if let backgroundTask { $0.backgroundTask = backgroundTask }
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

// MARK: - Background time for in-flight sends (amendments A3, A4)

private let gaefuID = DefaultNode.entry.interfaceID
private let inFlightHash = Data(repeating: 5, count: 32)

/// A `BackgroundTaskClient` that grants `granted`, keeps `onExpire` so a test can run the time
/// out, and records every `end`.
private final class BackgroundTaskStub: Sendable {
    let granted: Int?
    let onExpire = LockIsolated<(@Sendable () -> Void)?>(nil)
    let ended = LockIsolated<[Int]>([])

    init(granted: Int?) { self.granted = granted }

    var client: BackgroundTaskClient {
        BackgroundTaskClient(
            begin: { [self] expire in
                onExpire.setValue(expire)
                return granted
            },
            end: { [self] id in ended.withValue { $0.append(id) } })
    }
}

/// The default node, dialled so it has a TCP slot to close; `inFlight` puts one send in flight.
@MainActor
private func backgroundStore(_ db: any DatabaseWriter, task: BackgroundTaskStub? = nil, inFlight: Bool,
                             log: LockIsolated<[String]>,
                             configure: ((inout AppFeature.State) -> Void)? = nil) async -> TestStoreOf<AppFeature> {
    let store = makeStore(db, backgroundTask: task?.client, log: log) { s in
        s.$nodes.withLock { $0 = [DefaultNode.entry] }
        if inFlight { s.inFlightSends = [inFlightHash] }
        configure?(&s)
    }
    await store.send(.connectTapped)
    await store.skipReceivedActions(strict: false)
    return store
}

private func isDisconnect(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.tcpClients(.element(_, .disconnect))))) = action { return true }
    return false
}

private func isHold(_ on: Bool, _ action: AppFeature.Action) -> Bool {
    if case .node(.client(.holdOutbound(on))) = action { return true }
    return false
}

/// `end` runs in an effect the test cannot await, so wait (bounded) for it to be recorded.
@MainActor
private func waitForEnd(_ task: BackgroundTaskStub) async {
    for _ in 0..<1000 where task.ended.value.isEmpty { await Task.yield() }
}

/// Mutation: always begin a background task → the unimplemented `begin` fails the test.
@MainActor @Test func backgroundWithNothingInFlightClosesImmediately() async throws {
    let log = LockIsolated<[String]>([])
    let store = await backgroundStore(try AppDatabase.makeInMemory(), inFlight: false, log: log)
    await store.send(.backgrounded)
    await store.receive(isDisconnect)
    await store.skipReceivedActions(strict: false)
    #expect(log.value == ["disconnect"])
}

/// Mutation: close the sockets anyway → a disconnect is logged.
@MainActor @Test func backgroundWithSendsInFlightKeepsSocketsAndBeginsTask() async throws {
    let log = LockIsolated<[String]>([])
    let task = BackgroundTaskStub(granted: 7)
    let store = await backgroundStore(try AppDatabase.makeInMemory(), task: task, inFlight: true, log: log)
    await store.send(.backgrounded)
    await store.receive(.backgroundTaskBegan(7))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.backgroundTaskID == 7)
    #expect(log.value.isEmpty)
}

/// Mutation: skip the close when the last send settles → no disconnect is received.
@MainActor @Test func lastSendSettlingInBackgroundClosesSockets() async throws {
    let log = LockIsolated<[String]>([])
    let task = BackgroundTaskStub(granted: 7)
    let store = await backgroundStore(try AppDatabase.makeInMemory(), task: task, inFlight: true, log: log)
    await store.send(.backgrounded)
    await store.receive(.backgroundTaskBegan(7))
    await store.send(.node(.client(.delegate(.deliveryConfirmed(messageHash: inFlightHash)))))
    await store.receive(isDisconnect)
    await waitForEnd(task)
    #expect(task.ended.value == [7])
    #expect(store.state.backgroundTaskID == nil)
    // A second terminal outcome for the same send closes nothing more.
    await store.send(.node(.client(.delegate(.propagationAccepted(messageHash: inFlightHash)))))
    await store.skipReceivedActions(strict: false)
    #expect(log.value == ["disconnect"])
    #expect(task.ended.value == [7])
}

/// Mutation: ignore a nil grant → the sockets stay open.
@MainActor @Test func noBackgroundTimeClosesImmediately() async throws {
    let log = LockIsolated<[String]>([])
    let task = BackgroundTaskStub(granted: nil)
    let store = await backgroundStore(try AppDatabase.makeInMemory(), task: task, inFlight: true, log: log)
    await store.send(.backgrounded)
    await store.receive(.backgroundTaskBegan(nil))
    await store.receive(isDisconnect)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.backgroundTaskID == nil)
}

/// Mutation: no hold on expiry → no `holdOutbound(true)` and `outboundHeld` stays false.
@MainActor @Test func expiryHoldsOutboundAndCloses() async throws {
    let log = LockIsolated<[String]>([])
    let task = BackgroundTaskStub(granted: 7)
    let store = await backgroundStore(try AppDatabase.makeInMemory(), task: task, inFlight: true, log: log)
    await store.send(.backgrounded)
    await store.receive(.backgroundTaskBegan(7))
    let expire = try #require(task.onExpire.value)
    expire()
    await store.receive(.backgroundTimeExpired)
    await store.receive { isHold(true, $0) }
    await store.receive(isDisconnect)
    await waitForEnd(task)
    #expect(task.ended.value == [7])
    #expect(store.state.outboundHeld)
    #expect(store.state.backgroundTaskID == nil)
}

/// ReTiCA's hold protects an attempt only if it is on when the link-closed events arrive.
/// Mutation: close first, then hold → the log is in the other order.
@MainActor @Test func expiryHoldsBeforeClosing() async throws {
    let log = LockIsolated<[String]>([])
    let task = BackgroundTaskStub(granted: 7)
    let store = await backgroundStore(try AppDatabase.makeInMemory(), task: task, inFlight: true, log: log)
    await store.send(.backgrounded)
    await store.receive(.backgroundTaskBegan(7))
    let expire = try #require(task.onExpire.value)
    expire()
    await store.receive(.backgroundTimeExpired)
    await store.receive(isDisconnect)
    await store.skipReceivedActions(strict: false)
    #expect(log.value == ["hold(true)", "disconnect"])
}

/// Mutation: never release → no `holdOutbound(false)` and `outboundHeld` stays true.
@MainActor @Test func connectAfterHoldReleases() async throws {
    let log = LockIsolated<[String]>([])
    let store = makeStore(try AppDatabase.makeInMemory(), log: log) { $0.outboundHeld = true }
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
    await store.receive { isHold(false, $0) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.outboundHeld == false)
}

/// An app opened with no connectivity must not hold forever.
/// Mutation: release only on connect → no `holdOutbound(false)` on foreground.
@MainActor @Test func foregroundReleasesAHold() async throws {
    let log = LockIsolated<[String]>([])
    let store = makeStore(try AppDatabase.makeInMemory(), log: log) {
        $0.outboundHeld = true
        $0.isForeground = false
    }
    await store.send(.foregrounded)
    await store.receive { isHold(false, $0) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.outboundHeld == false)
}

/// Mutation: don't end the task on foreground → `end` is never called.
@MainActor @Test func foregroundEndsTheBackgroundTask() async throws {
    let log = LockIsolated<[String]>([])
    let task = BackgroundTaskStub(granted: 7)
    let store = await backgroundStore(try AppDatabase.makeInMemory(), task: task, inFlight: true, log: log)
    await store.send(.backgrounded)
    await store.receive(.backgroundTaskBegan(7))
    await store.send(.foregrounded)
    await waitForEnd(task)
    await store.skipReceivedActions(strict: false)
    #expect(task.ended.value == [7])
    #expect(store.state.backgroundTaskID == nil)
    #expect(log.value.isEmpty)
}

/// A grant that lands after the app came back is ended at once, not kept.
/// Mutation: store the id whatever the scene → it is kept and never ended.
@MainActor @Test func lateGrantAfterForegroundIsEnded() async throws {
    let task = BackgroundTaskStub(granted: 7)
    // A send still in flight, so only the foreground can be why it is ended.
    let store = makeStore(try AppDatabase.makeInMemory(), backgroundTask: task.client) {
        $0.inFlightSends = [inFlightHash]
    }
    await store.send(.backgroundTaskBegan(7))
    await waitForEnd(task)
    #expect(task.ended.value == [7])
    #expect(store.state.backgroundTaskID == nil)
}
