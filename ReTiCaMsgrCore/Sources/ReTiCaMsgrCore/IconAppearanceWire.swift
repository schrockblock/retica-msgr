import Foundation
import ReTiCA

/// A Sideband-style icon: an icon name plus foreground and background colours as 6-char lowercase hex.
public struct IconAppearance: Equatable, Sendable {
    public var name: String
    public var fg: String
    public var bg: String

    public init(name: String, fg: String, bg: String) {
        self.name = name
        self.fg = fg
        self.bg = bg
    }
}

/// Receive-only codec for LXMF `FIELD_ICON_APPEARANCE` (0x04), as Sideband writes it:
/// `[name, fg, bg]` with `fg`/`bg` the three raw bytes of `struct.pack("!BBB")`. We never send it.
public enum IconAppearanceWire {
    public static let fieldIconAppearance = 0x04
    public static let maxNameBytes = 64

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> IconAppearance? {
        guard let value = fields.first(where: { $0.key == fieldIconAppearance })?.value,
              case let .array(parts) = value, parts.count >= 3,
              let name = AttachmentWire.text(parts[0]),
              (1...maxNameBytes).contains(name.utf8.count),
              case let .bin(fg) = parts[1], fg.count == 3,
              case let .bin(bg) = parts[2], bg.count == 3
        else { return nil }
        return IconAppearance(name: name, fg: fg.hexString, bg: bg.hexString)
    }
}
