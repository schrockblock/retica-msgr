import Foundation

/// What stands in for an attachment where only text fits: reply quotes and the conversation
/// list's preview (spec 2026-09-28 §4).
public enum AttachmentPlaceholder {
    public static let photo = "📷 Photo"

    public static func text(for attachment: Attachment) -> String {
        attachment.isImage ? photo : "📎 \(attachment.name)"
    }

    /// The body when it says something, else the attachment's placeholder, else the body as is.
    public static func preview(body: String, attachment: Attachment?) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return body }
        guard let attachment else { return body }
        return text(for: attachment)
    }
}
