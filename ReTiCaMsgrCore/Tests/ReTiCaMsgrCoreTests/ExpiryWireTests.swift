import Testing
import Foundation
import ReTiCA
@testable import ReTiCaMsgrCore

/// A 0xFD field built by hand, so these tests pin the wire shape rather than `encode`.
private func meta(_ value: MsgPackValue) -> [MsgPackValue.IntPair] { [.init(0xFD, value)] }

@Test func expiryWireConstantsMatchTheSpec() {
    #expect(ExpiryWire.fieldCustomMeta == 0xFD)
    #expect(ExpiryWire.secondsKey == "reticamsgr.expiry")
    #expect(ExpiryWire.changeKey == "reticamsgr.expiry.change")
    #expect(ExpiryWire.maxSeconds == 2_419_200)
}

/// Spec §1: one field, a string-keyed map, the duration as an unsigned integer.
@Test func expiryWireEncodeIsOneMetaFieldWithTheSecondsKey() {
    let fields = ExpiryWire.encode(seconds: 86_400)
    #expect(fields.count == 1)
    #expect(fields[0].key == 0xFD)
    #expect(fields[0].value == .map([.init("reticamsgr.expiry", .uint(86_400))]))
}

/// Amendment A1: a timer-change message adds a boolean flag beside the duration.
@Test func expiryWireEncodeChangeAddsTheFlag() {
    let fields = ExpiryWire.encodeChange(seconds: 0)
    #expect(fields[0].value == .map([
        .init("reticamsgr.expiry", .uint(0)),
        .init("reticamsgr.expiry.change", .bool(true)),
    ]))
    #expect(ExpiryWire.decode(fields) == ExpiryWire.Decoded(seconds: 0, isChange: true))
}

@Test func expiryWireRoundTripsThroughRealLXMessage() throws {
    let m = LXMessage.create(
        source: Identity(),
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data(),
        content: Data("gone soon".utf8),
        fields: ExpiryWire.encode(seconds: 300)
    )
    let back = try #require(LXMessage.unpack(m.packed))
    #expect(back.content == Data("gone soon".utf8))
    #expect(back.fields.map(\.key) == [0xFD])
    #expect(ExpiryWire.decode(back.fields) == ExpiryWire.Decoded(seconds: 300, isChange: false))
}

/// Review Focus 3: a hostile or buggy peer cannot plant an absurd duration.
@Test func expiryWireDecodeRejectsOutOfRangeValues() {
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .int(-5))]))) == nil)
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .uint(2_419_201))]))) == nil)
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .string("86400"))]))) == nil)
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .double(60))]))) == nil)
    // The cap itself is fine, and a non-negative `.int` tag is accepted like `.uint`.
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .uint(2_419_200))])))?.seconds == 2_419_200)
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .int(60))])))?.seconds == 60)
}

/// Review Focus 2: another app's 0xFD (a non-map, or a map without our key) is not an expiry, and
/// extra keys beside ours are ignored. No field at all is nil too.
@Test func expiryWireDecodeIgnoresForeignCustomMeta() {
    #expect(ExpiryWire.decode([]) == nil)
    #expect(ExpiryWire.decode(meta(.bin(Data([1, 2, 3])))) == nil)
    #expect(ExpiryWire.decode(meta(.map([.init("somebody.else", .uint(9))]))) == nil)
    #expect(ExpiryWire.decode(meta(.intMap([.init(0, .uint(9))]))) == nil)
    let mixed = meta(.map([.init("somebody.else", .string("x")), .init("reticamsgr.expiry", .uint(30))]))
    #expect(ExpiryWire.decode(mixed) == ExpiryWire.Decoded(seconds: 30, isChange: false))
    // A change flag that is not literally `true` is not a change.
    let notFlag = meta(.map([.init("reticamsgr.expiry", .uint(30)), .init("reticamsgr.expiry.change", .uint(1))]))
    #expect(ExpiryWire.decode(notFlag) == ExpiryWire.Decoded(seconds: 30, isChange: false))
}

@Test func expiryWireClampBoundsToZeroAndTheCap() {
    #expect(ExpiryWire.clamp(-1) == 0)
    #expect(ExpiryWire.clamp(0) == 0)
    #expect(ExpiryWire.clamp(60) == 60)
    #expect(ExpiryWire.clamp(99_999_999) == 2_419_200)
    #expect(ExpiryWire.encode(seconds: 99_999_999)[0].value == .map([.init("reticamsgr.expiry", .uint(2_419_200))]))
}
