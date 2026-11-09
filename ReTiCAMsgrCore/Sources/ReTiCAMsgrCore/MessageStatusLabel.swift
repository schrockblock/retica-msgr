import Foundation

/// The words a one-to-one bubble shows for a `MessageStatus` (brief 2026-10-21). "Stored" says
/// only what the sender knows: the propagation node holds the message. Whether a push alert went
/// out is unknowable here, so no label claims it.
public enum MessageStatusLabel {
    /// `text(for:)`, except a `sending` row whose send is waiting for the peer's stamp cost or
    /// computing its stamp reads "Preparing…". Every other status ignores `preparing`.
    public static func text(for status: String, preparing: Bool) -> String {
        status == MessageStatus.sending && preparing ? "Preparing…" : text(for: status)
    }

    public static func text(for status: String) -> String {
        switch status {
        case MessageStatus.sending: return "Sending…"
        case MessageStatus.sent: return "Sent"
        case MessageStatus.propagated: return "Stored for pickup"
        case MessageStatus.delivered: return "Delivered"
        case MessageStatus.failed: return "Not sent"
        case MessageStatus.cancelled: return "Cancelled"
        case GroupDeliveryStatus.waiting: return "Waiting"
        case MessageStatus.received: return "Received"
        default: return status
        }
    }
}
