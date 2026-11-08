import Testing
import Foundation
import ReTiCA
@testable import ReTiCAMsgrCore

private let alice = Identity()
private let address = lxmfAddressHex(alice)
private let key = alice.publicKey.hexString

@Test func encodeProducesLowercaseLxmaWithAddressAndKey() {
    let encoded = ContactURI.encode(alice)
    #expect(encoded == "lxma://\(address):\(key)")
    let expectedLength = 168   // "lxma://" 7 + address 32 + ":" 1 + key 128
    #expect(encoded.count == expectedLength)
    #expect(encoded == encoded.lowercased())
}

@Test func parseRoundTripsEncode() {
    #expect(ContactURI.parse(ContactURI.encode(alice)) == ScannedContact(addressHex: address, publicKey: alice.publicKey))
}

@Test func parseAcceptsUppercaseAndWhitespace() {
    let messy = "  " + ContactURI.encode(alice).uppercased() + "\n"
    #expect(ContactURI.parse(messy) == ScannedContact(addressHex: address, publicKey: alice.publicKey))
}

@Test func parseAcceptsDotSeparator() {
    #expect(ContactURI.parse("lxma://\(address).\(key)")?.publicKey == alice.publicKey)
}

@Test func parseAcceptsLxmaWithoutKey() {
    #expect(ContactURI.parse("lxma://\(address)") == ScannedContact(addressHex: address, publicKey: nil))
}

@Test func parseKeepsLegacyForms() {
    let expected = ScannedContact(addressHex: address, publicKey: nil)
    #expect(ContactURI.parse(address) == expected)
    #expect(ContactURI.parse("lxmf://\(address)") == expected)
    #expect(ContactURI.parse("lxmf@\(address)") == expected)
}

@Test func parseRejectsKeyThatDoesNotMatchAddress() {
    let bob = Identity()
    #expect(ContactURI.parse("lxma://\(address):\(bob.publicKey.hexString)") == nil)
}

@Test func parseRejectsHalfLengthKey() {
    #expect(ContactURI.parse("lxma://\(address):\(key.prefix(64))") == nil)
}

@Test func parseRejectsNonHexKey() {
    #expect(ContactURI.parse("lxma://\(address):" + String(repeating: "z", count: 128)) == nil)
}

@Test func parseRejectsEmptyKeyAfterSeparator() {
    #expect(ContactURI.parse("lxma://\(address):") == nil)
}

@Test func parseRejectsSeparatorWithoutLxma() {
    #expect(ContactURI.parse("lxmf://\(address):\(key)") == nil)
}

@Test func parseRejectsPaperMessageURI() {
    #expect(ContactURI.parse("lxm://" + address) == nil)
}
