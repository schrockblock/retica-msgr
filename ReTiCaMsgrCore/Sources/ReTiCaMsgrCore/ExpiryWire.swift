import Foundation
import ReTiCA

/// Wire codec for the disappearing-messages timer carried in LXMF `fields` (spec 2026-10-05 §1,
/// amendment A1). `FIELD_CUSTOM_META` (0xFD, "for custom data structures" per LXMF.py) holds a
/// string-keyed msgpack map: `reticamsgr.expiry` = duration in seconds (uint), and on a
/// timer-change message `reticamsgr.expiry.change` = true. 0xFB/0xFC are left alone: Retichat uses
/// that pair for key transfer, and a message has only one such pair.
///
/// Received leniently: no 0xFD, a 0xFD that is not a map (lxmf-group-hub writes other data there), a
/// map without our key, a value that is not an integer, a negative value or one over the cap all
/// decode as `nil` ("no expiry"). A malformed field never drops the message. Reference LXMF has no
/// expiry field of its own (re-checked 2026-10-05).
public enum ExpiryWire {
    public static let fieldCustomMeta = 0xFD
    public static let secondsKey = "reticamsgr.expiry"
    public static let changeKey = "reticamsgr.expiry.change"
    /// Four weeks, the longest preset.
    public static let maxSeconds = 2_419_200

    public struct Decoded: Equatable, Sendable {
        public var seconds: Int
        /// The message announces a new conversation timer (0 = off) rather than carrying one.
        public var isChange: Bool

        public init(seconds: Int, isChange: Bool) {
            self.seconds = seconds
            self.isChange = isChange
        }
    }

    public static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, 0), maxSeconds)
    }

    /// The field on an ordinary message in a conversation whose timer is on.
    public static func encode(seconds: Int) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([.init(secondsKey, .uint(UInt64(clamp(seconds))))]))]
    }

    /// The field on a timer-change announcement. `seconds == 0` turns the timer off.
    public static func encodeChange(seconds: Int) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([
            .init(secondsKey, .uint(UInt64(clamp(seconds)))),
            .init(changeKey, .bool(true)),
        ]))]
    }

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded? {
        guard case let .map(pairs)? = fields.first(where: { $0.key == fieldCustomMeta })?.value,
              let value = pairs.first(where: { $0.key == secondsKey })?.value,
              let seconds = nonNegativeSeconds(value)
        else { return nil }
        let isChange: Bool
        if case .bool(true)? = pairs.first(where: { $0.key == changeKey })?.value {
            isChange = true
        } else {
            isChange = false
        }
        return Decoded(seconds: seconds, isChange: isChange)
    }

    /// `uint`, or a non-negative `int` tag, within 0...maxSeconds. Anything else is nil.
    static func nonNegativeSeconds(_ value: MsgPackValue) -> Int? {
        switch value {
        case let .uint(u):
            return u <= UInt64(maxSeconds) ? Int(u) : nil
        case let .int(i):
            return (0...Int64(maxSeconds)).contains(i) ? Int(i) : nil
        default:
            return nil
        }
    }
}
