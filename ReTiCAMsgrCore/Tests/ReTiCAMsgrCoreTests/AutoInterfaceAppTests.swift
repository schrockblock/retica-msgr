import Testing
import Foundation
import Darwin
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCAPush
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCAMsgrCore

// AutoInterface in the app (spec 2026-11-10-autointerface §5.8, §6, §8). These tests drive the real
// AppFeature → LXMFServiceNode → TransportEndpoint → AutoEndpoint → AutoInterface chain over a mock
// socket driver, so a peer is a real discovery datagram and a removal a real `driver.stop()`.

private let autoNIC = "en0"
private let autoNICIndex: UInt32 = 4
private let autoOwnLL = "fe80::a1"
private let autoPeerLL = "fe80::b2"
private let autoPeerID = AutoEndpoint.autoInterfaceID(nic: autoNIC, addr: autoPeerLL)
private let autoNow = Date(timeIntervalSince1970: 1_700_000_000)

enum AutoDriverCall: Equatable { case run, stopEntered, stopReturned }

/// A mock AutoInterface socket driver: each `run` opens a FRESH event stream, `stop` records
/// `.stopEntered`, blocks while stops are held, finishes the session and records `.stopReturned`.
final class AutoDriverHarness: Sendable {
    let calls = LockIsolated<[AutoDriverCall]>([])
    let sessions = LockIsolated<[AsyncStream<AutoSocketEvent>.Continuation]>([])
    let nics: LockIsolated<[AutoNIC]>
    private let held = LockIsolated(false)

    init(nics: [AutoNIC] = [AutoNIC(name: autoNIC, index: autoNICIndex, linkLocals: [autoOwnLL])]) {
        self.nics = LockIsolated(nics)
    }

    var driver: AutoInterfaceDriver {
        AutoInterfaceDriver(
            interfaces: { [self] in nics.value },
            run: { [self] _ in
                let session = AsyncStream<AutoSocketEvent>.makeStream()
                calls.withValue { $0.append(.run) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            rebind: { _ in }, unbind: { _ in },
            sendMulticast: { _, _, _ in .sent }, sendUnicast: { _, _, _, _ in .sent },
            stop: { [self] in
                calls.withValue { $0.append(.stopEntered) }
                while held.value { try? await Task.sleep(for: .milliseconds(1)) }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stopReturned) }
            })
    }

    var runCount: Int { calls.value.filter { $0 == .run }.count }
    var stopCount: Int { calls.value.filter { $0 == .stopReturned }.count }
    func holdStops() { held.setValue(true) }
    func releaseStops() { held.setValue(false) }
    func yield(_ event: AutoSocketEvent) { sessions.value.last?.yield(event) }
    func waitForRuns(_ count: Int) async {
        for _ in 0..<300 where runCount < count { await Task.megaYield() }
    }
    func waitForCall(_ call: AutoDriverCall) async {
        for _ in 0..<300 where !calls.value.contains(call) { await Task.megaYield() }
    }
}

/// An AppFeature store with AutoInterface on and the harness as its driver. The listener is off and
/// the node list empty, so AutoInterface is the only thing that can dial. `.off` exhaustivity.
@MainActor
private func autoStore(_ auto: AutoDriverHarness, clock: TestClock<Duration> = TestClock(),
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    let defaults = UserDefaults.inMemory
    var initial = withDependencies {
        $0.defaultAppStorage = defaults
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    initial.$listenEnabled.withLock { $0 = false }
    initial.$nodes.withLock { $0 = [] }
    initial.$autoInterfaceEnabled.withLock { $0 = true }
    initial.autoInterfaceAvailable = true
    initial.autoInterfaceStopsInBackground = false
    configure?(&initial)
    let db = try! AppDatabase.makeInMemory()
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.badge = .ignored
        $0.defaultAppStorage = defaults
        $0.defaultDatabase = db
        $0.date = .constant(autoNow)
        $0.transportDate = .constant(autoNow)
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in },
                                     close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in },
                                 openChannel: { _ in }, send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
        $0.radioScanner = RadioScanner(scan: { AsyncStream { _ in } })
        $0.autoInterfaceDriver = auto.driver
    }
    store.exhaustivity = .off
    return store
}

private func isPeeringWaitElapsed(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.auto(.interface(.peeringWaitElapsed))))) = action { return true }
    return false
}

private func isAutoDriverStopped(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.auto(.interface(.driverStopped))))) = action { return true }
    return false
}

private func autoDelegate(_ delegate: AutoInterface.Action.Delegate) -> AppFeature.Action {
    .node(.client(.endpoint(.auto(.interface(.delegate(delegate))))))
}

/// A discovery datagram from `source` carrying its valid token, as a peer's multicast announce.
private func discovery(from source: String) -> AutoSocketEvent {
    .datagram(nic: autoNIC, plane: .multicastDiscovery, source: source, sourceScope: autoNICIndex,
              payload: AutoInterfaceWire.discoveryToken(groupID: AutoInterfaceWire.defaultGroupID, linkLocal: source))
}

/// Connect, wait out the 1.92 s initial peering wait, then a peer announces and registers.
@MainActor
private func autoBringPeerOnline(_ store: TestStoreOf<AppFeature>, _ auto: AutoDriverHarness,
                                 _ clock: TestClock<Duration>) async {
    await store.send(.connectTapped)
    await auto.waitForRuns(1)
    await clock.advance(by: .seconds(2))
    await store.receive(isPeeringWaitElapsed, timeout: .seconds(2))
    auto.yield(discovery(from: autoPeerLL))
    await store.receive({ isInterfaceConnected($0, autoPeerID) }, timeout: .seconds(2))
}

// MARK: - Toggle and platform gate

@MainActor @Test func autoToggleDefaultsOnAndTheGateFollowsThePlatform() {
    let state = withDependencies {
        $0.defaultAppStorage = .inMemory
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    #expect(state.autoInterfaceEnabled, "AutoInterface must default on (spec §9 R2/R3)")
    #expect(state.autoInterfaceAvailable == AutoInterfaceAvailability.isAvailable)
    #expect(state.autoInterfaceStopsInBackground == AutoInterfaceAvailability.stopsInBackground)
    // R1: iOS stays gated until Apple grants the multicast entitlement.
    #expect(!AutoInterfaceAvailability.isEntitledOniOS)
    #if os(macOS)
    #expect(AutoInterfaceAvailability.isAvailable, "the Mac needs no entitlement")
    #expect(!AutoInterfaceAvailability.stopsInBackground, "the Mac keeps running in the background")
    #expect(state.autoInterfaceWanted)
    #endif
}

/// iOS without the entitlement: the toggle is on by default but the slot never appears and the
/// driver never runs, and an on-but-unavailable AutoInterface does not count as dialing.
@MainActor @Test func autoUnavailableNeverCreatesTheSlotOrCountsAsDialing() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto) { $0.autoInterfaceAvailable = false }
    #expect(!store.state.somethingWillDial)
    await store.send(.connectTapped)
    await store.send(.foregrounded)
    for _ in 0..<20 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.auto == nil)
    #expect(auto.runCount == 0)
    #expect(store.state.connection != .connecting, "Connecting… with nothing that can dial")
}

// MARK: - Slot sync

@MainActor @Test func autoConnectCreatesTheSlotAndRunsTheDriver() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto)
    #expect(store.state.somethingWillDial, "a wanted AutoInterface is something that will dial")
    await store.send(.connectTapped)
    await auto.waitForRuns(1)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.auto != nil)
    #expect(auto.runCount == 1)
    #expect(store.state.connection == .connecting)
}

/// A running slot is KEPT across syncs: a foreground, a Connect and a node edit's sync leave the
/// registered peer in place and never run the driver a second time.
@MainActor @Test func autoSyncKeepsTheRunningSlotAndItsPeer() async {
    let auto = AutoDriverHarness()
    let clock = TestClock<Duration>()
    let store = autoStore(auto, clock: clock)
    await autoBringPeerOnline(store, auto, clock)
    await store.send(.foregrounded)
    await store.send(.connectTapped)
    await store.send(.addNode(name: "lan", host: "10.0.0.9", port: 4242, pushHubHex: nil))
    for _ in 0..<20 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.auto?.peerInterfaces[autoPeerID] != nil, "the peer was dropped")
    #expect(store.state.node.client.endpoint.interfaces[autoPeerID] != nil, "the peer left Transport")
    #expect(store.state.connectedInterfaces.contains(autoPeerID))
    #expect(store.state.autoInterfacePeerCount == 1)
    #expect(auto.runCount == 1, "the slot was recreated or restarted")
    #expect(auto.stopCount == 0)
}

/// Toggled off: the next sync removes the slot through `.removeAuto`, which deregisters the peer and
/// stops the driver, and the slot goes only once the stop has returned.
@MainActor @Test func autoToggleOffRemovesTheSlotThroughRemoveAuto() async {
    let auto = AutoDriverHarness()
    let clock = TestClock<Duration>()
    let store = autoStore(auto, clock: clock)
    await autoBringPeerOnline(store, auto, clock)
    auto.holdStops()
    await store.send(.binding(.set(\.autoInterfaceEnabled, false)))
    await store.send(.foregrounded)
    await auto.waitForCall(.stopEntered)
    await Task.megaYield()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.auto != nil, "dropped before its driver stopped")
    #expect(store.state.node.client.endpoint.interfaces[autoPeerID] == nil, "the peer is still registered")
    #expect(!store.state.connectedInterfaces.contains(autoPeerID))
    auto.releaseStops()
    await store.receive(isAutoDriverStopped, timeout: .seconds(2))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.auto == nil)
    #expect(auto.calls.value == [.run, .stopEntered, .stopReturned])
}

/// Back on while the removal's stop is in flight: once the stop returns and the slot is gone, a
/// fresh slot is put in and started.
@MainActor @Test func autoReenabledDuringTheRemovalRecreatesTheSlotAfterTheStop() async {
    let auto = AutoDriverHarness()
    let clock = TestClock<Duration>()
    let store = autoStore(auto, clock: clock)
    await autoBringPeerOnline(store, auto, clock)
    auto.holdStops()
    await store.send(.binding(.set(\.autoInterfaceEnabled, false)))
    await store.send(.foregrounded)
    await auto.waitForCall(.stopEntered)
    await store.send(.binding(.set(\.autoInterfaceEnabled, true)))
    await store.send(.foregrounded)
    auto.releaseStops()
    await store.receive(isAutoDriverStopped, timeout: .seconds(2))
    await auto.waitForRuns(2)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.auto != nil, "a re-enabled slot stayed gone")
    #expect(store.state.node.client.endpoint.auto?.removalPending == false)
    #expect(auto.calls.value == [.run, .stopEntered, .stopReturned, .run])
}

// MARK: - Background and foreground

/// iOS: backgrounding stops the slot (its peer leaves Transport, the slot stays); a push wake does
/// not start it; the next foreground starts it afresh.
@MainActor @Test func autoOnIOSStopsInTheBackgroundAndRestartsOnForeground() async {
    let auto = AutoDriverHarness()
    let clock = TestClock<Duration>()
    let store = autoStore(auto, clock: clock) { $0.autoInterfaceStopsInBackground = true }
    await autoBringPeerOnline(store, auto, clock)
    await store.send(.backgrounded)
    await auto.waitForCall(.stopReturned)
    await store.receive(isAutoDriverStopped, timeout: .seconds(2))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.auto != nil, "a background stop dropped the slot")
    #expect(store.state.node.client.endpoint.interfaces[autoPeerID] == nil, "the peer is still registered")
    #expect(store.state.node.client.endpoint.auto?.interface.status == .stopped)
    await store.send(.pushWake)
    for _ in 0..<20 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
    #expect(auto.runCount == 1, "a push wake started AutoInterface in the background")
    await store.send(.foregrounded)
    await auto.waitForRuns(2)
    await store.skipReceivedActions(strict: false)
    #expect(auto.runCount == 2, "the foreground did not restart the slot")
    #expect(store.state.node.client.endpoint.auto?.interface.status == .starting)
}

/// The Mac keeps the slot running in the background.
@MainActor @Test func autoOnTheMacKeepsRunningInTheBackground() async {
    let auto = AutoDriverHarness()
    let clock = TestClock<Duration>()
    let store = autoStore(auto, clock: clock)
    await autoBringPeerOnline(store, auto, clock)
    await store.send(.backgrounded)
    for _ in 0..<20 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
    #expect(auto.calls.value == [.run], "the Mac stopped AutoInterface in the background")
    #expect(store.state.node.client.endpoint.interfaces[autoPeerID] != nil)
}

// MARK: - somethingWillDial

@MainActor @Test func autoSomethingWillDialExcludesADeniedSlot() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto)
    await store.send(.connectTapped)
    await auto.waitForRuns(1)
    #expect(store.state.connection == .connecting)
    await store.send(autoDelegate(.localNetworkDenied))
    #expect(store.state.autoInterfaceNotices.localNetworkDenied)
    #expect(!store.state.somethingWillDial, "a denied slot still counts as dialing")
    #expect(store.state.connection == .disconnected, "Connecting… held by a denied slot")
    // A peer appearing disproves the denial.
    await store.send(autoDelegate(.peerAdded(addr: autoPeerLL, nic: autoNIC)))
    #expect(!store.state.autoInterfaceNotices.localNetworkDenied)
    #expect(store.state.somethingWillDial)
}

/// The denial does not hide anything else that will dial: Connecting… stays while a node dials.
@MainActor @Test func autoDenialKeepsConnectingWhileSomethingElseDials() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto) { $0.$listenEnabled.withLock { $0 = true } }
    await store.send(.connectTapped)
    await auto.waitForRuns(1)
    await store.send(autoDelegate(.localNetworkDenied))
    #expect(store.state.somethingWillDial)
    #expect(store.state.connection == .connecting)
}

// MARK: - Surfaced delegates

/// The case this Mac hits with NomadNet running: the data port is taken. Driven through the real
/// interface: the bind failure surfaces as `.dataPortInUse`, and the notice clears once the retried
/// bind succeeds.
@MainActor @Test func autoDataPortInUseSurfacesAndClearsWhenTheBindSucceeds() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto)
    await store.send(.connectTapped)
    await auto.waitForRuns(1)
    auto.yield(.bindFailed(nic: autoNIC, plane: .data, errno: EADDRINUSE))
    await store.receive({ $0 == autoDelegate(.dataPortInUse(nic: autoNIC)) }, timeout: .seconds(2))
    #expect(store.state.autoInterfaceDataPortInUse == [autoNIC])
    let layer = DiagnosticsSnapshot.autoInterfaceLayer(store.state, at: autoNow)
    #expect(layer.health == .problem)
    // A default rnsd or NomadNet has no TCP server interface, so "connect to it over TCP" alone is
    // no remedy: the copy says to quit it, or to add one (with the exact config) and then the node.
    #expect(layer.reason?.contains("quit") == true)
    #expect(layer.reason?.contains("TCP server interface") == true)
    let text = AutoInterfaceText.dataPortInUse
    #expect(text.contains("rnsd"))
    #expect(text.contains("NomadNet"))
    #expect(text.contains("quit"))
    #expect(text.contains("[[TCP Server]]"))
    #expect(text.contains("type = TCPServerInterface"))
    #expect(text.contains("listen_ip = 127.0.0.1"))
    #expect(text.contains("listen_port = 4242"))
    #expect(text.contains("add 127.0.0.1:4242 as a node"))
    auto.yield(.bound(nic: autoNIC))
    for _ in 0..<50 where !store.state.autoInterfaceDataPortInUse.isEmpty {
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
    #expect(store.state.autoInterfaceDataPortInUse.isEmpty, "the notice outlived the successful bind")
}

@MainActor @Test func autoLocalNetworkDeniedShowsTheAlertOncePerLaunch() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto)
    await store.send(.connectTapped)
    await auto.waitForRuns(1)
    await store.send(autoDelegate(.localNetworkDenied))
    #expect(store.state.localNetworkAlert == .denied)
    #expect(DiagnosticsSnapshot.autoInterfaceLayer(store.state, at: autoNow).health == .problem)
    await store.send(.localNetworkAlertDismissed)
    #expect(store.state.localNetworkAlert == nil)
    await store.send(autoDelegate(.localNetworkDenied))
    #expect(store.state.localNetworkAlert == nil, "the alert came back within one launch")
    #expect(AutoInterfaceText.alertMessage(.denied).contains("Local Network"))
}

/// Multicast failing on the ONLY NIC is the permission signature: alert. On one NIC of two it is a
/// dead NIC, not a permission problem: notice only.
@MainActor @Test func autoMulticastUnavailableAlertsOnlyWhenEveryNICFails() async {
    let single = AutoDriverHarness()
    let store = autoStore(single)
    await store.send(.connectTapped)
    await single.waitForRuns(1)
    await store.send(autoDelegate(.multicastUnavailable(nic: autoNIC)))
    #expect(store.state.autoInterfaceNotices.multicastUnavailable == [autoNIC])
    #expect(store.state.localNetworkAlert == .multicastUnavailable)

    let two = AutoDriverHarness(nics: [AutoNIC(name: autoNIC, index: autoNICIndex, linkLocals: [autoOwnLL]),
                                       AutoNIC(name: "bridge0", index: 9, linkLocals: ["fe80::c3"])])
    let store2 = autoStore(two)
    await store2.send(.connectTapped)
    await two.waitForRuns(1)
    await store2.send(autoDelegate(.multicastUnavailable(nic: "bridge0")))
    #expect(store2.state.autoInterfaceNotices.multicastUnavailable == ["bridge0"])
    #expect(store2.state.localNetworkAlert == nil, "one dead NIC raised the permission alert")
}

@MainActor @Test func autoCarrierLostAndRecoveredFollowTheNIC() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto)
    await store.send(.connectTapped)
    await auto.waitForRuns(1)
    await store.send(autoDelegate(.multicastUnavailable(nic: autoNIC)))
    await store.send(autoDelegate(.carrierLost(nic: autoNIC)))
    #expect(store.state.autoInterfaceNotices.carrierLost == [autoNIC])
    await store.send(autoDelegate(.carrierRecovered(nic: autoNIC)))
    #expect(store.state.autoInterfaceNotices.carrierLost.isEmpty)
    #expect(store.state.autoInterfaceNotices.multicastUnavailable.isEmpty, "an echo arrived, multicast works")
}

/// No eligible NIC: the interface's live status says so, and Diagnostics warns.
@MainActor @Test func autoNoUsableInterfacesSurfaces() async {
    let auto = AutoDriverHarness(nics: [])
    let store = autoStore(auto)
    await store.send(.connectTapped)
    await store.receive({ $0 == autoDelegate(.noUsableInterfaces) }, timeout: .seconds(2))
    #expect(store.state.autoInterfaceNoUsableInterfaces)
    let layer = DiagnosticsSnapshot.autoInterfaceLayer(store.state, at: autoNow)
    #expect(layer.health == .warn)
    #expect(layer.reason?.contains("no usable network interface") == true)
}

/// A restart is a fresh session: Connect on a stopped slot clears the old notices (a denial among
/// them), and a running slot keeps them (its `.start` is a no-op and it won't report again).
@MainActor @Test func autoConnectOnAStoppedSlotClearsTheNotices() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto)
    await store.send(.connectTapped)
    await auto.waitForRuns(1)
    await store.send(autoDelegate(.localNetworkDenied))
    await store.send(.connectTapped)
    #expect(store.state.autoInterfaceNotices.localNetworkDenied, "a running slot lost its notice")
    await store.send(.disconnectTapped)
    await auto.waitForCall(.stopReturned)
    await store.receive(isAutoDriverStopped, timeout: .seconds(2))
    await store.send(.connectTapped)
    #expect(!store.state.autoInterfaceNotices.localNetworkDenied, "a fresh session kept the old denial")
    #expect(store.state.connection == .connecting)
}

// MARK: - Diagnostics

@MainActor @Test func autoDiagnosticsShowsThePeersAfterSocket() async {
    let auto = AutoDriverHarness()
    let clock = TestClock<Duration>()
    let store = autoStore(auto, clock: clock)
    await autoBringPeerOnline(store, auto, clock)
    let snapshot = DiagnosticsSnapshot(from: store.state, at: autoNow)
    #expect(Array(snapshot.layers.map(\.title).prefix(2)) == ["Socket", "AutoInterface"])
    let layer = DiagnosticsSnapshot.autoInterfaceLayer(store.state, at: autoNow)
    #expect(layer.rows.contains(DiagnosticsSnapshot.Row("peers", "1")))
    #expect(layer.rows.contains(DiagnosticsSnapshot.Row(autoPeerID.rawValue, "connected")))
    #expect(layer.health == .ok)

    var hidden = store.state
    hidden.autoInterfaceAvailable = false
    #expect(!DiagnosticsSnapshot(from: hidden, at: autoNow).layers.map(\.title).contains("AutoInterface"))
}

/// Spec §9 R5: our own echo arrives (multicast works) but no peer for over 30 s.
@MainActor @Test func autoNoPeersHintAfterThirtySecondsOfEchoesAlone() async {
    let auto = AutoDriverHarness()
    let clock = TestClock<Duration>()
    let store = autoStore(auto, clock: clock)
    await store.send(.connectTapped)
    await auto.waitForRuns(1)
    await clock.advance(by: .seconds(2))
    await store.receive(isPeeringWaitElapsed, timeout: .seconds(2))
    auto.yield(discovery(from: autoOwnLL))
    for _ in 0..<50 where store.state.node.client.endpoint.auto?.interface.nics[autoNIC]?.firstEcho == nil {
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
    #expect(!store.state.autoInterfaceNoPeersHint(at: autoNow.addingTimeInterval(29)))
    #expect(store.state.autoInterfaceNoPeersHint(at: autoNow.addingTimeInterval(31)))
    #expect(DiagnosticsSnapshot.autoInterfaceLayer(store.state, at: autoNow.addingTimeInterval(31)).health == .warn)
    auto.yield(discovery(from: autoPeerLL))
    await store.receive({ isInterfaceConnected($0, autoPeerID) }, timeout: .seconds(2))
    #expect(!store.state.autoInterfaceNoPeersHint(at: autoNow.addingTimeInterval(31)), "hint with a peer up")
}

// MARK: - Fix round 1

/// Review I1: a slot stopped by Disconnect, the setting turned off (here without the Settings binding,
/// which now removes at once), then a foreground. The sync sends `.removeAuto`; the foreground must not
/// also start the slot it is removing.
@MainActor @Test func autoForegroundAfterDisconnectAndToggleOffRemovesWithoutARestart() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto)
    await store.send(.connectTapped)
    await auto.waitForRuns(1)
    await store.send(.disconnectTapped)
    await auto.waitForCall(.stopReturned)
    await store.receive(isAutoDriverStopped, timeout: .seconds(2))
    let shared = store.state
    shared.$autoInterfaceEnabled.withLock { $0 = false }
    await store.send(.foregrounded)
    for _ in 0..<50 where store.state.node.client.endpoint.auto != nil {
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
    for _ in 0..<20 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.auto == nil, "the slot was not removed")
    #expect(auto.runCount == 1, "the foreground restarted a slot it was removing")
}

/// Review m3: an iOS launch in the background (a push or a Bluetooth wake; `AppRuntime.build` sets
/// `isForeground` false) neither creates nor starts the slot. The first foreground does both.
@MainActor @Test func autoIOSBackgroundLaunchWaitsForTheForeground() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto) {
        $0.autoInterfaceStopsInBackground = true
        $0.isForeground = false
    }
    await store.send(.onLaunch)
    await store.send(.pushWake)
    for _ in 0..<20 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.auto == nil, "a background launch created the slot")
    #expect(auto.runCount == 0, "a background launch started AutoInterface")
    await store.send(.foregrounded)
    await auto.waitForRuns(1)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.auto != nil)
    #expect(auto.runCount == 1, "the foreground did not start AutoInterface")
}

/// The Mac is unchanged: a launch with nobody looking still starts it.
@MainActor @Test func autoMacLaunchStartsEvenWhenInactive() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto) { $0.isForeground = false }
    await store.send(.onLaunch)
    await auto.waitForRuns(1)
    await store.skipReceivedActions(strict: false)
    #expect(auto.runCount == 1)
}

/// Review m4: turning the setting off removes the slot at once, with no Connect or foreground.
@MainActor @Test func autoToggleOffTakesEffectAtOnce() async {
    let auto = AutoDriverHarness()
    let clock = TestClock<Duration>()
    let store = autoStore(auto, clock: clock)
    await autoBringPeerOnline(store, auto, clock)
    await store.send(.binding(.set(\.autoInterfaceEnabled, false)))
    await store.receive(isAutoDriverStopped, timeout: .seconds(2))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.auto == nil)
    #expect(store.state.node.client.endpoint.interfaces[autoPeerID] == nil)
    #expect(auto.calls.value == [.run, .stopEntered, .stopReturned])
}

/// Review m4: turning it on creates and starts the slot at once, except after Disconnect, where the
/// slot waits for the next Connect.
@MainActor @Test func autoToggleOnStartsAtOnceUnlessDisconnected() async {
    let auto = AutoDriverHarness()
    let store = autoStore(auto) { $0.$autoInterfaceEnabled.withLock { $0 = false } }
    await store.send(.connectTapped)
    #expect(store.state.node.client.endpoint.auto == nil)
    await store.send(.binding(.set(\.autoInterfaceEnabled, true)))
    await auto.waitForRuns(1)
    #expect(auto.runCount == 1, "turning it on did not start it")

    let later = AutoDriverHarness()
    let disconnected = autoStore(later) { $0.$autoInterfaceEnabled.withLock { $0 = false } }
    await disconnected.send(.connectTapped)
    await disconnected.send(.disconnectTapped)
    await disconnected.send(.binding(.set(\.autoInterfaceEnabled, true)))
    for _ in 0..<20 { await Task.megaYield() }
    #expect(disconnected.state.node.client.endpoint.auto != nil, "the slot was not created")
    #expect(later.runCount == 0, "turning it on after Disconnect started it")
    await disconnected.send(.connectTapped)
    await later.waitForRuns(1)
    #expect(later.runCount == 1)
}

/// Review m2: on a Mac the user may grant Local Network while the session runs. The first echo then
/// proves the network works: the denial no longer shows or blocks dialing.
@MainActor @Test func autoDenialClearsOnceAnEchoArrives() async {
    let auto = AutoDriverHarness()
    let clock = TestClock<Duration>()
    let store = autoStore(auto, clock: clock)
    await store.send(.connectTapped)
    await auto.waitForRuns(1)
    await clock.advance(by: .seconds(2))
    await store.receive(isPeeringWaitElapsed, timeout: .seconds(2))
    await store.send(autoDelegate(.localNetworkDenied))
    #expect(store.state.autoInterfaceLocalNetworkDenied)
    #expect(!store.state.somethingWillDial)
    auto.yield(discovery(from: autoOwnLL))
    for _ in 0..<50 where store.state.node.client.endpoint.auto?.interface.nics[autoNIC]?.firstEcho == nil {
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
    #expect(!store.state.autoInterfaceLocalNetworkDenied, "the denial outlived the first echo")
    #expect(store.state.somethingWillDial)
    #expect(DiagnosticsSnapshot.autoInterfaceLayer(store.state, at: autoNow).health != .problem)
}
