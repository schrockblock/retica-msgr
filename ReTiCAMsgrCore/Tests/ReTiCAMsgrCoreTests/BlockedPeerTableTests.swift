import Testing
import Foundation
import GRDB
@testable import ReTiCAMsgrCore

private let blockTablePeerA = String(repeating: "a", count: 32)
private let blockTablePeerB = String(repeating: "b", count: 32)
private let blockTableT0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test func blockTableRoundTrips() throws {
    let db = try AppDatabase.makeInMemory()
    let row = BlockedPeer(peerHex: blockTablePeerA, blockedAt: blockTableT0)
    try db.write { try BlockedPeer.insertIfAbsent(row, $0) }
    #expect(try db.read { try BlockedPeer.fetch(peerHex: blockTablePeerA, $0) } == row)
    #expect(try db.read { try BlockedPeer.fetch(peerHex: blockTablePeerB, $0) } == nil)
}

@Test func blockTableInsertIfAbsentKeepsTheFirstDate() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: blockTablePeerA, blockedAt: blockTableT0), $0) }
    try db.write { try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: blockTablePeerA, blockedAt: blockTableT0 + 60), $0) }
    let rows = try db.read { try BlockedPeer.all($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.blockedAt == blockTableT0)
}

@Test func blockTableAllIsNewestFirst() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write {
        try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: blockTablePeerA, blockedAt: blockTableT0), $0)
        try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: blockTablePeerB, blockedAt: blockTableT0 + 60), $0)
    }
    #expect(try db.read { try BlockedPeer.all($0) }.map(\.peerHex) == [blockTablePeerB, blockTablePeerA])
}

@Test func blockTableDeleteRemovesOnlyThatPeer() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write {
        try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: blockTablePeerA, blockedAt: blockTableT0), $0)
        try BlockedPeer.insertIfAbsent(BlockedPeer(peerHex: blockTablePeerB, blockedAt: blockTableT0), $0)
    }
    try db.write { try BlockedPeer.delete(peerHex: blockTablePeerA, $0) }
    #expect(try db.read { try BlockedPeer.all($0) }.map(\.peerHex) == [blockTablePeerB])
    // Deleting an absent row is a no-op, not an error.
    try db.write { try BlockedPeer.delete(peerHex: blockTablePeerA, $0) }
}
