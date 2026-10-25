import Foundation
import Testing
import ReTiCA
import ReTiCAKeychain
import ReTiCaMsgrCore
@testable import ReTiCaMsgr

/// Deletes only test-owned services. Refuses the production service outright.
private enum TestKeychain {
    static let prefix = "reticamsgrtests.identity."
    static func location() -> IdentityKeychain.Location {
        IdentityKeychain.Location(service: prefix + UUID().uuidString, accessGroup: SharedIdentityLocation.accessGroup)
    }
    static func cleanUp(_ location: IdentityKeychain.Location) {
        precondition(location.service.hasPrefix(prefix), "refusing to delete a non-test service")
        _ = KeychainOps.live.delete(location)
    }
}

// Fenced on macOS: it needs the shared keychain-access-groups entitlement on the hosted test
// bundle, which only a provisioned (signed) Mac build carries. Unsigned macOS test runs fail
// with a keychain entitlement error here, and automatic signing needs an Xcode account.
#if os(iOS)
@Test func sharedKeychainRoundTripsATestServiceInTheRealAccessGroup() {
    let production = KeychainOps.live.read(SharedIdentityLocation.shared)
    let location = TestKeychain.location()
    defer { TestKeychain.cleanUp(location) }
    let identity = Identity()
    let data = identity.privateKey!
    let store = IdentityStore.live(ops: .live, shared: location)
    #expect(store.load(.loadOnly) == .absent)
    #expect(store.restore(data) == .restored(identity))
    #expect(store.load(.loadOnly) == .ready(identity))
    #expect(store.restore(Identity().privateKey!) == .identityPresent(service: location.service))
    #expect(KeychainOps.live.read(SharedIdentityLocation.shared) == production)
}
#endif
