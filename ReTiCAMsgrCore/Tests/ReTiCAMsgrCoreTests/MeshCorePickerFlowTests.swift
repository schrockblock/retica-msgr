import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCAMsgrCore

// The MeshCore radio picker flow (lane C, task 5): choosing a radio, the BLE pause around the
// picker, and where a pick is stored. Mirrors the Meshtastic flow in `MeshtasticSettingsTests`.

// MARK: - Helpers

/// A BLE slot as a Connect with `bleEnabled` on builds it, with its interface in `status`.
private func mcWithBLE(_ state: inout AppFeature.State, _ status: BLEInterfaceStatus) {
    state.$bleEnabled.withLock { $0 = true }
    var ble = BLEEndpoint.State(localIdentity: state.identity.hash)
    ble.ble.status = status
    state.node.client.endpoint.ble = ble
}

private func mcIsBLEStop(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.ble(.ble(.stop))))) = action { return true }
    return false
}

private func mcIsBLEStart(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.ble(.ble(.start))))) = action { return true }
    return false
}

private func mcIsPickerDismiss(_ action: AppFeature.Action) -> Bool {
    if case .radioPicker(.dismiss) = action { return true }
    return false
}

private func mcIsPickerSelection(_ action: AppFeature.Action) -> Bool {
    if case .radioPicker(.presented(.delegate(.selected))) = action { return true }
    return false
}

private let mcMeshtasticRadio = RadioScanResult(
    id: UUID(uuidString: "A1A1A1A1-0000-4000-8000-0000000000A1")!, name: "Meshtastic Radio", rssi: -61)

/// A MeshCore radio named "Alpha", for the stored-name assertion.
private let mcAlpha = RadioScanResult(id: mcRadioA.id, name: "Alpha", rssi: -58)

// MARK: - Tests

@MainActor @Test func mcFlowChooseOpensAMeshCorePicker() async {
    let store = mcStore()
    await store.send(.chooseMeshCoreRadioTapped)
    #expect(store.state.radioPicker?.kind == .meshCore)
}

@MainActor @Test func mcFlowChooseStartsOnTheStoredRadio() async {
    let store = mcStore { $0.$meshCoreRadioID.withLock { $0 = mcRadioA.id.uuidString } }
    await store.send(.chooseMeshCoreRadioTapped)
    #expect(store.state.radioPicker?.selectedID == mcRadioA.id)
}

@MainActor @Test func mcFlowChooseWhileAMeshtasticPickerIsOpenChangesNothing() async {
    let store = mcStore()
    await store.send(.chooseRadioTapped)
    await store.send(.chooseMeshCoreRadioTapped)
    #expect(store.state.radioPicker?.kind == .meshtastic)
}

@MainActor @Test func mcFlowPausesRunningBLE() async {
    let store = mcStore { mcWithBLE(&$0, .online) }
    await store.send(.chooseMeshCoreRadioTapped)
    await store.receive(mcIsBLEStop)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
    #expect(store.state.blePausedForRadioScan)
}

@MainActor @Test(arguments: PickerExit.allCases)
func mcFlowEveryExitResumesPausedBLE(_ exit: PickerExit) async {
    let store = mcStore { mcWithBLE(&$0, .online) }
    await store.send(.chooseMeshCoreRadioTapped)
    await store.receive(mcIsBLEStop)
    switch exit {
    case .swipe:
        await store.send(.radioPicker(.dismiss))
    case .cancel:
        await store.send(.radioPicker(.presented(.cancelTapped)))
        await store.receive(mcIsPickerDismiss)
    case .pick:
        await store.send(.radioPicker(.presented(.radioFound(mcRadioA))))
        await store.send(.radioPicker(.presented(.radioTapped(mcRadioA.id))))
        await store.receive(mcIsPickerDismiss)
    }
    await store.receive(mcIsBLEStart)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .starting)
    #expect(!store.state.blePausedForRadioScan)
}

@MainActor @Test func mcFlowLeavesStoppedBLEStopped() async {
    let store = mcStore { mcWithBLE(&$0, .stopped) }
    await store.send(.chooseMeshCoreRadioTapped)
    #expect(!store.state.blePausedForRadioScan)
    await store.send(.radioPicker(.dismiss))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
}

@MainActor @Test func mcFlowWithoutBLESlotSendsNoBLEAction() async {
    let store = mcStore { $0.$bleEnabled.withLock { $0 = true } }
    await store.send(.chooseMeshCoreRadioTapped)
    await store.skipReceivedActions(strict: false)
    #expect(!store.state.blePausedForRadioScan)
    await store.send(.radioPicker(.dismiss))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble == nil)
}

@MainActor @Test func mcFlowPickStoresTheRadioID() async {
    let defaults = UserDefaults.inMemory
    let store = mcStore(defaults: defaults)
    await store.send(.chooseMeshCoreRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(mcAlpha))))
    await store.send(.radioPicker(.presented(.radioTapped(mcAlpha.id))))
    await store.receive(mcIsPickerSelection)
    #expect(defaults.string(forKey: "meshCoreRadioID") == mcAlpha.id.uuidString)
}

@MainActor @Test func mcFlowPickStoresTheRadioName() async {
    let defaults = UserDefaults.inMemory
    let store = mcStore(defaults: defaults)
    await store.send(.chooseMeshCoreRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(mcAlpha))))
    await store.send(.radioPicker(.presented(.radioTapped(mcAlpha.id))))
    await store.receive(mcIsPickerSelection)
    #expect(defaults.string(forKey: "meshCoreRadioName") == "Alpha")
}

@MainActor @Test func mcFlowPickLeavesTheMeshtasticRadioAlone() async {
    let defaults = UserDefaults.inMemory
    defaults.set(mcMeshtasticRadio.id.uuidString, forKey: "meshtasticRadioID")
    defaults.set("Meshtastic Radio", forKey: "meshtasticRadioName")
    let store = mcStore(defaults: defaults)
    await store.send(.chooseMeshCoreRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(mcAlpha))))
    await store.send(.radioPicker(.presented(.radioTapped(mcAlpha.id))))
    await store.receive(mcIsPickerSelection)
    #expect(defaults.string(forKey: "meshtasticRadioID") == mcMeshtasticRadio.id.uuidString)
    #expect(defaults.string(forKey: "meshtasticRadioName") == "Meshtastic Radio")
}

@MainActor @Test func mcFlowMeshtasticPickLeavesTheMeshCoreRadioAlone() async {
    let defaults = UserDefaults.inMemory
    defaults.set(mcRadioA.id.uuidString, forKey: "meshCoreRadioID")
    defaults.set("MeshCore-1a2b", forKey: "meshCoreRadioName")
    let store = mcStore(defaults: defaults)
    await store.send(.chooseRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(mcMeshtasticRadio))))
    await store.send(.radioPicker(.presented(.radioTapped(mcMeshtasticRadio.id))))
    await store.receive(mcIsPickerSelection)
    #expect(defaults.string(forKey: "meshCoreRadioID") == mcRadioA.id.uuidString)
    #expect(defaults.string(forKey: "meshCoreRadioName") == "MeshCore-1a2b")
    #expect(defaults.string(forKey: "meshtasticRadioID") == mcMeshtasticRadio.id.uuidString)
    #expect(defaults.string(forKey: "meshtasticRadioName") == "Meshtastic Radio")
}

@MainActor @Test func mcFlowPickClosesThePicker() async {
    let store = mcStore()
    await store.send(.chooseMeshCoreRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(mcRadioA))))
    await store.send(.radioPicker(.presented(.radioTapped(mcRadioA.id))))
    await store.receive(mcIsPickerDismiss)
    #expect(store.state.radioPicker == nil)
}

@MainActor @Test func mcFlowUsesTheMeshCoreScanner() async {
    let meshtasticScans = LockIsolated(0)
    let meshCoreScans = LockIsolated(0)
    let scanner = RadioScanner(
        scan: {
            meshtasticScans.withValue { $0 += 1 }
            return AsyncStream { _ in }
        },
        scanMeshCore: {
            meshCoreScans.withValue { $0 += 1 }
            return AsyncStream { _ in }
        })
    let store = mcStore(scanner: scanner)
    await store.send(.chooseMeshCoreRadioTapped)
    await store.send(.radioPicker(.presented(.onAppear)))
    #expect(await waitUntil { meshCoreScans.value == 1 })
    #expect(meshCoreScans.value == 1)
    #expect(meshtasticScans.value == 0)
    await store.send(.radioPicker(.dismiss))
}

@MainActor @Test func mcFlowDismissStopsTheScan() async {
    let started = LockIsolated(false)
    let terminated = LockIsolated(false)
    let scanner = RadioScanner(
        scan: { AsyncStream { _ in } },
        scanMeshCore: {
            started.setValue(true)
            return AsyncStream { continuation in
                continuation.onTermination = { _ in terminated.setValue(true) }
            }
        })
    let store = mcStore(scanner: scanner)
    await store.send(.chooseMeshCoreRadioTapped)
    await store.send(.radioPicker(.presented(.onAppear)))
    // Precondition: the scan really started, so termination below is the dismiss's doing.
    #expect(await waitUntil { started.value })
    #expect(!terminated.value)
    await store.send(.radioPicker(.dismiss))
    #expect(await waitUntil { terminated.value })
}

/// The picker holds BLE paused; a foreground wake must not restart it under the scan.
@MainActor @Test func mcFlowForegroundWhileOpenKeepsBLEPaused() async {
    let store = mcStore { mcWithBLE(&$0, .online) }
    await store.send(.chooseMeshCoreRadioTapped)
    await store.receive(mcIsBLEStop)
    await store.send(.foregrounded)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
    await store.send(.radioPicker(.dismiss))
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func mcFlowGateOffOpensNothing() async {
    let store = mcStore { state in
        state.meshCoreAvailable = false
        mcWithBLE(&state, .online)
    }
    await store.send(.chooseMeshCoreRadioTapped)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.radioPicker == nil)
    #expect(!store.state.blePausedForRadioScan)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .online)
}

/// A swipe dismiss can land between the child's delegate send and its dismiss, so the parent can see
/// `.selected` with no picker. It has no kind to store under, so it stores nothing.
@MainActor @Test func mcFlowPickWithNoPickerOpenStoresNothing() async {
    let defaults = UserDefaults.inMemory
    let store = mcStore(defaults: defaults)
    #expect(store.state.radioPicker == nil)
    // TCA may report the delegate as an ifLet action sent with no presented state.
    await withKnownIssue(isIntermittent: true) {
        await store.send(.radioPicker(.presented(.delegate(.selected(mcAlpha)))))
    }
    #expect(defaults.string(forKey: "meshtasticRadioID") == nil)
    #expect(defaults.string(forKey: "meshtasticRadioName") == nil)
    #expect(defaults.string(forKey: "meshCoreRadioID") == nil)
    #expect(defaults.string(forKey: "meshCoreRadioName") == nil)
}
