import Testing
import Foundation
@testable import ReTiCAMsgrCore

private func msg(outgoing: Bool, validated: Bool, at ts: TimeInterval) -> Message {
    Message(id: UUID(), peerHex: "aa", isOutgoing: outgoing, body: "hi",
            timestamp: Date(timeIntervalSince1970: ts), status: MessageStatus.sent,
            validated: validated, messageHash: "")
}

@Test func listMarksLatestUnverifiedIncoming() {
    // An older validated message must not mask the newest, unverified one.
    let convos = Conversation.list(from: [
        msg(outgoing: false, validated: true, at: 1000),
        msg(outgoing: false, validated: false, at: 2000),
    ])
    #expect(convos.count == 1)
    #expect(convos[0].lastIsUnverified == true)
}

@Test func listDoesNotMarkValidatedOrOutgoing() {
    let validatedIncoming = Conversation.list(from: [
        msg(outgoing: false, validated: false, at: 1000),
        msg(outgoing: false, validated: true, at: 2000),
    ])
    #expect(validatedIncoming[0].lastIsUnverified == false)

    // Outgoing rows never carry a signature check, so validated is false on them.
    let outgoing = Conversation.list(from: [
        msg(outgoing: true, validated: false, at: 2000),
    ])
    #expect(outgoing[0].lastIsUnverified == false)
}
