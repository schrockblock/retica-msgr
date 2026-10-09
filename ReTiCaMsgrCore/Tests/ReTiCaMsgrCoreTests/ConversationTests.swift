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
