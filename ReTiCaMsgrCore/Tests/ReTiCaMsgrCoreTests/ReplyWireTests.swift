import Testing
import Foundation
import ReTiCA
@testable import ReTiCaMsgrCore

/// Non-uniform bytes, so a reversal or truncation changes the value.
private let originalHash = Data((0..<32).map { UInt8($0) })
private let quoteText = "Hi ☕ there"

/// Reply fields built by hand, so these tests pin the wire shape rather than `encode`.
private func replyFields(replyTo: MsgPackValue?, quote: MsgPackValue?) -> [MsgPackValue.IntPair] {
    var fields: [MsgPackValue.IntPair] = []
    if let replyTo { fields.append(.init(0x30, replyTo)) }
    if let quote { fields.append(.init(0x31, quote)) }
    return fields
}

@Test func replyWireConstantsMatchReferenceLXMF() {
    #expect(ReplyWire.fieldReplyTo == 0x30)
    #expect(ReplyWire.fieldReplyQuote == 0x31)
    #expect(ReplyWire.maxQuoteBytes == 400)
    #expect(ReplyWire.quoteCharacterLimit == 100)
}

/// The expected bytes are reference umsgpack's `packb({0x30: bytes(range(32)), 0x31: "Hi ☕ there".encode()})`,
/// from /tmp/ReTiCaMsgr/reply_fields_reference.py run with the rns env's Python.
@Test func replyWireEncodeMatchesReferenceUmsgpackBytes() throws {
    let expected = try #require(Data(hexString:
        "8230c420000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f31c40c486920e29895207468657265"))
    #expect(MsgPack.encode(.intMap(ReplyWire.encode(replyTo: originalHash, quote: quoteText))) == expected)
}

@Test func replyWireRoundTripsThroughRealLXMessage() throws {
    let m = LXMessage.create(
        source: Identity(),
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data(),
        content: Data("reply text".utf8),
        fields: ReplyWire.encode(replyTo: originalHash, quote: quoteText)
    )
    let back = try #require(LXMessage.unpack(m.packed))
    #expect(back.content == Data("reply text".utf8))
    #expect(back.fields.map(\.key) == [0x30, 0x31])
    let decoded = try #require(ReplyWire.decode(back.fields))
    #expect(decoded.replyTo == originalHash)
    #expect(decoded.quote == quoteText)
}

@Test func replyWireTrimLimitsTo100Characters() {
    let hundred = String(repeating: "a", count: 100)
    #expect(ReplyWire.trimQuote("hello") == "hello")
    #expect(ReplyWire.trimQuote(hundred) == hundred)
    #expect(ReplyWire.trimQuote(hundred + "b") == hundred + "…")
    #expect(ReplyWire.trimQuote(hundred + String(repeating: "c", count: 50)) == hundred + "…")
}

/// Review Focus 4: a blank original trims to "".
@Test func replyWireTrimStripsSurroundingWhitespace() {
    #expect(ReplyWire.trimQuote("  \n see you at 6 \t\n") == "see you at 6")
    #expect(ReplyWire.trimQuote(" \n\t ") == "")
    // Trimming happens before counting: 100 characters plus padding is not cut.
    let hundred = String(repeating: "a", count: 100)
    #expect(ReplyWire.trimQuote("   " + hundred + "\n\n") == hundred)
}

@Test func replyWireTrimDoesNotSplitZWJEmojiAtBoundary() {
    let family = "👨‍👩‍👧‍👦"                                          // 1 Character, 7 scalars
    let text = String(repeating: "a", count: 99) + family + "b"   // the 100th Character is the family
    #expect(text.count == 101)
    #expect(ReplyWire.trimQuote(text) == String(repeating: "a", count: 99) + family + "…")
}

/// Review Focus 1: 100 wide Characters are far more than the 400 bytes `decode` accepts.
@Test func replyWireTrimCapsWideCharactersAt400Bytes() throws {
    let family = "👨‍👩‍👧‍👦"
    #expect(family.utf8.count == 25)
    // 15 families + "…" = 375 + 3 = 378 bytes. A 16th family would make it 403.
    let capped = String(repeating: family, count: 15) + "…"
    // Under the character limit, over the byte limit.
    #expect(ReplyWire.trimQuote(String(repeating: family, count: 20)) == capped)
    // Over both limits.
    #expect(ReplyWire.trimQuote(String(repeating: family, count: 150)) == capped)
    // The capped quote survives our own decoder, so a recipient running this app still sees it.
    let decoded = try #require(ReplyWire.decode(ReplyWire.encode(replyTo: originalHash, quote: capped)))
    #expect(decoded.quote == capped)
}

@Test func replyWireInvalidReplyToIsNotAReply() {
    let quote = MsgPackValue.bin(Data("hi".utf8))
    let cases: [(String, [MsgPackValue.IntPair])] = [
        ("0x31 without 0x30", replyFields(replyTo: nil, quote: quote)),
        ("no fields", []),
        ("0x30 not bin", replyFields(replyTo: .string("abc"), quote: quote)),
        ("0x30 empty", replyFields(replyTo: .bin(Data()), quote: quote)),
        ("0x30 15 bytes", replyFields(replyTo: .bin(Data(repeating: 1, count: 15)), quote: quote)),
        ("0x30 33 bytes", replyFields(replyTo: .bin(Data(repeating: 1, count: 33)), quote: quote)),
    ]
    for (name, fields) in cases {
        #expect(ReplyWire.decode(fields) == nil, "\(name)")
    }
    for n in [16, 32] {
        let replyTo = Data((0..<n).map { UInt8($0) })
        let decoded = ReplyWire.decode(replyFields(replyTo: .bin(replyTo), quote: quote))
        #expect(decoded?.replyTo == replyTo, "length \(n)")
        #expect(decoded?.quote == "hi", "length \(n)")
    }
}

@Test func replyWireInvalidQuoteKeepsTheReply() {
    let replyTo = MsgPackValue.bin(originalHash)
    let cases: [(String, MsgPackValue?)] = [
        ("0x31 missing", nil),
        ("0x31 not bin", .string("hi")),
        ("0x31 401 bytes", .bin(Data(repeating: 0x61, count: 401))),
        ("0x31 invalid UTF-8", .bin(Data([0xFF, 0xFE, 0xFD]))),
    ]
    for (name, quote) in cases {
        let decoded = ReplyWire.decode(replyFields(replyTo: replyTo, quote: quote))
        // `decoded?.replyTo` is nil when decode returned nil, so this also proves the reply was kept.
        #expect(decoded?.replyTo == originalHash, "\(name)")
        #expect(decoded?.quote == nil, "\(name)")
    }
    let atLimit = ReplyWire.decode(replyFields(replyTo: replyTo, quote: .bin(Data(repeating: 0x61, count: 400))))
    #expect(atLimit?.quote == String(repeating: "a", count: 400))
}
