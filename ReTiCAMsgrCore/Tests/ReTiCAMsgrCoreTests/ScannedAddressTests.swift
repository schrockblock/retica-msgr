import Testing
import Foundation
@testable import ReTiCAMsgrCore

private let validLower = "0123456789abcdef0123456789abcdef"
private let validUpper = "0123456789ABCDEF0123456789ABCDEF"

@Test func scannedAddressParsesPlainLowercaseHex() {
    #expect(ScannedAddress.parse(validLower) == validLower)
}

@Test func scannedAddressParsesUppercaseHexAndLowercasesIt() {
    #expect(ScannedAddress.parse(validUpper) == validLower)
}

@Test func scannedAddressTrimsSurroundingWhitespaceAndNewlines() {
    #expect(ScannedAddress.parse("  \n\(validLower)\t\n  ") == validLower)
}

@Test func scannedAddressStripsLxmfSchemePrefix() {
    #expect(ScannedAddress.parse("lxmf://\(validLower)") == validLower)
}

@Test func scannedAddressStripsLxmfAtPrefix() {
    #expect(ScannedAddress.parse("lxmf@\(validLower)") == validLower)
}

@Test func scannedAddressStripsPrefixCaseInsensitively() {
    #expect(ScannedAddress.parse("LXMF://\(validUpper)") == validLower)
}

@Test func scannedAddressRejects31Chars() {
    let tooShort = String(validLower.dropLast())
    #expect(ScannedAddress.parse(tooShort) == nil)
}

@Test func scannedAddressRejects33Chars() {
    let tooLong = validLower + "0"
    #expect(ScannedAddress.parse(tooLong) == nil)
}

@Test func scannedAddressRejectsNonHexCharacters() {
    #expect(ScannedAddress.parse(String(repeating: "g", count: 32)) == nil)
}

@Test func scannedAddressRejectsEmptyString() {
    #expect(ScannedAddress.parse("") == nil)
}

@Test func scannedAddressRejectsURLThatIsNotAnAddress() {
    #expect(ScannedAddress.parse("https://example.com/not-an-address") == nil)
}

@Test func scannedAddressRejectsPrefixWithNothingAfter() {
    #expect(ScannedAddress.parse("lxmf://") == nil)
    #expect(ScannedAddress.parse("lxmf@") == nil)
}
