import Testing
import Foundation
@testable import ReTiCaMsgrCore

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1700000000)          // 2023-11-14 22:13:20 UTC
private let hash64 = "a1b2" + String(repeating: "0", count: 56) + "c3d4"
private let peer32 = "0123456789abcdef0123456789abcdef"

private func info(_ m: Message) -> [MessageInfo.Section] { MessageInfo.sections(for: m, timeZone: utc) }

private func missingRow(_ label: String) -> MessageInfo.Row {
    MessageInfo.Row(label: label, display: "—", copy: "")
}

@Test func infoSectionsOutgoingWithAllMilestones() {
    let m = Message(
        id: UUID(), peerHex: peer32, isOutgoing: true, body: "hi", timestamp: t0,
        status: MessageStatus.delivered, validated: false, messageHash: hash64,
        senderTimestamp: t0, sentViaPropagation: true,
        storedAt: t0.addingTimeInterval(4), deliveredAt: t0.addingTimeInterval(81),
        failedAt: t0.addingTimeInterval(3780),
        wireSize: 412, titleSize: 0, contentSize: 2, fieldKeys: ""
    )
    #expect(info(m) == [
        MessageInfo.Section(title: "Timeline", rows: [
            MessageInfo.Row(label: "Sent", display: "22:13:20", copy: "2023-11-14T22:13:20.000Z"),
            MessageInfo.Row(label: "Stored on node", display: "22:13:24 (+4s)", copy: "2023-11-14T22:13:24.000Z"),
            MessageInfo.Row(label: "Delivered", display: "22:14:41 (+1m 21s)", copy: "2023-11-14T22:14:41.000Z"),
            MessageInfo.Row(label: "Failed", display: "23:16:20 (+1h 03m)", copy: "2023-11-14T23:16:20.000Z"),
            MessageInfo.Row("Status", "Delivered"),
        ]),
        MessageInfo.Section(title: "Delivery", rows: [MessageInfo.Row("Propagation node copy", "Yes")]),
        MessageInfo.Section(title: "Identity", rows: [
            MessageInfo.Row(label: "Message hash", display: "a1b2…c3d4", copy: hash64),
            MessageInfo.Row(label: "Peer", display: "0123…cdef", copy: peer32),
            MessageInfo.Row("Signature", "n/a"),
        ]),
        MessageInfo.Section(title: "Payload", rows: [
            MessageInfo.Row("Wire size", "412 B"),
            MessageInfo.Row("Title size", "0 B"),
            MessageInfo.Row("Content size", "2 B"),
            MessageInfo.Row("Fields", "None"),
            missingRow("Stamp"),
        ]),
    ])
}

@Test func infoSectionsOutgoingWithOnlySent() {
    let m = Message(
        id: UUID(), peerHex: peer32, isOutgoing: true, body: "hi", timestamp: t0,
        status: MessageStatus.sending, validated: false, messageHash: hash64,
        senderTimestamp: t0, sentViaPropagation: false,
        wireSize: 100, titleSize: 0, contentSize: 2, fieldKeys: ""
    )
    let sections = info(m)
    #expect(sections.map(\.title) == ["Timeline", "Delivery", "Identity", "Payload"])
    #expect(sections[0].rows == [
        MessageInfo.Row(label: "Sent", display: "22:13:20", copy: "2023-11-14T22:13:20.000Z"),
        MessageInfo.Row("Status", "Sending…"),
    ])
    #expect(sections[1].rows == [MessageInfo.Row("Propagation node copy", "No")])
    #expect(sections[2].footer == nil)
}

@Test func infoSectionsIncomingPositiveAndNegativeSkew() {
    let base = Message(
        id: UUID(), peerHex: peer32, isOutgoing: false, body: "yo", timestamp: t0,
        status: MessageStatus.received, validated: true, messageHash: hash64,
        senderTimestamp: t0.addingTimeInterval(-81), arrivalMethod: ArrivalMethod.direct,
        wireSize: 300, titleSize: 0, contentSize: 5, fieldKeys: "0x02,0xfb", stampState: StampState.unchecked
    )
    #expect(info(base) == [
        MessageInfo.Section(title: "Timeline", rows: [
            MessageInfo.Row(label: "Written", display: "22:11:59", copy: "2023-11-14T22:11:59.000Z"),
            MessageInfo.Row(label: "Received", display: "22:13:20", copy: "2023-11-14T22:13:20.000Z"),
            MessageInfo.Row("Skew", "+1m 21s"),
            MessageInfo.Row("Status", "Received"),
        ]),
        MessageInfo.Section(title: "Delivery", rows: [MessageInfo.Row("Arrival", "Direct link")]),
        MessageInfo.Section(title: "Identity", rows: [
            MessageInfo.Row(label: "Message hash", display: "a1b2…c3d4", copy: hash64),
            MessageInfo.Row(label: "Peer", display: "0123…cdef", copy: peer32),
            MessageInfo.Row("Signature", "Validated"),
        ]),
        MessageInfo.Section(title: "Payload", rows: [
            MessageInfo.Row("Wire size", "300 B"),
            MessageInfo.Row("Title size", "0 B"),
            MessageInfo.Row("Content size", "5 B"),
            MessageInfo.Row("Field", "0x02 telemetry"),
            MessageInfo.Row("Field", "0xFB custom type"),
            MessageInfo.Row("Stamp", "Not checked"),
        ]),
    ])
    var ahead = base   // the sender's clock runs 3 s ahead of ours
    ahead.senderTimestamp = t0.addingTimeInterval(3)
    #expect(info(ahead)[0].rows[2] == MessageInfo.Row("Skew", "-3s"))
    #expect(info(ahead)[0].rows[0].display == "22:13:23")
}

/// Review Focus 4: a pre-reactions, pre-Info incoming row with no hash and all metadata nil.
@Test func infoSectionsLegacyIncoming() {
    let m = Message(id: UUID(), peerHex: peer32, isOutgoing: false, body: "old", timestamp: t0,
                    status: MessageStatus.received, validated: false, messageHash: "")
    #expect(info(m) == [
        MessageInfo.Section(title: "Timeline", rows: [
            missingRow("Written"),
            MessageInfo.Row(label: "Received", display: "22:13:20", copy: "2023-11-14T22:13:20.000Z"),
            missingRow("Skew"),
            MessageInfo.Row("Status", "Received"),
        ]),
        MessageInfo.Section(title: "Delivery", rows: [missingRow("Arrival")]),
        MessageInfo.Section(title: "Identity", rows: [
            missingRow("Message hash"),
            MessageInfo.Row(label: "Peer", display: "0123…cdef", copy: peer32),
            MessageInfo.Row("Signature", "Not validated"),
        ], footer: "Some details weren't recorded for messages from before this feature."),
        MessageInfo.Section(title: "Payload", rows: [
            missingRow("Wire size"), missingRow("Title size"), missingRow("Content size"),
            missingRow("Fields"), missingRow("Stamp"),
        ]),
    ])
}

/// Controller ruling P1: the legacy footer keys off `fieldKeys == nil`, not `senderTimestamp ==
/// nil`. Every new row sets `fieldKeys`; a new incoming message can still have `senderTimestamp ==
/// nil` when the sender's clock was rejected (see `MessageMetadata.senderTimestamp`), and that must
/// not resurrect the legacy footer.
@Test func infoSectionsNewMessageWithRejectedSenderClockHasNoLegacyFooter() {
    let m = Message(id: UUID(), peerHex: peer32, isOutgoing: false, body: "yo", timestamp: t0,
                    status: MessageStatus.received, validated: true, messageHash: hash64,
                    senderTimestamp: nil, fieldKeys: "")
    let sections = info(m)
    #expect(sections[2].footer == nil)
    #expect(sections[0].rows[0] == missingRow("Written"))
}

@Test func infoSectionsGapFormats() {
    #expect(MessageInfo.gap(4) == "+4s")
    #expect(MessageInfo.gap(4.9) == "+4s")
    #expect(MessageInfo.gap(0) == "+0s")
    #expect(MessageInfo.gap(-0.4) == "+0s")
    #expect(MessageInfo.gap(-3) == "-3s")
    #expect(MessageInfo.gap(65) == "+1m 05s")
    #expect(MessageInfo.gap(81) == "+1m 21s")
    #expect(MessageInfo.gap(7380) == "+2h 03m")
    #expect(MessageInfo.gap(-7380) == "-2h 03m")
    #expect(MessageInfo.gap(93_600) == "+26h 00m")        // Review Focus 1: big skews stay readable
}

@Test func infoSectionsCrossDayTime() {
    let lateSend = Date(timeIntervalSince1970: 1700006390)   // 2023-11-14 23:59:50 UTC
    let m = Message(id: UUID(), peerHex: peer32, isOutgoing: true, body: "hi", timestamp: lateSend,
                    status: MessageStatus.delivered, validated: false, messageHash: hash64,
                    senderTimestamp: lateSend, deliveredAt: lateSend.addingTimeInterval(40))
    #expect(info(m)[0].rows[1].display == "2023-11-15 00:00:30 (+40s)")
    #expect(info(m)[0].rows[0].display == "23:59:50")
    // The local time zone decides the day and the clock face, not UTC.
    let plus3 = TimeZone(secondsFromGMT: 3 * 3600)!
    #expect(MessageInfo.time(t0, sameDayAs: t0, timeZone: plus3) == "01:13:20")
    #expect(MessageInfo.time(t0, sameDayAs: lateSend.addingTimeInterval(40), timeZone: utc) == "2023-11-14 22:13:20")
}

/// Review Focus 5 plus the spec's full name table (LXMF 1.1.0 `LXMF/LXMF.py`).
@Test func infoSectionsFieldKeyNaming() {
    let names: [(String, String)] = [
        ("0x01", "0x01 embedded LXMs"), ("0x02", "0x02 telemetry"), ("0x03", "0x03 telemetry stream"),
        ("0x04", "0x04 icon appearance"), ("0x05", "0x05 file attachments"), ("0x06", "0x06 image"),
        ("0x07", "0x07 audio"), ("0x08", "0x08 thread"), ("0x09", "0x09 commands"),
        ("0x0a", "0x0A results"), ("0x0b", "0x0B group"), ("0x0c", "0x0C ticket"),
        ("0x0d", "0x0D event"), ("0x0e", "0x0E RNR refs"), ("0x0f", "0x0F renderer"),
        ("0x30", "0x30 reply to"), ("0x31", "0x31 reply quote"), ("0x40", "0x40 reaction"),
        ("0x41", "0x41 comment"), ("0x42", "0x42 continuation"), ("0xfb", "0xFB custom type"),
        ("0xfc", "0xFC custom data"), ("0xfd", "0xFD custom meta"), ("0xfe", "0xFE non-specific"),
        ("0xff", "0xFF debug"),
    ]
    for (token, expected) in names {
        #expect(MessageInfo.fieldDisplay(token) == expected)
    }
    #expect(MessageInfo.fieldRows("0x40,0x2a,0x100,junk") == [
        MessageInfo.Row("Field", "0x40 reaction"),
        MessageInfo.Row("Field", "0x2A"),
        MessageInfo.Row("Field", "0x100"),
        MessageInfo.Row("Field", "junk"),
    ])
    #expect(MessageInfo.fieldRows("") == [MessageInfo.Row("Fields", "None")])
    #expect(MessageInfo.fieldRows(nil) == [missingRow("Fields")])
}

@Test func infoSectionsHashTruncationAndCopy() {
    #expect(MessageInfo.hashRow("Peer", peer32) == MessageInfo.Row(label: "Peer", display: "0123…cdef", copy: peer32))
    #expect(MessageInfo.shortHash(hash64) == "a1b2…c3d4")
    #expect(MessageInfo.shortHash("abcdefghi") == "abcdefghi")       // 9 chars: nothing to hide
    #expect(MessageInfo.shortHash("abcdefghij") == "abcd…ghij")
}

// MARK: - Disappearing messages (spec 2026-10-05 §4 Info sheet)

private func expiryInfoMessage(expirySeconds: Int?, expiresAt: Date?) -> Message {
    Message(id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            peerHex: String(repeating: "a", count: 32), isOutgoing: true, body: "x",
            timestamp: Date(timeIntervalSince1970: 1700000000), status: MessageStatus.sent, validated: false,
            messageHash: String(repeating: "ab", count: 32), fieldKeys: "0xfd",
            expirySeconds: expirySeconds, expiresAt: expiresAt)
}

private func expiryInfoTimeline(_ m: Message) -> [MessageInfo.Row] {
    MessageInfo.sections(for: m, timeZone: TimeZone(identifier: "UTC")!).first { $0.title == "Timeline" }!.rows
}

/// A stamped row shows when it expires (same-day short form, ISO copy). The 0xFD field is named.
@Test func expiryInfoStampedRowShowsExpiresTime() {
    let rows = expiryInfoTimeline(expiryInfoMessage(expirySeconds: 300, expiresAt: Date(timeIntervalSince1970: 1700000300)))
    let expires = rows.first { $0.label == "Expires" }
    #expect(expires?.display == "22:18:20")
    #expect(expires?.copy == "2023-11-14T22:18:20.000Z")
    #expect(rows.contains { $0.label == "Disappears after" } == false)
    let payload = MessageInfo.sections(for: expiryInfoMessage(expirySeconds: 300, expiresAt: nil)).first { $0.title == "Payload" }!
    #expect(payload.rows.contains(MessageInfo.Row("Field", "0xFD custom meta")))
}

/// A received row that carries a duration but was not viewed yet shows the duration instead.
@Test func expiryInfoUnstampedRowShowsDuration() {
    let rows = expiryInfoTimeline(expiryInfoMessage(expirySeconds: 86_400, expiresAt: nil))
    #expect(rows.contains(MessageInfo.Row("Disappears after", "1 day")))
    #expect(rows.contains { $0.label == "Expires" } == false)
}

@Test func expiryInfoOrdinaryRowHasNeitherRow() {
    let rows = expiryInfoTimeline(expiryInfoMessage(expirySeconds: nil, expiresAt: nil))
    #expect(rows.contains { $0.label == "Expires" || $0.label == "Disappears after" } == false)
}
