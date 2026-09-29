import Foundation
import Security
import Testing
import ReTiCA
import ReTiCAKeychain
@testable import ReTiCaMsgrCore

private let shared = SharedIdentityLocation.shared

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

@Test func identityStoreTestValueIsStableAndAddressIsDeliveryHash() {
    let store = IdentityStore.testValue
    guard case let .ready(a) = store.load(.loadOnly), case let .ready(b) = store.load(.loadOrCreate) else {
        Issue.record("testValue must be ready under both policies")
        return
    }
    #expect(a == b)
    #expect(lxmfAddressHex(a) == LXMessage.deliveryHash(identityHash: a.hash).hexString)
    #expect(store.restore(Data(repeating: 1, count: 64)) == .identityPresent(service: "test"))
}

@Test func identityStoreSharedLocationIsTheOneNbhdUses() {
    #expect(shared.service == "reticulum.identity")
    #expect(shared.accessGroup == "HK6WSAR793.co.lithobyte.reticulum.identity")
}

@Test func identityStoreLoadOrCreateMintsOnAnEmptyKeychain() {
    let keychain = InMemoryKeychain()
    let store = IdentityStore.live(ops: keychain.ops)
    guard case let .ready(identity) = store.load(.loadOrCreate) else {
        Issue.record("expected ready")
        return
    }
    #expect(keychain.item(at: shared) == identity.privateKey)
    #expect(keychain.addCount == 1)
}

@Test func identityStoreLoadOnlyNeverMints() {
    let keychain = InMemoryKeychain()
    let store = IdentityStore.live(ops: keychain.ops)
    #expect(store.load(.loadOnly) == .absent)
    #expect(store.load(.loadOnly) == .absent)
    #expect(keychain.addCount == 0)
    #expect(keychain.item(at: shared) == nil)
}

@Test func identityStoreLoadReturnsTheStoredIdentityUnderBothPolicies() {
    let (identity, data) = makeSeed()
    let keychain = InMemoryKeychain([shared: data])
    let store = IdentityStore.live(ops: keychain.ops)
    #expect(store.load(.loadOnly) == .ready(identity))
    #expect(store.load(.loadOrCreate) == .ready(identity))
    #expect(keychain.addCount == 0)
}

@Test func identityStoreRestoreImportsOnceAndRefusesAfter() {
    let (identity, data) = makeSeed()
    let (_, other) = makeSeed()
    let keychain = InMemoryKeychain()
    let store = IdentityStore.live(ops: keychain.ops)
    #expect(store.restore(Data(repeating: 1, count: 10)) == .invalidKey)
    #expect(keychain.addCount == 0)
    #expect(store.restore(data) == .restored(identity))
    #expect(keychain.item(at: shared) == data)
    #expect(store.restore(other) == .identityPresent(service: "reticulum.identity"))
    #expect(keychain.item(at: shared) == data)
    #expect(keychain.addCount == 1)
}

@Test func identityStoreLoadMapsFailuresToReasons() {
    let (_, data) = makeSeed()
    let locked = InMemoryKeychain()
    locked.failRead(at: shared, status: errSecInteractionNotAllowed)
    #expect(IdentityStore.live(ops: locked.ops).load(.loadOnly) == .failed(.locked))
    #expect(IdentityStore.live(ops: locked.ops).load(.loadOrCreate) == .failed(.locked))
    #expect(locked.addCount == 0)

    let denied = InMemoryKeychain()
    denied.failRead(at: shared, status: errSecMissingEntitlement)
    #expect(IdentityStore.live(ops: denied.ops).load(.loadOrCreate) == .failed(.accessDenied))

    let stray = InMemoryKeychain([IdentityKeychain.Location(service: shared.service, accessGroup: "HK6WSAR793.co.lithobyte.wrong"): data])
    #expect(IdentityStore.live(ops: stray.ops).load(.loadOrCreate) == .failed(.strayItem("reticulum.identity")))
    #expect(stray.addCount == 0)

    let two = InMemoryKeychain([shared: data])
    two.set(data, at: shared, account: "second")
    #expect(IdentityStore.live(ops: two.ops).load(.loadOnly) == .failed(.strayItem("2 items at reticulum.identity")))

    let synced = InMemoryKeychain()
    synced.set(data, at: shared, synchronizable: true)
    #expect(IdentityStore.live(ops: synced.ops).load(.loadOnly) == .failed(.strayItem("synchronizable item at reticulum.identity")))

    let corrupt = InMemoryKeychain([shared: Data(repeating: 0xAB, count: 63)])
    #expect(IdentityStore.live(ops: corrupt.ops).load(.loadOnly) == .failed(.corrupt))
}

@Test func identityStoreReasonMapsEveryFailure() {
    let location = shared
    #expect(IdentityStore.reason(for: .readFailed(location: location, status: errSecInteractionNotAllowed)) == .locked)
    #expect(IdentityStore.reason(for: .readFailed(location: location, status: errSecNotAvailable)) == .locked)
    #expect(IdentityStore.reason(for: .readFailed(location: location, status: errSecMissingEntitlement)) == .accessDenied)
    #expect(IdentityStore.reason(for: .readFailed(location: location, status: -50)) == .other(-50))
    #expect(IdentityStore.reason(for: .addFailed(status: errSecMissingEntitlement)) == .accessDenied)
    #expect(IdentityStore.reason(for: .addFailed(status: -50)) == .other(-50))
    #expect(IdentityStore.reason(for: .verifyFailed(status: -7)) == .other(-7))
    #expect(IdentityStore.reason(for: .verifyFailed(status: nil)) == .other(nil))
    #expect(IdentityStore.reason(for: .mintFailed) == .other(nil))
    #expect(IdentityStore.reason(for: .invalidLocation(location)) == .other(nil))
    #expect(IdentityStore.reason(for: .corrupt(location: location)) == .corrupt)
    #expect(IdentityStore.reason(for: .unexpectedItem(service: "x.identity")) == .strayItem("x.identity"))
    #expect(IdentityStore.reason(for: .ambiguousItems(location: location, count: 3)) == .strayItem("3 items at reticulum.identity"))
    #expect(IdentityStore.reason(for: .synchronizableItem(location: location)) == .strayItem("synchronizable item at reticulum.identity"))
}
