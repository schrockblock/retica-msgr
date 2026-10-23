import Testing
import Foundation
@testable import ReTiCaMsgrCore
import struct ReTiCaMsgrCore.Attachment

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1700000000)          // 2023-11-14 22:13:20 UTC
private let me = String(repeating: "e", count: 32)
private let memberC = String(repeating: "c", count: 32)
private let memberD = String(repeating: "d", count: 32)
private let groupHex = String(repeating: "1a", count: 16)
private let postId = String(repeating: "5e", count: 16)
private let hashC = String(repeating: "a1", count: 32)

private func post(outgoing: Bool, peer: String) -> Message {
    Message(id: UUID(uuidString: "00000000-0000-0000-0000-000000000060")!, peerHex: peer, isOutgoing: outgoing,
            body: "sandbags at 6", timestamp: t0, status: MessageStatus.sending, validated: !outgoing,
            messageHash: postId, senderTimestamp: t0, sentViaPropagation: false, wireSize: nil,
            titleSize: 10, contentSize: 13, fieldKeys: "0xfd", groupHex: groupHex, groupPostId: postId)
}

/// Spec §4: a Members section after the others, one row per member sorted by address, naming
/// announced members, with the status and first proof time, and the copy's hash to copy.
@Test func groupInfoMembersSectionListsEachDelivery() {
    let m = post(outgoing: true, peer: me)
    let deliveries = [
        GroupDelivery(messageId: m.id, memberHex: memberD, messageHash: nil, status: GroupDeliveryStatus.waiting,
                      storedAt: nil, deliveredAt: nil, failedAt: nil),
        GroupDelivery(messageId: m.id, memberHex: memberC, messageHash: hashC, status: MessageStatus.delivered,
                      storedAt: nil, deliveredAt: t0.addingTimeInterval(81), failedAt: nil),
    ]
    let sections = MessageInfo.sections(for: m, deliveries: deliveries, memberNames: [memberC: "Cy"], timeZone: utc)
    #expect(sections.map(\.title) == ["Timeline", "Delivery", "Identity", "Payload", "Members"])
    #expect(sections[4].rows == [
        MessageInfo.Row(label: "Cy", display: "Delivered 22:14:41", copy: hashC),
        MessageInfo.Row(label: "dddd…dddd", display: "Waiting", copy: ""),
    ])
}

@Test func groupInfoNoDeliveriesNoMembersSection() {
    let sections = MessageInfo.sections(for: post(outgoing: false, peer: memberC), timeZone: utc)
    #expect(sections.map(\.title) == ["Timeline", "Delivery", "Identity", "Payload"])
    #expect(MessageInfo.sections(for: post(outgoing: true, peer: me), deliveries: [], timeZone: utc).count == 4)
}

/// In a group the quoted original is found by its post id (amendment A2) and labelled with its
/// own sender's name; a sender with no name falls back to the thread name, then "Them".
@Test func groupInfoReplyPreviewUsesSenderNames() {
    let original = Message(id: UUID(), peerHex: memberC, isOutgoing: false, body: "sandbags at 6", timestamp: t0,
                           status: MessageStatus.received, validated: true, messageHash: postId,
                           groupHex: groupHex, groupPostId: postId)
    let reply = Message(id: UUID(), peerHex: me, isOutgoing: true, body: "yes", timestamp: t0.addingTimeInterval(1),
                        status: MessageStatus.sending, validated: false, messageHash: String(repeating: "6f", count: 16),
                        replyToHash: postId, replyQuote: "sandbags at 6", groupHex: groupHex,
                        groupPostId: String(repeating: "6f", count: 16))
    let named = ReplyPreview.resolve(for: reply, in: [original, reply], peerName: nil, names: [memberC: "Cy"])
    #expect(named == ReplyPreview.Resolved(senderLabel: "Cy", text: "sandbags at 6", originalID: original.id))
    let unnamed = ReplyPreview.resolve(for: reply, in: [original, reply], peerName: nil, names: [memberD: "Dee"])
    #expect(unnamed?.senderLabel == "Them")
    let mine = Message(id: UUID(), peerHex: me, isOutgoing: true, body: "mine", timestamp: t0,
                       status: MessageStatus.sent, validated: false, messageHash: String(repeating: "7a", count: 16),
                       groupHex: groupHex, groupPostId: String(repeating: "7a", count: 16))
    var replyToMine = reply
    replyToMine.replyToHash = String(repeating: "7a", count: 16)
    #expect(ReplyPreview.resolve(for: replyToMine, in: [mine, replyToMine], peerName: nil, names: [me: "Ada"])?.senderLabel == "You")
    // One-to-one threads are unchanged: the peer's name labels the original.
    let direct = Message(id: UUID(), peerHex: memberC, isOutgoing: false, body: "hi", timestamp: t0,
                         status: MessageStatus.received, validated: true, messageHash: String(repeating: "9", count: 64))
    var directReply = reply
    directReply.replyToHash = String(repeating: "9", count: 64)
    #expect(ReplyPreview.resolve(for: directReply, in: [direct, directReply], peerName: "Cy")?.senderLabel == "Cy")
}
