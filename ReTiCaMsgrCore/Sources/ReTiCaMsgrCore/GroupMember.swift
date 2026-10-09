import Foundation
import GRDB
import SQLiteData

/// One member of one group, me included (spec 2026-10-09 §2). Replaced whole on every applied
/// roster, so the table always mirrors the creator's last roster.
@Table
public struct GroupMember: Equatable, Sendable {
    public var groupHex: String
    public var memberHex: String

    public init(groupHex: String, memberHex: String) {
        self.groupHex = groupHex
        self.memberHex = memberHex
    }

    /// The roster, sorted, so two rosters compare by value.
    public static func members(of groupHex: String, _ db: GRDB.Database) throws -> [String] {
        try GroupMember.where { $0.groupHex.eq(groupHex) }.fetchAll(db).map(\.memberHex).sorted()
    }

    public static func replace(_ groupHex: String, with members: [String], _ db: GRDB.Database) throws {
        try GroupMember.where { $0.groupHex.eq(groupHex) }.delete().execute(db)
        for member in Set(members) {
            try GroupMember.insert { GroupMember(groupHex: groupHex, memberHex: member) }.execute(db)
        }
    }

    public static func contains(_ groupHex: String, _ memberHex: String, _ db: GRDB.Database) throws -> Bool {
        try GroupMember.where { $0.groupHex.eq(groupHex) && $0.memberHex.eq(memberHex) }.fetchOne(db) != nil
    }
}
