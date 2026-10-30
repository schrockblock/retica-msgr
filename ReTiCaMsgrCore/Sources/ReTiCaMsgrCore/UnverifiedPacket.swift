import Foundation
import SQLiteData

/// The packed LXMF bytes of an incoming row stored with `validated = false`, kept so
/// `UnverifiedRecheck` can check the signature once the sender's identity is known (spec
/// 2026-10-28). A side table, not a `messages` column: every list and thread reload fetches whole
/// `Message` rows, and up to 256 KB per unknown-sender message must not ride along (final review
/// F1). The row goes on promotion, and with its message (`ON DELETE CASCADE`).
@Table("unverifiedPackets")
public struct UnverifiedPacket: Equatable, Sendable {
    public var messageId: UUID
    public var bytes: Data

    public init(messageId: UUID, bytes: Data) {
        self.messageId = messageId
        self.bytes = bytes
    }
}
