import Testing
import Foundation
import GRDB
@testable import ReTiCaMsgrCore

private let linkTablePeer = String(repeating: "a", count: 32)
private let linkTablePeer2 = String(repeating: "b", count: 32)
private let linkTableT0 = Date(timeIntervalSince1970: 1_700_000_000)

private func linkTableRow(peer: String = linkTablePeer, contact: String = "CN-1", name: String = "Jane Doe",
                          source: String = ContactLinkSource.manual, verified: Bool = true) -> ContactLink {
    ContactLink(peerHex: peer, contactIdentifier: contact, cachedName: name, source: source,
                discoveredViaHex: nil, discoveredSessionId: nil, discoveredAt: nil,
                confirmationsJSON: "[]", verified: verified, conflictedAt: nil, conflictPeerHex: nil,
                createdAt: linkTableT0, updatedAt: linkTableT0)
}

@Test func linkTableRoundTripsEveryColumn() throws {
    let db = try AppDatabase.makeInMemory()
    var row = linkTableRow(source: ContactLinkSource.discovered, verified: false)
    row.discoveredViaHex = linkTablePeer2
    row.discoveredSessionId = "sess-1"
    row.discoveredAt = linkTableT0
    row.confirmations = [ContactConfirmation(peerHex: linkTablePeer2, sessionId: "sess-2", date: linkTableT0)]
    row.conflictedAt = linkTableT0
    row.conflictPeerHex = linkTablePeer2
    try db.write { try ContactLink.insertReplacing(row, $0) }
    let back = try db.read { try ContactLink.fetch(peerHex: linkTablePeer, $0) }
    #expect(back == row)
    #expect(back?.confirmations == [ContactConfirmation(peerHex: linkTablePeer2, sessionId: "sess-2", date: linkTableT0)])
    #expect(try db.read { try ContactLink.fetch(contactIdentifier: "CN-1", $0) } == row)
    #expect(try db.read { try ContactLink.fetch(peerHex: linkTablePeer2, $0) } == nil)
}

@Test func linkTableContactIdentifierIsUnique() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try ContactLink.insert { linkTableRow() }.execute($0) }
    // A raw insert (not `insertReplacing`) with the same contact for another peer must fail.
    #expect(throws: (any Error).self) {
        try db.write { try ContactLink.insert { linkTableRow(peer: linkTablePeer2, contact: "CN-1") }.execute($0) }
    }
    #expect(try db.read { try ContactLink.all($0) }.count == 1)
}

@Test func linkTableInsertReplacingDropsBothCollidingRows() throws {
    let db = try AppDatabase.makeInMemory()
    let peer3 = String(repeating: "c", count: 32)
    try db.write { db in
        try ContactLink.insertReplacing(linkTableRow(peer: linkTablePeer, contact: "CN-1"), db)
        try ContactLink.insertReplacing(linkTableRow(peer: linkTablePeer2, contact: "CN-2"), db)
    }
    // peer3 takes CN-1 (collides on contact) — and we re-point linkTablePeer2 to CN-9 (collides on peer).
    try db.write { db in
        try ContactLink.insertReplacing(linkTableRow(peer: peer3, contact: "CN-1", name: "Jane (new)"), db)
        try ContactLink.insertReplacing(linkTableRow(peer: linkTablePeer2, contact: "CN-9", name: "Bob"), db)
    }
    let all = try db.read { try ContactLink.all($0) }
    #expect(all.map(\.peerHex) == [linkTablePeer2, peer3])
    #expect(all.map(\.contactIdentifier) == ["CN-9", "CN-1"])
    #expect(try db.read { try ContactLink.fetch(peerHex: linkTablePeer, $0) } == nil, "the old owner of CN-1 is gone")
}

@Test func linkTableDeleteAndEmptyConfirmations() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try ContactLink.insertReplacing(linkTableRow(), $0) }
    #expect(try db.read { try ContactLink.fetch(peerHex: linkTablePeer, $0) }?.confirmations == [])
    try db.write { try ContactLink.delete(peerHex: linkTablePeer, $0) }
    #expect(try db.read { try ContactLink.all($0) }.isEmpty)
    // A malformed JSON blob reads as no confirmations rather than crashing.
    var row = linkTableRow()
    row.confirmationsJSON = "not json"
    #expect(row.confirmations == [])
}
