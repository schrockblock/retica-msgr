import Foundation
import ReTiCA

/// Wire codec for an emoji reaction carried in LXMF `fields`.
///
/// Uses LXMF's reserved extension keys rather than inventing a field number:
/// `FIELD_CUSTOM_TYPE` (0xFB) names the extension, `FIELD_CUSTOM_DATA` (0xFC) carries
/// `{ "target": bin, "emoji": str }`. An empty `emoji` means "I removed my reaction".
/// A message whose custom type matches is a reaction regardless of its `content`, so a later
/// human-readable fallback in `content` never renders as a bubble in this app.
public enum ReactionWire {
    public static let fieldCustomType = 0xFB
    public static let fieldCustomData = 0xFC
    public static let customType = "reticamsgr.reaction"
    /// Upper bound on the emoji's UTF-8 size. Generous enough for any ZWJ sequence with skin
    /// tones; small enough that a peer can't stuff a paragraph into a badge.
    public static let maxEmojiBytes = 64
    public static let targetLengths = 16...32

    public enum Decoded: Equatable, Sendable {
        /// Not our extension — handle as an ordinary message.
        case notReaction
        case reaction(target: Data, emoji: String)
        /// Claims to be a reaction but the payload is unusable — drop it.
        case malformed
    }

    public static func encode(target: Data, emoji: String) -> [MsgPackValue.IntPair] {
        [
            .init(fieldCustomType, .string(customType)),
            .init(fieldCustomData, .map([
                .init("target", .bin(target)),
                .init("emoji", .string(emoji)),
            ])),
        ]
    }

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded {
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
