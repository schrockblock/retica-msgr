import Testing
import Foundation
import ReTiCA
import ReTiCANode
@testable import ReTiCaMsgrCore

private let peer = String(repeating: "ab", count: 16)
private let originalHash = String(repeating: "a1", count: 32)

private func message(_ n: Int, outgoing: Bool, body: String, hash: String = "",
                     replyTo: String? = nil, quote: String? = nil) -> Message {
    Message(id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!,
            peerHex: peer, isOutgoing: outgoing, body: body,
            timestamp: Date(timeIntervalSince1970: 1700000000 + Double(n)),
            status: outgoing ? MessageStatus.sent : MessageStatus.received,
            validated: !outgoing, messageHash: hash, replyToHash: replyTo, replyQuote: quote)
}

@Test func replyPreviewNotAReplyIsNil() {
    // A hashless legacy row is in the thread, so a resolver that looked up a missing replyToHash
    // as "" would find it.
    let legacy = message(1, outgoing: false, body: "legacy")
    let plain = message(2, outgoing: true, body: "plain", hash: originalHash)
    #expect(ReplyPreview.resolve(for: plain, in: [legacy, plain], peerName: "Alice") == nil)
}

@Test func replyPreviewOriginalOutgoingIsYou() {
    let original = message(1, outgoing: true, body: "  my original \n", hash: originalHash)
    let reply = message(2, outgoing: false, body: "ok", hash: String(repeating: "b2", count: 32),
                        replyTo: originalHash, quote: "stale quote")
    // The found original wins over the carried quote, and is trimmed like one.
    #expect(ReplyPreview.resolve(for: reply, in: [original, reply], peerName: "Alice")
            == ReplyPreview.Resolved(senderLabel: "You", text: "my original", originalID: original.id))
}

@Test func replyPreviewOriginalIncomingUsesPeerNameOrThem() {
    let original = message(1, outgoing: false, body: "their words", hash: originalHash)
    let reply = message(2, outgoing: true, body: "mine", hash: String(repeating: "b2", count: 32),
                        replyTo: originalHash, quote: "their words")
    #expect(ReplyPreview.resolve(for: reply, in: [original, reply], peerName: "Alice")
            == ReplyPreview.Resolved(senderLabel: "Alice", text: "their words", originalID: original.id))
    #expect(ReplyPreview.resolve(for: reply, in: [original, reply], peerName: nil)
            == ReplyPreview.Resolved(senderLabel: "Them", text: "their words", originalID: original.id))
}

/// P1 controller ruling: the original IS found in the thread, but its trimmed body is empty, so
/// the quote text falls back to "unavailable" while `originalID` still points at it — the quote
/// block keeps scrolling to the (blank) original.
@Test func replyPreviewBlankOriginalShowsUnavailableButStillScrolls() {
    let original = message(1, outgoing: true, body: "   \n  ", hash: originalHash)
    let reply = message(2, outgoing: false, body: "ok", hash: String(repeating: "b2", count: 32),
                        replyTo: originalHash, quote: "stale quote")
    let resolved = ReplyPreview.resolve(for: reply, in: [original, reply], peerName: "Alice")
    #expect(resolved?.text == ReplyPreview.unavailable)
    #expect(resolved?.originalID == original.id)
}

@Test func replyPreviewQuoteOnlyUsesReplyDirection() {
    // An incoming reply quotes one of ours, and an outgoing reply quotes one of theirs.
    let incoming = message(1, outgoing: false, body: "re", replyTo: originalHash, quote: "q")
    let outgoing = message(2, outgoing: true, body: "re", replyTo: originalHash, quote: "q")
    #expect(ReplyPreview.resolve(for: incoming, in: [incoming], peerName: "Alice")
            == ReplyPreview.Resolved(senderLabel: "You", text: "q", originalID: nil))
    #expect(ReplyPreview.resolve(for: outgoing, in: [outgoing], peerName: "Alice")
            == ReplyPreview.Resolved(senderLabel: "Alice", text: "q", originalID: nil))
    #expect(ReplyPreview.resolve(for: outgoing, in: [outgoing], peerName: nil)
            == ReplyPreview.Resolved(senderLabel: "Them", text: "q", originalID: nil))
}

@Test func replyPreviewNeitherShowsUnavailable() {
    let incoming = message(1, outgoing: false, body: "re", replyTo: originalHash)
    let outgoing = message(2, outgoing: true, body: "re", replyTo: originalHash)
    #expect(ReplyPreview.resolve(for: incoming, in: [incoming], peerName: nil)
            == ReplyPreview.Resolved(senderLabel: "You", text: "Original message not available", originalID: nil))
    #expect(ReplyPreview.resolve(for: outgoing, in: [outgoing], peerName: nil)
            == ReplyPreview.Resolved(senderLabel: "Them", text: "Original message not available", originalID: nil))
}

/// Review Focus 4. P2 controller ruling: assert ONLY `.text`, so the direction-flip mutation (M4)
/// cannot be what turns this red — only the empty-quote check (M5) can.
@Test func replyPreviewEmptyQuoteCountsAsMissing() {
    let incoming = message(1, outgoing: false, body: "re", replyTo: originalHash, quote: "")
    #expect(ReplyPreview.resolve(for: incoming, in: [incoming], peerName: nil)?.text
            == ReplyPreview.unavailable)
}

/// Review Focus 5.
@MainActor @Test func replyPreviewOpenPeerDisplayNameIsTrimmedAndNeverBlank() {
    let peerHash = Data(repeating: 0xab, count: 16)
    var state = AppFeature.State(identity: Identity())
    #expect(state.openPeerDisplayName == nil)            // no open conversation
    state.openPeerHex = peer
    #expect(state.openPeerDisplayName == nil)            // no announce heard
    state.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: "  Alice \n", stampCost: nil, supportsCompression: false,
        learnedAt: Date(timeIntervalSince1970: 1700000000))
    #expect(state.openPeerDisplayName == "Alice")
    state.node.client.learnedPeers[peerHash]?.displayName = "   "
    #expect(state.openPeerDisplayName == nil)
    state.node.client.learnedPeers[peerHash]?.displayName = nil
    #expect(state.openPeerDisplayName == nil)
}
