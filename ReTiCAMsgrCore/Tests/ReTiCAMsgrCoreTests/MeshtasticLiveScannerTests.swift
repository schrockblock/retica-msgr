import Testing
import Foundation
import ComposableArchitecture
import MeshtasticKit
@testable import ReTiCAMsgrCore

private let liveScanID = UUID(uuidString: "5CA40000-0000-4000-8000-0000000000AA")!

@MainActor @Test func meshLiveScanMapsEachRadio() async {
    let upstream = AsyncStream<DiscoveredRadio>.makeStream()
    let scanner = RadioScanner.meshtastic { upstream.stream }
    let seen = LockIsolated<[RadioScanResult]>([])
    let consumer = Task { for await result in scanner.scan() { seen.withValue { $0.append(result) } } }
    upstream.continuation.yield(DiscoveredRadio(id: liveScanID, name: "Alpha", rssi: -40))
    #expect(await meshWaitUntil { seen.value.count == 1 })
    #expect(seen.value == [RadioScanResult(id: liveScanID, name: "Alpha", rssi: -40)])
    consumer.cancel()
}

@MainActor @Test func meshLiveScanFinishesWhenTheSourceFinishes() async {
    let upstream = AsyncStream<DiscoveredRadio>.makeStream()
    let scanner = RadioScanner.meshtastic { upstream.stream }
    let finished = LockIsolated(false)
    let consumer = Task {
        for await _ in scanner.scan() {}
        finished.setValue(true)
    }
    upstream.continuation.finish()
    #expect(await meshWaitUntil { finished.value })
    consumer.cancel()
}

@MainActor @Test func meshLiveScanCancellingEndsTheSource() async {
    let ended = LockIsolated(false)
    let scanner = RadioScanner.meshtastic {
        AsyncStream { continuation in continuation.onTermination = { _ in ended.setValue(true) } }
    }
    let consumer = Task { for await _ in scanner.scan() {} }
    try? await Task.sleep(for: .milliseconds(50))
    consumer.cancel()
    #expect(await meshWaitUntil { ended.value })
}
