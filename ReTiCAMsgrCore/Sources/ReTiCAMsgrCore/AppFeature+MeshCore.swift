import Foundation
import ComposableArchitecture

// MeshCore settings (spec 2026-11-07 §6). Lane D reads `meshCoreWillDial` at connect time.

extension AppFeature.State {
    /// The chosen radio, or nil when none is chosen OR the stored string is not a UUID: a hand-edited
    /// or corrupted default must read as "no radio", never as a radio to dial.
    public var meshCoreRadioUUID: UUID? {
        meshCoreRadioID.flatMap(UUID.init(uuidString:))
    }

    /// The Settings radio row: the name the radio advertised when it was picked, else its UUID,
    /// else "None".
    public var meshCoreRadioLabel: String {
        guard let id = meshCoreRadioUUID else { return "None" }
        let name = meshCoreRadioName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? id.uuidString : name
    }

    /// Every condition a MeshCore slot needs to start. Stale defaults (restored from a backup without
    /// the Keychain item, or left over from a Debug build) fail the key or gate check, so nothing dials.
    var meshCoreWillDial: Bool {
        meshCoreAvailable && meshCoreEnabled && meshCoreRadioUUID != nil && meshCoreKeyPresence == .present
    }
}
