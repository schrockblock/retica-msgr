import Foundation
import SQLiteData

/// One entry in the learned-peer table, mirrored from `LXMFNode.State.learnedPeers` so a cold
/// start can stamp outbound messages at the costs peers last advertised, instead of sending
/// unstamped to every peer until each announce is re-heard — which any peer running
/// `enforce_stamps()` drops.
///
/// Mirrors reference's `outbound_stamp_costs` persistence (LXMRouter.py:1029, LXMF 1.1.0):
/// `[time.time(), stamp_cost]` per delivery destination, loaded at startup and swept by
/// `clean_outbound_stamp_costs` (LXMRouter.py:1272-1285).
///
/// **Expiry is handled by the library, not this table.** `LXMFNode.rehydrateLearnedPeers` drops
/// entries older than `LXMFNode.stampCostExpiry` (45 days), matching reference's startup sweep.
/// This table is not pruned at write time — only a rehydration sees the sweep. Old entries that
/// are never refreshed by a new announce will be dropped when they age past the expiry, and the
/// next announce from that peer repopulates the entry.
///
/// **Write policy — upsert on every `.pathLearned`.** `learnedPeers` is updated once per
/// announce; writing immediately ensures stamp costs survive a kill between announces.
/// An announce is an infrequent event (minutes to hours), so the write rate is negligible.
@Table
public struct LearnedPeerRow: Equatable, Sendable {
    /// `lxmf.delivery` destination hash (16 bytes, hex-encoded). Primary key.
    public var destinationHashHex: String
    /// Display name from the peer's announce app-data, or nil if absent.
    public var displayName: String?
    /// Stamp cost the peer advertised, or nil.
    public var stampCost: Double?
    /// Whether the peer's announce indicated compression support.
    public var supportsCompression: Bool
    /// Wall-clock time the entry was last written. Consumed by `LXMFNode.rehydrateLearnedPeers`
    /// to sweep entries older than `LXMFNode.stampCostExpiry`.
    public var learnedAt: Date

    public init(destinationHashHex: String, displayName: String?, stampCost: Double?,
                supportsCompression: Bool, learnedAt: Date) {
        self.destinationHashHex = destinationHashHex
        self.displayName = displayName
        self.stampCost = stampCost
        self.supportsCompression = supportsCompression
        self.learnedAt = learnedAt
    }
}
