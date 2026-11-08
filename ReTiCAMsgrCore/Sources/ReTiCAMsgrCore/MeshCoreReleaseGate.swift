import Foundation

/// The one compile-time switch for the MeshCore feature. MeshCore is Debug-only until lane E removes
/// this gate. Logic reads this value (through `AppFeature.State.meshCoreAvailable`) instead of using
/// `#if DEBUG` itself, so tests can turn the feature off.
public enum MeshCoreReleaseGate {
    public static var isCompiledIn: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

/// Whether the channel key is in the Keychain. Declared here and used by the key store.
public enum MeshCoreKeyPresence: Equatable, Sendable {
    case absent
    case present
    /// The Keychain read failed. This is never treated as `.absent`.
    case unreadable
}
