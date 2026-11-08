import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport
@testable import ReTiCAMsgrCore

// `makeLinkStore` (ContactLinkTests) pins `date` and `transportDate` to this instant.
private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let alice = Identity()
private let aliceAddress = lxmfAddressHex(alice)
private let aliceHash = Data(hexString: aliceAddress)!

@MainActor @Test func scannedKeyIsRememberedForUnknownPeer() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: []))
    await store.send(.scannedContactKey(ScannedContact(addressHex: aliceAddress, publicKey: alice.publicKey)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.recall(destinationHash: aliceHash)?.publicKey == alice.publicKey)
}

/// An announced peer's entry carries its link cost. A scan must not replace it with a cost-less one,
/// or the next link to a peer that enforces stamps would go out unstamped.
@MainActor @Test func scannedKeyDoesNotReplaceKnownEntry() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: []))
    let heard = now.addingTimeInterval(-60)
    let announced = KnownDestination(identity: alice, appData: nil, lastHeard: heard, linkCost: 8)
    await store.send(.node(.client(.endpoint(.transport(.rehydrateKnownDestinations([aliceHash: announced]))))))
    await store.send(.scannedContactKey(ScannedContact(addressHex: aliceAddress, publicKey: alice.publicKey)))
    await store.skipReceivedActions(strict: false)
    let entry = store.state.node.client.endpoint.transport.knownDestinations[aliceHash]
    #expect(entry?.linkCost == 8)
    #expect(entry?.lastHeard == heard)
}

@MainActor @Test func scannedContactWithoutKeyDoesNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: []))
    await store.send(.scannedContactKey(ScannedContact(addressHex: aliceAddress, publicKey: nil)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.transport.knownDestinations[aliceHash] == nil)
}
