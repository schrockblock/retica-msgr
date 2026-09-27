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

// MARK: - Standard FIELD_REACTION (0x40), spec addendum 2026-09-27

/// The shipped-on-2026-09-25 legacy format, built by hand now that `encode` no longer emits it.
private func legacyFields(target: Data, emoji: String) -> [MsgPackValue.IntPair] {
    [
        .init(0xFB, .string("reticamsgr.reaction")),
        .init(0xFC, .map([.init("target", .bin(target)), .init("emoji", .string(emoji))])),
    ]
}

private func standardField(_ payload: MsgPackValue) -> [MsgPackValue.IntPair] {
    [.init(0x40, payload)]
}

private func standardPayload(target: Data, content: Data) -> MsgPackValue {
    .intMap([.init(0x00, .bin(target)), .init(0x01, .bin(content))])
}

@Test func stdReactionEncodeEmitsOnlyTheStandardField() {
    #expect(ReactionWire.fieldReaction == 0x40)
    #expect(ReactionWire.reactionTo == 0x00)
    #expect(ReactionWire.reactionContent == 0x01)
    #expect(ReactionWire.encode(target: target32, emoji: "❤️")
            == standardField(standardPayload(target: target32, content: Data("❤️".utf8))))
}

@Test func stdReactionRoundTripsThroughRealLXMessageIncludingRemoval() throws {
    for emoji in ["❤️", ""] {
        let m = LXMessage.create(
            source: Identity(),
            destinationHash: Data(repeating: 0x11, count: 16),
            timestamp: 1700000000.25,
            title: Data(),
            content: Data(),
            fields: ReactionWire.encode(target: target32, emoji: emoji)
        )
        let back = try #require(LXMessage.unpack(m.packed))
        #expect(back.fields.map(\.key) == [0x40], "emoji \(emoji.isEmpty ? "<removal>" : emoji)")
        #expect(ReactionWire.decode(back.fields) == .reaction(target: target32, emoji: emoji))
    }
}

@Test func stdReactionLegacyFormatStillDecodes() {
    #expect(ReactionWire.decode(legacyFields(target: target32, emoji: "👍"))
            == .reaction(target: target32, emoji: "👍"))
}

@Test func stdReactionStandardWinsWhenBothFormatsPresent() {
    // Legacy first in wire order, so "first field wins" would pick the wrong one.
    let fields = legacyFields(target: target32, emoji: "👍")
        + standardField(standardPayload(target: target32, content: Data("❤️".utf8)))
    #expect(ReactionWire.decode(fields) == .reaction(target: target32, emoji: "❤️"))
}

/// Every malformed shape listed in the spec addendum is dropped (`.malformed`), never a bubble.
@Test func stdReactionMalformedStandardCasesAreDropped() {
    let heart = Data("❤️".utf8)
    let cases: [(String, MsgPackValue)] = [
        ("string-keyed map", .map([.init("to", .bin(target32)), .init("content", .bin(heart))])),
        ("empty map", .map([])),
        ("not a map", .bin(target32)),
        ("0x00 missing", .intMap([.init(0x01, .bin(heart))])),
        ("0x00 not bin", .intMap([.init(0x00, .string("abc")), .init(0x01, .bin(heart))])),
        ("0x00 empty", standardPayload(target: Data(), content: heart)),
        ("0x00 15 bytes", standardPayload(target: Data(repeating: 1, count: 15), content: heart)),
        ("0x00 33 bytes", standardPayload(target: Data(repeating: 1, count: 33), content: heart)),
        ("0x01 missing", .intMap([.init(0x00, .bin(target32))])),
        ("0x01 not bin", .intMap([.init(0x00, .bin(target32)), .init(0x01, .string("❤️"))])),
        ("0x01 over 64 bytes", standardPayload(target: target32,
                                               content: Data(repeating: 0x61, count: ReactionWire.maxEmojiBytes + 1))),
        ("0x01 invalid UTF-8", standardPayload(target: target32, content: Data([0xFF, 0xFE, 0xFD]))),
    ]
    for (name, payload) in cases {
        #expect(ReactionWire.decode(standardField(payload)) == .malformed, "\(name)")
    }
}

@Test func stdReactionBoundaryValuesAreAccepted() {
    for n in [16, 32] {
        let target = Data(repeating: 7, count: n)
        #expect(ReactionWire.decode(standardField(standardPayload(target: target, content: Data("👍".utf8))))
                == .reaction(target: target, emoji: "👍"), "target length \(n)")
    }
    let atLimit = String(repeating: "a", count: ReactionWire.maxEmojiBytes)
    #expect(ReactionWire.decode(standardField(standardPayload(target: target32, content: Data(atLimit.utf8))))
            == .reaction(target: target32, emoji: atLimit))
    #expect(ReactionWire.decode(standardField(standardPayload(target: target32, content: Data())))
            == .reaction(target: target32, emoji: ""))
}

/// Review Focus 2: a mixed-version sender with a broken 0x40 beside a good legacy reaction.
@Test func stdReactionMalformedStandardFallsBackToValidLegacy() {
    let fields = standardField(.intMap([.init(0x00, .bin(Data(repeating: 1, count: 3)))]))
        + legacyFields(target: target32, emoji: "😮")
    #expect(ReactionWire.decode(fields) == .reaction(target: target32, emoji: "😮"))
}
