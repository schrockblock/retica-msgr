import Foundation

/// The one compile-time switch for the RNode feature. RNode is Debug-only until lane E removes this
/// gate. Logic reads this value (through `AppFeature.State.rnodeAvailable`) instead of using
/// `#if DEBUG` itself, so tests can turn the feature off.
public enum RNodeReleaseGate {
    public static var isCompiledIn: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
