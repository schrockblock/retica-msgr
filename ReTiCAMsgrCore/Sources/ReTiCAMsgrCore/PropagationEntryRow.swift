import Foundation
import SQLiteData

/// One stored propagation entry, mirrored from the in-memory `PropagationStore` so a node's
/// store-and-forward backlog survives relaunch. `transientIdHex` is the LXMF transient_id (hex) —
/// the store's dedup key; `lxmfData` is the exact stamped bytes the node ingested and re-serves.
@Table
public struct PropagationEntryRow: Identifiable, Equatable, Sendable {
    public var id: String { transientIdHex }
    public var transientIdHex: String
    public var destinationHashHex: String
    public var lxmfData: Data
    public var storedAt: Date

    public init(transientIdHex: String, destinationHashHex: String, lxmfData: Data, storedAt: Date) {
        self.transientIdHex = transientIdHex
        self.destinationHashHex = destinationHashHex
        self.lxmfData = lxmfData
        self.storedAt = storedAt
    }
}
