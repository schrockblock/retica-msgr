import Foundation
import SQLiteData

/// One entry in the dedup ring set, mirrored from `LXMFRouter.State.seen` so a cold start
/// does not re-deliver messages the router already processed.
///
/// **`storedAt` ordering is load-bearing.** The rehydration query must supply rows
/// **oldest-first** (ascending `storedAt`) because `RingSet` evicts at capacity and insertion
/// order decides which hashes survive. Supplying newest-first would retain the oldest 10 000
/// instead of the newest — the feature is defeated while every test passes. The `ORDER BY
/// storedAt` in `AppFeature.onLaunch` satisfies this contract.
///
/// **Table is pruned to `RingSet.capacity` (10 000)** on every write. The in-memory ring
/// discards the oldest hash at capacity; without the same prune the DB would grow indefinitely
/// while mirroring a bounded structure. The prune always keeps the newest 10 000, matching what
/// the ring would retain.
///
/// **Write policy — one row per delivered message, no batching.** Durability beats write volume
/// here: on iOS the process kill is the normal suspend path, so a batch window is a routine loss
/// window. This is a deliberate starting point chosen to be pulled back if write pressure proves
/// to be a problem; the pull-back shape is a time-based batch with a flush on
/// applicationDidEnterBackground / applicationWillTerminate.
///
/// Reference for the dedup set: `LXMRouter.py:1837-1844` (RNS 1.4.2/LXMF 1.1.0) inserts
/// `message.hash` into `delivery_hashes` immediately before delivering.
@Table
public struct SeenHashRow: Equatable, Sendable {
    /// `LXMessage.hash` (32 bytes, hex-encoded). Primary key.
    public var hashHex: String
    /// When this hash was first seen (wall-clock time from the `\.date` dependency).
    /// Used for pruning (oldest pruned first) and for the `ORDER BY` that makes rehydration
    /// deterministic.
    public var storedAt: Date

    public init(hashHex: String, storedAt: Date) {
        self.hashHex = hashHex
        self.storedAt = storedAt
    }
}
