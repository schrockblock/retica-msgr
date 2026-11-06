import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
@testable import ReTiCAMsgrCore

@MainActor @Test func meshRedialForegroundRestartsAStoppedRadio() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    await store.send(.disconnectTapped)
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await store.send(.foregrounded)
    await radio.waitForStarts(2)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioA)])
}

@MainActor @Test func meshRedialForegroundLeavesAnOnlineRadioAlone() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    await store.send(.foregrounded)
    await Task.megaYield()
    await store.skipReceivedActions(strict: false)
    #expect(radio.calls.value == [.start(meshSlotRadioA)])
    #expect(store.state.node.client.endpoint.interfaces[meshSlotIDA] != nil)
}

/// `redialDownNodes` returns early when every TCP node is up; the radio restart must not be skipped.
@MainActor @Test func meshRedialForegroundRestartsAnUnavailableRadioEvenWhenEveryNodeIsUp() async {
    let radio = MeshRadioHarness()
    let tcp = MeshTCPHarness()
    let node = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio, tcp: tcp) { state in
        state.$nodes.withLock { $0 = [node] }
    }
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, node.interfaceID) }, timeout: .seconds(2))
    await radio.waitForStarts(1)
    radio.yieldToLatest(.unavailable(.poweredOff))
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.delegate(.adapterUnavailable))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    await store.send(.foregrounded)
    await radio.waitForStarts(2)
    #expect(radio.startCount == 2, "calls: \(radio.calls.value)")
}

/// Review Focus 5: a foreground during a swap must not `.start` the slot being replaced.
@MainActor @Test func meshRedialNeverRestartsTheSlotASwapIsReplacing() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.foregrounded)
    await store.send(.foregrounded)
    await Task.megaYield()
    #expect(radio.calls.value == [.start(meshSlotRadioA)])
    radio.releaseStops()
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await radio.waitForStarts(2)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioB)])
}

/// Lane D's note: Connect while the picker is open would `.start` the BLE the picker paused,
/// taking FCB's one scan from the picker.
@MainActor @Test func meshRedialConnectWhileThePickerIsOpenLeavesPausedBLEStopped() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: nil, harness: radio) { state in
        state.$bleEnabled.withLock { $0 = true }
        var ble = BLEEndpoint.State(localIdentity: state.identity.hash)
        ble.ble.status = .online
        state.node.client.endpoint.ble = ble
    }
    await store.send(.chooseRadioTapped)
    await store.receive { if case .node(.client(.endpoint(.ble(.ble(.stop))))) = $0 { return true }; return false }
    await store.send(.connectTapped)
    await Task.megaYield()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
    #expect(store.state.blePausedForRadioScan)
}

/// A swap finishing after Disconnect installs the new radio stopped, and `connection` stays
/// Disconnected rather than showing Connecting… for a radio that is not dialing.
@MainActor @Test func meshRedialDisconnectDuringASwapLeavesTheNewRadioStopped() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.foregrounded)
    await store.send(.disconnectTapped)
    radio.releaseStops()
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    try? await Task.sleep(for: .milliseconds(100))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioB)
    #expect(store.state.node.client.endpoint.meshtastic?.interface.status == .stopped)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop])
    #expect(store.state.connection == .disconnected, "a swap finishing after Disconnect must not show Connecting…")
}
