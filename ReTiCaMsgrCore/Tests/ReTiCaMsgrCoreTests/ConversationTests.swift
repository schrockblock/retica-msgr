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
