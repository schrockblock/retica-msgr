import Foundation
import ReTiCA
import ReTiCANode

/// Maps ReTiCA's view of a message onto the strings stored in `messages` for the Info sheet.
/// Pure. `AppFeature` calls these while building the row it inserts.
enum MessageMetadata {
    /// 9999-12-31T23:59:59Z, the last instant the ISO-8601 text column can hold.
    static let maxSenderTimestamp: Double = 253_402_300_799

    /// The sender's LXMF timestamp as a Date, or nil when a peer's clock produced a value that
    /// cannot be stored and read back (non-finite, before 1970, or after year 9999).
    static func senderTimestamp(_ t: Double) -> Date? {
        guard t.isFinite, (0...maxSenderTimestamp).contains(t) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func arrivalMethod(_ method: LXMFRouter.DeliveryMethod) -> String {
        switch method {
        case .opportunistic: return ArrivalMethod.opportunistic
        case .direct: return ArrivalMethod.direct
        case .propagated: return ArrivalMethod.propagated
        }
    }

    /// No stamp is "none" even when validation ran. ReTiCA reports a missing stamp under a
    /// configured cost as checked-and-invalid, but "there was no stamp" says more when debugging.
    static func stampState(_ message: LXMessage) -> String {
        guard message.stamp != nil else { return StampState.none }
        guard message.stampChecked else { return StampState.unchecked }
        return message.stampValid ? StampState.valid : StampState.invalid
    }

    /// Lowercase two-digit hex keys in wire order, e.g. "0x02,0xfb". "" when there are none.
    static func fieldKeys(_ fields: [MsgPackValue.IntPair]) -> String {
        fields.map { pair in
            let hex = String(pair.key, radix: 16)
            return "0x" + (hex.count < 2 ? "0" + hex : hex)
        }.joined(separator: ",")
    }
}
