import Foundation
import SQLiteData

/// A single chat message row. `peerHex` is the other party's lxmf.delivery hash (hex);
/// `messageHash` is the LXMessage.hash (hex) — correlates deliveryFailed for outgoing rows and is
/// the reaction target for all rows.
@Table
public struct Message: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var peerHex: String
    public var isOutgoing: Bool
    public var body: String
    public var timestamp: Date
    public var status: String        // MessageStatus.*
    public var validated: Bool       // incoming: signature validated
    public var messageHash: String   // LXMessage.hash hex ("" for incoming rows stored before reactions shipped)

    public init(
        id: UUID,
        peerHex: String,
        isOutgoing: Bool,
        body: String,
        timestamp: Date,
        status: String,
        validated: Bool,
        messageHash: String
    ) {
        self.id = id
        self.peerHex = peerHex
        self.isOutgoing = isOutgoing
        self.body = body
        self.timestamp = timestamp
        self.status = status
        self.validated = validated
        self.messageHash = messageHash
    }
}

public enum MessageStatus {
    public static let sending = "sending"
    public static let sent = "sent"
    public static let failed = "failed"
    public static let received = "received"
    public static let propagated = "stored"
}
