import Foundation
import ComposableArchitecture

// Meshtastic settings (spec 2026-10-16 §7 lane D). Lane E reads `meshtasticEnabled` and
// `meshtasticRadioUUID` at connect time to build the endpoint slot.

extension AppFeature.State {
    /// The chosen radio, or nil when none is chosen OR the stored string is not a UUID (Review
    /// Focus 4): a hand-edited or corrupted default must read as "no radio", never as a radio to dial.
    public var meshtasticRadioUUID: UUID? {
        meshtasticRadioID.flatMap(UUID.init(uuidString:))
    }

    /// The Settings radio row: the name the radio advertised when it was picked, else its UUID,
    /// else "None".
    public var meshtasticRadioLabel: String {
        guard let id = meshtasticRadioUUID else { return "None" }
        let name = meshtasticRadioName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? id.uuidString : name
    }
}
