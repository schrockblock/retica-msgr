import Foundation
import ComposableArchitecture
import MeshCoreKit
import ReTiCAInterfaces
import ReTiCAMeshCoreLive

// The app's live MeshCore dependencies (spec 2026-11-07 §6 "App", lane D). The channel key enters
// only here, at `driver.start`: `resolvingSecrets` reads it from the key store into a local config
// copy that goes straight to the live adapter, so it never reaches reducer state, an action or a log.

extension MeshCoreDriver {
    /// What a start reports when the key store can't produce the key. Not a policy failure: the
    /// interface treats it as non-terminal, so a later foreground or Connect tries again.
    static let channelKeyUnreadable = "The channel key can't be read"

    /// `base`, with the channel key and the retired keys filled in from `keyStore` at each `start`.
    ///
    /// With no readable key, `start` never calls `base.start`: no radio connect, so the radio's
    /// queued messages are not drained by a handshake that could not set up our channel. It yields
    /// `.unavailable(.other(channelKeyUnreadable))` and finishes.
    ///
    /// On `.retiredChannelsCleared` it forgets exactly the retired keys THAT start carried, before
    /// forwarding the event: a key retired after the start is still on the radio, so it stays.
    ///
    /// `willForward` runs after that forget and before each event is yielded. It's a test hook (the
    /// app never passes one): a test reads the key store from it to prove the forget came first.
    static func resolvingSecrets(base: MeshCoreDriver, keyStore: MeshCoreKeyStore,
                                 willForward: @escaping @Sendable (MeshCoreDriverEvent) async -> Void = { _ in })
        -> MeshCoreDriver {
        MeshCoreDriver(
            start: { config in
                guard let secrets = keyStore.secrets() else {
                    return AsyncStream { continuation in
                        continuation.yield(.unavailable(.other(channelKeyUnreadable)))
                        continuation.finish()
                    }
                }
                var filled = config
                filled.channelSecret = secrets.current
                filled.retiredChannelSecrets = secrets.retired
                let upstream = base.start(filled)
                return AsyncStream { continuation in
                    let task = Task {
                        for await event in upstream {
                            if event == .retiredChannelsCleared {
                                keyStore.forgetRetired(secrets.retired)
                            }
                            await willForward(event)
                            continuation.yield(event)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            send: { await base.send($0) },
            removeChannel: { await base.removeChannel() },
            stop: { await base.stop() })
    }
}

/// The radio's name, firmware code and our channel slot, as the live driver last reported them
/// (nil when no radio is connected). Read by Diagnostics at `.radioOnline`.
private enum MeshCoreRadioDetailsKey: DependencyKey {
    static let liveValue: @Sendable () -> MeshCoreRadioDetails? = { nil }
    static let testValue: @Sendable () -> MeshCoreRadioDetails? = { nil }
}

extension DependencyValues {
    public var meshCoreRadioDetails: @Sendable () -> MeshCoreRadioDetails? {
        get { self[MeshCoreRadioDetailsKey.self] }
        set { self[MeshCoreRadioDetailsKey.self] = newValue }
    }
}

extension RadioScanner {
    /// The live MeshCore scanner: each MeshCoreKit `DiscoveredMeshCoreRadio` from `radios()` as a
    /// `RadioScanResult`, field for field. Finishes when the source does, and cancelling the
    /// consumer ends the source's scan.
    public static func meshCoreResults(
        _ radios: @escaping @Sendable () -> AsyncStream<DiscoveredMeshCoreRadio>
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

public enum MeshCoreLiveWiring {
    /// The radio-side app name the session sends in its handshake. Not UI copy.
    static let appName = "ReTiCAMsgr"

    /// What the live driver last reported for Diagnostics.
    private static let details = LockIsolated<MeshCoreRadioDetails?>(nil)

    /// The ONE app-owned session, built on first use (so no CoreBluetooth manager exists until a
    /// MeshCore slot starts) and kept for the process lifetime. Never dropped, so the "disconnect
    /// before dropping" rule holds by construction; every slot stop disconnects it.
    private static let session: MeshCoreSession = MeshCoreLive.makeSession(appName: appName)

    /// The ONE `.live` driver over that session.
    private static let driver: MeshCoreDriver = .live(session: session, details: { details.setValue($0) })

    /// `$0.meshCoreDriver`: the live driver, forwarding lazily, behind `resolvingSecrets` so the key
    /// is read from `keyStore` only at `driver.start`.
    public static func installDriver(into values: inout DependencyValues, keyStore: MeshCoreKeyStore) {
        let lazyDriver = MeshCoreDriver(
            start: { driver.start($0) },
            send: { await driver.send($0) },
            removeChannel: { await driver.removeChannel() },
            stop: { await driver.stop() })
        installDriver(into: &values, keyStore: keyStore, base: lazyDriver)
    }

    /// `installDriver(into:keyStore:)` over `base`, so a test can check that what's installed goes
    /// through `resolvingSecrets` without starting CoreBluetooth.
    static func installDriver(into values: inout DependencyValues, keyStore: MeshCoreKeyStore,
                              base: MeshCoreDriver) {
        values.meshCoreDriver = .resolvingSecrets(base: base, keyStore: keyStore)
    }

    /// `$0.meshCoreRadioDetails`: what the live driver last reported.
    public static func installDetails(into values: inout DependencyValues) {
        values.meshCoreRadioDetails = { details.value }
    }

    /// The MeshCore half of the radio picker scan: MeshCoreKit's scanner over FCB's live central.
    /// Sets only `scanMeshCore`, so the order against `MeshtasticLiveWiring.installScanner` can't matter.
    public static func installScanner(into values: inout DependencyValues) {
        installScanner(into: &values, source: { MeshCoreLive.scanRadios() })
    }

    /// `installScanner(into:)` over `source`, for tests that must not start CoreBluetooth.
    static func installScanner(into values: inout DependencyValues,
                               source: @escaping @Sendable () -> AsyncStream<DiscoveredMeshCoreRadio>) {
        values.radioScanner.scanMeshCore = RadioScanner.meshCoreResults(source)
    }
}
