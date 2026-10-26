import Foundation
import ReTiCA

/// Wire codec for my display name riding on messages (`0xA1`, spec 2026-10-25), our own key next
/// to the photo's `0xA0`. The value is `bin(UTF-8 name)`, trimmed; an empty bin means "no name".
/// Other LXMF clients ignore it and keep using the announce.
public enum NameWire {
    public static let fieldDisplayName = 0xA1
    public static let maxBytes = 128

    /// The name trimmed, then cut at a character boundary so it fits in `maxBytes` of UTF-8.
    public static func encode(_ name: String) -> [MsgPackValue.IntPair] {
        var trimmed = Substring(name.trimmingCharacters(in: .whitespacesAndNewlines))
        while trimmed.utf8.count > maxBytes { trimmed = trimmed.dropLast() }
        return [.init(fieldDisplayName, .bin(Data(trimmed.utf8)))]
    }

    /// The carried name, `""` for a cleared one; nil when the field is absent, not a bin, longer
    /// than `maxBytes` or not valid UTF-8.
    public static func decode(_ fields: [MsgPackValue.IntPair]) -> String? {
        guard let value = fields.first(where: { $0.key == fieldDisplayName })?.value,
              case let .bin(bytes) = value,
              bytes.count <= maxBytes
        else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}
