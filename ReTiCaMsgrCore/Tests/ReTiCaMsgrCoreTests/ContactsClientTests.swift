import Testing
import Foundation
@testable import ReTiCaMsgrCore

private let linkClientPeer = String(repeating: "a", count: 32)

@Test func linkClientFakeRecordsWritesAndClears() async throws {
    let fake = FakeContacts(contacts: [ContactSummary(identifier: "CN-1", name: "Jane Doe", hasPhoto: false)])
    try await fake.client.writeAddress("CN-1", linkClientPeer)
    try await fake.client.clearAddress("CN-1")
    #expect(fake.writes == [FakeContacts.Write(identifier: "CN-1", peerHex: linkClientPeer)])
    #expect(fake.clears == ["CN-1"])
    // A write is reflected in what an import would find, so a toggle-on followed by a scan sees it.
    #expect(try await fake.client.addressedContacts().isEmpty, "a cleared card carries no address")
}

@Test func linkClientFakeReturnsNilForUnknownContactAndGrantsOnRequest() async throws {
    let fake = FakeContacts(authorization: .notDetermined, grantOnRequest: .limited,
                            contacts: [ContactSummary(identifier: "CN-1", name: "Jane Doe", hasPhoto: true)])
    #expect(fake.client.authorizationStatus() == .notDetermined)
    #expect(await fake.client.requestAccess() == .limited)
    #expect(fake.client.authorizationStatus() == .limited)
    #expect(try await fake.client.contact("CN-1") == ContactSummary(identifier: "CN-1", name: "Jane Doe", hasPhoto: true))
    #expect(try await fake.client.contact("CN-404") == nil)
    #expect(await fake.client.thumbnail("CN-404") == nil)
}

@Test func linkClientFakeListsAddressedContactsForImport() async throws {
    let fake = FakeContacts(contacts: [ContactSummary(identifier: "CN-1", name: "Jane Doe", hasPhoto: false)],
                            addresses: ["CN-1": linkClientPeer, "CN-2": "zzz"])
    let found = try await fake.client.addressedContacts()
    #expect(Set(found) == [ImportCandidate(identifier: "CN-1", name: "Jane Doe", peerHex: linkClientPeer),
                           ImportCandidate(identifier: "CN-2", name: "", peerHex: "zzz")],
            "the fake reports every card with an address, well-formed or not; filtering is the reducer's job")
}
