import Foundation
import Testing
import GRDB
import ReTiCA
import ReTiCAKeychain
@testable import ReTiCAMsgrCore

private func insertOneMessage(_ db: any DatabaseWriter) throws {
    let m = Message(id: UUID(), peerHex: String(repeating: "ab", count: 16), isOutgoing: true, body: "hi",
                    timestamp: Date(timeIntervalSince1970: 1), status: MessageStatus.sending, validated: true,
                    messageHash: String(repeating: "cd", count: 32))
    try db.write { try Message.insert { m }.execute($0) }
}

private func freshDefaults() -> UserDefaults {
    let name = "identityLaunchTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

@Test func identityLaunchPolicyIsLoadOrCreateOnlyWithoutMessages() throws {
    let db = try AppDatabase.makeInMemory()
    let anchor = IdentityAnchor(defaults: freshDefaults())
    #expect(try AppDatabase.hasMessages(db) == false)
    #expect(LoadPolicy.forLaunch(database: db, anchor: anchor) == .loadOrCreate)
    try insertOneMessage(db)
    #expect(try AppDatabase.hasMessages(db) == true)
    #expect(LoadPolicy.forLaunch(database: db, anchor: anchor) == .loadOnly)
}

/// A failed count is "unknown", never "fresh install".
@Test func identityLaunchPolicyIsLoadOnlyWhenTheCountThrows() throws {
    let queue = try DatabaseQueue()
    let anchor = IdentityAnchor(defaults: freshDefaults())
    // No migration ran: the messages table does not exist, so the count throws.
    #expect(throws: (any Error).self) { try AppDatabase.hasMessages(queue) }
    #expect(LoadPolicy.forLaunch(database: queue, anchor: anchor) == .loadOnly)
}

/// An anchor is itself local state: it forces `.loadOnly` even with zero message rows.
@Test func identityLaunchPolicyIsLoadOnlyWhenAnAnchorExists() throws {
    let db = try AppDatabase.makeInMemory()
    #expect(try AppDatabase.hasMessages(db) == false)
    let anchor = IdentityAnchor(defaults: freshDefaults())
    let expected = Data(repeating: 0x77, count: 16)
    anchor.recordReady(expected)
    let policy = LoadPolicy.forLaunch(database: db, anchor: anchor)
    #expect(policy == .loadOnly)
    let keychain = InMemoryKeychain()
    let result = LaunchIdentity.resolve(policy: policy, anchor: anchor, store: .live(ops: keychain.ops))
    #expect(result.state == .missing(expected: expected))
    #expect(keychain.addCount == 0)
}

@Test func identityLaunchAnchorIsWriteOnceUntilReplaced() {
    let anchor = IdentityAnchor(defaults: freshDefaults())
    let a = Data(repeating: 0x11, count: 16)
    let b = Data(repeating: 0x22, count: 16)
    #expect(anchor.expected() == nil)
    anchor.recordReady(a)
    #expect(anchor.expected() == a)
    anchor.recordReady(b)
    #expect(anchor.expected() == a)
    anchor.replace(with: b)
    #expect(anchor.expected() == b)
}

@Test func identityLaunchAnchorIgnoresMalformedValues() {
    let defaults = freshDefaults()
    let anchor = IdentityAnchor(defaults: defaults)
    defaults.set("not-hex", forKey: IdentityAnchor.key)
    #expect(anchor.expected() == nil)
    defaults.set("abcd", forKey: IdentityAnchor.key)      // too short
    #expect(anchor.expected() == nil)
    defaults.set(String(repeating: "ab", count: 16), forKey: IdentityAnchor.key)
    #expect(anchor.expected() == Data(repeating: 0xAB, count: 16))
}

@Test func identityLaunchResolveFreshInstallIsReadyAndWritesTheAnchor() {
    let (identity, data) = makeSeed()
    let keychain = InMemoryKeychain([SharedIdentityLocation.shared: data])
    let anchor = IdentityAnchor(defaults: freshDefaults())
    let result = LaunchIdentity.resolve(policy: .loadOrCreate, anchor: anchor, store: .live(ops: keychain.ops))
    #expect(result.state == .ready(identity.hash))
    #expect(result.identity == identity)
    #expect(anchor.expected() == identity.hash)
}

@Test func identityLaunchResolveMatchingAnchorIsReady() {
    let (identity, data) = makeSeed()
    let keychain = InMemoryKeychain([SharedIdentityLocation.shared: data])
    let anchor = IdentityAnchor(defaults: freshDefaults())
    anchor.recordReady(identity.hash)
    let result = LaunchIdentity.resolve(policy: .loadOnly, anchor: anchor, store: .live(ops: keychain.ops))
    #expect(result.state == .ready(identity.hash))
    #expect(result.identity == identity)
}

@Test func identityLaunchResolveDifferingAnchorRefusesReadyAndKeepsTheAnchor() {
    let (identity, data) = makeSeed()
    let other = Data(repeating: 0x33, count: 16)
    let keychain = InMemoryKeychain([SharedIdentityLocation.shared: data])
    let anchor = IdentityAnchor(defaults: freshDefaults())
    anchor.recordReady(other)
    let result = LaunchIdentity.resolve(policy: .loadOnly, anchor: anchor, store: .live(ops: keychain.ops))
    #expect(result.state == .identityChanged(expected: other, got: identity.hash))
    #expect(result.identity == nil)
    #expect(anchor.expected() == other)
}

@Test func identityLaunchResolveAbsentIsMissingWithTheAnchor() {
    let expected = Data(repeating: 0x44, count: 16)
    let keychain = InMemoryKeychain()
    let anchor = IdentityAnchor(defaults: freshDefaults())
    anchor.recordReady(expected)
    let result = LaunchIdentity.resolve(policy: .loadOnly, anchor: anchor, store: .live(ops: keychain.ops))
    #expect(result.state == .missing(expected: expected))
    #expect(result.identity == nil)
    #expect(keychain.addCount == 0)
    let noAnchor = LaunchIdentity.resolve(policy: .loadOnly, anchor: IdentityAnchor(defaults: freshDefaults()), store: .live(ops: keychain.ops))
    #expect(noAnchor.state == .missing(expected: nil))
}

@Test func identityLaunchResolveFailureIsUnavailableAndMintsNothing() {
    let keychain = InMemoryKeychain()
    keychain.failRead(at: SharedIdentityLocation.shared, status: -25308)
    let result = LaunchIdentity.resolve(policy: .loadOrCreate, anchor: IdentityAnchor(defaults: freshDefaults()), store: .live(ops: keychain.ops))
    #expect(result.state == .unavailable(.locked))
    #expect(result.identity == nil)
    #expect(keychain.addCount == 0)
}

@Test func identityLaunchShortIDIsTheFirstEightHexChars() {
    #expect(shortID(Data(repeating: 0xAB, count: 16)) == "abababab")
}
