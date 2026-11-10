import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
import ReTiCAKeychain
import ReTiCAMeshCoreLive
@testable import ReTiCAMsgrCore

// Each radio's status light in Settings (`radioLight`): grey while off or stopped, yellow while
// dialling, green once online, red once the radio reports itself unavailable. Every store runs the
// real reducers down to the radio interfaces, over the mock drivers in the radio test support files.

private func rlWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

/// Off until the RNode is turned on and started, Connecting while it dials, Connected once online,
/// a problem once it reports itself unavailable.
@MainActor @Test func rlFollowsTheRNodeSlot() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, enabled: false, radioHarness: radio)
    #expect(store.state.radioLight(.rnode) == .off)
    await store.send(.binding(.set(\.rnodeEnabled, true)))
    #expect(store.state.radioLight(.rnode) == .off)
    await store.send(.radioConnectTapped(.rnode))
    #expect(await rnEventually(store) { store.state.radioLight(.rnode) == .connecting })
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    #expect(store.state.radioLight(.rnode) == .connected)
    radio.yieldToLatest(.unavailable(.poweredOff))
    await store.receive({
        if case .node(.client(.endpoint(.rnode(.delegate(.adapterUnavailable))))) = $0 { return true }
        return false
    }, timeout: .seconds(20))
    #expect(store.state.radioLight(.rnode) == .problem)
}

/// Meshtastic: Off before Connect, Connecting, Connected once online, a problem once Bluetooth goes away.
@MainActor @Test func rlFollowsTheMeshtasticSlot() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    #expect(store.state.radioLight(.meshtastic) == .off)
    await store.send(.connectTapped)
    #expect(await rnEventually(store) { store.state.radioLight(.meshtastic) == .connecting })
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    #expect(store.state.radioLight(.meshtastic) == .connected)
    radio.yieldToLatest(.unavailable(.poweredOff))
    await store.receive({
        if case .node(.client(.endpoint(.meshtastic(.delegate(.adapterUnavailable))))) = $0 { return true }
        return false
    }, timeout: .seconds(20))
    #expect(store.state.radioLight(.meshtastic) == .problem)
}

/// MeshCore: Connected once online; a policy failure (no free channel slot) is a problem.
@MainActor @Test func rlFollowsTheMeshCoreSlot() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    #expect(store.state.radioLight(.meshCore) == .connected)

    let failing = MeshCoreRadioHarness()
    let failed = mcRadioStore(radio: mcRadioIDA, radioHarness: failing)
    await failed.send(.connectTapped)
    #expect(await rlWait { failing.startCount >= 1 })
    failing.yieldToLatest(.unavailable(.other(MeshCoreLiveMessage.noFreeSlot)))
    failing.finishLatest()
    await failed.receive({
        if case .node(.client(.endpoint(.meshCore(.delegate(.adapterUnavailable))))) = $0 { return true }
        return false
    }, timeout: .seconds(20))
    #expect(failed.state.radioLight(.meshCore) == .problem)
}

/// A swap replacing an online slot will start the new one: Connecting. After a Disconnect the swap
/// leaves it stopped: Off.
@MainActor @Test func rlDuringASwap() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    radio.holdStops()
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.radioConnectTapped(.rnode))
    #expect(store.state.rnodeSwap != nil)
    #expect(store.state.radioLight(.rnode) == .connecting)
    await store.send(.disconnectTapped)
    #expect(store.state.radioLight(.rnode) == .off)
    radio.releaseStops()
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
}

/// A radio that won't dial is Off: no radio chosen, the Release gate, a missing MeshCore key.
@MainActor @Test func rlOffWhenTheRadioWontDial() async {
    #expect(meshRadioStore(radio: nil, harness: MeshRadioHarness()).state.radioLight(.meshtastic) == .off)
    let rnGated = rnRadioStore(radio: rnRadioIDA, radioHarness: RNodeRadioHarness()) { $0.rnodeAvailable = false }
    #expect(rnGated.state.radioLight(.rnode) == .off)
    let mcNoKey = mcRadioStore(radio: mcRadioIDA, radioHarness: MeshCoreRadioHarness(), keychain: InMemoryKeychain())
    #expect(mcNoKey.state.radioLight(.meshCore) == .off)
}

@Test func rlAccessibilityText() {
    #expect(RadioLight.off.accessibilityText == "Not connected")
    #expect(RadioLight.connecting.accessibilityText == "Connecting")
    #expect(RadioLight.connected.accessibilityText == "Connected")
    #expect(RadioLight.problem.accessibilityText == "Can’t connect")
}
