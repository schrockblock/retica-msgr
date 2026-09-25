import Testing
import Foundation
import ReTiCA
@testable import ReTiCaMsgrCore

private let target32 = Data(repeating: 0xAB, count: 32)

@Test func reactionRoundTripsThroughRealLXMessagePackUnpack() throws {
    let sender = Identity()
    let m = LXMessage.create(
        source: sender,
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data(),
        content: Data(),
        fields: ReactionWire.encode(target: target32, emoji: "❤️")
    )
    let back = try #require(LXMessage.unpack(m.packed))
    #expect(ReactionWire.decode(back.fields) == .reaction(target: target32, emoji: "❤️"))
}

@Test func emptyEmojiRoundTripsAsRemoval() {
    let fields = ReactionWire.encode(target: target32, emoji: "")
    #expect(ReactionWire.decode(fields) == .reaction(target: target32, emoji: ""))
}

@Test func noFieldsIsNotAReaction() {
    #expect(ReactionWire.decode([]) == .notReaction)
}

@Test func otherCustomTypeIsNotAReaction() {
    let fields: [MsgPackValue.IntPair] = [.init(0xFB, .string("someone.else")), .init(0xFC, .map([]))]
    #expect(ReactionWire.decode(fields) == .notReaction)
}

@Test func unrelatedFieldsAreNotAReaction() {
    let fields: [MsgPackValue.IntPair] = [.init(0x04, .array([]))]
    #expect(ReactionWire.decode(fields) == .notReaction)
}

@Test func missingDataIsMalformed() {
    let fields: [MsgPackValue.IntPair] = [.init(0xFB, .string("reticamsgr.reaction"))]
    #expect(ReactionWire.decode(fields) == .malformed)
}

@Test func missingTargetIsMalformed() {
    let fields: [MsgPackValue.IntPair] = [
        .init(0xFB, .string("reticamsgr.reaction")),
        .init(0xFC, .map([.init("emoji", .string("👍"))])),
    ]
    #expect(ReactionWire.decode(fields) == .malformed)
}

@Test func badTargetLengthsAreMalformed() {
    for n in [0, 15, 33] {
        let fields = ReactionWire.encode(target: Data(repeating: 1, count: n), emoji: "👍")
        #expect(ReactionWire.decode(fields) == .malformed, "length \(n)")
    }
    for n in [16, 32] {
        let fields = ReactionWire.encode(target: Data(repeating: 1, count: n), emoji: "👍")
        #expect(ReactionWire.decode(fields) != .malformed, "length \(n)")
    }
}

@Test func nonStringEmojiIsMalformed() {
    let fields: [MsgPackValue.IntPair] = [
        .init(0xFB, .string("reticamsgr.reaction")),
        .init(0xFC, .map([.init("target", .bin(target32)), .init("emoji", .bin(Data([0xF0])))])),
    ]
    #expect(ReactionWire.decode(fields) == .malformed)
}

@Test func oversizedEmojiIsMalformed() {
    let tooLong = String(repeating: "a", count: ReactionWire.maxEmojiBytes + 1)
    #expect(ReactionWire.decode(ReactionWire.encode(target: target32, emoji: tooLong)) == .malformed)
    let atLimit = String(repeating: "a", count: ReactionWire.maxEmojiBytes)
    #expect(ReactionWire.decode(ReactionWire.encode(target: target32, emoji: atLimit))
            == .reaction(target: target32, emoji: atLimit))
}

@Test func quickReactionsAreTheAgreedSix() {
    #expect(QuickReactions.default == ["❤️", "👍", "👎", "😂", "😮", "😢"])
}

// MARK: - Cross-device hash pinning (final-review Fix B)
//
// Reactions target a message by its LXMF hash, so the hash the receiver computes after unpacking
// must equal the sender's `msg.hash`. These tests document (they do not fix) existing ReTiCA
// behaviour — see LXMessage.unpack, which recomputes the hash from the on-wire payload.

@Test func unpackedHashEqualsSenderHash() throws {
    let sender = Identity()
    let m = LXMessage.create(
        source: sender,
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data(),
        content: Data("hello".utf8),
        fields: []
    )
    #expect(LXMessage.unpack(m.packed)?.hash == m.hash)
}

@Test func unpackedHashEqualsSenderHashWithReactionFields() throws {
    let sender = Identity()
    let m = LXMessage.create(
        source: sender,
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data(),
        content: Data(),
        fields: ReactionWire.encode(target: target32, emoji: "❤️")
    )
    #expect(LXMessage.unpack(m.packed)?.hash == m.hash)
}

/// A stamped copy attaches a delivery stamp via `withStamp` without changing `hash`/`signature`
/// (LXMessage.withStamp doc comment). `unpack` must still recompute the same hash from the
/// 4-element payload (the stamp is excluded from the hash, per LXMessage.unpack).
@Test func unpackedHashEqualsSenderHashWithStamp() throws {
    let sender = Identity()
    let m = LXMessage.create(
        source: sender,
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data(),
        content: Data("hello".utf8),
        fields: []
    )
    let stamped = m.withStamp(Data(repeating: 0xFF, count: LXStamper.stampSize))
    #expect(LXMessage.unpack(stamped.packed)?.hash == stamped.hash)
}
