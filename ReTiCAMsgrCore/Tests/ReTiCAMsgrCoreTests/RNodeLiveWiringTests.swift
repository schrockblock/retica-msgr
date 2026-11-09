import Testing
import Foundation
import ComposableArchitecture
import MeshCoreKit
import MeshtasticKit
import ReTiCAInterfaces
import RNodeKit
@testable import ReTiCAMsgrCore

private let rnScanID = UUID(uuidString: "5CA40000-0000-4000-8000-0000000000E1")!
private let rnMeshtasticScanID = UUID(uuidString: "5CA40000-0000-4000-8000-0000000000E2")!
private let rnMeshCoreScanID = UUID(uuidString: "5CA40000-0000-4000-8000-0000000000E3")!

/// `meshWaitUntil` with room for a whole-package run: there, the forwarding tasks can wait seconds
/// for a thread. It returns as soon as `condition` holds, so only a failing check pays the timeout.
private func rnWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

@MainActor @Test func rnLiveScanMapsEachRadio() async {
    let upstream = AsyncStream<DiscoveredRNode>.makeStream()
    let scan = RadioScanner.rnodeResults { upstream.stream }
    let seen = LockIsolated<[RadioScanResult]>([])
    let consumer = Task { for await result in scan() { seen.withValue { $0.append(result) } } }
    upstream.continuation.yield(DiscoveredRNode(id: rnScanID, name: "RNode 1A2B", rssi: -44))
    upstream.continuation.yield(DiscoveredRNode(id: rnRadioIDB, name: nil, rssi: -90))
    #expect(await rnWait { seen.value.count == 2 })
    #expect(seen.value == [RadioScanResult(id: rnScanID, name: "RNode 1A2B", rssi: -44),
                           RadioScanResult(id: rnRadioIDB, name: nil, rssi: -90)])
    consumer.cancel()
}

@MainActor @Test func rnLiveScanFinishesWhenTheSourceFinishes() async {
    let upstream = AsyncStream<DiscoveredRNode>.makeStream()
    let scan = RadioScanner.rnodeResults { upstream.stream }
    let finished = LockIsolated(false)
    let consumer = Task {
        for await _ in scan() {}
        finished.setValue(true)
    }
    upstream.continuation.finish()
    #expect(await rnWait { finished.value })
    consumer.cancel()
}

@MainActor @Test func rnLiveScanCancellingEndsTheSource() async {
    let ended = LockIsolated(false)
    let scan = RadioScanner.rnodeResults {
        AsyncStream { continuation in continuation.onTermination = { _ in ended.setValue(true) } }
    }
    let stream = scan()
    let consumer = Task { for await _ in stream {} }
    consumer.cancel()
    #expect(await rnWait { ended.value })
}

/// Each `installScanner` sets only its own third of `radioScanner`, in all six orders. Every
/// installer takes a source here, so no CoreBluetooth starts.
@MainActor @Test(arguments: [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]])
func rnLiveScanInstallsDoNotOverwriteEachOther(order: [Int]) async {
    let meshtasticSource: @Sendable () -> AsyncStream<DiscoveredRadio> = {
        AsyncStream { $0.yield(DiscoveredRadio(id: rnMeshtasticScanID, name: "Mesh", rssi: -50)) }
    }
    let meshCoreSource: @Sendable () -> AsyncStream<DiscoveredMeshCoreRadio> = {
        AsyncStream { $0.yield(DiscoveredMeshCoreRadio(id: rnMeshCoreScanID, name: "Core", rssi: -60)) }
    }
    let rnodeSource: @Sendable () -> AsyncStream<DiscoveredRNode> = {
        AsyncStream { $0.yield(DiscoveredRNode(id: rnScanID, name: "RNode", rssi: -70)) }
    }
    var values = DependencyValues()
    values.radioScanner = RadioScanner(scan: { AsyncStream { $0.finish() } },
                                       scanMeshCore: { AsyncStream { $0.finish() } },
                                       scanRNode: { AsyncStream { $0.finish() } })
    for step in order {
        switch step {
        case 0: MeshtasticLiveWiring.installScanner(into: &values, source: meshtasticSource)
        case 1: MeshCoreLiveWiring.installScanner(into: &values, source: meshCoreSource)
        default: RNodeLiveWiring.installScanner(into: &values, source: rnodeSource)
        }
    }
    let scanner = values.radioScanner
    let seen = LockIsolated<[RadioScanResult]>([])
    let consumers = [RadioKind.meshtastic, .meshCore, .rnode].map { kind in
        Task { for await result in scanner.stream(for: kind) { seen.withValue { $0.append(result) } } }
    }
    #expect(await rnWait { seen.value.count == 3 })
    #expect(Set(seen.value.map(\.id)) == [rnMeshtasticScanID, rnMeshCoreScanID, rnScanID])
    for consumer in consumers { consumer.cancel() }
}
