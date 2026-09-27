import Testing
import Foundation
@testable import ReTiCaMsgrCore

/// Review Focus 1: a peer's clock can say anything. Only values that store and read back as a
/// Date are kept. Everything else becomes nil ("—" in Info) instead of poisoning the row.
@Test func infoReceiveSenderTimestampRejectsUnrepresentableValues() {
    #expect(MessageMetadata.senderTimestamp(1700000000.5) == Date(timeIntervalSince1970: 1700000000.5))
    #expect(MessageMetadata.senderTimestamp(0) == Date(timeIntervalSince1970: 0))
    #expect(MessageMetadata.senderTimestamp(253_402_300_799) == Date(timeIntervalSince1970: 253_402_300_799))
    #expect(MessageMetadata.senderTimestamp(253_402_300_800) == nil)
    #expect(MessageMetadata.senderTimestamp(1e18) == nil)
    #expect(MessageMetadata.senderTimestamp(-1) == nil)
    #expect(MessageMetadata.senderTimestamp(.nan) == nil)
    #expect(MessageMetadata.senderTimestamp(.infinity) == nil)
}
