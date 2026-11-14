import Foundation

/// The one switch for the RNode feature. It was Debug-only until the owner confirmed it on hardware
/// (lane E) on 2026-11-13; it is now on in every build. Logic reads this value through
/// `AppFeature.State.rnodeAvailable`, so tests can still turn the feature off.
public enum RNodeReleaseGate {
    public static let isCompiledIn = true
}
