import Foundation
import ReTiCAInterfaces

extension BLEAdapterUnavailable {
    /// For Settings: a sentence for the causes the user can act on, the driver's own text for `.other`.
    /// One mapping for every radio's status (`MeshCoreStatus`, `RNodeStatus`), so the wording can't drift.
    var userMessage: String {
        switch self {
        case let .other(detail):
            return detail ?? "The Bluetooth path to the radio is unavailable."
        case .unauthorized:
            return "Bluetooth permission is off for this app. Allow it in Settings."
        case .unsupported:
            return "This device has no Bluetooth LE radio."
        case .poweredOff:
            return "Bluetooth is off. Turn it on to reach the radio."
        }
    }
}
