import Foundation

/// What the composer's picker handed over: the bytes plus the kind and, for a file, its name.
/// The view reads the picker item (security-scoped for `fileImporter`) and sends this.
public struct PickedItem: Equatable, Sendable {
    public var kind: String       // AttachmentKind.*
    public var name: String       // "" for a photo (the name is generated)
    public var data: Data
    /// The conversation open when the pick started. The picker's reads outlive the chat view, so
    /// a slow read from one conversation must not land in another's composer.
    public var peerHex: String

    public init(kind: String, name: String, data: Data, peerHex: String) {
        self.kind = kind
        self.name = name
        self.data = data
        self.peerHex = peerHex
    }
}

/// The attachment waiting in the composer bar (spec 2026-09-28 §3): already encoded for the wire.
public struct PendingAttachment: Equatable, Sendable {
    public var kind: String
    public var name: String
    public var format: String
    public var data: Data
    public var width: Int?
    public var height: Int?
    /// Images: the picker's bytes, kept so the Original toggle can re-encode. nil for files.
    public var originalSource: Data?
    public var isOriginal: Bool

    public init(kind: String, name: String, format: String, data: Data, width: Int?, height: Int?,
                originalSource: Data?, isOriginal: Bool) {
        self.kind = kind
        self.name = name
        self.format = format
        self.data = data
        self.width = width
        self.height = height
        self.originalSource = originalSource
        self.isOriginal = isOriginal
    }

    public var isImage: Bool { kind == AttachmentKind.image }
    public var size: Int { data.count }
}

/// The size notes the composer shows (spec: informational, never blocking). The limits are the
/// reference LXMF defaults: a propagation node accepts 256 KB per message and a receiving router
/// 1 000 KB (neither is announced per peer, so these are the safe assumptions).
public enum AttachmentSizeNote {
    public static let propagationLimitBytes = 256_000
    public static let deliveryLimitBytes = 1_000_000
    public static let overPropagation = "Over 256 KB — direct only, won't be stored at the propagation node"
    public static let overDelivery = "Over 1 MB — may be refused by other clients"

    public static func note(for size: Int) -> String? {
        if size > deliveryLimitBytes { return overDelivery }
        if size > propagationLimitBytes { return overPropagation }
        return nil
    }

    /// `900 B`, `34 KB`, `1.2 MB` (decimal units, like the limits).
    public static func formattedSize(_ bytes: Int) -> String {
        if bytes < 1000 { return "\(bytes) B" }
        if bytes < 1_000_000 { return "\(bytes / 1000) KB" }
        let mb = Double(bytes) / 1_000_000
        return String(format: "%.1f MB", mb)
    }
}

/// Turns a picked item into a pending attachment. Pure and synchronous; `AppFeature` runs it in
/// an effect so a large photo never encodes on the main thread.
public enum AttachmentPreparation {
    public static let undecodableImage = "Couldn't read that image"
    public static let encodingFailed = "Couldn't encode that image"
    public static let storeFailed = "Couldn't save the attachment — nothing was sent"

    public struct PreparationError: Error, Equatable, Sendable {
        public var message: String
        public init(message: String) { self.message = message }
    }

    public static func prepare(_ item: PickedItem, original: Bool, now: Date) -> Result<PendingAttachment, PreparationError> {
        if item.kind == AttachmentKind.image {
            do {
                let encoded = try ImageEncoder.encodeJPEG(item.data, preset: original ? .original : .standard)
                let name = item.name.isEmpty ? imageName(at: now) : item.name
                return .success(PendingAttachment(
                    kind: AttachmentKind.image, name: name, format: AttachmentWire.sentImageFormat,
                    data: encoded.data, width: encoded.width, height: encoded.height,
                    originalSource: item.data, isOriginal: original))
            } catch ImageEncoder.Failure.encodingFailed {
                // ImageIO read the image but could not write the JPEG: not the user's file's fault.
                return .failure(PreparationError(message: encodingFailed))
            } catch {
                return .failure(PreparationError(message: undecodableImage))
            }
        }
        let name = AttachmentWire.sanitizedFileName(item.name)
        return .success(PendingAttachment(
            kind: AttachmentKind.file, name: name, format: AttachmentWire.fileExtension(name),
            data: item.data, width: nil, height: nil, originalSource: nil, isOriginal: false))
    }

    /// `IMG_yyyyMMdd_HHmmss.jpg` in UTC, so the name is the same wherever the phone is.
    public static func imageName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "'IMG_'yyyyMMdd'_'HHmmss'.jpg'"
        return formatter.string(from: date)
    }
}
