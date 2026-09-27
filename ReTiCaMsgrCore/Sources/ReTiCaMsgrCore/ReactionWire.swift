import Foundation
import ReTiCA

/// Wire codec for an emoji reaction carried in LXMF `fields`.
///
/// **Sent** in the standard LXMF 1.1.0 format (`LXMF/LXMF.py:25,109-110`): `FIELD_REACTION` (0x40)
/// holds an int-keyed map with `REACTION_TO` (0x00) = the target's full `LXMessage.hash` as bin,
/// and `REACTION_CONTENT` (0x01) = the reaction as UTF-8 bin. The standard defines no removal, so
/// by our convention **empty `REACTION_CONTENT` means "I removed my reaction"**.
///
/// **Received** in either format. A well-formed 0x40 wins. Otherwise the legacy format this app
/// shipped on 2026-09-25 is tried: `FIELD_CUSTOM_TYPE` (0xFB) = "reticamsgr.reaction" and
/// `FIELD_CUSTOM_DATA` (0xFC) = `{ "target": bin, "emoji": str }`. A 0x40 field that is present
/// but unusable, with no usable legacy reaction beside it, is `.malformed` and dropped.
///
/// A message that decodes as a reaction is a reaction whatever its `content`, so a human-readable
/// fallback in `content` never renders as a bubble in this app.
public enum ReactionWire {
    public static let fieldReaction = 0x40
    public static let reactionTo = 0x00
    public static let reactionContent = 0x01
    public static let fieldCustomType = 0xFB
    public static let fieldCustomData = 0xFC
    public static let customType = "reticamsgr.reaction"
    /// Upper bound on the emoji's UTF-8 size. Generous enough for any ZWJ sequence with skin
    /// tones; small enough that a peer can't stuff a paragraph into a badge.
    public static let maxEmojiBytes = 64
    public static let targetLengths = 16...32

    public enum Decoded: Equatable, Sendable {
        /// Neither reaction format — handle as an ordinary message.
        case notReaction
        case reaction(target: Data, emoji: String)
        /// Claims to be a reaction but the payload is unusable — drop it.
        case malformed
    }

    public static func encode(target: Data, emoji: String) -> [MsgPackValue.IntPair] {
        [
            .init(fieldReaction, .intMap([
                .init(reactionTo, .bin(target)),
                .init(reactionContent, .bin(Data(emoji.utf8))),
            ])),
        ]
    }

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded {
        let standard = fields.first(where: { $0.key == fieldReaction })?.value
        if let standard, let reaction = decodeStandard(standard) {
            return .reaction(target: reaction.target, emoji: reaction.emoji)
        }
        let legacy = decodeLegacy(fields)
        if case .notReaction = legacy, standard != nil { return .malformed }
        return legacy
    }

    /// `nil` when the 0x40 payload is unusable.
    private static func decodeStandard(_ value: MsgPackValue) -> (target: Data, emoji: String)? {
        guard case let .intMap(pairs) = value,
              case let .bin(target)? = pairs.first(where: { $0.key == reactionTo })?.value,
              targetLengths.contains(target.count),
              case let .bin(content)? = pairs.first(where: { $0.key == reactionContent })?.value,
              content.count <= maxEmojiBytes
        else { return nil }
        // Strict UTF-8: `String(decoding:)` repairs invalid bytes with U+FFFD, so the bytes are
        // valid exactly when they survive a round trip unchanged.
        let emoji = String(decoding: content, as: UTF8.self)
        guard Data(emoji.utf8) == content else { return nil }
        return (target, emoji)
    }

    /// The 2026-09-25 format. Kept so reactions from builds that predate the addendum still work.
    private static func decodeLegacy(_ fields: [MsgPackValue.IntPair]) -> Decoded {
        guard case .string(customType)? = fields.first(where: { $0.key == fieldCustomType })?.value else {
            return .notReaction
        }
        guard case let .map(pairs)? = fields.first(where: { $0.key == fieldCustomData })?.value,
              case let .bin(target)? = pairs.first(where: { $0.key == "target" })?.value,
              targetLengths.contains(target.count),
              case let .string(emoji)? = pairs.first(where: { $0.key == "emoji" })?.value,
              emoji.utf8.count <= maxEmojiBytes
        else { return .malformed }
        return .reaction(target: target, emoji: emoji)
    }
}

public enum QuickReactions {
    public static let `default`: [String] = ["❤️", "👍", "👎", "😂", "😮", "😢"]
}
