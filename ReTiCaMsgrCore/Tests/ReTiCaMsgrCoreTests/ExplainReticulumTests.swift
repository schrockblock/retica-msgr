import Testing
import Foundation
@testable import ReTiCaMsgrCore

// Plain-language explanations of Reticulum and the "Not sent" label (spec 2026-10-22). Each test
// names the mutation of the code under test that it must catch.

private let t0 = Date(timeIntervalSince1970: 1700000000)

/// Mutation: map failed back to "Failed".
@Test func failedReadsNotSent() {
    #expect(MessageStatusLabel.text(for: MessageStatus.failed) == "Not sent")
}

/// Mutation: drop a stage topic's term sentence (e.g. connecting's).
@Test func stageExplainersNameTheReticulumTerm() {
    #expect(ReticulumExplainer.explainer(for: .connecting).body.hasSuffix("Reticulum calls this link."))
    #expect(ReticulumExplainer.explainer(for: .lookingForThem).body.hasSuffix("Reticulum calls this path request."))
    #expect(ReticulumExplainer.explainer(for: .leavingForPickup).body.hasSuffix("Reticulum calls this propagation node."))
}

/// Mutation: a title containing a count, or an empty body, for any topic.
@Test func everyTopicHasTitleBodyAndHTTPSLink() {
    for topic in ExplainerTopic.allCases {
        let e = ReticulumExplainer.explainer(for: topic)
        #expect(!e.title.isEmpty, "\(topic) title")
        #expect(!e.body.isEmpty, "\(topic) body")
        #expect(e.learnMoreURL.scheme == "https", "\(topic) link")
        #expect(e.title.rangeOfCharacter(from: .decimalDigits) == nil, "\(topic) title has a count")
    }
}

/// Mutation: the stored body states the alert as fact ("They've been alerted.").
@Test func storedNeverClaimsTheyWereNotified() {
    let body = ReticulumExplainer.explainer(for: .storedForPickup).body
    #expect(body.contains("If they have notifications on"))
}

/// Mutation: GroupRoster.statusLabel returns the raw derived status again.
@Test func groupLabelUsesPlainWords() {
    let delivered = GroupDelivery(messageId: UUID(), memberHex: String(repeating: "d", count: 32), messageHash: "h",
                                  status: MessageStatus.delivered, storedAt: nil, deliveredAt: nil, failedAt: nil)
    #expect(GroupRoster.statusLabel([delivered]) == "Delivered")
}

/// Mutation: the Info sheet's Members rows show the raw status again (final review I2).
@Test func groupInfoMembersUsePlainWords() {
    let failed = GroupDelivery(messageId: UUID(), memberHex: String(repeating: "d", count: 32), messageHash: "h",
                               status: MessageStatus.failed, storedAt: nil, deliveredAt: nil, failedAt: nil)
    let section = MessageInfo.members([failed], names: [:], sameDayAs: t0, TimeZone(identifier: "UTC")!)
    #expect(section.rows.map(\.display) == ["Not sent"])
}

/// Mutation: the Info timeline's failure milestone back to "Failed".
@Test func infoTimelineSaysNotSent() {
    let m = Message(
        id: UUID(), peerHex: String(repeating: "0", count: 32), isOutgoing: true, body: "hi", timestamp: t0,
        status: MessageStatus.failed, validated: false, messageHash: String(repeating: "a", count: 64),
        failedAt: t0.addingTimeInterval(60)
    )
    let timeline = MessageInfo.sections(for: m, timeZone: TimeZone(identifier: "UTC")!).first
    #expect(timeline?.rows.contains { $0.label == "Not sent" } == true)
    #expect(timeline?.rows.contains { $0.label == "Failed" } == false)
}
