import Foundation
import Testing
import ReTiCA
import ReTiCAKeychain
@testable import ReTiCaMsgrCore

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

@Test func identityRestoreTextFormAcceptsPaddedUnpaddedAndWhitespace() {
    let (_, data) = makeSeed()
    let padded = IdentityBackup.base32(data)
    let unpadded = String(padded.filter { $0 != "=" })
    #expect(IdentityRestore.key(fromText: padded) == .success(data))
    #expect(IdentityRestore.key(fromText: unpadded) == .success(data))
    #expect(IdentityRestore.key(fromText: "  \n\(padded)\n") == .success(data))
    #expect(IdentityRestore.key(fromText: padded.lowercased()) == .failure(.badEncoding))
    #expect(IdentityRestore.key(fromText: "MZXW6===") == .failure(.wrongLength(3)))
}

@Test func identityRestoreFileFormIsExactly64Bytes() {
    let (_, data) = makeSeed()
    #expect(IdentityRestore.key(fromFile: data) == .success(data))
    #expect(IdentityRestore.key(fromFile: data + Data([0])) == .failure(.wrongLength(65)))
    #expect(IdentityRestore.key(fromFile: Data()) == .failure(.wrongLength(0)))
}

@Test func identityRestoreValidateIsStrict() {
    let (identity, data) = makeSeed()
    let (other, _) = makeSeed()
    #expect(IdentityRestore.validate(privateKey: data, expected: identity.hash) == .success(identity))
    #expect(IdentityRestore.validate(privateKey: data, expected: other.hash) == .failure(.mismatch(got: identity.hash, expected: other.hash)))
    #expect(IdentityRestore.validate(privateKey: data, expected: nil) == .failure(.noExpectedIdentity))
    #expect(IdentityRestore.validate(privateKey: Data(repeating: 1, count: 10), expected: identity.hash) == .failure(.wrongLength(10)))
}

@Test func identityRestoreReadKeyFileRefusesLargeFiles() throws {
    let (_, data) = makeSeed()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("identityRestore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let small = dir.appendingPathComponent("identity")
    try data.write(to: small)
    #expect(IdentityRestore.readKeyFile(at: small) == data)
    let big = dir.appendingPathComponent("big")
    try Data(repeating: 0, count: IdentityRestore.maxFileBytes + 1).write(to: big)
    #expect(IdentityRestore.readKeyFile(at: big) == nil)
    let exact = dir.appendingPathComponent("exact")
    try Data(repeating: 0, count: IdentityRestore.maxFileBytes).write(to: exact)
    #expect(IdentityRestore.readKeyFile(at: exact)?.count == IdentityRestore.maxFileBytes)
    #expect(IdentityRestore.readKeyFile(at: dir.appendingPathComponent("missing")) == nil)
}

@Test func identityRestoreDescribeIsLogSafe() {
    let got = Data(repeating: 0xAB, count: 16)
    let expected = Data(repeating: 0xCD, count: 16)
    #expect(IdentityRestore.describe(.badEncoding) == "badEncoding")
    #expect(IdentityRestore.describe(.wrongLength(7)) == "wrongLength 7")
    #expect(IdentityRestore.describe(.invalidKey) == "invalidKey")
    #expect(IdentityRestore.describe(.mismatch(got: got, expected: expected)) == "mismatch got=\(got.hexString) expected=\(expected.hexString)")
    #expect(IdentityRestore.describe(.noExpectedIdentity) == "noExpectedIdentity")
}
