import Testing
import Foundation
@testable import ReTiCaMsgrCore

private let reportPeer = String(repeating: "ab", count: 16)
private let reportT0 = Date(timeIntervalSince1970: 1_700_000_000)

private func reportUUID(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
}

private func inbound(_ n: Int, _ body: String, at seconds: TimeInterval) -> Message {
    Message(id: reportUUID(n), peerHex: reportPeer, isOutgoing: false, body: body,
            timestamp: Date(timeIntervalSince1970: seconds), status: MessageStatus.received,
            validated: true, messageHash: String(repeating: "0", count: 64))
}

@Test func reportDraftCarriesAddressNameSubjectAndRecipient() {
    let draft = ReportDraft.compose(peerHex: reportPeer, announcedName: "Mallory",
                                    messages: [inbound(1, "hi", at: 1_700_000_000)],
                                    attachmentNames: [:], composedAt: reportT0)
    #expect(draft.id == reportPeer)
    #expect(draft.recipient == SupportContact.reportAddress)
    #expect(draft.subject == "Report: \(shortHexForReport(reportPeer))")
    #expect(draft.body.contains("Reported address: \(reportPeer)"))
    #expect(draft.body.contains("Announced name: Mallory"))
    #expect(draft.body.contains("[2023-11-14T22:13:20Z] hi"))
    #expect(draft.body.contains("composed by the app"))
}

@Test func reportDraftNoNameSaysSo() {
    let draft = ReportDraft.compose(peerHex: reportPeer, announcedName: nil, messages: [],
                                    attachmentNames: [:], composedAt: reportT0)
    #expect(draft.body.contains("Announced name: (none)"))
}

@Test func reportDraftNoMessagesStillHasABody() {
    let draft = ReportDraft.compose(peerHex: reportPeer, announcedName: nil, messages: [],
                                    attachmentNames: [:], composedAt: reportT0)
    #expect(draft.body.contains("Reported address: \(reportPeer)"))
    #expect(draft.body.contains("(no messages stored)"))
}

@Test func reportDraftNewestFirstAndCapped() {
    let rows = (0..<25).map { inbound($0, "m\($0)", at: 1_700_000_000 + Double($0)) }.shuffled()
    let draft = ReportDraft.compose(peerHex: reportPeer, announcedName: nil, messages: rows,
                                    attachmentNames: [:], composedAt: reportT0)
    let lines = draft.body.split(separator: "\n").filter { $0.hasPrefix("[") }
    #expect(lines.count == ReportDraft.maxMessages)
    #expect(lines.first?.hasSuffix(" m24") == true)
    #expect(lines.last?.hasSuffix(" m5") == true)
    #expect(!draft.body.contains(" m4\n"))
}

@Test func reportDraftListsAttachmentsByNameOnly() {
    let row = inbound(1, "", at: 1_700_000_000)
    let draft = ReportDraft.compose(peerHex: reportPeer, announcedName: nil, messages: [row],
                                    attachmentNames: [row.id: "photo.jpg"], composedAt: reportT0)
    #expect(draft.body.contains("[2023-11-14T22:13:20Z] (attachment: photo.jpg)"))
}

@Test func reportDraftSkipsOutgoingRows() {
    var mine = inbound(1, "mine", at: 1_700_000_000)
    mine.isOutgoing = true
    let draft = ReportDraft.compose(peerHex: reportPeer, announcedName: nil,
                                    messages: [mine, inbound(2, "theirs", at: 1_700_000_001)],
                                    attachmentNames: [:], composedAt: reportT0)
    #expect(draft.body.contains(" theirs"))
    #expect(!draft.body.contains(" mine"))
}
