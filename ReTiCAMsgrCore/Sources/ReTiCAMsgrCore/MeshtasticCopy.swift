import Foundation

/// The Meshtastic Settings section's own Connect button and hop limit text. The rest of that
/// section's copy is still inline in SettingsView.
public enum MeshtasticCopy {
    public static let connectButton = "Connect Meshtastic radio"
    public static let connecting = "Connecting…"
    public static let applyChanges = "Apply changes"

    /// The hop limit stepper's label, with the current value.
    public static func hopLimitRow(_ hops: Int) -> String { "Hop limit: \(hops)" }
    public static let hopLimitNotice = "How many times other Meshtastic radios may pass on each message "
        + "piece this app sends. Every hop retransmits every piece, using airtime everyone on your mesh "
        + "shares. Please be kind to your mesh: use the lowest number that reaches the people you talk "
        + "to. 1 is usually enough."
}

/// Meshtastic's hop limit as the app offers it: 1 by default (landandair's), up to the firmware's
/// maximum of 7.
public enum MeshtasticHopLimit {
    public static let defaultValue = 1
    public static let range = 1...7
}
