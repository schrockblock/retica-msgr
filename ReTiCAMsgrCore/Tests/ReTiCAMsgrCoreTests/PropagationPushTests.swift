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
@testable import ReTiCAMsgrCore

// Direct-first sends (spec 2026-10-21 propagation push): the in-flight set, the fallback flag and
// the meaning of `sentViaPropagation`.

// MARK: - Helpers (mirrors AppFeatureTests.makeStore)

/// `log`, when given, records each hold, TCP disconnect and `backgroundTimeExpired` the store
/// reduces, in order: a `.off` TestStore cannot assert an action absent, nor the order of two it
/// skipped past.
@MainActor
private func makeStore(_ db: any DatabaseWriter, backgroundTask: BackgroundTaskClient? = nil,
                       log: LockIsolated<[String]>? = nil, clock: TestClock<Duration> = TestClock(),
                       attachmentStore: AttachmentStore = AttachmentStore.testValue,
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
                case .backgroundTimeExpired: log?.withValue { $0.append("expired") }
                case .node(.client(.syncFromPropagationNode)): log?.withValue { $0.append("sync") }
                default: break
                }
                return .none
            }
        }
    } withDependencies: {
        $0.badge = .ignored
        if let backgroundTask { $0.backgroundTask = backgroundTask }
        $0.defaultDatabase = db
        $0.attachmentStore = attachmentStore
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = clock
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

/// The same two successes in the other order: the proof still wins over "propagated".
/// Mutation: let `deliveryConfirmed` skip rows already `propagated` → the status stays propagated.
@MainActor @Test func bothSuccessesAcceptedThenConfirmedEndDelivered() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = sendingStore(db, propagationNode: pnHex)
    let (hash, _) = await sendHi(store)
    await store.send(.node(.client(.delegate(.propagationAccepted(messageHash: hash)))))
    await store.finish()
    await store.send(.node(.client(.delegate(.deliveryConfirmed(messageHash: hash)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try await firstRow(db)
    #expect(row.status == MessageStatus.delivered)
    #expect(row.sentViaPropagation == true)
    #expect(store.state.inFlightSends.isEmpty)
}

/// A refused propagated copy is not a terminal outcome: the direct copy still decides.
/// Mutation: remove the hash on `propagationRefused` → the set is empty.
@MainActor @Test func propagationRefusedKeepsTheHashInFlight() async throws {
    let store = sendingStore(try AppDatabase.makeInMemory(), propagationNode: pnHex)
    let (hash, _) = await sendHi(store)
    await store.send(.node(.client(.delegate(.propagationRefused(messageHash: hash, reason: .tooLargeForNode)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.inFlightSends == [hash])
}

// MARK: - Background time for in-flight sends (amendments A3, A4)

/// The margin before the time left, never below zero, at most the cap. `.nan` is there because
/// it is the one input only the `isFinite` guard handles: an infinite or huge time is capped by
/// the `min` anyway. Mutations: drop the clamp to zero → 3 s gives −2 s; drop the `isFinite`
/// branch → `.nan` gives 0 s.
@Test func backgroundDeadlineClampsAndCaps() {
    #expect(AppFeature.backgroundDeadline(remaining: 20) == 15)
    #expect(AppFeature.backgroundDeadline(remaining: 3) == 0)
    #expect(AppFeature.backgroundDeadline(remaining: .infinity) == 25)
    #expect(AppFeature.backgroundDeadline(remaining: Double.greatestFiniteMagnitude) == 25)
    #expect(AppFeature.backgroundDeadline(remaining: .nan) == 25)
}

private let gaefuID = DefaultNode.entry.interfaceID
private let inFlightHash = Data(repeating: 5, count: 32)

/// A `BackgroundTaskClient` that grants `granted` with `remaining` seconds left, keeps `onExpire`
/// so a test can run the time out, and records every `end`.
private final class BackgroundTaskStub: Sendable {
    let granted: Int?
    let remaining: TimeInterval
    let onExpire = LockIsolated<(@Sendable () -> Void)?>(nil)
    let ended = LockIsolated<[Int]>([])
    /// One per `waitForEnds` call, nudged on every `end`.
    private let listeners = LockIsolated<[AsyncStream<Void>.Continuation]>([])

    init(granted: Int?, remaining: TimeInterval = 30) {
        self.granted = granted
        self.remaining = remaining
    }

    var client: BackgroundTaskClient {
        BackgroundTaskClient(
            begin: { [self] expire in
                onExpire.setValue(expire)
                return granted
            },
            end: { [self] id in
                ended.withValue { $0.append(id) }
                for listener in listeners.value { listener.yield() }
            },
            remaining: { [self] in remaining })
    }

    /// `end` runs in an effect the test cannot await: wait until `count` ends are recorded, for at
    /// most five seconds (the caller's expectation then reports a shortfall).
    func waitForEnds(_ count: Int = 1) async {
        let (nudges, listener) = AsyncStream.makeStream(of: Void.self)
        listeners.withValue { $0.append(listener) }
        listener.yield()   // ends recorded before this call count too
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [ended] in
                for await _ in nudges where ended.value.count >= count { return }
            }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }
            await group.next()
            group.cancelAll()
        }
    }
}

/// The default node, dialled so it has a TCP slot to close; `inFlight` puts one send in flight.
@MainActor
private func backgroundStore(_ db: any DatabaseWriter, task: BackgroundTaskStub? = nil,
                             client: BackgroundTaskClient? = nil, inFlight: Bool,
                             log: LockIsolated<[String]>, clock: TestClock<Duration> = TestClock(),
                             configure: ((inout AppFeature.State) -> Void)? = nil) async -> TestStoreOf<AppFeature> {
    let store = makeStore(db, backgroundTask: client ?? task?.client, log: log, clock: clock) { s in
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
    await task.waitForEnds()
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
    await task.waitForEnds()
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
    #expect(log.value == ["expired", "hold(true)", "disconnect"])
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
    await task.waitForEnds()
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
    await task.waitForEnds()
    #expect(task.ended.value == [7])
    #expect(store.state.backgroundTaskID == nil)
}

/// The app holds and closes 5 s before iOS's time runs out, while the process surely still runs.
/// Mutation: no early-deadline timer → nothing happens until iOS's expiry.
@MainActor @Test func earlyDeadlineHoldsAndClosesBeforeExpiry() async throws {
    let log = LockIsolated<[String]>([])
    let clock = TestClock()
    let task = BackgroundTaskStub(granted: 7, remaining: 30)
    let store = await backgroundStore(try AppDatabase.makeInMemory(), task: task, inFlight: true, log: log,
                                      clock: clock)
    await store.send(.backgrounded)
    await store.receive(.backgroundTaskBegan(7))
    await clock.advance(by: .seconds(24))
    #expect(log.value.isEmpty, "not before remaining − 5 s")
    await clock.advance(by: .seconds(1))
    await store.receive(.backgroundTimeExpired)
    await store.receive(isDisconnect)
    await task.waitForEnds()
    await store.skipReceivedActions(strict: false)
    #expect(log.value == ["expired", "hold(true)", "disconnect"])
    #expect(task.ended.value == [7])
    #expect(store.state.outboundHeld)
}

/// Mutation: don't cancel the early deadline when the task ends → it still fires after foreground.
@MainActor @Test func foregroundCancelsTheEarlyDeadline() async throws {
    let log = LockIsolated<[String]>([])
    let clock = TestClock()
    let task = BackgroundTaskStub(granted: 7, remaining: 30)
    let store = await backgroundStore(try AppDatabase.makeInMemory(), task: task, inFlight: true, log: log,
                                      clock: clock)
    await store.send(.backgrounded)
    await store.receive(.backgroundTaskBegan(7))
    await clock.advance(by: .seconds(10))
    await store.send(.foregrounded)
    await clock.advance(by: .seconds(20))
    await store.skipReceivedActions(strict: false)
    #expect(log.value.isEmpty)
    #expect(store.state.outboundHeld == false)
}

/// A second grant while one is still held gives the first back.
/// Mutation: overwrite the held id without ending it → `end(3)` is never called.
@MainActor @Test func replacedGrantEndsTheHeldOne() async throws {
    let task = BackgroundTaskStub(granted: 7)
    let store = makeStore(try AppDatabase.makeInMemory(), backgroundTask: task.client) {
        $0.isForeground = false
        $0.inFlightSends = [inFlightHash]
        $0.backgroundTaskID = 3
    }
    await store.send(.backgroundTaskBegan(7))
    await task.waitForEnds()
    #expect(task.ended.value == [3])
    #expect(store.state.backgroundTaskID == 7)
}

/// Every send settled while iOS was still answering: nothing is left to finish.
/// Mutation: drop the `inFlightSends.isEmpty` check → the id is kept and the sockets stay open.
@MainActor @Test func sendsSettledWhileAskingCloseOnTheGrant() async throws {
    let log = LockIsolated<[String]>([])
    let task = BackgroundTaskStub(granted: 7)
    let store = await backgroundStore(try AppDatabase.makeInMemory(), task: task, inFlight: false, log: log) {
        $0.isForeground = false
    }
    await store.send(.backgroundTaskBegan(7))
    await store.receive(isDisconnect)
    await task.waitForEnds()
    #expect(task.ended.value == [7])
    #expect(store.state.backgroundTaskID == nil)
}

// MARK: - Sends still in their hand-over effect (final review I1, M1)

private let pendingPDF = PendingAttachment(kind: AttachmentKind.file, name: "Trail map.pdf", format: "pdf",
                                           data: Data("%PDF fake".utf8), width: nil, height: nil,
                                           originalSource: nil, isOriginal: false)

/// Polls `condition` for at most five seconds (the caller's expectation then reports a shortfall).
private func waitUntil(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// The scene backgrounds while the attachment is still being stored: nothing is in `inFlightSends`
/// yet, but the reservation keeps the sockets open and asks for time.
/// Mutation: `.backgrounded` ignores `pendingHandOvers` → the sockets close and `begin` never runs.
@MainActor @Test func backgroundDuringAnAttachmentHandOverBeginsATask() async throws {
    let db = try AppDatabase.makeInMemory()
    let log = LockIsolated<[String]>([])
    let task = BackgroundTaskStub(granted: 7)
    let store = await backgroundStore(db, task: task, inFlight: false, log: log) { s in
        s.openPeerHex = peer
        s.pendingAttachment = pendingPDF
    }
    let gate = DatabaseGate()
    await gate.hold(db)
    await store.send(.sendTapped)
    #expect(store.state.pendingHandOvers == 1)
    await store.send(.backgrounded)
    await store.receive(.backgroundTaskBegan(7))
    gate.release()
    await store.receive { if case .node(.client(.sendMessage)) = $0 { return true }; return false }
    await store.receive(.handOverEnded)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingHandOvers == 0)
    #expect(store.state.inFlightSends.count == 1)
    #expect(store.state.backgroundTaskID == 7)
    #expect(log.value.isEmpty)
}

/// The attachment cannot be stored: nothing is handed over, and the reservation is given back.
/// Mutation: no decrement on `attachmentSendFailed` → it stays at 1.
@MainActor @Test func handOverFailureReleasesItsReservation() async throws {
    // A file where the attachments directory should be, so every store fails.
    let blocker = FileManager.default.temporaryDirectory.appending(path: "handOverBlocker-\(UUID().uuidString)")
    try Data([0]).write(to: blocker)
    defer { try? FileManager.default.removeItem(at: blocker) }
    let broken = AttachmentStore(baseDirectory: blocker.appending(path: "Attachments"))
    let store = makeStore(try AppDatabase.makeInMemory(), attachmentStore: broken) { s in
        s.openPeerHex = peer
        s.draft = "cap"
        s.pendingAttachment = pendingPDF
    }
    await store.send(.sendTapped)
    await store.receive(.attachmentSendFailed(draft: "cap"))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingHandOvers == 0)
}

/// A send handed over after the sockets closed for the background (here, as a group copy would
/// be) is held at once, so its retries are not spent on closed sockets.
/// Mutation: drop the safety net → no `holdOutbound(true)` and `outboundHeld` stays false.
@MainActor @Test func sendWhileBackgroundedWithoutATaskHolds() async throws {
    let log = LockIsolated<[String]>([])
    let store = await backgroundStore(try AppDatabase.makeInMemory(), inFlight: false, log: log)
    await store.send(.backgrounded)
    await store.receive(isDisconnect)
    let message = LXMessage.create(source: Identity(), destinationHash: Data(hexString: peer)!,
                                   timestamp: 1700000000, title: Data(), content: Data("hi".utf8), fields: [])
    await store.send(.node(.client(.sendMessage(message: message, fallbackToPropagation: false))))
    await store.receive { isHold(true, $0) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.outboundHeld)
    #expect(store.state.inFlightSends == [message.hash])
}

/// A `BackgroundTaskClient` whose n-th `begin` waits for `open(n)`, or for its effect's
/// cancellation (an `AsyncStream` wait ends then), and grants 7 + n.
private final class GatedBackgroundTask: Sendable {
    let calls = LockIsolated(0)
    let ended = LockIsolated<[Int]>([])
    private let gates = (0..<2).map { _ in AsyncStream.makeStream(of: Void.self) }

    var client: BackgroundTaskClient {
        BackgroundTaskClient(
            begin: { [self] _ in
                let n = calls.withValue { count in
                    count += 1
                    return count - 1
                }
                for await _ in gates[n].stream { break }
                return 7 + n
            },
            end: { [self] id in ended.withValue { $0.append(id) } },
            remaining: { 30 })
    }

    func open(_ n: Int) { gates[n].continuation.yield() }
}

/// Background, foreground, background: two requests wait under the one cancel ID. The first grant
/// is held; the last send settling ends it and cancels the second request, whose grant would then
/// be dropped with its `send` — so the request ends it itself.
/// Mutation: don't end a grant that comes back cancelled → `end(8)` is never called.
@MainActor @Test func cancelledBeginEndsItsOwnGrant() async throws {
    let gated = GatedBackgroundTask()
    let store = await backgroundStore(try AppDatabase.makeInMemory(), client: gated.client, inFlight: true,
                                      log: LockIsolated([]))
    await store.send(.backgrounded)
    await waitUntil { gated.calls.value == 1 }
    await store.send(.foregrounded)
    await store.send(.backgrounded)
    await waitUntil { gated.calls.value == 2 }
    gated.open(0)
    await store.receive(.backgroundTaskBegan(7))
    // The second request is never opened: only the cancellation can end its wait, so its grant
    // always comes back cancelled.
    await store.send(.node(.client(.delegate(.deliveryConfirmed(messageHash: inFlightHash)))))
    await waitUntil { gated.ended.value.count >= 2 }
    await store.skipReceivedActions(strict: false)
    #expect(gated.ended.value.sorted() == [7, 8])
    #expect(store.state.backgroundTaskID == nil)
}

// MARK: - Sync on foreground and on a propagated push (spec §3, A1)

/// The default node with a propagation node configured (or not), dialled so it has a TCP slot,
/// and the sync log.
@MainActor
private func syncStore(_ db: any DatabaseWriter, propagationNode: String,
                       log: LockIsolated<[String]>) async -> TestStoreOf<AppFeature> {
    let store = makeStore(db, log: log) { s in
        s.$nodes.withLock { $0 = [DefaultNode.entry] }
        s.$propagationNodeHex.withLock { $0 = propagationNode }
    }
    await store.send(.connectTapped)
    await store.skipReceivedActions(strict: false)
    return store
}

/// Mutation: return `.none` → no sync is received.
@MainActor @Test func propagatedPushSyncs() async throws {
    let store = await syncStore(try AppDatabase.makeInMemory(), propagationNode: pnHex, log: LockIsolated([]))
    await store.send(.propagatedPush)
    await store.receive(.node(.client(.syncFromPropagationNode)))
}

/// A1: only the configured node. Mutation: drop the guard → a sync is logged.
@MainActor @Test func propagatedPushWithoutANodeDoesNothing() async throws {
    let log = LockIsolated<[String]>([])
    let store = await syncStore(try AppDatabase.makeInMemory(), propagationNode: "", log: log)
    await store.send(.propagatedPush)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(log.value.isEmpty)
}

/// Mutation: never sync on foreground → the log stays empty.
@MainActor @Test func foregroundSyncsOnceWhenTCPIsUp() async throws {
    let log = LockIsolated<[String]>([])
    let store = await syncStore(try AppDatabase.makeInMemory(), propagationNode: pnHex, log: log)
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    log.setValue([])   // the connect synced already
    await store.send(.foregrounded)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(log.value == ["sync"])
}

/// A redial's connect syncs, so foreground itself must not (two syncs would race one transfer).
/// Mutation: always sync on foreground → "sync" is logged before the connect.
@MainActor @Test func foregroundAfterCloseSyncsOnConnectOnly() async throws {
    let log = LockIsolated<[String]>([])
    let store = await syncStore(try AppDatabase.makeInMemory(), propagationNode: pnHex, log: log)
    await store.send(.foregrounded)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(log.value.isEmpty)
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(gaefuID, .tcp))))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(log.value == ["sync"])
}

// MARK: - Group posts in Info (final review M2)

/// Each member copy carries its own hash, so no acceptance ever names the post row: Info shows no
/// "Propagation node copy" row rather than a "No" that is never corrected.
/// Mutation: store `false` for a group post → the row reads "No".
@MainActor @Test func groupPostHasNoPropagationCopyRow() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let groupHex = String(repeating: "1a", count: 16)
    let group = ChatGroup(groupHex: groupHex, name: "Mutual Aid", creatorHex: myHex, revision: 1,
                          state: GroupState.active, updatedAt: Date(timeIntervalSince1970: 1700000000))
    let roster = [myHex, peer].sorted()
    try await db.write { db in
        try ChatGroup.upsert(group, db)
        try GroupMember.replace(groupHex, with: roster, db)
    }
    let store = makeStore(db) { s in
        s.identity = me
        s.myAddressHex = myHex
        s.openPeerHex = groupHex
        s.openConversationKind = .group
        s.openGroup = group
        s.openGroupMembers = roster.map { GroupMember(groupHex: groupHex, memberHex: $0) }
        s.draft = "to the group"
        s.$propagationNodeHex.withLock { $0 = pnHex }
    }
    await store.send(.sendTapped)
    await store.receive(.handOverEnded)
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    let post = try #require(rows.first { $0.groupHex == groupHex && $0.groupPostId != nil })
    #expect(post.sentViaPropagation == nil)
    let labels = MessageInfo.sections(for: post).flatMap(\.rows).map(\.label)
    #expect(!labels.contains("Propagation node copy"))
}
