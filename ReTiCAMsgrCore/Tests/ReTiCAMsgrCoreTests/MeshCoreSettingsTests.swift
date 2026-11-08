import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAMsgrCore

// MARK: - Radio picker kind (T1)

/// A picker store whose dismiss only records that it ran.
@MainActor
private func mcPickerStore(kind: RadioKind, scanner: RadioScanner) -> TestStoreOf<RadioPickerFeature> {
    let store = TestStore(initialState: RadioPickerFeature.State(kind: kind)) {
        RadioPickerFeature()
    } withDependencies: {
        $0.radioScanner = scanner
        $0.dismiss = DismissEffect { }
    }
    store.exhaustivity = .off
    return store
}

/// A scanner whose two closures count their calls and stay open.
private func mcCountingScanner(meshtastic: LockIsolated<Int>, meshCore: LockIsolated<Int>) -> RadioScanner {
    RadioScanner(
        scan: {
            meshtastic.withValue { $0 += 1 }
            return AsyncStream { _ in }
        },
        scanMeshCore: {
            meshCore.withValue { $0 += 1 }
            return AsyncStream { _ in }
        })
}

@Test func mcPickerDefaultsToMeshtastic() {
    #expect(RadioPickerFeature.State().kind == .meshtastic)
}

@MainActor @Test func mcPickerMeshCoreScanUsesScanMeshCore() async {
    let meshtasticScans = LockIsolated(0)
    let meshCoreScans = LockIsolated(0)
    let store = mcPickerStore(
        kind: .meshCore, scanner: mcCountingScanner(meshtastic: meshtasticScans, meshCore: meshCoreScans))
    await store.send(.onAppear)
    #expect(await waitUntil { meshCoreScans.value == 1 })
    #expect(meshCoreScans.value == 1)
    #expect(meshtasticScans.value == 0)
    await store.send(.cancelTapped)
}

@MainActor @Test func mcPickerMeshtasticScanUsesScan() async {
    let meshtasticScans = LockIsolated(0)
    let meshCoreScans = LockIsolated(0)
    let store = mcPickerStore(
        kind: .meshtastic, scanner: mcCountingScanner(meshtastic: meshtasticScans, meshCore: meshCoreScans))
    await store.send(.onAppear)
    #expect(await waitUntil { meshtasticScans.value == 1 })
    #expect(meshtasticScans.value == 1)
    #expect(meshCoreScans.value == 0)
    await store.send(.cancelTapped)
}

/// Asserts only the action, like `radioPickerUninstalledLiveScannerEndsTheScan`.
@MainActor @Test func mcPickerUninstalledMeshCoreScannerEndsTheScan() async {
    let store = mcPickerStore(kind: .meshCore, scanner: RadioScanner.liveValue)
    await store.send(.onAppear)
    await store.receive { if case .scanFinished = $0 { return true }; return false }
}

@Test func mcPickerMeshCoreMessagesNameMeshCore() {
    #expect(RadioPickerFeature.State(kind: .meshCore).scanningMessage
            == "Scanning for MeshCore radios… Make sure the radio is on and not connected to another app.")
    #expect(RadioPickerFeature.State(kind: .meshCore).scanEndedEmptyMessage
            == "Scanning stopped before any radio was found. MeshCore support may not be installed in this "
            + "build, or Bluetooth may be off or not allowed.")
}

@Test func mcPickerMeshtasticMessagesAreUnchanged() {
    #expect(RadioPickerFeature.State().scanningMessage
            == "Scanning for Meshtastic radios… Make sure the radio is on and not connected to another app.")
    #expect(RadioPickerFeature.State().scanEndedEmptyMessage == RadioPickerFeature.scanEndedEmptyMessage)
}
