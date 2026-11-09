import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCAMsgrCore

// The RNode radio picker flow (lane C, task 3): choosing a radio, the BLE pause around the picker
// (the shared path, proven for `.rnode`), and where a pick is stored. RNode and MeshCore share a
// service UUID, so the key separation is the point.

// MARK: - Helpers

private func rnWithBLE(_ state: inout AppFeature.State, _ status: BLEInterfaceStatus) {
    state.$bleEnabled.withLock { $0 = true }
    var ble = BLEEndpoint.State(localIdentity: state.identity.hash)
    ble.ble.status = status
    state.node.client.endpoint.ble = ble
}

private func rnIsBLEStop(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.ble(.ble(.stop))))) = action { return true }
    return false
}

private func rnIsBLEStart(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.ble(.ble(.start))))) = action { return true }
    return false
}

private func rnIsPickerDismiss(_ action: AppFeature.Action) -> Bool {
    if case .radioPicker(.dismiss) = action { return true }
    return false
}

private func rnIsPickerSelection(_ action: AppFeature.Action) -> Bool {
    if case .radioPicker(.presented(.delegate(.selected))) = action { return true }
    return false
}

private let rnMeshtasticRadio = RadioScanResult(
    id: UUID(uuidString: "A1A1A1A1-0000-4000-8000-0000000000A1")!, name: "Meshtastic Radio", rssi: -61)

private let rnMeshCoreRadio = RadioScanResult(
    id: UUID(uuidString: "C1C1C1C1-0000-4000-8000-0000000000C1")!, name: "MeshCore-1a2b", rssi: -58)

// MARK: - Tests

@MainActor @Test func rnFlowChooseOpensTheRNodePicker() async {
    let store = rnStore { $0.$rnodeRadioID.withLock { $0 = rnRadioA.id.uuidString } }
    await store.send(.chooseRNodeRadioTapped)
    #expect(store.state.radioPicker?.kind == .rnode)
    #expect(store.state.radioPicker?.selectedID == rnRadioA.id)
}

@MainActor @Test func rnFlowChooseDoesNothingWithTheGateOff() async {
    let store = rnStore { $0.rnodeAvailable = false }
    await store.send(.chooseRNodeRadioTapped)
    #expect(store.state.radioPicker == nil)
}

@MainActor @Test func rnFlowPickStoresTheRNode() async {
    let defaults = UserDefaults.inMemory
    let store = rnStore(defaults: defaults)
    await store.send(.chooseRNodeRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(rnRadioA))))
    await store.send(.radioPicker(.presented(.radioTapped(rnRadioA.id))))
    await store.receive(rnIsPickerSelection)
    #expect(defaults.string(forKey: "rnodeRadioID") == rnRadioA.id.uuidString)
    #expect(defaults.string(forKey: "rnodeRadioName") == "RNode 1A2B")
}

@MainActor @Test func rnFlowPickLeavesTheMeshCoreRadioAlone() async {
    let defaults = UserDefaults.inMemory
    defaults.set(rnMeshCoreRadio.id.uuidString, forKey: "meshCoreRadioID")
    defaults.set("MeshCore-1a2b", forKey: "meshCoreRadioName")
    let store = rnStore(defaults: defaults)
    await store.send(.chooseRNodeRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(rnRadioA))))
    await store.send(.radioPicker(.presented(.radioTapped(rnRadioA.id))))
    await store.receive(rnIsPickerSelection)
    #expect(defaults.string(forKey: "meshCoreRadioID") == rnMeshCoreRadio.id.uuidString)
    #expect(defaults.string(forKey: "meshCoreRadioName") == "MeshCore-1a2b")
}

@MainActor @Test func rnFlowMeshCorePickLeavesTheRNodeAlone() async {
    let defaults = UserDefaults.inMemory
    defaults.set(rnRadioA.id.uuidString, forKey: "rnodeRadioID")
    defaults.set("RNode 1A2B", forKey: "rnodeRadioName")
    let store = rnStore(defaults: defaults)
    await store.send(.chooseMeshCoreRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(rnMeshCoreRadio))))
    await store.send(.radioPicker(.presented(.radioTapped(rnMeshCoreRadio.id))))
    await store.receive(rnIsPickerSelection)
    #expect(defaults.string(forKey: "meshCoreRadioID") == rnMeshCoreRadio.id.uuidString)
    #expect(defaults.string(forKey: "rnodeRadioID") == rnRadioA.id.uuidString)
    #expect(defaults.string(forKey: "rnodeRadioName") == "RNode 1A2B")
}

@MainActor @Test func rnFlowPickLeavesTheMeshtasticRadioAlone() async {
    let defaults = UserDefaults.inMemory
    defaults.set(rnMeshtasticRadio.id.uuidString, forKey: "meshtasticRadioID")
    defaults.set("Meshtastic Radio", forKey: "meshtasticRadioName")
    let store = rnStore(defaults: defaults)
    await store.send(.chooseRNodeRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(rnRadioA))))
    await store.send(.radioPicker(.presented(.radioTapped(rnRadioA.id))))
    await store.receive(rnIsPickerSelection)
    #expect(defaults.string(forKey: "meshtasticRadioID") == rnMeshtasticRadio.id.uuidString)
    #expect(defaults.string(forKey: "meshtasticRadioName") == "Meshtastic Radio")
}

@MainActor @Test func rnFlowChoosePausesARunningBLE() async {
    let store = rnStore { rnWithBLE(&$0, .online) }
    await store.send(.chooseRNodeRadioTapped)
    await store.receive(rnIsBLEStop)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
    #expect(store.state.blePausedForRadioScan)
}

@MainActor @Test func rnFlowDismissResumesBLE() async {
    let store = rnStore { rnWithBLE(&$0, .online) }
    await store.send(.chooseRNodeRadioTapped)
    await store.receive(rnIsBLEStop)
    await store.send(.radioPicker(.dismiss))
    await store.receive(rnIsBLEStart)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .starting)
    #expect(!store.state.blePausedForRadioScan)
}
