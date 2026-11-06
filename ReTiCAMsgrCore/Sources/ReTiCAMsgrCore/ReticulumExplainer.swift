import Foundation

/// What an ⓘ explains: the four points on the empty Chats screen, each live send stage, and the
/// settled states that need explaining (spec 2026-10-22).
public enum ExplainerTopic: String, CaseIterable, Sendable, Identifiable {
    case direct, encrypted, resilient, anyConnection
    case preparing, waitingForConnection, lookingForThem, connecting, sending, tryingAgain, leavingForPickup
    case storedForPickup, notSent, groupDelivery

    public var id: String { rawValue }
}

/// One plain-language explanation: a title with no counts, a body that ends by naming the
/// Reticulum term where there is one, and a page of the Reticulum or LXMF docs.
public struct Explainer: Equatable, Sendable {
    public let title: String
    public let body: String
    public let learnMoreURL: URL
}

/// The single source of the app's lay explanations of Reticulum. Every one ties back to the
/// principle on the empty Chats screen: no company server in the middle. Jargon appears only in
/// the closing "Reticulum calls this …" sentence.
public enum ReticulumExplainer {
    private static let manual = "https://reticulum.network/manual/"
    private static let whatIs = URL(string: manual + "whatis.html")!
    private static let understanding = URL(string: manual + "understanding.html")!
    private static let interfaces = URL(string: manual + "interfaces.html")!
    private static let lxmf = URL(string: "https://github.com/markqvist/LXMF")!

    public static func explainer(for topic: ExplainerTopic) -> Explainer {
        switch topic {
        case .direct:
            return Explainer(
                title: "Direct",
                body: "There's no company server in the middle. Your phone hands messages to theirs, through "
                    + "whatever relays are nearby, and nobody stores your chats along the way. That's also why big "
                    + "things like photos move best when you're both online. Reticulum is the network underneath "
                    + "ReTiCAMsgr.",
                learnMoreURL: whatIs)
        case .encrypted:
            return term(
                "Encrypted by default",
                "Every message is encrypted on your phone before it leaves, and only their phone can unlock it. "
                    + "Even the relays and pickup points that carry it can't read it.",
                "end-to-end encryption to a destination", understanding)
        case .resilient:
            return term(
                "Resilient",
                "If they can't be reached, your phone keeps trying. If they're still away, it leaves an encrypted "
                    + "copy at a pickup point that they collect next time they're online.",
                "propagation", lxmf)
        case .anyConnection:
            return term(
                "Any connection",
                "ReTiCAMsgr can reach people over the internet, local Wi‑Fi, Bluetooth, or a LoRa radio, and can "
                    + "switch between them. No phone signal is needed if another path exists.",
                "interfaces", interfaces)
        case .preparing:
            return term(
                "Preparing",
                "Your phone is doing a small calculation the recipient asks for, to prove it isn't sending spam. "
                    + "It takes a moment and happens before the message leaves.",
                "stamp", lxmf)
        case .waitingForConnection:
            return Explainer(
                title: "Waiting for a connection",
                body: "Your phone isn't connected to any network path right now. The message will go as soon as it is.",
                learnMoreURL: whatIs)
        case .lookingForThem:
            return term(
                "Looking for them",
                "Your phone is asking the network which way leads to them. Nobody keeps a central directory, so "
                    + "the route is discovered as needed.",
                "path request", understanding)
        case .connecting:
            return term(
                "Connecting",
                "Your phone is setting up a private, encrypted connection directly to theirs. Bigger messages "
                    + "travel over it.",
                "link", understanding)
        case .sending:
            return term(
                "Sending",
                "The message is going over that private connection in pieces. Bigger messages take longer on "
                    + "slow connections.",
                "resource", understanding)
        case .tryingAgain:
            return term(
                "Trying again",
                "The last try didn't get through, maybe because they're out of signal or the app is closed. Your "
                    + "phone tries a few more times, then leaves a copy at your pickup point.",
                "retry", lxmf)
        case .leavingForPickup:
            return term(
                "Leaving it for pickup",
                "They seem to be offline, so your phone is leaving an encrypted copy at your pickup point (a propagation node). They "
                    + "collect it next time they're online.",
                "propagation node", lxmf)
        case .storedForPickup:
            return term(
                "Stored for pickup",
                "Your pickup point has an encrypted copy and holds it until they check in. If they have "
                    + "notifications on, they're alerted.",
                "propagated message", lxmf)
        case .notSent:
            return term(
                "Not sent",
                "Your phone couldn't reach them or a pickup point. Long-press the message and choose Retry to try "
                    + "again.",
                "delivery failed", understanding)
        case .groupDelivery:
            return Explainer(
                title: "Group messages",
                body: "A group message goes separately to each member, straight from your phone. Each member's "
                    + "copy has its own progress.",
                learnMoreURL: understanding)
        }
    }

    private static func term(_ title: String, _ body: String, _ term: String, _ url: URL) -> Explainer {
        Explainer(title: title, body: body + " Reticulum calls this \(term).", learnMoreURL: url)
    }
}
