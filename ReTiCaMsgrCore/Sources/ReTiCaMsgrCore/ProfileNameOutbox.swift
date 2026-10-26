import Foundation
import ReTiCA

/// The outbound rule for my display name, per outgoing message to one peer (spec 2026-10-25).
/// Pure, like `ProfilePhotoOutbox`: the caller supplies my trimmed name and the peer's delivery
/// row, and writes `pendingName` (with the message hash) back through
/// `ProfileNameDelivery.markPending`.
public enum ProfileNameOutbox {
    /// The name rides until the peer confirms it, neither delivered nor already in flight. A
    /// cleared name rides as `""`, only once a non-empty name was confirmed to that peer.
    public static func plan(
        myName: String, delivery: ProfileNameDelivery?
    ) -> (fields: [MsgPackValue.IntPair], pendingName: String?) {
        if myName.isEmpty {
            guard let delivered = delivery?.deliveredName, !delivered.isEmpty,
                  delivery?.pendingName != ""
            else { return ([], nil) }
            return (NameWire.encode(""), "")
        }
        guard myName != delivery?.deliveredName, myName != delivery?.pendingName else { return ([], nil) }
        return (NameWire.encode(myName), myName)
    }
}
