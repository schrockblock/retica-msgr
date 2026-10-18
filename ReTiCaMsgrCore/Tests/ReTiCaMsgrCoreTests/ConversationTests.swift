import Testing
import Foundation
@testable import ReTiCaMsgrCore

@Test func conversationListKeepsNewestPerPeerMostRecentFirst() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = Date(timeIntervalSince1970: 2000)
    let t2 = Date(timeIntervalSince1970: 3000)
    func msg(_ peer: String, _ body: String, _ ts: Date) -> Message {
        Message(id: UUID(), peerHex: peer, isOutgoing: true, body: body,
                timestamp: ts, status: MessageStatus.sent, validated: false, messageHash: "")
    }
    let messages = [
        msg("aa", "a-old", t0),
        msg("aa", "a-new", t2),
        msg("bb", "b-mid", t1),
    ]
    let convos = Conversation.list(from: messages)
    #expect(convos.count == 2)
    #expect(convos[0].peerHex == "aa")        // t2 is newest overall
    #expect(convos[0].lastBody == "a-new")    // newest row for aa, not a-old
    #expect(convos[1].peerHex == "bb")
    #expect(convos[1].lastTimestamp == t1)
}

// MARK: - Group chats (spec 2026-10-09 §2)

/// Group rows collapse by group id with the group's name as title, one-to-one rows by peer as
/// before, and the newest row wins inside each.
@Test func groupConvListCollapsesByGroupAndCarriesTitle() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = Date(timeIntervalSince1970: 2000)
    let t2 = Date(timeIntervalSince1970: 3000)
    let g = String(repeating: "1a", count: 16)
    func row(_ peer: String, _ body: String, _ ts: Date, group: String? = nil) -> Message {
        Message(id: UUID(), peerHex: peer, isOutgoing: false, body: body, timestamp: ts,
                status: MessageStatus.received, validated: true, messageHash: "", groupHex: group)
    }
    let groups = [g: ChatGroup(groupHex: g, name: "Mutual Aid", creatorHex: "cc", revision: 1,
                               state: GroupState.invited, updatedAt: t0)]
    let convos = Conversation.list(from: [
        row("aa", "from aa", t1),
        row("aa", "aa in group", t0, group: g),
        row("bb", "bb in group", t2, group: g),
    ], groups: groups)
    #expect(convos.count == 2)
    #expect(convos[0].peerHex == g)
    #expect(convos[0].kind == .group)
    #expect(convos[0].title == "Mutual Aid")
    #expect(convos[0].groupState == "invited")
    #expect(convos[0].lastBody == "bb in group")
    #expect(convos[1].peerHex == "aa")
    #expect(convos[1].kind == .peer)
    #expect(convos[1].title == nil)
    #expect(convos[1].lastBody == "from aa")
    // A group row whose group is unknown still lists, under a placeholder title.
    let orphan = Conversation.list(from: [row("aa", "x", t0, group: "ff")])
    #expect(orphan.first?.title == "Group")
}

// MARK: - Drafts

/// A row with a draft previews it; one without keeps its last message; whitespace is no draft.
@Test func applyingDraftsPreviewsTheDraftOnItsRow() {
    let a = String(repeating: "a", count: 32)
    let b = String(repeating: "b", count: 32)
    let c = String(repeating: "c", count: 32)
    let t = Date(timeIntervalSince1970: 1000)
    let rows = [
        Conversation(peerHex: a, lastBody: "last from a", lastTimestamp: t.addingTimeInterval(2)),
        Conversation(peerHex: b, lastBody: "last from b", lastTimestamp: t.addingTimeInterval(1)),
        Conversation(peerHex: c, lastBody: "last from c", lastTimestamp: t),
    ]
    let shown = Conversation.applyingDrafts(rows, [
        a: ConversationDraft(text: "unsent", updatedAt: t),
        c: ConversationDraft(text: "  \n", updatedAt: t),
    ])
    #expect(shown.map(\.peerHex) == [a, b, c])
    #expect(shown.map(\.preview) == ["Draft: unsent", "last from b", "last from c"])
}

/// A peer with only a draft gets its own row, dated by the draft; a group's draft or an invalid
/// key does not.
@Test func applyingDraftsAddsADraftOnlyPeerRow() {
    let a = String(repeating: "a", count: 32)
    let fresh = String(repeating: "d", count: 32)
    let group = String(repeating: "9", count: 32)
    let t = Date(timeIntervalSince1970: 1000)
    let rows = [Conversation(peerHex: a, lastBody: "old", lastTimestamp: t)]
    let shown = Conversation.applyingDrafts(rows, [
        fresh: ConversationDraft(text: "hello?", updatedAt: t.addingTimeInterval(5)),
        group: ConversationDraft(text: "group text", updatedAt: t.addingTimeInterval(9), isGroup: true),
        "zz": ConversationDraft(text: "bad key", updatedAt: t.addingTimeInterval(9)),
    ])
    #expect(shown.map(\.peerHex) == [fresh, a])
    #expect(shown.first?.kind == .peer)
    #expect(shown.first?.preview == "Draft: hello?")
    #expect(shown.first?.lastTimestamp == t.addingTimeInterval(5))
}
