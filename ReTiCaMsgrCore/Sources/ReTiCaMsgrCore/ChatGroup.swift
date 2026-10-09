import Foundation
import GRDB
import SQLiteData

/// One group the user created or was invited to (spec 2026-10-09 §2). Named `ChatGroup` because
/// SwiftUI owns `Group` and `GROUPS` is an SQLite keyword (amendment A1). `creatorHex` is the
/// roster authority: the sender of the first roster ever seen for this id, or me. `revision` is
/// the last applied roster revision. `state` is `GroupState.*`.
@Table
public struct ChatGroup: Equatable, Sendable {
    public var groupHex: String
    public var name: String
    public var creatorHex: String
    public var revision: Int
    public var state: String
    public var updatedAt: Date

    public init(groupHex: String, name: String, creatorHex: String, revision: Int, state: String, updatedAt: Date) {
        self.groupHex = groupHex
        self.name = name
        self.creatorHex = creatorHex
        self.revision = revision
        self.state = state
        self.updatedAt = updatedAt
    }

    /// Posts, reactions and leaves from members are accepted while the group is invited or active.
    public var isOpen: Bool { state == GroupState.active || state == GroupState.invited }

    public static func fetch(_ groupHex: String, _ db: GRDB.Database) throws -> ChatGroup? {
        try ChatGroup.where { $0.groupHex.eq(groupHex) }.fetchOne(db)
    }

    /// Upsert by primary key. Never deletes the row: `groupMembers` cascades from it, so a
    /// delete-then-insert (the `ConversationSetting.set` pattern) would wipe the roster.
    public static func upsert(_ group: ChatGroup, _ db: GRDB.Database) throws {
        if try fetch(group.groupHex, db) == nil {
            try ChatGroup.insert { group }.execute(db)
        } else {
            try ChatGroup.where { $0.groupHex.eq(group.groupHex) }
                .update {
                    $0.name = group.name
                    $0.creatorHex = group.creatorHex
                    $0.revision = group.revision
                    $0.state = group.state
                    $0.updatedAt = group.updatedAt
                }
                .execute(db)
        }
    }
}

public enum GroupState {
    /// A roster arrived for a group the user has not accepted yet.
    public static let invited = "invited"
    public static let active = "active"
    /// The user left, declined, or was removed. Read-only.
    public static let left = "left"
    /// The creator deleted the group (an empty roster). Read-only and terminal.
    public static let dissolved = "dissolved"
}

/// What an outgoing event line carries to the members (`Message.groupControl`).
public enum GroupControl {
    public static let roster = "roster"
    public static let leave = "leave"
}
