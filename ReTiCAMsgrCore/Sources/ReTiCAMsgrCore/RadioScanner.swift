import Foundation
import ComposableArchitecture
import MeshtasticKit

/// One Meshtastic radio heard advertising during a scan (spec 2026-10-16 §7 lane D). Mirrors
/// MeshtasticKit's `DiscoveredRadio` (spec Contract 1) field for field, so lane E's live value is
/// a plain map. `id` is the CoreBluetooth peripheral UUID, the value `meshtasticRadioID` stores.
///
/// `name` is the radio's advertised Bluetooth name: UNAUTHENTICATED text from the air. Show it
/// through `displayName`, and never put it in a diagnostics reason (rows are escaped, reasons
/// are not).
public struct RadioScanResult: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String?
    public var rssi: Int

    public init(id: UUID, name: String?, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }

    /// The advertised name trimmed, or "Unnamed radio" when it is missing or blank.
    public var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unnamed radio" : trimmed
    }
}

/// Scanning for Meshtastic radios over Bluetooth.
///
/// `scan` reports each radio again on every advertisement, with a fresh `rssi`. The stream
/// FINISHES only when scanning has stopped for good (no scanner installed, adapter gone).
/// Cancelling the consuming task stops the scan. FCB runs one scan per process (spec §2), so the
/// app pauses its BLE interface while a scan runs (see `MeshtasticSettingsReducer`).
public struct RadioScanner: Sendable {
    public var scan: @Sendable () -> AsyncStream<RadioScanResult>

    public init(scan: @escaping @Sendable () -> AsyncStream<RadioScanResult>) {
        self.scan = scan
    }
}

extension RadioScanner: DependencyKey {
    /// LOUD stub for hosts that install no scanner (previews, tests). The app installs
    /// `MeshtasticLiveWiring.installScanner(into:)`. It is not a silent no-op: the stream
    /// finishes at once, so the picker reaches `scanEnded` and shows
    /// `RadioPickerFeature.scanEndedEmptyMessage` instead of a spinner that never resolves.
    /// `radioPickerUninstalledLiveScannerEndsTheScan` pins this.
    public static let liveValue = RadioScanner(scan: { AsyncStream<RadioScanResult> { $0.finish() } })

    public static let testValue = RadioScanner(
        scan: unimplemented("RadioScanner.scan", placeholder: AsyncStream<RadioScanResult> { $0.finish() }))

    /// Three fake radios, then an open stream (a scan in progress), for SwiftUI previews.
    public static let previewValue = RadioScanner(scan: {
        AsyncStream<RadioScanResult> { continuation in
            continuation.yield(RadioScanResult(
                id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001")!, name: "Meshtastic_1a2b", rssi: -52))
            continuation.yield(RadioScanResult(
                id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000002")!, name: "Base camp T-Beam", rssi: -71))
            continuation.yield(RadioScanResult(
                id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000003")!, name: nil, rssi: -88))
        }
    })
}

extension DependencyValues {
    public var radioScanner: RadioScanner {
        get { self[RadioScanner.self] }
        set { self[RadioScanner.self] = newValue }
    }
}

extension RadioScanner {
    /// The live scanner (spec 2026-10-16 §7 lane E): each MeshtasticKit `DiscoveredRadio` from
    /// `radios()` as a `RadioScanResult`, field for field. Finishes when the source does — the
    /// live source (`MeshtasticLive.scanRadios()`) only when scanning stopped for good — and
    /// cancelling the consumer ends the source's scan.
    public static func meshtastic(_ radios: @escaping @Sendable () -> AsyncStream<DiscoveredRadio>) -> RadioScanner {
        RadioScanner(scan: {
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
        })
    }
}
