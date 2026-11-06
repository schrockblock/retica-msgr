import Testing
import Foundation
import struct ReTiCAMsgrCore.Attachment
@testable import ReTiCAMsgrCore

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1700000000)
private let hash64 = "a1b2" + String(repeating: "0", count: 56) + "c3d4"
private let peer32 = "0123456789abcdef0123456789abcdef"
private let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!

private func outgoing(status: String = MessageStatus.sending, body: String = "", failureReason: String? = nil,
                      propagationRefused: String? = nil) -> Message {
    Message(id: messageID, peerHex: peer32, isOutgoing: true, body: body, timestamp: t0, status: status,
            validated: false, messageHash: hash64, senderTimestamp: t0, sentViaPropagation: true,
            wireSize: 500, titleSize: 0, contentSize: body.utf8.count, fieldKeys: "0x06",
            failureReason: failureReason, propagationRefused: propagationRefused)
}

private func image(path: String = "\(hash64)-out.jpeg") -> Attachment {
    Attachment(id: UUID(), messageId: messageID, kind: AttachmentKind.image, name: "IMG_20231114_221320.jpg",
               format: "jpeg", size: 34_211, width: 1280, height: 853, path: path)
}

private func file(name: String = "notes.pdf", format: String = "pdf") -> Attachment {
    Attachment(id: UUID(), messageId: messageID, kind: AttachmentKind.file, name: name, format: format,
               size: 12_000, width: nil, height: nil, path: "\(hash64)-in.pdf")
}

@Test func attachInfoSectionAppearsForAnImage() {
    let sections = MessageInfo.sections(for: outgoing(), attachment: image(), timeZone: utc)
    #expect(sections.map(\.title) == ["Timeline", "Delivery", "Identity", "Payload", "Attachment"])
    #expect(sections[4] == MessageInfo.Section(title: "Attachment", rows: [
        MessageInfo.Row("Kind", "Image"),
        MessageInfo.Row("Name", "IMG_20231114_221320.jpg"),
        MessageInfo.Row("Format", "JPEG"),
        MessageInfo.Row("Size", "34211 B"),
        MessageInfo.Row("Dimensions", "1280 × 853"),
        MessageInfo.Row("Stored", "Yes"),
    ]))
}

@Test func attachInfoSectionForAFileHasNoDimensionsAndShowsUnavailableBytes() {
    var f = file()
    f.path = ""
    let sections = MessageInfo.sections(for: outgoing(), attachment: f, timeZone: utc)
    #expect(sections[4] == MessageInfo.Section(title: "Attachment", rows: [
        MessageInfo.Row("Kind", "File"),
        MessageInfo.Row("Name", "notes.pdf"),
        MessageInfo.Row("Format", "PDF"),
        MessageInfo.Row("Size", "12000 B"),
        MessageInfo.Row(label: "Dimensions", display: "—", copy: ""),
        MessageInfo.Row("Stored", "No"),
    ]))
    // A file without an extension shows "—" for the format.
    let bare = MessageInfo.sections(for: outgoing(), attachment: file(name: "README", format: ""), timeZone: utc)
    #expect(bare[4].rows[2] == MessageInfo.Row(label: "Format", display: "—", copy: ""))
}

@Test func attachInfoNoAttachmentNoSectionAndNoReasonRows() {
    let sections = MessageInfo.sections(for: outgoing(), timeZone: utc)
    #expect(sections.map(\.title) == ["Timeline", "Delivery", "Identity", "Payload"])
    #expect(sections[0].rows.last == MessageInfo.Row("Status", "Sending…"))
    #expect(sections[1].rows == [MessageInfo.Row("Propagation node copy", "Yes")])
}

@Test func attachInfoFailureReasonAndRefusalRows() {
    let cancelled = MessageInfo.sections(
        for: outgoing(status: MessageStatus.cancelled, failureReason: FailureReason.cancelled,
                      propagationRefused: PropagationRefusal.tooLargeForNode),
        timeZone: utc)
    #expect(Array(cancelled[0].rows.suffix(2)) == [MessageInfo.Row("Status", "Cancelled"), MessageInfo.Row("Reason", "Cancelled")])
    #expect(cancelled[1].rows == [
        MessageInfo.Row("Propagation node copy", "Yes"),
        MessageInfo.Row("Propagation refusal", "Refused: too large for node"),
    ])
    let rejected = MessageInfo.sections(
        for: outgoing(status: MessageStatus.failed, failureReason: FailureReason.rejected), timeZone: utc)
    #expect(rejected[0].rows.last == MessageInfo.Row("Reason", "Rejected by recipient"))
    // An unknown stored reason is shown as-is rather than dropped.
    let odd = MessageInfo.sections(for: outgoing(status: MessageStatus.failed, failureReason: "weird"), timeZone: utc)
    #expect(odd[0].rows.last == MessageInfo.Row("Reason", "weird"))
}

@Test func attachInfoPlaceholderTextAndPreview() {
    #expect(AttachmentPlaceholder.text(for: image()) == "📷 Photo")
    #expect(AttachmentPlaceholder.text(for: file(name: "notes.pdf")) == "📎 notes.pdf")
    #expect(AttachmentPlaceholder.preview(body: "look at this", attachment: image()) == "look at this")
    #expect(AttachmentPlaceholder.preview(body: "", attachment: image()) == "📷 Photo")
    #expect(AttachmentPlaceholder.preview(body: " \n", attachment: file()) == "📎 notes.pdf")
    #expect(AttachmentPlaceholder.preview(body: "", attachment: nil) == "")
    #expect(AttachmentPlaceholder.preview(body: "text", attachment: nil) == "text")
}

@Test func attachInfoConversationPreviewUsesPlaceholder() {
    let withPhoto = outgoing(body: "")
    let older = Message(id: UUID(), peerHex: peer32, isOutgoing: false, body: "earlier", timestamp: t0.addingTimeInterval(-10),
                        status: MessageStatus.received, validated: true, messageHash: "")
    let list = Conversation.list(from: [older, withPhoto], attachments: [withPhoto.id: image()])
    #expect(list.map(\.lastBody) == ["📷 Photo"])
    // Without the attachment map the preview is the (empty) body, as before.
    #expect(Conversation.list(from: [older, withPhoto]).map(\.lastBody) == [""])
    // A file placeholder carries the name.
    let withFile = outgoing(body: "")
    #expect(Conversation.list(from: [withFile], attachments: [withFile.id: file(name: "map.gpx", format: "gpx")])
            .map(\.lastBody) == ["📎 map.gpx"])
}

/// Spec §4: a reply to a photo that is in the thread quotes `📷 Photo`, not "Original message not
/// available" (the photo's body is empty). A file quotes its name. Without the map, as before.
@Test func attachInfoReplyPreviewQuotesAPhotoInTheThread() {
    let photoMessage = Message(id: messageID, peerHex: peer32, isOutgoing: false, body: "", timestamp: t0,
                               status: MessageStatus.received, validated: true, messageHash: hash64)
    // No carried quote, so the text can only come from the original in the thread.
    let reply = Message(id: UUID(uuidString: "00000000-0000-0000-0000-000000000051")!, peerHex: peer32,
                        isOutgoing: true, body: "nice", timestamp: t0.addingTimeInterval(5),
                        status: MessageStatus.sending, validated: false, messageHash: "",
                        replyToHash: hash64)
    let thread = [photoMessage, reply]
    let resolved = ReplyPreview.resolve(for: reply, in: thread, peerName: "Ann",
                                        attachments: [photoMessage.id: image()])
    #expect(resolved == ReplyPreview.Resolved(senderLabel: "Ann", text: "📷 Photo", originalID: photoMessage.id))
    let asFile = ReplyPreview.resolve(for: reply, in: thread, peerName: "Ann",
                                      attachments: [photoMessage.id: file()])
    #expect(asFile?.text == "📎 notes.pdf")
    #expect(ReplyPreview.resolve(for: reply, in: thread, peerName: "Ann")?.text == ReplyPreview.unavailable)
}
