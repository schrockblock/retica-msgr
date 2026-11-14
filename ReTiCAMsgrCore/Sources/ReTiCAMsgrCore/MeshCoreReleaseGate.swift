import Foundation

/// The one switch for the MeshCore feature. It was Debug-only pending the hardware run (lane E);
/// since 2026-11-13 it is on in every build at the owner's request, with that run still to do, so
/// the Settings section stays under "Experimental". Logic reads this value through
/// `AppFeature.State.meshCoreAvailable`, so tests can still turn the feature off.
public enum MeshCoreReleaseGate {
    public static let isCompiledIn = true
}

/// Whether the channel key is in the Keychain. Declared here and used by the key store.
public enum MeshCoreKeyPresence: Equatable, Sendable {
    case absent
    case present
    /// The Keychain read failed. This is never treated as `.absent`.
    case unreadable
}
