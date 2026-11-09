import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCARNodeLive
import RNodeKit

// The app's live RNode dependencies (spec 2026-11-08 §6 "App", lane D). Nothing here touches
// CoreBluetooth until a slot starts or the picker scans.

extension RadioScanner {
    /// The live RNode scanner: each RNodeKit `DiscoveredRNode` from `radios()` as a
    /// `RadioScanResult`, field for field. Finishes when the source does, and cancelling the
    /// consumer ends the source's scan.
    public static func rnodeResults(
        _ radios: @escaping @Sendable () -> AsyncStream<DiscoveredRNode>
    ) -> @Sendable () -> AsyncStream<RadioScanResult> {
        {
            let upstream = radios()
            return AsyncStream { continuation in
                let task = Task {
                    for await radio in upstream {
                        continuation.yield(RadioScanResult(id: radio.id, name: radio.name, rssi: radio.rssi))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

public enum RNodeLiveWiring {
    /// The ONE app-owned session, built on first use (so no CoreBluetooth manager exists until an
    /// RNode slot starts) and kept for the process lifetime. Never dropped, so the "disconnect
    /// before dropping" rule holds by construction; every slot stop disconnects it.
    private static let session: RNodeSession = RNodeLive.makeSession()

    /// The ONE `.live` driver over that session.
    private static let driver: RNodeDriver = .live(session: session)

    /// `$0.rnodeDriver`: the live driver, forwarding lazily so the session is built at the first
    /// call, not at install.
    public static func installDriver(into values: inout DependencyValues) {
        values.rnodeDriver = RNodeDriver(
            start: { driver.start($0) },
            send: { await driver.send($0) },
            stop: { await driver.stop() })
    }

    /// The RNode half of the radio picker scan: RNodeKit's scanner over FCB's live central.
    /// Sets only `scanRNode`, so the order against the other installers can't matter.
    public static func installScanner(into values: inout DependencyValues) {
        installScanner(into: &values, source: { RNodeLive.scanRadios() })
    }

    /// `installScanner(into:)` over `source`, for tests that must not start CoreBluetooth.
    static func installScanner(into values: inout DependencyValues,
                               source: @escaping @Sendable () -> AsyncStream<DiscoveredRNode>) {
        values.radioScanner.scanRNode = RadioScanner.rnodeResults(source)
    }
}
