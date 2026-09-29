import Foundation
import ReTiCA

/// Wire codec for one attachment carried in LXMF `fields`, in the standard format
/// (`LXMF/LXMF.py:12-13`, as Sideband writes it): `FIELD_IMAGE` (0x06) is `[format, bytes]` and
/// `FIELD_FILE_ATTACHMENTS` (0x05) is `[[name, bytes], ...]`.
///
/// Sent: one field, `0x06 = ["jpeg", <jpeg>]` or `0x05 = [[name, <bytes>]]`. Received: lenient.
/// The image wins when both are present, the first file entry wins, an image format we cannot
/// decode is kept as a file, and a malformed field is `nil` — `AppFeature` then stores the
/// message as plain text (a message is never lost over a bad field).
public enum AttachmentWire {
    public static let fieldFileAttachments = 0x05
    public static let fieldImage = 0x06
    /// The format string we send. Sideband/Kivy accept "jpeg" and "jpg" alike.
    public static let sentImageFormat = "jpeg"
    /// Formats ImageIO decodes on iOS and that render inline. Anything else is a file row.
    public static let imageFormats: Set<String> = ["jpeg", "png", "webp", "heic"]
    public static let maxNameBytes = 255
    public static let fallbackFileName = "file"

    public struct Decoded: Equatable, Sendable {
        public var kind: String      // AttachmentKind.*
        public var name: String
        public var format: String
        public var data: Data
        /// 0x05 entries left out: those after the first, or all of them when an image won.
        /// `AppFeature` logs it (spec §2: one attachment per message is kept, the rest noted).
        public var droppedFileCount: Int

        public init(kind: String, name: String, format: String, data: Data, droppedFileCount: Int = 0) {
            self.kind = kind
            self.name = name
            self.format = format
            self.data = data
            self.droppedFileCount = droppedFileCount
        }
    }

    public static func encodeImage(_ data: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldImage, .array([.string(sentImageFormat), .bin(data)]))]
    }

    public static func encodeFile(name: String, data: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldFileAttachments, .array([.array([.string(name), .bin(data)])]))]
    }

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded? {
        let fileValue = fields.first(where: { $0.key == fieldFileAttachments })?.value
        if let value = fields.first(where: { $0.key == fieldImage })?.value,
           var image = decodeImage(value) {
            // The image wins: every file entry beside it is dropped.
            image.droppedFileCount = fileEntryCount(fileValue)
            return image
        }
        if let fileValue, let file = decodeFile(fileValue) {
            return file
        }
        return nil
    }

    /// How many entries a 0x05 value lists (0 when absent or not a list).
    static func fileEntryCount(_ value: MsgPackValue?) -> Int {
        guard case let .array(entries)? = value else { return 0 }
        return entries.count
    }

    /// `[format, bin]`. An unknown format is a file named `image.<ext>` (ext sanitised).
    static func decodeImage(_ value: MsgPackValue) -> Decoded? {
        guard case let .array(parts) = value, parts.count == 2,
              let raw = text(parts[0]),
              case let .bin(data) = parts[1], !data.isEmpty
        else { return nil }
        let format = normalizedImageFormat(raw)
        if imageFormats.contains(format) {
            return Decoded(kind: AttachmentKind.image, name: "image.\(format)", format: format, data: data)
        }
        let ext = AttachmentStore.sanitizedExtension(raw)
        return Decoded(kind: AttachmentKind.file, name: ext.isEmpty ? "image" : "image.\(ext)", format: ext, data: data)
    }

    /// `[[name, bin], ...]` — the first entry only (known limit, spec §2).
    static func decodeFile(_ value: MsgPackValue) -> Decoded? {
        guard case let .array(entries) = value,
              case let .array(pair)? = entries.first, pair.count == 2,
              let rawName = text(pair[0]),
              case let .bin(data) = pair[1]
        else { return nil }
        let name = sanitizedFileName(rawName)
        return Decoded(kind: AttachmentKind.file, name: name, format: fileExtension(name), data: data,
                       droppedFileCount: entries.count - 1)
    }

    /// A `str`, or a `bin` that is strictly valid UTF-8 (`String(decoding:)` repairs invalid bytes,
    /// so the bytes are valid exactly when they survive a round trip unchanged).
    static func text(_ value: MsgPackValue) -> String? {
        switch value {
        case let .string(s):
            return s
        case let .bin(b):
            let s = String(decoding: b, as: UTF8.self)
            return Data(s.utf8) == b ? s : nil
        default:
            return nil
        }
    }

    /// Trimmed, lowercased, no leading dot; `jpg` → `jpeg`, `heif` → `heic`.
    public static func normalizedImageFormat(_ raw: String) -> String {
        var f = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if f.hasPrefix(".") { f.removeFirst() }
        switch f {
        case "jpg", "jpeg": return "jpeg"
        case "heif", "heic": return "heic"
        default: return f
        }
    }

    /// Review Focus 2: separators, colons, NUL and every control or format character (`Cc`, `Cf`:
    /// bidi overrides such as U+202E, zero-width spaces) become `_`, leading dots are stripped (no
    /// hidden or `..` names), the result is cut to `maxNameBytes` on a Character boundary, and an
    /// empty result is `fallbackFileName`. The store never uses this name in a path anyway.
    public static func sanitizedFileName(_ raw: String) -> String {
        var name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).map { ch -> Character in
            (ch == "/" || ch == "\\" || ch == ":" || ch == "\u{0}" || ch.isNewline || isControlOrFormat(ch)) ? "_" : ch
        })
        while name.hasPrefix(".") { name.removeFirst() }
        if name.utf8.count > maxNameBytes {
            var kept = Substring(name)
            while !kept.isEmpty, kept.utf8.count > maxNameBytes { kept = kept.dropLast() }
            name = String(kept)
        }
        return name.isEmpty ? fallbackFileName : name
    }

    /// Judged by the Character's FIRST scalar: bidi controls and U+200B are grapheme-break
    /// `Control`, so each is a Character of its own, while a ZWJ inside an emoji sequence only
    /// extends the emoji before it and must not break it apart.
    static func isControlOrFormat(_ ch: Character) -> Bool {
        guard let first = ch.unicodeScalars.first else { return false }
        switch first.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }

    /// The sanitised extension after the last dot, `""` when there is none or the dot leads.
    public static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return AttachmentStore.sanitizedExtension(String(name[name.index(after: dot)...]))
    }
}
