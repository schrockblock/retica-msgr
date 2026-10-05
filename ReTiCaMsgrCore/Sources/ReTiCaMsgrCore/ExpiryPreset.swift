import Foundation

/// The disappearing-messages durations the toolbar menu offers (Signal's presets, spec §4), their
/// labels, and the text of the announcement rows. Pure, so the strings are testable and the same
/// label serves the menu, the title indicator, the Info sheet and the announcements.
public enum ExpiryPreset: Int, CaseIterable, Sendable {
    case off = 0
    case thirtySeconds = 30
    case fiveMinutes = 300
    case oneHour = 3_600
    case eightHours = 28_800
    case oneDay = 86_400
    case oneWeek = 604_800
    case fourWeeks = 2_419_200

    public var seconds: Int { rawValue }
    public var label: String { Self.label(forSeconds: rawValue) }

    public static let offLabel = "Off"
    /// Shown with the menu: Sideband, NomadNet and Retichat ignore the field and keep the message.
    public static let caveat = "Only ReTiCaMsgr peers honour this. Other apps keep messages."

    /// "Off" for 0, otherwise the largest unit that divides the value evenly, so a peer's
    /// non-preset value still reads naturally ("90 seconds", "2 hours").
    public static func label(forSeconds seconds: Int) -> String {
        guard seconds > 0 else { return offLabel }
        let units: [(size: Int, name: String)] = [(604_800, "week"), (86_400, "day"), (3_600, "hour"), (60, "minute")]
        for unit in units where seconds % unit.size == 0 {
            return plural(seconds / unit.size, unit.name)
        }
        return plural(seconds, "second")
    }

    /// The body of the timer-change message this device sends (it is also what other LXMF clients
    /// display, since they ignore the field).
    public static func announcement(seconds: Int) -> String {
        seconds > 0
            ? "Disappearing messages set to \(label(forSeconds: seconds))"
            : "Disappearing messages turned off"
    }

    /// The local line for a change the peer made (a received change message with an empty body,
    /// or the convergence rule, spec §3). `peerName` nil falls back to "Them", as reply previews do.
    public static func peerAnnouncement(peerName: String?, seconds: Int) -> String {
        let who = peerName ?? ReplyPreview.them
        return seconds > 0
            ? "\(who) set disappearing messages to \(label(forSeconds: seconds))"
            : "\(who) turned disappearing messages off"
    }

    static func plural(_ n: Int, _ unit: String) -> String {
        n == 1 ? "1 \(unit)" : "\(n) \(unit)s"
    }
}
