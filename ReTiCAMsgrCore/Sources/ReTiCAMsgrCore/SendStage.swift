import Foundation
import ReTiCA
import ReTiCANode

/// Where a one-to-one message being sent is right now, in plain words (spec 2026-10-22). Derived
/// only from state the networking layer really holds, so a label never claims something the app
/// can't know.
public enum SendStage: Equatable, Sendable {
    case preparing, waitingForConnection, lookingForThem, connecting
    /// The delivery copy is going over a link as a Resource.
    case sending(fraction: Double?)
    case tryingAgain(attempt: Int, of: Int)
    /// The copy for the propagation node is in its stamp search, queued, or going over.
    case leavingForPickup(fraction: Double?)
    /// Sending, with nothing more specific known: e.g. after a relaunch, before the router has it.
    case inProgress

    public var label: String {
        switch self {
        case .preparing: return "Preparing…"
        case .waitingForConnection: return "Waiting for a connection…"
        case .lookingForThem: return "Looking for them…"
        case .connecting: return "Connecting…"
        case let .sending(fraction): return Self.withPercent("Sending", fraction)
        case let .tryingAgain(attempt, total): return "Trying again (\(attempt) of \(total))"
        case let .leavingForPickup(fraction): return Self.withPercent("Leaving it for pickup", fraction)
        case .inProgress: return "Sending…"
        }
    }

    public var topic: ExplainerTopic {
        switch self {
        case .preparing: return .preparing
        case .waitingForConnection: return .waitingForConnection
        case .lookingForThem: return .lookingForThem
        case .connecting: return .connecting
        case .sending, .inProgress: return .sending
        case .tryingAgain: return .tryingAgain
        case .leavingForPickup: return .leavingForPickup
        }
    }

    /// The stage for `messageHash` to `recipient` (its LXMF delivery destination). The first rule
    /// that holds wins, most concrete activity first; the pickup copy outranks a delivery retry
    /// because once it is under way it is the work actually happening.
    public static func current(messageHash: Data, recipient: Data,
                               client: LXMFNode.State, connection: AppFeature.Connection,
                               reportedPreparing: Bool = false) -> SendStage {
        let router = client.router
        let delivery = router.pendingDeliveries[.delivery(messageHash)]
        if delivery?.phase == .transferring {
            return .sending(fraction: clamped(client.transferProgress[.delivery(messageHash)]))
        }
        // Above the link rules: the router hands the pickup copy over from inside link
        // establishment, while the recipient's link is still parked or opening.
        if router.pendingPropagatedCopies.contains(messageHash)
            || router.pendingDeliveries[.propagated(messageHash)] != nil {
            return .leavingForPickup(fraction: clamped(client.transferProgress[.propagated(messageHash)]))
        }
        switch router.directLinks[recipient] {
        case .establishing: return .connecting
        case .awaitingPath: return .lookingForThem
        default: break
        }
        if let delivery, delivery.phase == .retrying, delivery.attempts >= 2 {
            return .tryingAgain(attempt: delivery.attempts, of: LXMFDelivery.maxAttempts)
        }
        if connection != .connected || router.held { return .waitingForConnection }
        // `reportedPreparing`: the node said this send is waiting for the peer's stamp cost or
        // stamping, which `inFlightDeliveryStamps` does not cover (the wait).
        if reportedPreparing || client.inFlightDeliveryStamps.contains(messageHash) { return .preparing }
        return .inProgress
    }

    private static func clamped(_ fraction: Double?) -> Double? {
        fraction.map { min(max($0, 0), 1) }
    }

    private static func withPercent(_ text: String, _ fraction: Double?) -> String {
        guard let fraction else { return text + "…" }
        return "\(text) \(Int((fraction * 100).rounded()))%"
    }
}

extension AppFeature.State {
    /// The live stage for an outgoing one-to-one row still sending; nil for every other row (group
    /// posts, incoming, settled, timer and group-event lines) and for a row whose hashes don't parse.
    public func sendStage(for message: Message) -> SendStage? {
        guard message.isOutgoing, message.status == MessageStatus.sending, message.groupHex == nil,
              !message.isTimerChange, !message.isGroupEvent,
              let hash = Data(hexString: message.messageHash), !hash.isEmpty,
              let recipient = Data(hexString: message.peerHex), recipient.count == 16
        else { return nil }
        return SendStage.current(messageHash: hash, recipient: recipient, client: node.client, connection: connection,
                                 reportedPreparing: preparingHashes.contains(message.messageHash))
    }
}
