import Testing
import Foundation
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCAPush
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCaMsgrCore

// Turning "Connect over Bluetooth" off drops the BLE slot on the next sync. Dropping it with a
// bare `= nil` cancels the interface's effects without `driver.stop()`, so the adapter keeps
// scanning and advertising and its peers stay registered in Transport. These tests drive the
// real AppFeature → LXMFServiceNode → TransportEndpoint → BLEInterface chain over a mock driver.

private let bleSlotPeer = Data(repeating: 0x5A, count: 16)
private let bleSlotPeerID = bleInterfaceID(bleSlotPeer)

enum BLESlotCall: Equatable { case start, stopEntered, stopReturned }

/// A mock BLE driver shaped like the live adapter: every `start` opens a FRESH session stream, and
/// `stop` records `.stopEntered`, blocks while stops are held, finishes the session and records
/// `.stopReturned`. A `stop` whose effect is cancelled (its slot dropped while it runs) sets
/// `stopCancelled`; the stop itself carries on, as the live adapter's would.
final class BLESlotHarness: Sendable {
    let calls = LockIsolated<[BLESlotCall]>([])
    let sessions = LockIsolated<[AsyncStream<BLEDriverEvent>.Continuation]>([])
    let stopCancelled = LockIsolated(false)
    /// Interface-level `.ble(.start)` actions the store reduced (`bleSlotStore`'s recorder).
    let interfaceStarts = LockIsolated(0)
    private let held = LockIsolated(false)

    var driver: BLEDriver {
        BLEDriver(
            start: { [self] _ in
                let session = AsyncStream<BLEDriverEvent>.makeStream()
                calls.withValue { $0.append(.start) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            readIdentity: { _ in }, openChannel: { _ in }, send: { _, _ in }, closeChannel: { _ in },
            stop: { [self] in
                calls.withValue { $0.append(.stopEntered) }
                await withTaskCancellationHandler {
                    // Polls with a sleep, not a bare `Task.yield()` spin, so a held stop does not
                    // keep a cooperative-pool thread busy while the rest of the suite runs.
                    while held.value { try? await Task.sleep(for: .milliseconds(1)) }
                } onCancel: {
                    stopCancelled.setValue(true)
                }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stopReturned) }
            })
    }

    var startCount: Int { calls.value.filter { $0 == .start }.count }
    func holdStops() { held.setValue(true) }
    func releaseStops() { held.setValue(false) }
    func yieldToLatest(_ event: BLEDriverEvent) { sessions.value.last?.yield(event) }
    func waitForStarts(_ count: Int) async {
        for _ in 0..<300 where startCount < count { await Task.megaYield() }
    }
    func waitForCall(_ call: BLESlotCall) async {
        for _ in 0..<300 where !calls.value.contains(call) { await Task.megaYield() }
    }
}

@MainActor
private func bleSlotStore(_ ble: BLESlotHarness) -> TestStoreOf<AppFeature> {
    let defaults = UserDefaults.inMemory
    var initial = withDependencies {
        $0.defaultAppStorage = defaults
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    initial.$bleEnabled.withLock { $0 = true }
    let db = try! AppDatabase.makeInMemory()
    let store = TestStore(initialState: initial) {
        CombineReducers {
            AppFeature()
            // Counts what reaches the interface, which a `.off` TestStore cannot assert absent.
            Reduce<AppFeature.State, AppFeature.Action> { _, action in
                if case .node(.client(.endpoint(.ble(.ble(.start))))) = action {
                    ble.interfaceStarts.withValue { $0 += 1 }
                }
                return .none
            }
        }
    } withDependencies: {
        $0.badge = .ignored
        $0.defaultAppStorage = defaults
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in },
                                     close: { _ in }, stop: { })
        $0.bleDriver = ble.driver
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
        $0.radioScanner = RadioScanner(scan: { AsyncStream { _ in } })
    }
    store.exhaustivity = .off
    return store
}

private func isDriverStopped(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.ble(.ble(.driverStopped))))) = action { return true }
    return false
}

private func isPickerDismiss(_ action: AppFeature.Action) -> Bool {
    if case .radioPicker(.dismiss) = action { return true }
    return false
}

/// Connect with BLE on, then a peer comes in over an inbound channel and registers in Transport.
@MainActor
private func bleSlotBringPeerOnline(_ store: TestStoreOf<AppFeature>, _ ble: BLESlotHarness) async {
    await store.send(.connectTapped)
    await ble.waitForStarts(1)
    let channel = BLEChannelID(id: UUID(uuidString: "C0C0C0C0-0000-4000-8000-0000000000C1")!)
    let handle = BLEPeerHandle(id: UUID(uuidString: "D0D0D0D0-0000-4000-8000-0000000000D1")!)
    ble.yieldToLatest(.ready)
    ble.yieldToLatest(.channelOpened(channel, handle, direction: .inbound, mtu: 185))
    ble.yieldToLatest(.channelData(channel, bleSlotPeer))
    await store.receive({ isInterfaceConnected($0, bleSlotPeerID) }, timeout: .seconds(2))
}

/// The bug: the slot was dropped with no `.stop`. Now the driver is stopped, the peer leaves
/// Transport at once, and the slot survives until `driver.stop()` returns.
@MainActor @Test func bleSlotDisablingStopsTheDriverAndDropsTheSlotOnlyAfterTheStopReturns() async {
    let ble = BLESlotHarness()
    let store = bleSlotStore(ble)
    await bleSlotBringPeerOnline(store, ble)
    ble.holdStops()
    await store.send(.binding(.set(\.bleEnabled, false)))
    await store.send(.foregrounded)
    await ble.waitForCall(.stopEntered)
    await Task.megaYield()
    // `store.state` only catches up with received actions when the test receives or skips them.
    await store.skipReceivedActions(strict: false)
    #expect(ble.calls.value == [.start, .stopEntered], "the driver was not told to stop")
    #expect(store.state.node.client.endpoint.ble != nil, "dropped before its driver stopped")
    #expect(store.state.node.client.endpoint.interfaces[bleSlotPeerID] == nil, "the peer is still registered")
    ble.releaseStops()
    await store.receive(isDriverStopped, timeout: .seconds(2))
    #expect(store.state.node.client.endpoint.ble == nil)
    #expect(!store.state.bleSlotRemovalPending)
    await store.skipReceivedActions(strict: false)
    #expect(ble.calls.value == [.start, .stopEntered, .stopReturned])
    #expect(!ble.stopCancelled.value, "the driver stop was cancelled")
}

/// Back on while the stop is in flight: the slot is kept, and the foreground's start (deferred by
/// the interface until the stop returns) restarts the driver once, after the stop.
@MainActor @Test func bleSlotReenabledDuringTheStopKeepsTheSlotAndRestartsAfterTheStop() async {
    let ble = BLESlotHarness()
    let store = bleSlotStore(ble)
    await bleSlotBringPeerOnline(store, ble)
    ble.holdStops()
    await store.send(.binding(.set(\.bleEnabled, false)))
    await store.send(.foregrounded)
    await ble.waitForCall(.stopEntered)
    await store.send(.binding(.set(\.bleEnabled, true)))
    await store.send(.foregrounded)
    await Task.megaYield()
    await store.skipReceivedActions(strict: false)
    #expect(ble.calls.value == [.start, .stopEntered], "a start reached the driver mid-stop")
    #expect(store.state.node.client.endpoint.ble?.ble.status == .starting, "the start was not deferred")
    ble.releaseStops()
    await store.receive(isDriverStopped, timeout: .seconds(2))
    await ble.waitForStarts(2)
    await store.skipReceivedActions(strict: false)
    #expect(ble.calls.value == [.start, .stopEntered, .stopReturned, .start])
    #expect(store.state.node.client.endpoint.ble != nil, "a re-enabled slot was dropped")
    #expect(store.state.node.client.endpoint.ble?.ble.status == .starting)
    #expect(!store.state.bleSlotRemovalPending)
}

/// Connect while the removal's stop is in flight: `.endpoint(.start)` reaches the slot, and the
/// interface defers that start behind the stop. It must not restart the driver of a slot that is
/// being dropped.
@MainActor @Test func bleSlotConnectDuringTheRemovalNeverRestartsTheDriver() async {
    let ble = BLESlotHarness()
    let store = bleSlotStore(ble)
    await bleSlotBringPeerOnline(store, ble)
    ble.holdStops()
    await store.send(.binding(.set(\.bleEnabled, false)))
    await store.send(.connectTapped)
    await ble.waitForCall(.stopEntered)
    await store.send(.connectTapped)
    ble.releaseStops()
    await store.receive(isDriverStopped, timeout: .seconds(2))
    for _ in 0..<20 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble == nil)
    #expect(ble.calls.value == [.start, .stopEntered, .stopReturned], "calls: \(ble.calls.value)")
}

/// A second sync while the removal's stop is held re-advances the removal. The interface reads
/// `.stopped` then, but it is not idle (`stopping`): dropping it on `.stopped` alone would leave
/// the `driver.stop()` in flight with no slot to report to. The slot must survive every advance
/// until the stop returns, and the stop must never be cancelled.
@MainActor @Test func bleSlotASyncDuringTheHeldStopDoesNotDropTheSlot() async {
    let ble = BLESlotHarness()
    let store = bleSlotStore(ble)
    await bleSlotBringPeerOnline(store, ble)
    ble.holdStops()
    await store.send(.binding(.set(\.bleEnabled, false)))
    await store.send(.foregrounded)
    await ble.waitForCall(.stopEntered)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
    await store.send(.connectTapped)
    await store.send(.foregrounded)
    await Task.megaYield()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble != nil, "dropped by a sync while its stop was in flight")
    #expect(store.state.bleSlotRemovalPending)
    ble.releaseStops()
    await ble.waitForCall(.stopReturned)
    for _ in 0..<20 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
    #expect(!ble.stopCancelled.value, "the driver stop was cancelled")
    #expect(store.state.node.client.endpoint.ble == nil)
    #expect(ble.calls.value == [.start, .stopEntered, .stopReturned], "calls: \(ble.calls.value)")
}

/// The radio picker's pause stops BLE WITHOUT dropping the slot, and closing the picker starts it
/// again on the same slot.
@MainActor @Test func bleSlotPickerPauseKeepsTheSlotAndResumesIt() async {
    let ble = BLESlotHarness()
    let store = bleSlotStore(ble)
    await bleSlotBringPeerOnline(store, ble)
    await store.send(.chooseRadioTapped)
    await store.receive(isDriverStopped, timeout: .seconds(2))
    #expect(store.state.node.client.endpoint.ble != nil, "the pause dropped the slot")
    await store.send(.radioPicker(.dismiss))
    await ble.waitForStarts(2)
    await store.skipReceivedActions(strict: false)
    #expect(ble.calls.value == [.start, .stopEntered, .stopReturned, .start])
    #expect(store.state.node.client.endpoint.ble?.ble.status == .starting)
}

/// Turned off while the picker has BLE paused: the slot is dropped once the pause's stop returns,
/// and closing the picker neither restarts BLE nor shows Connecting… for it.
@MainActor @Test func bleSlotDisabledWhilePausedIsDroppedAndThePickerDoesNotResumeIt() async {
    let ble = BLESlotHarness()
    let store = bleSlotStore(ble)
    await bleSlotBringPeerOnline(store, ble)
    ble.holdStops()
    await store.send(.chooseRadioTapped)
    await ble.waitForCall(.stopEntered)
    await store.send(.binding(.set(\.bleEnabled, false)))
    await store.send(.foregrounded)
    await store.skipReceivedActions(strict: false)
    let startsBeforeDismiss = ble.interfaceStarts.value
    await store.send(.radioPicker(.dismiss))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connection != .connecting, "Connecting… for a BLE slot being removed")
    ble.releaseStops()
    await store.receive(isDriverStopped, timeout: .seconds(2))
    for _ in 0..<20 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
    // The driver call log cannot show this: `BLESlotReducer` would re-stop a start before it ran.
    #expect(ble.interfaceStarts.value == startsBeforeDismiss, "the picker resumed a slot being removed")
    #expect(store.state.node.client.endpoint.ble == nil)
    #expect(ble.calls.value == [.start, .stopEntered, .stopReturned], "calls: \(ble.calls.value)")
}
