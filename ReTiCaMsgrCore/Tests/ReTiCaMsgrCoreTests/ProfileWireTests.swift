import Testing
import Foundation
import ReTiCA
@testable import ReTiCaMsgrCore

private let smallJPEG = TestImages.jpeg(width: 64, height: 64)

private func field(_ items: [MsgPackValue]) -> [MsgPackValue.IntPair] {
    [.init(0xA0, .array(items))]
}

@Test func profileWirePhotoRoundTrips() {
    let v = ProfileWire.version(of: smallJPEG)
    let decoded = ProfileWire.decode(ProfileWire.encodePhoto(version: v, jpeg: smallJPEG))
    #expect(decoded == .photo(version: v, jpeg: smallJPEG))
}

@Test func profileWireTagRoundTrips() {
    let v = ProfileWire.version(of: smallJPEG)
    #expect(ProfileWire.decode(ProfileWire.encodeTag(version: v)) == .tag(version: v))
}

@Test func profileWireRemovedRoundTrips() {
    #expect(ProfileWire.decode(ProfileWire.encodeRemoved()) == .removed)
}

@Test func profileWireVersionIsSha256Prefix8() {
    #expect(ProfileWire.version(of: Data("abc".utf8)).hexString == "ba7816bf8f01cfea")
}

@Test func profileWireHashMismatchFallsBackToTag() {
    let v = ProfileWire.version(of: smallJPEG)
    let other = TestImages.jpeg(width: 32, height: 48)
    #expect(ProfileWire.decode(field([.bin(v), .bin(other)])) == .tag(version: v))
}

@Test func profileWireOversizeFallsBackToTag() {
    let big = smallJPEG + Data(repeating: 0, count: 65_537 - smallJPEG.count)
    #expect(big.count == 65_537)
    let v = ProfileWire.version(of: big)
    #expect(ProfileWire.decode(field([.bin(v), .bin(big)])) == .tag(version: v))
}

@Test func profileWireUndecodableFallsBackToTag() {
    let junk = Data("not an image".utf8)
    let v = ProfileWire.version(of: junk)
    #expect(ProfileWire.decode(field([.bin(v), .bin(junk)])) == .tag(version: v))
}

@Test func profileWireTooLargePixelsFallsBackToTag() {
    let wide = TestImages.jpeg(width: 600, height: 600)
    #expect(wide.count <= ProfileWire.maxImageBytes)
    let v = ProfileWire.version(of: wide)
    #expect(ProfileWire.decode(field([.bin(v), .bin(wide)])) == .tag(version: v))
}

@Test func profileWireRejectsWrongVersionLength() {
    #expect(ProfileWire.decode(field([.bin(Data(repeating: 1, count: 7))])) == nil)
}

@Test func profileWireAbsentIsNil() {
    #expect(ProfileWire.decode([]) == nil)
    #expect(ProfileWire.decode([.init(0x30, .array([.bin(Data(repeating: 1, count: 8))]))]) == nil)
}

@Test func iconWireDecodesSidebandShape() {
    let fields: [MsgPackValue.IntPair] = [.init(0x04, .array([
        .string("account"), .bin(Data([0xff, 0, 0])), .bin(Data([0, 0, 0xff])),
    ]))]
    #expect(IconAppearanceWire.decode(fields) == IconAppearance(name: "account", fg: "ff0000", bg: "0000ff"))
}

@Test func iconWireAcceptsBinNameAndExtraItems() {
    let fields: [MsgPackValue.IntPair] = [.init(0x04, .array([
        .bin(Data("boat".utf8)), .bin(Data([1, 2, 3])), .bin(Data([4, 5, 6])), .uint(7),
    ]))]
    #expect(IconAppearanceWire.decode(fields)?.name == "boat")
}

@Test func iconWireRejectsWrongColourLength() {
    let fields: [MsgPackValue.IntPair] = [.init(0x04, .array([
        .string("account"), .bin(Data([1, 2, 3, 4])), .bin(Data([0, 0, 1])),
    ]))]
    #expect(IconAppearanceWire.decode(fields) == nil)
}

@Test func iconWireRejectsEmptyOrLongName() {
    func fields(_ name: String) -> [MsgPackValue.IntPair] {
        [.init(0x04, .array([.string(name), .bin(Data([1, 2, 3])), .bin(Data([1, 2, 3]))]))]
    }
    #expect(IconAppearanceWire.decode(fields("")) == nil)
    #expect(IconAppearanceWire.decode(fields(String(repeating: "a", count: 65))) == nil)
}
