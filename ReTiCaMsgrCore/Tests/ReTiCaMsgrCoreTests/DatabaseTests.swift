import Testing
import Foundation
import GRDB
import SQLiteData
@testable import ReTiCaMsgrCore

@Test func messageInsertAndFetchByPeer() throws {
    let db = try AppDatabase.makeInMemory()
    let peer = "aa" + String(repeating: "00", count: 15)
    let m = Message(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        peerHex: peer,
        isOutgoing: true,
        body: "hi",
        timestamp: Date(timeIntervalSince1970: 1),
        status: MessageStatus.sent,
        validated: false,
        messageHash: "abcd"
    )
    try db.write { try Message.insert { m }.execute($0) }
    let rows = try db.read { try Message.where { $0.peerHex.eq(peer) }.order(by: \.timestamp).fetchAll($0) }
    #expect(rows == [m])
}
