import Testing
import Foundation
import GRDB
import SQLiteData
@testable import ReTiCAMsgrCore

// MARK: - learnedPeerStampCostToReal

/// A row written as INTEGER before the migration (the old schema) loads as that number, a nil cost
/// stays nil, and the other columns survive the column swap.
@Test func fractionalCostOldIntegerRowLoadsAsDouble() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator().migrate(queue, upTo: "addKnownDestinationRatchets")
    try queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO learnedPeerRows (destinationHashHex, displayName, stampCost, supportsCompression, learnedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [String(repeating: "a", count: 32), "Ada", 8, 1, "2023-11-14 22:13:20.000"])
        try db.execute(
            sql: """
                INSERT INTO learnedPeerRows (destinationHashHex, displayName, stampCost, supportsCompression, learnedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [String(repeating: "b", count: 32), nil, nil, 0, "2023-11-14 22:13:20.000"])
    }
    try AppDatabase.migrator().migrate(queue)
    let rows = try queue.read { try LearnedPeerRow.all.fetchAll($0) }
    let ada = try #require(rows.first { $0.destinationHashHex == String(repeating: "a", count: 32) })
    #expect(ada.stampCost == 8.0)
    #expect(ada.displayName == "Ada")
    #expect(ada.supportsCompression == true)
    #expect(ada.learnedAt == Date(timeIntervalSince1970: 1700000000))
    let none = try #require(rows.first { $0.destinationHashHex == String(repeating: "b", count: 32) })
    #expect(none.stampCost == nil)
    // The column is REAL now, so a fractional value is stored exactly, not truncated.
    let columnType = try queue.read { db in
        try db.columns(in: "learnedPeerRows").first { $0.name == "stampCost" }?.type
    }
    #expect(columnType?.uppercased() == "DOUBLE" || columnType?.uppercased() == "REAL")
}

@Test func fractionalCostRoundTrips() throws {
    let db = try AppDatabase.makeInMemory()
    let row = LearnedPeerRow(destinationHashHex: String(repeating: "c", count: 32), displayName: "Cy",
                             stampCost: 8.5, supportsCompression: true,
                             learnedAt: Date(timeIntervalSince1970: 1700000000))
    try db.write { try LearnedPeerRow.insert { row }.execute($0) }
    let back = try #require(try db.read { try LearnedPeerRow.all.fetchAll($0) }.first)
    #expect(back.stampCost == 8.5)
    #expect(back == row)
    // Stored as a REAL, not as text or a truncated integer.
    let stored = try db.read { try String.fetchOne($0, sql: "SELECT typeof(stampCost) FROM learnedPeerRows") }
    #expect(stored == "real")
}

// MARK: - Display

@Test func fractionalCostDisplayDropsTrailingZeroOnly() {
    #expect(DiagnosticsSnapshot.formatStampCost(8) == "8")
    #expect(DiagnosticsSnapshot.formatStampCost(8.0) == "8")
    #expect(DiagnosticsSnapshot.formatStampCost(8.5) == "8.5")
    #expect(DiagnosticsSnapshot.formatStampCost(3.25) == "3.25")
    #expect(DiagnosticsSnapshot.formatStampCost(0) == "0")
    // Hostile values must not trap on the Int conversion.
    #expect(DiagnosticsSnapshot.formatStampCost(.infinity) == "inf")
    #expect(DiagnosticsSnapshot.formatStampCost(.nan) == "nan")
    #expect(DiagnosticsSnapshot.formatStampCost(1e300) == String(1e300))
}
