import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
@testable import ReTiCaMsgrCore

@MainActor @Test func meshSlotConnectStartsTheChosenRadio() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await radio.waitForStarts(1)
    #expect(radio.calls.value == [.start(meshSlotRadioA)])
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioA)
}

@MainActor @Test func meshSlotConnectWithMeshtasticOffBuildsNoSlot() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, enabled: false, harness: radio)
    await store.send(.connectTapped)
    await Task.megaYield()
    #expect(store.state.node.client.endpoint.meshtastic == nil)
    #expect(radio.calls.value.isEmpty)
}

@MainActor @Test func meshSlotConnectWithoutARadioBuildsNoSlotAndDialsNothing() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: nil, harness: radio)
    await store.send(.connectTapped)
    await Task.megaYield()
    #expect(store.state.node.client.endpoint.meshtastic == nil)
    #expect(store.state.connection == .disconnected, "nothing will dial: Connecting… would never resolve")
}

/// Amendment A10 ("will something dial") gains the radio.
@MainActor @Test func meshSlotConnectWithOnlyARadioShowsConnecting() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    #expect(store.state.connection == .connecting)
}

/// Contract 3: `.stop`, wait for `.radioOffline`, THEN nil — an online slot nil'd at once would
/// leave its interface registered in Transport.
@MainActor @Test func meshSlotDisablingStopsTheRadioBeforeDroppingTheSlot() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticEnabled, false)))
    await store.send(.foregrounded)
    await Task.megaYield()
    #expect(store.state.node.client.endpoint.meshtastic != nil, "dropped before its driver stopped")
    radio.releaseStops()
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.meshtastic == nil)
    #expect(store.state.node.client.endpoint.interfaces[meshSlotIDA] == nil)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop])
}

@MainActor @Test func meshSlotChangingTheRadioStartsTheNewRadioOnlyAfterTheOldStopped() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.foregrounded)
    await Task.megaYield()
    #expect(radio.calls.value == [.start(meshSlotRadioA)], "a driver call during the old stop")
    radio.releaseStops()
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await radio.waitForStarts(2)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioB)])
}

/// Review Focus 3: not online yet (connecting), still not idle — the swap waits for its stop.
@MainActor @Test func meshSlotChangingTheRadioWhileTheOldOneIsStillConnectingWaitsForItsStop() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await radio.waitForStarts(1)                     // never connected: status .connecting
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.foregrounded)
    await Task.megaYield()
    #expect(radio.calls.value == [.start(meshSlotRadioA)])
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioA)
    radio.releaseStops()
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await radio.waitForStarts(2)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioB)])
}

/// After Disconnect the old slot is idle (stopped, its stop returned): replaced in the same action.
@MainActor @Test func meshSlotAnIdleOldSlotIsReplacedAtOnce() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    await store.send(.disconnectTapped)
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.connectTapped)
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioB)
    #expect(store.state.meshtasticSwap == nil)
    await radio.waitForStarts(2)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioB)])
}

/// Review Focus 5. Connect's `.endpoint(.start)` reaches the old slot mid-stop; the interface
/// restarts it after its stop returns and reports offline first, so the app sees a NON-idle slot
/// at `.radioOffline` and stops it again.
@MainActor @Test func meshSlotConnectDuringASwapNeverStartsTwiceWithoutAStop() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.connectTapped)
    radio.releaseStops()
    let ended = await meshWaitUntil(timeout: .seconds(3)) {
        radio.calls.value.last == .start(meshSlotRadioB)
    }
    #expect(ended, "calls: \(radio.calls.value)")
    #expect(meshNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    // The second `.stop` is the app stopping the restarted (non-idle) old slot before dropping it
    // (Contract 3: only an idle slot is dropped), not leaning on the interface to discard it.
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .stop, .start(meshSlotRadioB)])
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioB)
    #expect(store.state.meshtasticSwap == nil)
}
