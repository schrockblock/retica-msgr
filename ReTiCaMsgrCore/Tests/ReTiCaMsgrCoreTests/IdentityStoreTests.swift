import Testing
import Foundation
import Dependencies
import ReTiCA
@testable import ReTiCaMsgrCore

@Test func identityStoreTestValueIsStableAndAddressIsDeliveryHash() {
    let store = IdentityStore.testValue
    let a = store.load(); let b = store.load()
    #expect(a.hash == b.hash)                                   // stable within a run
    #expect(lxmfAddressHex(a) == LXMessage.deliveryHash(identityHash: a.hash).hexString)
}

@Test func identityRoundTripsThroughPrivateKey() {
    let id = Identity()
    let restored = Identity(privateKey: id.privateKey!)
    #expect(restored?.hash == id.hash)                          // persistence round-trip (what Keychain does)
}
