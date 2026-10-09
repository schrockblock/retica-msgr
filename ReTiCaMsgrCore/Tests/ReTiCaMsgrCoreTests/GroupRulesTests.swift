import Testing
import Foundation
@testable import ReTiCaMsgrCore

private let creator = String(repeating: "c", count: 32)
private let other = String(repeating: "d", count: 32)
private let me = String(repeating: "e", count: 32)
private let groupHex = String(repeating: "1a", count: 16)
private let messageId = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!

private func stored(revision: Int, state: String = GroupState.active) -> ChatGroup {
    ChatGroup(groupHex: groupHex, name: "g", creatorHex: creator, revision: revision, state: state,
              updatedAt: Date(timeIntervalSince1970: 1700000000))
}

private func delivery(_ member: String, _ status: String) -> GroupDelivery {
    GroupDelivery(messageId: messageId, memberHex: member, messageHash: status == GroupDeliveryStatus.waiting ? nil : "h",
                  status: status, storedAt: nil, deliveredAt: nil, failedAt: nil)
}

/// Spec §1 receive rules: the first roster for an id establishes its creator, later ones must come
/// from that creator with a strictly higher revision, and a dissolved group never revives.
@Test func groupRulesRosterAppliesOnlyFromCreatorWithHigherRevision() {
    #expect(GroupRoster.applies(revision: 1, from: other, to: nil) == true)
    #expect(GroupRoster.applies(revision: 2, from: creator, to: stored(revision: 1)) == true)
    #expect(GroupRoster.applies(revision: 1, from: creator, to: stored(revision: 1)) == false)
    #expect(GroupRoster.applies(revision: 0, from: creator, to: stored(revision: 1)) == false)
    #expect(GroupRoster.applies(revision: 9, from: other, to: stored(revision: 1)) == false)
    #expect(GroupRoster.applies(revision: 9, from: creator, to: stored(revision: 1, state: GroupState.dissolved)) == false)
    #expect(GroupRoster.applies(revision: 9, from: creator, to: stored(revision: 1, state: GroupState.left)) == true)
}

@Test func groupRulesDiffYieldsAddedRemovedRenamedAndDissolved() {
    let diff = GroupRoster.diff(oldMembers: [creator, me, other], oldName: "g",
                                newMembers: [me, creator, "ff" + String(repeating: "0", count: 30)], newName: "G2")
    #expect(diff == GroupRoster.Diff(added: ["ff" + String(repeating: "0", count: 30)], removed: [other], renamed: "G2", dissolved: false))
    let same = GroupRoster.diff(oldMembers: [me, creator], oldName: "g", newMembers: [creator, me], newName: "g")
    #expect(same == GroupRoster.Diff(added: [], removed: [], renamed: nil, dissolved: false))
    let gone = GroupRoster.diff(oldMembers: [me, creator], oldName: "g", newMembers: [], newName: "g")
    #expect(gone == GroupRoster.Diff(added: [], removed: [creator, me], renamed: nil, dissolved: true))
    // Sorted output, whatever order the inputs came in.
    let two = GroupRoster.diff(oldMembers: [], oldName: "g", newMembers: [other, creator], newName: "g")
    #expect(two.added == [creator, other])
}

/// Amendment A8: sending beats everything, then delivered, stored, failed, else sent.
@Test func groupRulesDerivedStatusFollowsTheAmendmentOrder() {
    let d = MessageStatus.delivered, s = MessageStatus.propagated, f = MessageStatus.failed
    let c = MessageStatus.cancelled, g = MessageStatus.sending, w = GroupDeliveryStatus.waiting
    #expect(GroupRoster.derivedStatus([]) == MessageStatus.sent)
    #expect(GroupRoster.derivedStatus([delivery(creator, d), delivery(other, w)]) == MessageStatus.sending)
    #expect(GroupRoster.derivedStatus([delivery(creator, f), delivery(other, g)]) == MessageStatus.sending)
    #expect(GroupRoster.derivedStatus([delivery(creator, d), delivery(other, d)]) == MessageStatus.delivered)
    #expect(GroupRoster.derivedStatus([delivery(creator, d), delivery(other, s)]) == MessageStatus.propagated)
    #expect(GroupRoster.derivedStatus([delivery(creator, s)]) == MessageStatus.propagated)
    #expect(GroupRoster.derivedStatus([delivery(creator, f), delivery(other, c)]) == MessageStatus.failed)
    #expect(GroupRoster.derivedStatus([delivery(creator, d), delivery(other, f)]) == MessageStatus.sent)
    #expect(GroupRoster.derivedStatus([delivery(creator, MessageStatus.sent), delivery(other, d)]) == MessageStatus.sent)
}

/// Spec §4: "Delivered to d of n" while partial, else the derived status word.
@Test func groupRulesStatusLabelCountsDeliveries() {
    let d = MessageStatus.delivered, f = MessageStatus.failed, g = MessageStatus.sending
    #expect(GroupRoster.statusLabel([]) == "sent")
    #expect(GroupRoster.statusLabel([delivery(creator, g), delivery(other, g)]) == "sending")
    #expect(GroupRoster.statusLabel([delivery(creator, d), delivery(other, g)]) == "Delivered to 1 of 2")
    #expect(GroupRoster.statusLabel([delivery(creator, d), delivery(other, f)]) == "Delivered to 1 of 2")
    #expect(GroupRoster.statusLabel([delivery(creator, d), delivery(other, d)]) == "delivered")
    #expect(GroupRoster.statusLabel([delivery(creator, f), delivery(other, f)]) == "failed")
}

@Test func groupRulesEventLinesReadAsSpecified() {
    #expect(GroupEventText.you == "You")
    #expect(GroupEventText.fallbackName(String(repeating: "ab", count: 16)) == "abababab")
    #expect(GroupEventText.created(name: "Mutual Aid") == "You created the group Mutual Aid")
    #expect(GroupEventText.invited(by: "Ada", name: "Mutual Aid") == "Ada invited you to the group Mutual Aid")
    #expect(GroupEventText.added(by: "Ada", who: "Bob") == "Ada added Bob")
    #expect(GroupEventText.added(by: "You", who: "Bob, Cy") == "You added Bob, Cy")
    #expect(GroupEventText.removed(by: "Ada", who: "Bob") == "Ada removed Bob")
    #expect(GroupEventText.removedYou(by: "Ada") == "Ada removed you from the group")
    #expect(GroupEventText.renamed(by: "Ada", to: "Block 4") == "Ada renamed the group to Block 4")
    #expect(GroupEventText.left(who: "Bob") == "Bob left the group")
    #expect(GroupEventText.left(who: "You") == "You left the group")
    #expect(GroupEventText.declined() == "You declined the invitation")
    #expect(GroupEventText.deleted(by: "Ada") == "Ada deleted the group")
}

/// Amendment A4: the bodies other clients see.
@Test func groupRulesWireBodiesNameTheAppAndGroup() {
    #expect(GroupEventText.rosterBody(inviter: "Ada", name: "Mutual Aid") == "Ada invited you to the group Mutual Aid in ReTiCaMsgr")
    #expect(GroupEventText.leaveBody(who: "Bob", name: "Mutual Aid") == "Bob left the group Mutual Aid")
    #expect(GroupEventText.deleteBody(who: "Ada", name: "Mutual Aid") == "Ada deleted the group Mutual Aid")
    #expect(GroupEventText.caveat == "Members on other apps see posts as separate direct messages and cannot reply to the group.")
}
