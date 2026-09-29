import Foundation
import SQLiteData

/// One attachment of one message (spec 2026-09-28 §1): the bytes live on disk under
/// `AttachmentStore`, this row is what the thread and the Info sheet read. Today a message carries
/// at most one attachment; the schema does not assume it (the app does).
///
/// `path` is relative to the attachments directory, `""` when the bytes could not be written
/// (the bubble then says the attachment is unavailable). `width`/`height` are set for images only.
@Table
public struct Attachment: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var messageId: UUID
    public var kind: String        // AttachmentKind.*
    /// The file name: the sender's for files, `IMG_<yyyyMMdd_HHmmss>.jpg` for photos we send,
    /// `image.<format>` for images we receive (LXMF FIELD_IMAGE carries no name).
    public var name: String
    /// Images: `jpeg`/`webp`/`png`/`heic`. Files: the extension without the dot, `""` if none.
    public var format: String
    /// Bytes as sent or received.
    public var size: Int
    public var width: Int?
    public var height: Int?
    public var path: String

    public init(id: UUID, messageId: UUID, kind: String, name: String, format: String, size: Int,
                width: Int?, height: Int?, path: String) {
        self.id = id
        self.messageId = messageId
        self.kind = kind
        self.name = name
        self.format = format
        self.size = size
        self.width = width
        self.height = height
        self.path = path
    }

    public var isImage: Bool { kind == AttachmentKind.image }
    /// The bytes are on disk (an empty path means the write failed or the file is gone).
    public var hasBytes: Bool { !path.isEmpty }

    /// Rows keyed by their message. The app keeps one attachment per message today; should a
    /// message ever carry more, the first row wins.
    public static func byMessageId(_ rows: [Attachment]) -> [UUID: Attachment] {
        Dictionary(rows.map { ($0.messageId, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

public enum AttachmentKind {
    public static let image = "image"
    public static let file = "file"
}
