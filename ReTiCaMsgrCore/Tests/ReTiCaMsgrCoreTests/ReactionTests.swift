import Testing
import Foundation
import GRDB
import SQLiteData
@testable import ReTiCaMsgrCore

private let h1 = String(repeating: "1", count: 64)
private let h2 = String(repeating: "2", count: 64)
private let me = String(repeating: "e", count: 32)
private let peer = String(repeating: "p", count: 32)

private func r(_ emoji: String, _ at: Double, hash: String = h1, reactor: String = peer) -> Reaction {
    Reaction(messageHash: hash, reactorHex: reactor, emoji: emoji, sentAt: at)
}

private func all(_ db: any DatabaseWriter) throws -> [Reaction] {
    try db.read { try Reaction.all.fetchAll($0) }
}

@Test func applyInsertsWhenAbsent() throws {
    let db = try AppDatabase.makeInMemory()
    let wrote = try db.write { try Reaction.apply(r("❤️", 10), $0) }
    #expect(wrote)
    #expect(try all(db) == [r("❤️", 10)])
}

@Test func applyNewerReplaces() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try Reaction.apply(r("❤️", 10), $0) }
    try db.write { try Reaction.apply(r("👍", 11), $0) }
    #expect(try all(db) == [r("👍", 11)])
}

@Test func applyOlderIsIgnored() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try Reaction.apply(r("👍", 11), $0) }
    let wrote = try db.write { try Reaction.apply(r("❤️", 10), $0) }
    #expect(!wrote)
    #expect(try all(db) == [r("👍", 11)])
}

@Test func applyEqualTimestampIsIgnored() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try Reaction.apply(r("👍", 11), $0) }
    let wrote = try db.write { try Reaction.apply(r("❤️", 11), $0) }
    #expect(!wrote)
    #expect(try all(db) == [r("👍", 11)])
}

@Test func tombstoneBeatsLateOlderAdd() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try Reaction.apply(r("", 20), $0) }        // removal arrives first
    try db.write { try Reaction.apply(r("❤️", 10), $0) }      // the older add, late
    #expect(try all(db) == [r("", 20)])
}

@Test func reactorsAndMessagesAreIndependentKeys() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try Reaction.apply(r("❤️", 10, hash: h1, reactor: peer), $0) }
    try db.write { try Reaction.apply(r("😂", 5, hash: h1, reactor: me), $0) }
    try db.write { try Reaction.apply(r("👍", 1, hash: h2, reactor: peer), $0) }
    #expect(try all(db).count == 3)
}

@Test func summaryDropsTombstonesCountsAndFlagsMe() {
    let rows = [
        r("❤️", 2, hash: h1, reactor: peer),
        r("❤️", 3, hash: h1, reactor: me),
        r("", 1, hash: h1, reactor: "x"),          // tombstone
    ]
    #expect(ReactionSummary.summarize(rows, me: me) == [.init(emoji: "❤️", count: 2, includesMe: true)])
}

@Test func summaryOrdersByEarliestSentAt() {
    let rows = [r("😂", 5, hash: h1, reactor: peer), r("👍", 1, hash: h1, reactor: me)]
    #expect(ReactionSummary.summarize(rows, me: me).map(\.emoji) == ["👍", "😂"])
    #expect(ReactionSummary.summarize(rows, me: me).map(\.includesMe) == [true, false])
}

@Test func byMessageGroupsAndOmitsAllTombstoneMessages() {
    let rows = [r("😂", 5, hash: h1, reactor: peer), r("", 6, hash: h2, reactor: peer)]
    let grouped = ReactionSummary.byMessage(rows, me: me)
    #expect(grouped.keys.sorted() == [h1])
    #expect(grouped[h1] == [.init(emoji: "😂", count: 1, includesMe: false)])
}
