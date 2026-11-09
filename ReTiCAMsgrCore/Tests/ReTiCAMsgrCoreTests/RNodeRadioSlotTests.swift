import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
@testable import ReTiCAMsgrCore

// The RNode radio slot (RNode lane D Task 7). Every store here runs the real reducers down to
// `RNodeInterface`, over `RNodeRadioHarness`. The slot follows the settings at Connect with
// Meshtastic's replace-on-change swap: any config change, radio or parameters, replaces it.
//
// Connect sends `.endpoint(.start)` in the same burst as the swap's `.stop`, so the start reaches the
// old slot mid-stop and the interface queues a restart behind its offline. `finishRNodeSwap` sees a
// slot that isn't idle and stops it again: a running slot replaced at Connect shows
// `[…, .stop, .stop, …]` (MeshCore ruling F12, `meshSlotConnectDuringASwapNeverStartsTwiceWithoutAStop`).
// Those tests also check `rnNoOverlappingStarts`.

private func rnWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

/// Lets in-flight effects run before an absence check ("nothing more happened"), then brings the
/// store's state up to date with what they sent.
@MainActor
private func rnSettle(_ store: TestStoreOf<AppFeature>) async {
    for _ in 0..<5 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func slot(_ store: TestStoreOf<AppFeature>) -> RNodeEndpoint.State? {
    store.state.node.client.endpoint.rnode
}

/// `rnCompleteSettings` as ReTiCA params.
private let paramsF1 = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                       spreadingFactor: 8, codingRate: 6)
/// The same with 869.525 MHz.
private let paramsF2 = RNodeLoRaParams(frequencyHz: 869_525_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                       spreadingFactor: 8, codingRate: 6)
private let startA1 = RnRadioCall.start(RNodeDriverConfig(radio: rnRadioIDA, params: paramsF1))
private let startA2 = RnRadioCall.start(RNodeDriverConfig(radio: rnRadioIDA, params: paramsF2))
private let startB1 = RnRadioCall.start(RNodeDriverConfig(radio: rnRadioIDB, params: paramsF1))

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

// MARK: - Connect

/// A nonzero TX power (17 dBm), so every field of the conversion is pinned: the shared fixture's is 0.
@MainActor @Test func rnSlotConnectStartsTheChosenRadioWithItsParams() async {
    let radio = RNodeRadioHarness()
    var settings = rnCompleteSettings
    settings.txPowerDBm = 17
    let params = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 17,
                                 spreadingFactor: 8, codingRate: 6)
    let store = rnRadioStore(radio: rnRadioIDA, settings: settings, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(await rnWait { radio.startCount >= 1 })
    #expect(radio.calls.value.first == .start(RNodeDriverConfig(radio: rnRadioIDA, params: params)))
    #expect(slot(store)?.interface.config == RNodeDriverConfig(radio: rnRadioIDA, params: params))
}

@MainActor @Test func rnSlotConnectWithRNodeOffBuildsNoSlot() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, enabled: false, radioHarness: radio)
    await store.send(.connectTapped)
    await rnSettle(store)
    #expect(slot(store) == nil)
    #expect(radio.calls.value.isEmpty)
}

@MainActor @Test func rnSlotConnectWithoutARadioBuildsNoSlot() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: nil, radioHarness: radio)
    await store.send(.connectTapped)
    await rnSettle(store)
    #expect(slot(store) == nil)
    #expect(radio.calls.value.isEmpty)
    #expect(store.state.connection == .disconnected, "nothing will dial: Connecting… would never resolve")
}

@MainActor @Test func rnSlotConnectWithIncompleteSettingsBuildsNoSlot() async {
    let radio = RNodeRadioHarness()
    var settings = rnCompleteSettings
    settings.frequencyHz = nil
    let store = rnRadioStore(radio: rnRadioIDA, settings: settings, radioHarness: radio)
    await store.send(.connectTapped)
    await rnSettle(store)
    #expect(slot(store) == nil)
    #expect(radio.calls.value.isEmpty)
    #expect(store.state.connection == .disconnected)
}

/// Preflight M7: SF 13 fits `UInt8`, so only `rnodeWillDial` (lane C's range check) keeps it off the
/// air. This is the case that separates the will-dial gate from the type conversion.
@MainActor @Test func rnSlotConnectWithAnOutOfRangeSettingBuildsNoSlot() async {
    let radio = RNodeRadioHarness()
    var settings = rnCompleteSettings
    settings.spreadingFactor = 13
    let store = rnRadioStore(radio: rnRadioIDA, settings: settings, radioHarness: radio)
    await store.send(.connectTapped)
    await rnSettle(store)
    #expect(slot(store) == nil)
    #expect(radio.calls.value.isEmpty)
    #expect(store.state.connection == .disconnected)
}

/// Amendment A10 ("will something dial") gains the RNode.
@MainActor @Test func rnSlotConnectWithOnlyAnRNodeShowsConnecting() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(store.state.connection == .connecting)
}

@MainActor @Test func rnSlotSettingsCompletedLaterStartAtTheNextConnect() async {
    let radio = RNodeRadioHarness()
    var settings = rnCompleteSettings
    settings.frequencyHz = nil
    let store = rnRadioStore(radio: rnRadioIDA, settings: settings, radioHarness: radio)
    await store.send(.connectTapped)
    await rnSettle(store)
    #expect(slot(store) == nil)
    await store.send(.rnodeFrequencyTextChanged("868.1"))
    await rnSettle(store)
    #expect(radio.calls.value.isEmpty, "a settings edit alone dials nothing")
    await store.send(.connectTapped)
    #expect(await rnWait { radio.startCount >= 1 })
    #expect(radio.calls.value == [startA1])
}

// MARK: - Changes wait for Connect

/// Review Focus 4. No foreground here (preflight L12): a foreground also applies an edit, as
/// Meshtastic's does.
@MainActor @Test func rnSlotEditingWhileOnlineDoesNotRestart() async {
    let radio = RNodeRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await rnSettle(store)
    #expect(radio.calls.value == [startA1])
    #expect(store.state.rnodeSwap == nil)
    #expect(slot(store)?.interface.isOnline == true)
}

@MainActor @Test func rnSlotAParameterChangeReplacesTheSlotAtConnect() async {
    let radio = RNodeRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.connectTapped)
    #expect(await rnWait { radio.startCount >= 2 })
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rnSettle(store)
    #expect(radio.calls.value == [startA1, .stop, .stop, startA2])
    #expect(rnNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    #expect(slot(store)?.interface.config.params == paramsF2)
}

@MainActor @Test func rnSlotChangingTheRadioReplacesTheSlotAtConnect() async {
    let radio = RNodeRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.binding(.set(\.rnodeRadioID, rnRadioIDB.uuidString)))
    await rnSettle(store)
    #expect(radio.calls.value == [startA1], "a radio change restarted before Connect")
    await store.send(.connectTapped)
    #expect(await rnWait { radio.startCount >= 2 })
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rnSettle(store)
    #expect(radio.calls.value == [startA1, .stop, .stop, startB1])
    #expect(rnNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    #expect(slot(store)?.interface.config.radio == rnRadioIDB)
}

@MainActor @Test func rnSlotTurningOffStopsAtTheNextConnect() async {
    let radio = RNodeRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.binding(.set(\.rnodeEnabled, false)))
    await rnSettle(store)
    #expect(radio.calls.value == [startA1], "turning off stopped the radio before Connect")
    await store.send(.connectTapped)
    #expect(await rnEventually(store) { slot(store) == nil })
    await rnSettle(store)
    #expect(radio.calls.value == [startA1, .stop, .stop])
    #expect(store.state.rnodeSwap == nil)
    #expect(store.state.node.client.endpoint.interfaces[rnSlotIDA] == nil)
}

/// After Disconnect the old slot is idle: replaced in the Connect action itself (preflight L10).
@MainActor @Test func rnSlotAnIdleOldSlotIsReplacedAtOnce() async {
    let radio = RNodeRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.disconnectTapped)
    #expect(await rnEventually(store) { slot(store)?.interface.isIdle == true })
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.connectTapped)
    #expect(slot(store)?.interface.config.params == paramsF2)
    #expect(store.state.rnodeSwap == nil)
    #expect(await rnWait { radio.startCount >= 2 })
    await rnSettle(store)
    #expect(radio.calls.value == [startA1, .stop, startA2])
}

/// Not online yet (connecting), still not idle: the swap waits for its stop. The Connect's start
/// reaches the stopping slot, so the app stops it again before replacing it.
@MainActor @Test func rnSlotChangeWhileConnectingWaitsForItsStop() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(await rnWait { radio.startCount >= 1 })        // never connected: .connecting
    radio.holdStops()
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.connectTapped)
    await rnSettle(store)
    #expect(radio.calls.value == [startA1])
    #expect(slot(store)?.interface.config.params == paramsF1)
    radio.releaseStops()
    #expect(await rnWait { radio.startCount >= 2 })
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rnSettle(store)
    #expect(radio.calls.value == [startA1, .stop, .stop, startA2])
    #expect(rnNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
}

/// A swap is replacing f1 with f2, the frequency is set back to f1, then Connect: the in-flight swap
/// is retargeted rather than ignored, and no two starts run without a stop between them.
@MainActor @Test func rnSlotConnectDuringASwapNeverStartsTwiceWithoutAStop() async {
    let radio = RNodeRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdStops()
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.foregrounded)
    #expect(store.state.rnodeSwap != nil)
    await store.send(.rnodeFrequencyTextChanged("868.1"))
    await store.send(.connectTapped)
    radio.releaseStops()
    #expect(await rnWait { radio.startCount >= 2 })
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rnSettle(store)
    #expect(rnNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    #expect(radio.calls.value == [startA1, .stop, .stop, startA1])
    #expect(slot(store)?.interface.config.params == paramsF1)
}

// MARK: - Profile, relay, counters

/// Spec §5.8: the RNode slot carries no IFAC.
@MainActor @Test func rnSlotSlotProfileHasNoIFAC() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(slot(store) != nil)
    #expect(slot(store)?.profile.ifac == nil)
}

/// Relay is global (spec §5.8): nothing reaches the RNode.
@MainActor @Test func rnSlotRelayChangeDoesNotTouchTheRNode() async {
    let radio = RNodeRadioHarness()
    let commands = LockIsolated<[RnSlotCommand]>([])
    let store = await connectedStore(radio: radio, slotCommands: commands)
    let before = commands.value
    await store.send(.setRelayMode(true))
    await rnSettle(store)
    #expect(radio.calls.value == [startA1])
    #expect(commands.value == before)
    #expect(slot(store)?.interface.isOnline == true)
}

@MainActor @Test func rnSlotCountersSurviveAReplacement() async {
    let radio = RNodeRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.node(.client(.endpoint(.rnode(.interface(.send(Data(repeating: 0xA5, count: 600))))))))
    #expect(slot(store)?.counters.oversize == 1)
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.connectTapped)
    #expect(await rnEventually(store) { slot(store)?.interface.config.params == paramsF2 })
    #expect(store.state.rnodeRetiredCounters.oversize == 1)
    #expect(slot(store)?.counters.oversize == 0)
}

/// The T6-review carry: `.stop` goes only to a slot that exists. With the RNode off there is no
/// slot, and Disconnect sends it nothing.
@MainActor @Test func rnSlotDisconnectWithNoSlotSendsNoStop() async {
    let radio = RNodeRadioHarness()
    let commands = LockIsolated<[RnSlotCommand]>([])
    let store = rnRadioStore(radio: rnRadioIDA, enabled: false, radioHarness: radio, slotCommands: commands)
    await store.send(.connectTapped)
    await store.send(.disconnectTapped)
    await rnSettle(store)
    #expect(slot(store) == nil)
    #expect(commands.value.isEmpty)
    #expect(radio.calls.value.isEmpty)
}

// MARK: - The checked conversion (lane C F17, preflight M9)

/// Lane C's ranges fit the types and `rnodeWillDial` blocks first, so state can't reach this nil
/// path: the init is tested directly.
@Test(arguments: [
    RNodeRadioSettings(frequencyHz: 5_000_000_000, bandwidthHz: 62_500, spreadingFactor: 8, codingRate: 6,
                       txPowerDBm: 0),
    RNodeRadioSettings(frequencyHz: 868_100_000, bandwidthHz: 62_500, spreadingFactor: 300, codingRate: 6,
                       txPowerDBm: 0),
])
func rnSlotParamsThatDoNotFitTheirTypeBuildNoSlot(_ settings: RNodeRadioSettings) {
    #expect(RNodeLoRaParams(settings) == nil)
}

// MARK: - All three radios (Review Focus 5)

private func allThreeRadios(_ state: inout AppFeature.State) {
    state.$meshtasticEnabled.withLock { $0 = true }
    state.$meshtasticRadioID.withLock { $0 = meshSlotRadioA.uuidString }
    state.$meshCoreEnabled.withLock { $0 = true }
    state.$meshCoreRadioID.withLock { $0 = mcRadioIDA.uuidString }
}

private let mcStartA = McRadioCall.start(mcRadioIDA, canRoute: false, secretBytes: 0)

@MainActor @Test func rnSlotAllThreeRadiosStartAtConnect() async {
    let radio = RNodeRadioHarness()
    let meshtastic = MeshRadioHarness()
    let meshCore = MeshCoreRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, meshtastic: meshtastic, meshCore: meshCore,
                             configure: allThreeRadios)
    await store.send(.connectTapped)
    #expect(await rnWait { radio.startCount >= 1 && meshtastic.startCount >= 1 && meshCore.startCount >= 1 })
    #expect(radio.calls.value == [startA1])
    #expect(meshtastic.calls.value == [.start(meshSlotRadioA)])
    #expect(meshCore.calls.value == [mcStartA])
}

@MainActor @Test func rnSlotSwappingTheRNodeLeavesTheOtherRadiosRunning() async {
    let radio = RNodeRadioHarness()
    let meshtastic = MeshRadioHarness()
    let meshCore = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio, meshtastic: meshtastic, meshCore: meshCore,
                                     configure: allThreeRadios)
    await meshBringRadioOnline(store, meshtastic, id: meshSlotIDA)
    await mcBringRadioOnline(store, meshCore, id: mcSlotIDA)
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.connectTapped)
    #expect(await rnWait { radio.startCount >= 2 })
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rnSettle(store)
    #expect(radio.calls.value.last == startA2)
    #expect(meshtastic.calls.value == [.start(meshSlotRadioA)])
    #expect(meshCore.calls.value == [mcStartA])
    #expect(store.state.node.client.endpoint.meshtastic?.interface.isOnline == true)
    #expect(store.state.node.client.endpoint.meshCore?.interface.isOnline == true)
}

@MainActor @Test func rnSlotChangingMeshCoreLeavesTheRNodeRunning() async {
    let radio = RNodeRadioHarness()
    let meshCore = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio, meshCore: meshCore, configure: allThreeRadios)
    await mcBringRadioOnline(store, meshCore, id: mcSlotIDA)
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.connectTapped)
    #expect(await rnWait { meshCore.startCount >= 2 })
    #expect(meshCore.calls.value.last == .start(mcRadioIDB, canRoute: false, secretBytes: 0))
    await rnSettle(store)
    #expect(radio.calls.value == [startA1])
    #expect(slot(store)?.interface.isOnline == true)
}
