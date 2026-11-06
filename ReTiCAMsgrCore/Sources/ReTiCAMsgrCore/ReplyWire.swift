import Foundation
import ReTiCA

/// Wire codec for a reply carried in LXMF `fields`, in the standard format
/// (`LXMF/LXMF.py:23-24`): `FIELD_REPLY_TO` (0x30) holds the original's full `LXMessage.hash` as
/// bin, and `FIELD_REPLY_QUOTE` (0x31) holds the quoted text as UTF-8 bin.
///
/// A reply is otherwise a normal text message, so a client without reply support shows it as one.
/// `AppFeature` only calls `decode` on messages `ReactionWire` did not claim: reply fields on a
/// reaction are ignored.
public enum ReplyWire {
    public static let fieldReplyTo = 0x30
    public static let fieldReplyQuote = 0x31
    /// Upper bound on the quote's UTF-8 size. A larger quote is ignored, but the reply is kept.
    public static let maxQuoteBytes = 400
    public static let quoteCharacterLimit = 100
    public static let replyToLengths = 16...32
    public static let ellipsis = "…"

    /// The reply fields. `quote` goes on the wire as given: pass `trimQuote(...)` output. An empty
    /// quote (a whitespace-only original) omits `0x31` entirely, rather than sending an empty value.
    public static func encode(replyTo: Data, quote: String) -> [MsgPackValue.IntPair] {
        var fields: [MsgPackValue.IntPair] = [.init(fieldReplyTo, .bin(replyTo))]
        if !quote.isEmpty {
            fields.append(.init(fieldReplyQuote, .bin(Data(quote.utf8))))
        }
        return fields
    }

    /// `nil` when the message is not a reply: 0x30 missing, not bin, or not 16–32 bytes (0x31 is
    /// then ignored too). An unusable 0x31 keeps the reply with `quote == nil`.
    public static func decode(_ fields: [MsgPackValue.IntPair]) -> (replyTo: Data, quote: String?)? {
        guard case let .bin(replyTo)? = fields.first(where: { $0.key == fieldReplyTo })?.value,
              replyToLengths.contains(replyTo.count)
        else { return nil }
        return (replyTo, decodeQuote(fields))
    }

    /// `0x31` may arrive as msgpack `bin` or `str`, under the same 400-byte UTF-8 cap either way. A
    /// `str` is already valid UTF-8 by construction, so only the byte cap applies to it; a `bin`
    /// additionally needs the strict round-trip check, since arbitrary bytes may not be valid UTF-8.
    private static func decodeQuote(_ fields: [MsgPackValue.IntPair]) -> String? {
        switch fields.first(where: { $0.key == fieldReplyQuote })?.value {
        case let .bin(bytes):
            guard bytes.count <= maxQuoteBytes else { return nil }
            // Strict UTF-8, as in ReactionWire: `String(decoding:)` repairs invalid bytes with
            // U+FFFD, so the bytes are valid exactly when they survive a round trip unchanged.
            let text = String(decoding: bytes, as: UTF8.self)
            guard Data(text.utf8) == bytes else { return nil }
            return text
        case let .string(s):
            guard s.utf8.count <= maxQuoteBytes else { return nil }
            return s
        default:
            return nil
        }
    }

    /// The quote for a reply: surrounding whitespace and newlines trimmed, then at most
    /// `quoteCharacterLimit` Characters, with "…" appended when cut. Characters are grapheme
    /// clusters, so an emoji sequence is never split.
    ///
    /// It also never exceeds `maxQuoteBytes`, "…" included. 100 wide Characters (a ZWJ family is 25
    /// bytes) would otherwise be dropped by every receiver's `decode`, ours included.
    public static func trimQuote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= quoteCharacterLimit, trimmed.utf8.count <= maxQuoteBytes { return trimmed }
        var kept = trimmed.prefix(quoteCharacterLimit)
        while !kept.isEmpty, kept.utf8.count + ellipsis.utf8.count > maxQuoteBytes {
            kept = kept.dropLast()
        }
        return String(kept) + ellipsis
    }
}
