import Foundation
import GRDB
import SQLiteData

/// One member's copy of one outgoing group row (spec 2026-10-09 §2): its LXMF hash once built,
/// and the outcome the delivery delegates reported for that hash. `messageHash` is nil and
/// `status` is `GroupDeliveryStatus.waiting` until the member has a path; from then on `status`
/// takes the `MessageStatus` values with the same first-milestone rules as `messages`.
@Table
public struct GroupDelivery: Equatable, Sendable {
    public var messageId: UUID
    public var memberHex: String
    public var messageHash: String?
    public var status: String
    public var storedAt: Date?
    public var deliveredAt: Date?
    public var failedAt: Date?

    public init(messageId: UUID, memberHex: String, messageHash: String?, status: String,
                storedAt: Date?, deliveredAt: Date?, failedAt: Date?) {
        self.messageId = messageId
        self.memberHex = memberHex
        self.messageHash = messageHash
        self.status = status
        self.storedAt = storedAt
        self.deliveredAt = deliveredAt
        self.failedAt = failedAt
    }

    /// A row that has not been sent yet: the member has no path.
    public static func waiting(messageId: UUID, memberHex: String) -> GroupDelivery {
        GroupDelivery(messageId: messageId, memberHex: memberHex, messageHash: nil,
                      status: GroupDeliveryStatus.waiting, storedAt: nil, deliveredAt: nil, failedAt: nil)
    }

    /// Rows keyed by their message, each list sorted by member so the UI order is stable.
    public static func byMessageId(_ rows: [GroupDelivery]) -> [UUID: [GroupDelivery]] {
        Dictionary(grouping: rows, by: \.messageId).mapValues { $0.sorted { $0.memberHex < $1.memberHex } }
    }

    /// Writes the row's derived status (amendment A8) into `messages.status`, so the bubble, the
    /// list preview and the Info sheet keep reading one column.
    public static func refreshDerivedStatus(messageId: UUID, _ db: GRDB.Database) throws {
        let rows = try GroupDelivery.where { $0.messageId.eq(messageId) }.fetchAll(db)
        let status = GroupRoster.derivedStatus(rows)
        try Message.where { $0.id.eq(messageId) }.update { $0.status = status }.execute(db)
    }
}

public enum GroupDeliveryStatus {
    /// Not sent yet: the member had no known path when the row was written.
    public static let waiting = "waiting"
}
