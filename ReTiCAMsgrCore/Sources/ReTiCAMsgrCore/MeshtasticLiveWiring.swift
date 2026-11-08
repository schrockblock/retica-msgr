import ComposableArchitecture
import MeshtasticKit
import ReTiCAInterfaces
import ReTiCAMeshtasticLive

/// The app's live Meshtastic dependencies (spec 2026-10-16 §7 lane E, Contract 2).
public enum MeshtasticLiveWiring {
    /// The ONE app-owned session's driver, built on first use (so no CoreBluetooth manager exists
    /// until a radio slot starts) and kept for the process lifetime. Never dropped, so the
    /// "disconnect before dropping" rule holds by construction; every slot stop disconnects it.
    private static let driver: MeshtasticDriver = .live(session: MeshtasticLive.makeSession())

    /// `$0.meshtasticDriver = .live(session:)` over the app-owned session, forwarding lazily.
    public static func installDriver(into values: inout DependencyValues) {
        values.meshtasticDriver = MeshtasticDriver(
            start: { driver.start($0) },
            send: { await driver.send($0) },
            stop: { await driver.stop() })
    }

    /// The live radio picker scan: MeshtasticKit's scanner over FCB's live central, finishing only
    /// when scanning stopped for good (`MeshtasticLive.scanRadios()`). Gated on lane F: FCB has
    /// one scan per process, and before lane F a BLE stop could end it. Sets only `scan`, so the
    /// order against `MeshCoreLiveWiring.installScanner` can't matter.
    public static func installScanner(into values: inout DependencyValues) {
        installScanner(into: &values, source: { MeshtasticLive.scanRadios() })
    }

    /// `installScanner(into:)` over `source`, for tests that must not start CoreBluetooth.
    static func installScanner(into values: inout DependencyValues,
                               source: @escaping @Sendable () -> AsyncStream<DiscoveredRadio>) {
        values.radioScanner.scan = RadioScanner.meshtastic(source).scan
    }
}
