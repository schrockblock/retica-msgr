import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
import ReTiCARNodeLive
import RNodeKit
@testable import ReTiCAMsgrCore

// The RNode slot's re-dial, Disconnect, picker guards and the user-action gate (RNode lane D
// Task 8). Every store runs the real reducers down to `RNodeInterface`, over `RNodeRadioHarness`.
//
// Absence checks ("no `.start` went out") read the store's slot-command log after `redial`, which
// waits for the re-dial's push re-point: `redialDownNodes` concatenates the radio sync and restarts
// BEFORE it, so by then any `.rnode(.start)` or `.stop` it sent has been reduced.

private func rnWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

/// Lets in-flight effects run before an absence check on the harness, then brings the store's state
/// up to date with what they sent.
@MainActor
private func rnSettle(_ store: TestStoreOf<AppFeature>) async {
    for _ in 0..<5 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func slot(_ store: TestStoreOf<AppFeature>) -> RNodeEndpoint.State? {
    store.state.node.client.endpoint.rnode
}

private func isRNodeAdapterUnavailable(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.rnode(.delegate(.adapterUnavailable))))) = action { return true }
    return false
}

private func isMeshtasticAdapterUnavailable(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.meshtastic(.delegate(.adapterUnavailable))))) = action { return true }
    return false
}

private func isMeshCoreAdapterUnavailable(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.meshCore(.delegate(.adapterUnavailable))))) = action { return true }
    return false
}

/// Sends `action` (`.foregrounded` or `.pushWake`) and waits until `redialDownNodes` has run past its
/// restarts: its push re-point's `.push(.hubChanged)` comes after them. Needs no TCP client slot, so
/// the re-dial takes its full path. Actions already received are skipped first, so an earlier
/// re-point (Connect's) can't stand in for this one.
@MainActor
private func redial(_ store: TestStoreOf<AppFeature>, _ action: AppFeature.Action) async {
    await store.skipReceivedActions(strict: false)
    await store.send(action)
    await store.receive({ if case .push(.hubChanged) = $0 { return true }; return false }, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
}

/// The newest session ends the way the live adapter ends one: `.unavailable(.other(text))`, then the
/// stream finishes. Waits until the app has reduced the endpoint's delegate.
@MainActor
private func failRadio(_ store: TestStoreOf<AppFeature>, _ radio: RNodeRadioHarness, _ text: String?) async {
    radio.yieldToLatest(.unavailable(.other(text)))
    radio.finishLatest()
    await store.receive(isRNodeAdapterUnavailable, timeout: .seconds(20))
}

/// Connect, then wait for radio A's first start (the radio is still connecting, where user-action
/// failures happen).
@MainActor
private func connectingStore(radio: RNodeRadioHarness, settings: RNodeRadioSettings = rnCompleteSettings,
                             slotCommands: LockIsolated<[RnSlotCommand]>? = nil) async -> TestStoreOf<AppFeature> {
    let store = rnRadioStore(radio: rnRadioIDA, settings: settings, radioHarness: radio, slotCommands: slotCommands)
    await store.send(.connectTapped)
    _ = await rnWait { radio.startCount >= 1 }
    return store
}

/// Connect, then bring radio A online.
@MainActor
private func connectedStore(radio: RNodeRadioHarness,
                            meshtastic: MeshRadioHarness = MeshRadioHarness(),
                            meshCore: MeshCoreRadioHarness = MeshCoreRadioHarness(),
                            slotCommands: LockIsolated<[RnSlotCommand]>? = nil,
                            configure: ((inout AppFeature.State) -> Void)? = nil) async -> TestStoreOf<AppFeature> {
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, meshtastic: meshtastic, meshCore: meshCore,
                             slotCommands: slotCommands, configure: configure)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    return store
}

/// Disconnect, and wait until the RNode slot is fully down and nothing is connected.
@MainActor
private func disconnect(_ store: TestStoreOf<AppFeature>) async {
    await store.send(.disconnectTapped)
    #expect(await rnEventually(store) {
        slot(store)?.interface.isIdle == true && store.state.connectedInterfaces.isEmpty
    })
}

private func allThreeRadios(_ state: inout AppFeature.State) {
    state.$meshtasticEnabled.withLock { $0 = true }
    state.$meshtasticRadioID.withLock { $0 = meshSlotRadioA.uuidString }
    state.$meshCoreEnabled.withLock { $0 = true }
    state.$meshCoreRadioID.withLock { $0 = mcRadioIDA.uuidString }
}

/// `rnCompleteSettings` as ReTiCA params.
private let paramsF1 = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                       spreadingFactor: 8, codingRate: 6)
/// The same with 869.525 MHz.
private let paramsF2 = RNodeLoRaParams(frequencyHz: 869_525_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                       spreadingFactor: 8, codingRate: 6)
private let startA1 = RnRadioCall.start(RNodeDriverConfig(radio: rnRadioIDA, params: paramsF1))
private let startB1 = RnRadioCall.start(RNodeDriverConfig(radio: rnRadioIDB, params: paramsF1))
private let mcStartA = McRadioCall.start(mcRadioIDA, canRoute: false, secretBytes: 0)

/// Review Focus 1: the user asked for 30 dBm, the radio clamps to 22.
private var tx30Settings: RNodeRadioSettings {
    var settings = rnCompleteSettings
    settings.txPowerDBm = 30
    return settings
}
private func paramsTX(_ dBm: UInt8) -> RNodeLoRaParams {
    RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: dBm, spreadingFactor: 8, codingRate: 6)
}
private let startTX30 = RnRadioCall.start(RNodeDriverConfig(radio: rnRadioIDA, params: paramsTX(30)))
private let startTX22 = RnRadioCall.start(RNodeDriverConfig(radio: rnRadioIDA, params: paramsTX(22)))

/// Not a user-action failure: the radio wasn't found this time, and a later attempt may find it.
private let radioNotFound = "radio not found"

/// The TX power clamp, as the live adapter words it.
private let txPowerRejected = RNodeLiveMessage.configurationRejected(
    [RNodeParameterMismatch(field: .txPower, requested: 30, reported: 22)])

/// Spec Contract 2's four failures only the user can fix, built from the live target's own texts.
private let userActionFailures = [RNodeLiveMessage.firmwareTooOld, RNodeLiveMessage.pairingRequired,
                                  RNodeLiveMessage.pairingRemoved, txPowerRejected]

// MARK: - Foreground and push wake

@MainActor @Test func rnRedialForegroundRestartsAStoppedRadio() async {
    let radio = RNodeRadioHarness()
    let store = await connectedStore(radio: radio)
    await disconnect(store)
    await store.send(.foregrounded)
    #expect(await rnWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA1, .stop, startA1])
}

/// `.start` reaches an online interface, which ignores it; nothing stops the radio first.
@MainActor @Test func rnRedialForegroundLeavesAnOnlineRadioAlone() async {
    let radio = RNodeRadioHarness()
    let commands = LockIsolated<[RnSlotCommand]>([])
    let store = await connectedStore(radio: radio, slotCommands: commands)
    commands.setValue([])
    await redial(store, .foregrounded)
    #expect(!commands.value.contains(.stop), "commands: \(commands.value)")
    await rnSettle(store)
    #expect(radio.calls.value == [startA1])
    #expect(slot(store)?.interface.isOnline == true)
    #expect(store.state.node.client.endpoint.interfaces[rnSlotIDA] != nil)
}

/// `redialDownNodes` returns early when every TCP node is up; the radio restart must still go out.
/// "radio not found" is not a user-action failure.
@MainActor @Test func rnRedialRestartsAnUnavailableRadio() async {
    let radio = RNodeRadioHarness()
    let tcp = MeshTCPHarness()
    let node = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, tcp: tcp) { state in
        state.$nodes.withLock { $0 = [node] }
    }
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, node.interfaceID) }, timeout: .seconds(20))
    #expect(await rnWait { radio.startCount >= 1 })
    await failRadio(store, radio, radioNotFound)
    #expect(!store.state.rnodeNeedsUserAction)
    await store.send(.foregrounded)
    #expect(await rnWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA1, startA1])
}

/// Preflight L13: `.other(nil)` carries no reason, so it is never a user-action failure.
@MainActor @Test func rnRedialAnUnavailableRadioWithNoReasonIsRestarted() async {
    let radio = RNodeRadioHarness()
    let store = await connectingStore(radio: radio)
    await failRadio(store, radio, nil)
    #expect(!store.state.rnodeNeedsUserAction)
    await store.send(.foregrounded)
    #expect(await rnWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
    #expect(radio.calls.value == [startA1, startA1])
}

@MainActor @Test func rnRedialPushWakeRestartsAStoppedRadio() async {
    let radio = RNodeRadioHarness()
    let store = await connectedStore(radio: radio)
    await disconnect(store)
    await store.send(.pushWake)
    #expect(await rnWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA1, .stop, startA1])
}

// MARK: - Failures only the user can fix (Review Focus 1)

@MainActor @Test(arguments: userActionFailures)
func rnRedialUserActionFailureIsNotRestartedByForegrounding(_ text: String) async {
    let radio = RNodeRadioHarness()
    let commands = LockIsolated<[RnSlotCommand]>([])
    let store = await connectingStore(radio: radio, slotCommands: commands)
    await failRadio(store, radio, text)
    #expect(store.state.rnodeNeedsUserAction)
    commands.setValue([])
    await redial(store, .foregrounded)
    #expect(commands.value == [], "a foreground re-dialled a radio only the user can fix")
    await rnSettle(store)
    #expect(radio.calls.value == [startA1])
}

@MainActor @Test(arguments: userActionFailures)
func rnRedialUserActionFailureIsNotRestartedByAPushWake(_ text: String) async {
    let radio = RNodeRadioHarness()
    let commands = LockIsolated<[RnSlotCommand]>([])
    let store = await connectingStore(radio: radio, slotCommands: commands)
    await failRadio(store, radio, text)
    #expect(store.state.rnodeNeedsUserAction)
    commands.setValue([])
    await redial(store, .pushWake)
    #expect(commands.value == [], "a push wake re-dialled a radio only the user can fix")
    await rnSettle(store)
    #expect(radio.calls.value == [startA1])
}

/// The user pairs, updates or fixes the radio and taps Connect: that retries. Once the flag is clear,
/// an ordinary drop is re-dialled again.
@MainActor @Test(arguments: userActionFailures)
func rnRedialConnectRetriesAUserActionFailure(_ text: String) async {
    let radio = RNodeRadioHarness()
    let commands = LockIsolated<[RnSlotCommand]>([])
    let store = await connectingStore(radio: radio, slotCommands: commands)
    await failRadio(store, radio, text)
    commands.setValue([])
    await redial(store, .foregrounded)
    #expect(commands.value == [])
    await store.send(.connectTapped)
    #expect(!store.state.rnodeNeedsUserAction)
    #expect(await rnWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA1, startA1])
    await failRadio(store, radio, radioNotFound)
    await store.send(.foregrounded)
    #expect(await rnWait { radio.startCount >= 3 }, "calls: \(radio.calls.value)")
}

/// Preflight B4 (MeshCore review fix 1): with only an RNode set up, a failure only the user can fix
/// leaves nothing dialing, so the app shows Disconnected and its Connect button.
@MainActor @Test func rnRedialUserActionFailureWithOnlyAnRNodeShowsDisconnected() async {
    let radio = RNodeRadioHarness()
    let store = await connectingStore(radio: radio)
    #expect(store.state.connection == .connecting)
    await failRadio(store, radio, RNodeLiveMessage.firmwareTooOld)
    #expect(store.state.connection == .disconnected, "Connecting… with nothing dialing")
}

/// Preflight B4: a re-dial after Disconnect dials nothing, so it must not show a Connecting… that
/// never resolves.
@MainActor @Test func rnRedialUserActionFailureThenDisconnectForegroundStaysDisconnected() async {
    let radio = RNodeRadioHarness()
    let commands = LockIsolated<[RnSlotCommand]>([])
    let store = await connectingStore(radio: radio, slotCommands: commands)
    await failRadio(store, radio, RNodeLiveMessage.pairingRequired)
    await disconnect(store)
    #expect(store.state.connection == .disconnected)
    commands.setValue([])
    await redial(store, .foregrounded)
    #expect(store.state.connection == .disconnected, "Connecting… with nothing dialing")
    #expect(commands.value == [])
    await rnSettle(store)
    #expect(radio.calls.value == [startA1, .stop])
}

/// Review Focus 1, through a foreground (preflight B5: Connect clears the flag itself, so it would
/// hide whether the install does). The radio clamps 30 dBm to 22; the user lowers TX power; the
/// next foreground replaces the slot, starts the new parameters, and the flag is clear.
@MainActor @Test func rnRedialAParameterChangeClearsTheFailure() async {
    let radio = RNodeRadioHarness()
    let store = await connectingStore(radio: radio, settings: tx30Settings)
    await failRadio(store, radio, txPowerRejected)
    #expect(store.state.rnodeNeedsUserAction)
    await store.send(.rnodeTXPowerChanged(22))
    await store.send(.foregrounded)
    #expect(await rnWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rnSettle(store)
    #expect(radio.calls.value == [startTX30, .stop, startTX22])
    #expect(!store.state.rnodeNeedsUserAction)
    await failRadio(store, radio, radioNotFound)
    await store.send(.foregrounded)
    #expect(await rnWait { radio.startCount >= 3 }, "calls: \(radio.calls.value)")
    #expect(radio.calls.value.last == startTX22)
}

/// Review Focus 1 the way the user does it: lower TX power, then Connect. A new slot starts with the
/// new parameters and comes online.
@MainActor @Test func rnRedialAParameterChangeThenConnectComesOnline() async {
    let radio = RNodeRadioHarness()
    let store = await connectingStore(radio: radio, settings: tx30Settings)
    await failRadio(store, radio, txPowerRejected)
    await store.send(.rnodeTXPowerChanged(22))
    await store.send(.connectTapped)
    #expect(!store.state.rnodeNeedsUserAction)
    #expect(await rnWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rnSettle(store)
    #expect(radio.calls.value.first == startTX30)
    #expect(radio.calls.value.last == startTX22)
    #expect(rnNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    await rnBringRadioOnline(store, radio, id: rnSlotIDA, starts: 2)
    #expect(slot(store)?.interface.isOnline == true)
    #expect(store.state.connection == .connected)
}

/// Installing a different radio clears the flag: B may be paired. Through a foreground (B5).
@MainActor @Test func rnRedialANewRadioIsNotHeldByTheOldFailure() async {
    let radio = RNodeRadioHarness()
    let store = await connectingStore(radio: radio)
    await failRadio(store, radio, RNodeLiveMessage.pairingRemoved)
    #expect(store.state.rnodeNeedsUserAction)
    await store.send(.binding(.set(\.rnodeRadioID, rnRadioIDB.uuidString)))
    await store.send(.foregrounded)
    #expect(await rnWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rnSettle(store)
    #expect(radio.calls.value == [startA1, .stop, startB1])
    #expect(!store.state.rnodeNeedsUserAction)
    await failRadio(store, radio, radioNotFound)
    await store.send(.foregrounded)
    #expect(await rnWait { radio.startCount >= 3 }, "calls: \(radio.calls.value)")
    #expect(radio.calls.value.last == startB1)
}

// MARK: - Swaps

/// Review Focus 5: a foreground during a swap must not `.start` the slot being replaced.
@MainActor @Test func rnRedialNeverRestartsTheSlotASwapIsReplacing() async {
    let radio = RNodeRadioHarness()
    let commands = LockIsolated<[RnSlotCommand]>([])
    let store = await connectedStore(radio: radio, slotCommands: commands)
    radio.holdStops()
    await store.send(.binding(.set(\.rnodeRadioID, rnRadioIDB.uuidString)))
    commands.setValue([])
    await redial(store, .foregrounded)
    await redial(store, .foregrounded)
    #expect(commands.value == [.stop], "commands: \(commands.value)")
    #expect(radio.calls.value == [startA1])
    radio.releaseStops()
    #expect(await rnWait { radio.startCount >= 2 })
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rnSettle(store)
    #expect(radio.calls.value == [startA1, .stop, startB1])
}

// MARK: - All three radios (Review Focus 5)

@MainActor @Test func rnRedialRestartsEachRadioIndependently() async {
    let radio = RNodeRadioHarness()
    let meshtastic = MeshRadioHarness()
    let meshCore = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio, meshtastic: meshtastic, meshCore: meshCore,
                                     configure: allThreeRadios)
    await meshBringRadioOnline(store, meshtastic, id: meshSlotIDA)
    await mcBringRadioOnline(store, meshCore, id: mcSlotIDA)
    // The RNode goes down, the others stay online.
    radio.yieldToLatest(.unavailable(.poweredOff))
    await store.receive(isRNodeAdapterUnavailable, timeout: .seconds(20))
    await store.send(.foregrounded)
    #expect(await rnWait { radio.startCount >= 2 })
    await rnSettle(store)
    #expect(meshtastic.calls.value == [.start(meshSlotRadioA)])
    #expect(meshCore.calls.value == [mcStartA])
    // The reverse: the RNode online, the others down.
    await rnBringRadioOnline(store, radio, id: rnSlotIDA, starts: 2)
    meshtastic.yieldToLatest(.unavailable(.poweredOff))
    await store.receive(isMeshtasticAdapterUnavailable, timeout: .seconds(20))
    meshCore.yieldToLatest(.unavailable(.poweredOff))
    await store.receive(isMeshCoreAdapterUnavailable, timeout: .seconds(20))
    await store.send(.foregrounded)
    #expect(await rnWait { meshtastic.startCount >= 2 && meshCore.startCount >= 2 })
    await rnSettle(store)
    #expect(radio.calls.value == [startA1, startA1])
    #expect(slot(store)?.interface.isOnline == true)
}

// MARK: - The picker

/// An RNode session connects by retrieval and never scans, so its restart isn't held behind the
/// picker. BLE's is: it would take FCB's one scan.
@MainActor @Test func rnRedialIsNotDeferredByThePicker() async {
    let radio = RNodeRadioHarness()
    let store = await connectedStore(radio: radio) { state in
        state.$bleEnabled.withLock { $0 = true }
        var ble = BLEEndpoint.State(localIdentity: state.identity.hash)
        ble.ble.status = .stopped
        state.node.client.endpoint.ble = ble
    }
    await disconnect(store)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
    await store.send(.chooseRNodeRadioTapped)
    #expect(store.state.radioPicker?.kind == .rnode)
    await redial(store, .foregrounded)
    #expect(await rnWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA1, .stop, startA1])
    await rnSettle(store)
    #expect(store.state.blePausedForRadioScan)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
}

/// The Connect button sits behind the sheet: a tap under the RNode picker is dropped.
@MainActor @Test func rnRedialConnectUnderAnRNodePickerIsDropped() async {
    let radio = RNodeRadioHarness()
    let commands = LockIsolated<[RnSlotCommand]>([])
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, slotCommands: commands)
    await store.send(.chooseRNodeRadioTapped)
    #expect(store.state.radioPicker?.kind == .rnode)
    await store.send(.connectTapped)
    #expect(slot(store) == nil)
    #expect(store.state.connection == .disconnected)
    await rnSettle(store)
    #expect(commands.value == [])
    #expect(radio.calls.value == [])
}

// MARK: - Disconnect

/// Review Focus 4: a swap finishing after Disconnect installs the new config stopped, and
/// `connection` stays Disconnected rather than showing Connecting… for a radio that isn't dialing.
@MainActor @Test func rnRedialDisconnectDuringASwapLeavesTheNewConfigStopped() async {
    let radio = RNodeRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdStops()
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.foregrounded)
    #expect(store.state.rnodeSwap != nil)
    await store.send(.disconnectTapped)
    #expect(store.state.rnodeSwap?.startNext == false)
    radio.releaseStops()
    await store.receive(isRNodeRadioOffline, timeout: .seconds(20))
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rnSettle(store)
    #expect(slot(store)?.interface.config.params == paramsF2)
    #expect(slot(store)?.interface.isIdle == true)
    #expect(radio.calls.value == [startA1, .stop])
    #expect(store.state.connection == .disconnected, "a swap finishing after Disconnect must not show Connecting…")
}

@MainActor @Test func rnRedialDisconnectStopsAllThreeRadios() async {
    let radio = RNodeRadioHarness()
    let meshtastic = MeshRadioHarness()
    let meshCore = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio, meshtastic: meshtastic, meshCore: meshCore,
                                     configure: allThreeRadios)
    await meshBringRadioOnline(store, meshtastic, id: meshSlotIDA)
    await mcBringRadioOnline(store, meshCore, id: mcSlotIDA)
    await store.send(.disconnectTapped)
    #expect(await rnWait {
        radio.calls.value.count >= 2 && meshtastic.calls.value.count >= 2 && meshCore.calls.value.count >= 2
    })
    #expect(radio.calls.value == [startA1, .stop])
    #expect(meshtastic.calls.value == [.start(meshSlotRadioA), .stop])
    #expect(meshCore.calls.value == [mcStartA, .stop])
    #expect(store.state.connection == .disconnected)
}
