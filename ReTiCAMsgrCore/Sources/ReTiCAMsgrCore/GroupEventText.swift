import Foundation

/// The system lines a group thread shows and the readable bodies group control messages carry
/// for other LXMF clients (spec 2026-10-09 §1 and §3, amendment A4). Pure, so every string is
/// testable and the same text serves the thread, the list preview and the wire.
public enum GroupEventText {
    public static let you = "You"
    public static let appName = "ReTiCAMsgr"
    /// Shown on the group info screen (spec §4).
    public static let caveat = "Members on other apps see posts as separate direct messages and cannot reply to the group."

    /// A member with no announce display name: the first eight hex characters of their address.
    public static func fallbackName(_ hex: String) -> String { String(hex.prefix(8)) }

    // MARK: Lines in the thread

    public static func created(name: String) -> String { "\(you) created the group \(name)" }
    public static func invited(by inviter: String, name: String) -> String { "\(inviter) invited you to the group \(name)" }
    public static func added(by actor: String, who: String) -> String { "\(actor) added \(who)" }
    public static func removed(by actor: String, who: String) -> String { "\(actor) removed \(who)" }
    public static func removedYou(by actor: String) -> String { "\(actor) removed you from the group" }
    public static func renamed(by actor: String, to name: String) -> String { "\(actor) renamed the group to \(name)" }
    public static func left(who: String) -> String { "\(who) left the group" }
    public static func declined() -> String { "\(you) declined the invitation" }
    public static func deleted(by actor: String) -> String { "\(actor) deleted the group" }

    // MARK: Bodies on the wire

    /// Every roster message carries the invite sentence (amendment A4).
    public static func rosterBody(inviter: String, name: String) -> String {
        "\(inviter) invited you to the group \(name) in \(appName)"
    }
    public static func leaveBody(who: String, name: String) -> String { "\(who) left the group \(name)" }
    public static func deleteBody(who: String, name: String) -> String { "\(who) deleted the group \(name)" }
}
