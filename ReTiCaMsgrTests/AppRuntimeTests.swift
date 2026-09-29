import Foundation
import Testing
import GRDB
import SQLiteData
import StructuredQueriesCore
import ReTiCA
import ReTiCAKeychain
import ReTiCaMsgrCore
@testable import ReTiCaMsgr

private let shared = SharedIdentityLocation.shared

/// Local hex helper — ReTiCaMsgrCore's `Data.hexString` is internal to the package (see
/// ReTiCaMsgr/AnnounceListView.swift for the same pattern in app code).
private func toHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

@MainActor
private struct Fixture {
    let keychain = InMemoryKeychain()
    let database: any DatabaseWriter
    let defaults: UserDefaults
    let runtime: AppRuntime

    init(messages: Int = 0, planted: Data? = nil, anchor: Data? = nil) throws {
        database = try AppDatabase.makeInMemory()
        let suite = "appRuntimeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let planted { keychain.set(planted, at: shared) }
        if let anchor { defaults.set(toHex(anchor), forKey: IdentityAnchor.key) }
        for i in 0..<messages {
            let m = Message(id: UUID(), peerHex: String(repeating: "ab", count: 16), isOutgoing: true, body: "m\(i)",
                            timestamp: Date(timeIntervalSince1970: Double(i)), status: MessageStatus.sending, validated: true,
                            messageHash: String(repeating: "cd", count: 32))
            try database.write { try Message.insert { m }.execute($0) }
        }
        let clock = Clock()
        runtime = AppRuntime(environment: .init(
            database: database,
            identityStore: .live(ops: keychain.ops),
            anchor: IdentityAnchor(defaults: defaults),
            now: { clock.now }))
        self.clock = clock
    }

    let clock: Clock
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
}

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

@MainActor
@Test func appRuntimeFreshInstallMintsAndBuildsTheStore() throws {
    let f = try Fixture()
    f.runtime.build()
    guard case let .ready(hash) = f.runtime.state else {
        Issue.record("expected ready: \(f.runtime.state)")
        return
    }
    #expect(f.runtime.store != nil)
    #expect(f.keychain.addCount == 1)
    #expect(IdentityAnchor(defaults: f.defaults).expected() == hash)
}

/// I1 / FIX-1: an anchor is itself local state, so zero message rows does not mean fresh install.
@MainActor
@Test func appRuntimeAnchorWithoutMessagesNeverMints() throws {
    let expected = Data(repeating: 0x88, count: 16)
    let f = try Fixture(messages: 0, anchor: expected)
    f.runtime.build()
    #expect(f.runtime.state == .missing(expected: expected))
    #expect(f.runtime.store == nil)
    #expect(f.keychain.addCount == 0)
}

@MainActor
@Test func appRuntimeMessagesPresentAndKeychainEmptyIsMissingAndMintsNothing() throws {
    let expected = Data(repeating: 0x55, count: 16)
    let f = try Fixture(messages: 1, anchor: expected)
    f.runtime.build()
    #expect(f.runtime.state == .missing(expected: expected))
    #expect(f.runtime.store == nil)
    #expect(f.keychain.addCount == 0)
}

@MainActor
@Test func appRuntimeLockedIsUnavailableAndRetryRecovers() throws {
    let (identity, data) = makeSeed()
    let f = try Fixture(messages: 1, planted: data, anchor: identity.hash)
    f.keychain.failRead(at: shared, status: -25308)
    f.runtime.build()
    #expect(f.runtime.state == .unavailable(.locked))
    #expect(f.keychain.addCount == 0)
    // Rate limit: the first retry runs (still locked), the second within a second does not.
    #expect(f.runtime.retry() == true)
    #expect(f.runtime.retry() == false)
    f.keychain.clearFailures()
    #expect(f.runtime.retry() == false)
    f.clock.now = f.clock.now.addingTimeInterval(1)
    #expect(f.runtime.retry() == true)
    #expect(f.runtime.state == .ready(identity.hash))
    #expect(f.runtime.store != nil)
}

@MainActor
@Test func appRuntimeRestoreRightKeyReachesReady() throws {
    let (identity, data) = makeSeed()
    let f = try Fixture(messages: 1, anchor: identity.hash)
    f.runtime.build()
    #expect(f.runtime.state == .missing(expected: identity.hash))
    #expect(f.runtime.restore(privateKey: data) == .restored(identity.hash))
    #expect(f.runtime.state == .ready(identity.hash))
    #expect(f.runtime.store != nil)
    #expect(f.keychain.item(at: shared) == data)
}

@MainActor
@Test func appRuntimeRestoreWrongKeyIsRejectedAndWritesNothing() throws {
    let (identity, _) = makeSeed()
    let (other, otherData) = makeSeed()
    let f = try Fixture(messages: 1, anchor: identity.hash)
    f.runtime.build()
    #expect(f.runtime.restore(privateKey: otherData) == .rejected(.mismatch(got: other.hash, expected: identity.hash)))
    #expect(f.runtime.state == .missing(expected: identity.hash))
    #expect(f.keychain.addCount == 0)
}

@MainActor
@Test func appRuntimeRestoreRefusedWhenNotMissing() throws {
    let (identity, data) = makeSeed()
    let f = try Fixture(planted: data, anchor: identity.hash)
    f.runtime.build()
    #expect(f.runtime.state == .ready(identity.hash))
    #expect(f.runtime.restore(privateKey: data) == .refused(.notMissing))
    #expect(f.keychain.addCount == 0)
}

@MainActor
@Test func appRuntimeRestoreRefusedWhenAnIdentityAppeared() throws {
    let (identity, data) = makeSeed()
    let (_, otherData) = makeSeed()
    let f = try Fixture(messages: 1, anchor: identity.hash)
    f.runtime.build()
    f.keychain.set(otherData, at: shared)     // Nbhd wrote the shared item meanwhile
    #expect(f.runtime.restore(privateKey: data) == .refused(.identityPresent(service: "reticulum.identity")))
    #expect(f.runtime.state == .missing(expected: identity.hash))
    #expect(f.keychain.item(at: shared) == otherData)
}

@MainActor
@Test func appRuntimeIdentityChangedRefusesReadyUntilAccepted() throws {
    let (identity, data) = makeSeed()
    let old = Data(repeating: 0x66, count: 16)
    let f = try Fixture(messages: 1, planted: data, anchor: old)
    f.runtime.build()
    #expect(f.runtime.state == .identityChanged(expected: old, got: identity.hash))
    #expect(f.runtime.store == nil)
    #expect(IdentityAnchor(defaults: f.defaults).expected() == old)
    f.runtime.acceptNewIdentity()
    #expect(f.runtime.state == .ready(identity.hash))
    #expect(f.runtime.store != nil)
    #expect(IdentityAnchor(defaults: f.defaults).expected() == identity.hash)
}

/// FIX-0 / spec amendment 1 to §5.5: the only explicit way out of a no-anchor `.missing` state.
@MainActor
@Test func appRuntimeCreateNewIdentityOnlyFromTheNoAnchorMissingState() throws {
    let f = try Fixture(messages: 1)
    f.runtime.build()
    #expect(f.runtime.state == .missing(expected: nil))
    f.runtime.createNewIdentity()
    guard case let .ready(hash) = f.runtime.state else {
        Issue.record("expected ready: \(f.runtime.state)")
        return
    }
    #expect(f.runtime.store != nil)
    #expect(f.keychain.addCount == 1)
    #expect(IdentityAnchor(defaults: f.defaults).expected() == hash)
    // A second call is a no-op: state is already `.ready`, not the no-anchor `.missing` state.
    f.runtime.createNewIdentity()
    #expect(f.keychain.addCount == 1)
}

@MainActor
@Test func appRuntimeCreateNewIdentityIsRefusedWithAnAnchor() throws {
    let (identity, _) = makeSeed()
    let f = try Fixture(messages: 1, anchor: identity.hash)
    f.runtime.build()
    #expect(f.runtime.state == .missing(expected: identity.hash))
    f.runtime.createNewIdentity()
    #expect(f.runtime.state == .missing(expected: identity.hash))
    #expect(f.keychain.addCount == 0)
}

@MainActor
@Test func appRuntimeBuildIsIdempotentOnceReady() throws {
    let f = try Fixture()
    f.runtime.build()
    let first = f.runtime.store
    f.runtime.build()
    #expect(f.runtime.store === first)
    #expect(f.keychain.addCount == 1)
    #expect(f.runtime.retry() == false)
}

@MainActor
@Test func appRuntimeTestHostEnvironmentNeverTouchesTheRealKeychain() {
    #expect(AppRuntime.Environment.isTestHost)   // hosted XCTest sets XCTestConfigurationFilePath
    let runtime = AppRuntime(environment: .testHost())
    runtime.build()
    guard case .ready = runtime.state else {
        Issue.record("expected ready: \(runtime.state)")
        return
    }
}
