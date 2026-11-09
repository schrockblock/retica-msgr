import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAMsgrCore

// MARK: - Radio picker, RNode kind (T1)

/// A picker store whose dismiss only records that it ran.
@MainActor
private func rnPickerStore(kind: RadioKind, scanner: RadioScanner) -> TestStoreOf<RadioPickerFeature> {
    let store = TestStore(initialState: RadioPickerFeature.State(kind: kind)) {
        RadioPickerFeature()
    } withDependencies: {
        $0.radioScanner = scanner
        $0.dismiss = DismissEffect { }
    }
    store.exhaustivity = .off
    return store
}

/// A scanner whose three closures count their calls and stay open.
private func rnCountingScanner(meshtastic: LockIsolated<Int>, meshCore: LockIsolated<Int>,
                               rnode: LockIsolated<Int>) -> RadioScanner {
    RadioScanner(
        scan: {
            meshtastic.withValue { $0 += 1 }
            return AsyncStream { _ in }
        },
        scanMeshCore: {
            meshCore.withValue { $0 += 1 }
            return AsyncStream { _ in }
        },
        scanRNode: {
            rnode.withValue { $0 += 1 }
            return AsyncStream { _ in }
        })
}

@MainActor @Test func rnPickerRNodeScanUsesScanRNode() async {
    let meshtasticScans = LockIsolated(0)
    let meshCoreScans = LockIsolated(0)
    let rnodeScans = LockIsolated(0)
    let store = rnPickerStore(
        kind: .rnode,
        scanner: rnCountingScanner(meshtastic: meshtasticScans, meshCore: meshCoreScans, rnode: rnodeScans))
    await store.send(.onAppear)
    #expect(await waitUntil { rnodeScans.value == 1 })
    #expect(rnodeScans.value == 1)
    #expect(meshCoreScans.value == 0)
    #expect(meshtasticScans.value == 0)
    await store.send(.cancelTapped)
}

/// Asserts only the action, like `mcPickerUninstalledMeshCoreScannerEndsTheScan`.
@MainActor @Test func rnPickerUninstalledRNodeScannerEndsTheScan() async {
    let store = rnPickerStore(kind: .rnode, scanner: RadioScanner.liveValue)
    await store.send(.onAppear)
    await store.receive { if case .scanFinished = $0 { return true }; return false }
}

@Test func rnPickerRNodeMessagesNameRNodes() {
    #expect(RadioPickerFeature.State(kind: .rnode).scanningMessage
            == "Scanning for RNodes… Only RNodes with Bluetooth LE appear. Make sure the radio is on, its "
            + "Bluetooth is on, and it isn't connected to another app.")
    #expect(RadioPickerFeature.State(kind: .rnode).scanEndedEmptyMessage
            == "Scanning stopped before any radio was found. RNode support may not be installed in this "
            + "build, or Bluetooth may be off or not allowed.")
}
