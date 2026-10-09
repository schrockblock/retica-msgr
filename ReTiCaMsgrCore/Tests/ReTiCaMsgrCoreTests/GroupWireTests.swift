import Testing
import Foundation
import ReTiCA
@testable import ReTiCaMsgrCore

private let gid = Data((0..<16).map { UInt8($0 + 0x10) })
private let pid = Data((0..<16).map { UInt8(0xF0 - $0) })
private let memberX = Data(repeating: 0xAA, count: 16)
private let memberY = Data(repeating: 0xBB, count: 16)

/// A 0xFD field built by hand, so these tests pin the wire shape rather than `encode`.
private func meta(_ value: MsgPackValue) -> [MsgPackValue.IntPair] { [.init(0xFD, value)] }

private func ctl(_ pairs: [MsgPackValue.Pair], ids: [MsgPackValue] = [.bin(gid)]) -> [MsgPackValue.IntPair] {
    meta(.map([.init("reticamsgr.group", .array(ids)), .init("reticamsgr.group.ctl", .map(pairs))]))
}

@Test func groupWireConstantsMatchTheSpec() {
    #expect(GroupWire.fieldCustomMeta == 0xFD)
    #expect(GroupWire.groupKey == "reticamsgr.group")
    #expect(GroupWire.controlKey == "reticamsgr.group.ctl")
    #expect(GroupWire.idLength == 16)
    #expect(GroupWire.maxNameBytes == 32)
    #expect(GroupWire.maxMembers == 12)
    #expect(GroupWire.actionRoster == "roster")
    #expect(GroupWire.actionLeave == "leave")
}

@Test func groupWireRandomIdsAre16BytesAndDistinct() {
    let a = GroupWire.randomId()
    let b = GroupWire.randomId()
    #expect(a.count == 16)
    #expect(b.count == 16)
    #expect(a != b)
}

/// Spec §1: a post carries `[group id, post id]` under the group key, nothing else.
@Test func groupWireEncodePostIsOneMetaFieldWithBothIds() {
    let fields = GroupWire.encodePost(groupId: gid, postId: pid)
    #expect(fields.count == 1)
    #expect(fields[0].key == 0xFD)
    #expect(fields[0].value == .map([.init("reticamsgr.group", .array([.bin(gid), .bin(pid)]))]))
    #expect(GroupWire.decode(fields) == .post(groupId: gid, postId: pid))
}

@Test func groupWireEncodeMarkerIsOneIdOnly() {
    let fields = GroupWire.encodeMarker(groupId: gid)
    #expect(fields[0].value == .map([.init("reticamsgr.group", .array([.bin(gid)]))]))
    #expect(GroupWire.decode(fields) == .marker(groupId: gid))
}

/// Spec §1: the control map keys are `a`, `n`, `m`, `r`, in that order, with the full roster.
@Test func groupWireEncodeRosterShapeAndRoundTrip() throws {
    let fields = GroupWire.encodeRoster(groupId: gid, name: "Mutual Aid", members: [memberX, memberY], revision: 3)
    #expect(fields.count == 1)
    #expect(fields[0].value == .map([
        .init("reticamsgr.group", .array([.bin(gid)])),
        .init("reticamsgr.group.ctl", .map([
            .init("a", .string("roster")),
            .init("n", .string("Mutual Aid")),
            .init("m", .array([.bin(memberX), .bin(memberY)])),
            .init("r", .uint(3)),
        ])),
    ]))
    let m = LXMessage.create(
        source: Identity(),
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data("Mutual Aid".utf8),
        content: Data("Ada invited you to the group Mutual Aid in ReTiCaMsgr".utf8),
        fields: fields
    )
    let back = try #require(LXMessage.unpack(m.packed))
    #expect(back.fields.map(\.key) == [0xFD])
    #expect(GroupWire.decode(back.fields) == .roster(groupId: gid, name: "Mutual Aid", members: [memberX, memberY], revision: 3))
}

@Test func groupWireEncodeLeaveRoundTrips() {
    let fields = GroupWire.encodeLeave(groupId: gid)
    #expect(fields[0].value == .map([
        .init("reticamsgr.group", .array([.bin(gid)])),
        .init("reticamsgr.group.ctl", .map([.init("a", .string("leave"))])),
    ]))
    #expect(GroupWire.decode(fields) == .leave(groupId: gid))
}

/// An encoder trims the name to the cap so a local pick never produces an undecodable roster.
@Test func groupWireEncodeRosterTrimsTheName() {
    let long = String(repeating: "é", count: 20)   // 40 bytes
    let fields = GroupWire.encodeRoster(groupId: gid, name: "  " + long + "  ", members: [memberX], revision: 1)
    #expect(GroupWire.decode(fields) == .roster(groupId: gid, name: String(repeating: "é", count: 16), members: [memberX], revision: 1))
}

/// Review Focus 4: cut on a Character boundary, never mid-scalar, and whitespace trimmed first.
@Test func groupWireTrimNameKeepsCharacterBoundaries() {
    #expect(GroupWire.trimName("  Block 4  ") == "Block 4")
    #expect(GroupWire.trimName(String(repeating: "a", count: 40)) == String(repeating: "a", count: 32))
    let family = "👨‍👩‍👧‍👦"   // 25 bytes, one Character
    #expect(GroupWire.trimName(family + family) == family)
    #expect(GroupWire.trimName("") == "")
}

/// Not a group message: no field, a foreign 0xFD, no group key, or a value that is not an array
/// of one or two 16-byte ids.
@Test func groupWireDecodeIgnoresForeignAndMalformedIds() {
    #expect(GroupWire.decode([]) == nil)
    #expect(GroupWire.decode(meta(.bin(Data([1, 2, 3])))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.expiry", .uint(60))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .bin(gid))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .array([]))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .array([.bin(Data(repeating: 1, count: 15))]))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .array([.bin(gid), .bin(Data(repeating: 1, count: 32))]))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .array([.bin(gid), .string("x")]))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .array([.bin(gid), .bin(pid), .bin(pid)]))]))) == nil)
}

/// Review Focus 4: an oversized name or roster, a bad member, or an unknown action is nil.
@Test func groupWireDecodeRejectsOversizedNameAndRoster() {
    let ok: [MsgPackValue.Pair] = [.init("a", .string("roster")), .init("n", .string("g")), .init("m", .array([.bin(memberX)])), .init("r", .uint(1))]
    #expect(GroupWire.decode(ctl(ok)) == .roster(groupId: gid, name: "g", members: [memberX], revision: 1))
    let thirteen = MsgPackValue.array((0..<13).map { .bin(Data(repeating: UInt8($0), count: 16)) })
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string("g")), .init("m", thirteen), .init("r", .uint(1))])) == nil)
    let twelve = MsgPackValue.array((0..<12).map { .bin(Data(repeating: UInt8($0), count: 16)) })
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string("g")), .init("m", twelve), .init("r", .uint(1))])) != nil)
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string(String(repeating: "x", count: 33))), .init("m", .array([.bin(memberX)])), .init("r", .uint(1))])) == nil)
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string("g")), .init("m", .array([.bin(Data(repeating: 1, count: 8))])), .init("r", .uint(1))])) == nil)
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string("g")), .init("m", .array([.bin(memberX)])), .init("r", .int(-1))])) == nil)
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string("g")), .init("m", .array([.bin(memberX)]))])) == nil)
    #expect(GroupWire.decode(ctl([.init("a", .string("kick"))])) == nil)
    #expect(GroupWire.decode(ctl([.init("n", .string("g"))])) == nil)
    // A control map on a post-shaped entry is ignored: it is a post.
    #expect(GroupWire.decode(ctl([.init("a", .string("leave"))], ids: [.bin(gid), .bin(pid)])) == .post(groupId: gid, postId: pid))
}

/// Lenient where it is safe: extra keys ignored, a `bin` name accepted, a non-negative `int`
/// revision accepted, an empty roster accepted (that is a delete), and the group entry decodes
/// beside an expiry entry under both codecs.
@Test func groupWireDecodeIsLenientWhereSafe() {
    let extra = ctl([.init("a", .string("roster")), .init("n", .bin(Data("Block 4".utf8))), .init("m", .array([])), .init("r", .int(7)), .init("z", .null)])
    #expect(GroupWire.decode(extra) == .roster(groupId: gid, name: "Block 4", members: [], revision: 7))
    let mixed = meta(.map([
        .init("reticamsgr.expiry", .uint(600)),
        .init("reticamsgr.group", .array([.bin(gid), .bin(pid)])),
    ]))
    #expect(GroupWire.decode(mixed) == .post(groupId: gid, postId: pid))
    #expect(ExpiryWire.decode(mixed) == ExpiryWire.Decoded(seconds: 600, isChange: false))
}
