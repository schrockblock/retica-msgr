import Foundation
import SQLiteData
import ReTiCA
import ReTiCATransport

/// One entry in the learned-destination table, mirrored from `Transport.State.learned` so a cold
/// start can route to known destinations immediately, without waiting for re-announces.
///
/// Mirrors reference's `save_path_table` / `load_path_table` (stock 1.4.2 `Transport.py:3335`,
/// `:307`). Reference also saves the packet-hash ring (`save_packet_hashlist`, `:3292`) — we
/// deliberately do NOT: at `seenPacketRingSize = 262_144` entries that ring is ~8.4 MB. Writing
/// it on a 30 s debounce (the policy here) would be continuous disk traffic. Losing it costs
/// re-processing and briefly reopens announce-loop damping, not data loss, because
/// `LXMFRouter.seen` persists at the LXMF layer. **This is a deliberate divergence; record it
/// as one.** See the plan's Background section for the full ruling.
///
/// **Write policy — debounced, NOT per-event.** `learned` updates on EVERY announce that improves
/// a path: a per-event write would mean continuous disk traffic on a busy mesh. The debounce
/// window is ~30 s; the loss on a kill in that window is re-learned from the next announce. A
/// flush fires on `applicationDidEnterBackground` / `applicationWillTerminate` to close the window
/// before the process is killed by the OS.
///
/// This is a DELIBERATE contrast with `SeenHashRow` and `LearnedPeerRow`, which write per-event.
/// The reason is the write *rate*, not a change of principle: messages and peer announces are
/// discrete and infrequent; path updates are continuous on a meshed network. See `SeenHashRow`'s
/// write-policy comment for the per-event rationale.
///
/// **Expiry.** `learned` is swept by `Transport.maintenanceTick` using `Transport.pathExpiry`
/// (7 days by default). This table is pruned at launch — BEFORE the read — on the same 7-day
/// cutoff. Without the prune, a destination heard once and never again accumulates on disk
/// forever while the in-memory table stays bounded.
///
/// `Transport.rehydrateLearnedDestinations` enforces the same cutoff in one more pass, dropping
/// rows that expired between the prune and the action landing. The double-check is cheap and
/// closes a race where a row that expired during the read would otherwise be restored.
@Table
public struct LearnedDestinationRow: Equatable, Sendable {
    /// Destination hash (16 bytes, hex-encoded). Primary key.
    public var destinationHashHex: String
    /// The destination's public key (64 bytes, hex-encoded). Used to reconstruct `Identity`.
    public var publicKeyHex: String
    /// Optional announce app-data, hex-encoded.
    public var appDataHex: String?
    /// Optional 32-byte ratchet public key, hex-encoded.
    public var ratchetHex: String?
    /// The `InterfaceID.rawValue` through which this destination was last heard.
    public var interfaceId: String
    /// Hop count as of the last announce.
    public var hops: Int
    /// Optional next-hop transport identity (16 bytes, hex-encoded); nil if directly heard.
    public var nextHopHex: String?
    /// Emission timestamp from the announce's random hash (UInt64 as Int64 in storage).
    public var announceEmitted: Int
    /// When this path was learned. Used for expiry (Transport.pathExpiry = 7 days).
    public var learnedAt: Date

    public init(destinationHashHex: String, publicKeyHex: String, appDataHex: String?,
                ratchetHex: String?, interfaceId: String, hops: Int, nextHopHex: String?,
                announceEmitted: Int, learnedAt: Date) {
        self.destinationHashHex = destinationHashHex
        self.publicKeyHex = publicKeyHex
        self.appDataHex = appDataHex
        self.ratchetHex = ratchetHex
        self.interfaceId = interfaceId
        self.hops = hops
        self.nextHopHex = nextHopHex
        self.announceEmitted = announceEmitted
        self.learnedAt = learnedAt
    }
}

extension LearnedDestinationRow {
    /// Build a row from a destination hash and its `LearnedDestination`.
    ///
    /// Returns nil if the destination hash is not 16 bytes (malformed, should not happen in
    /// practice) or if `announceEmitted` overflows `Int` (cannot happen on current platforms
    /// where `Int` is 64-bit — guarded defensively).
    init?(hash: Data, destination: LearnedDestination) {
        guard hash.count == 16 else { return nil }
        // UInt64 → Int: on 64-bit platforms Int is 64 bits so this is always exact.
        // Guard defensively so a 32-bit build (if one ever exists) traps here not silently.
        let emitted = Int(exactly: destination.announceEmitted) ?? Int(bitPattern: UInt(destination.announceEmitted & UInt64(bitPattern: Int64.max)))
        self.init(
            destinationHashHex: hash.hexString,
            publicKeyHex: destination.identity.publicKey.hexString,
            appDataHex: destination.appData.map(\.hexString),
            ratchetHex: destination.ratchet.map(\.hexString),
            interfaceId: destination.interfaceID.rawValue,
            hops: Int(destination.hops),
            nextHopHex: destination.nextHop.map(\.hexString),
            announceEmitted: emitted,
            learnedAt: destination.learnedAt
        )
    }

    /// Reconstruct a `LearnedDestination` from this row.
    ///
    /// Returns nil if the public key is malformed (shouldn't happen on a write we generated,
    /// but DB rows can be corrupted externally) or if required hex fields don't decode.
    func toLearnedDestination() -> (hash: Data, destination: LearnedDestination)? {
        guard let hashData = Data(hexString: destinationHashHex),
              hashData.count == 16,
              let publicKeyData = Data(hexString: publicKeyHex),
              let identity = Identity(publicKey: publicKeyData)
        else { return nil }

        let appData = appDataHex.flatMap { Data(hexString: $0) }
        let ratchet = ratchetHex.flatMap { Data(hexString: $0) }
        let nextHop = nextHopHex.flatMap { Data(hexString: $0) }
        // announceEmitted is stored as Int (always 64-bit on our platform), safe to cast.
        let emitted = UInt64(bitPattern: Int64(announceEmitted))

        let destination = LearnedDestination(
            identity: identity,
            appData: appData,
            ratchet: ratchet,
            interfaceID: InterfaceID(interfaceId),
            hops: UInt8(clamping: hops),
            nextHop: nextHop,
            announceEmitted: emitted,
            learnedAt: learnedAt
        )
        return (hash: hashData, destination: destination)
    }
}
