import Foundation
import SQLiteData
import ReTiCA
import ReTiCATransport

/// One entry in the known-destination table, mirrored from `Transport.State.knownDestinations`
/// (reference `Identity.known_destinations`, saved to `storagepath/known_destinations`).
///
/// **Why it exists.** Since RNS 1.6 network stamps, a known destination carries `linkCost`: the
/// stamp cost that destination demands on link requests. Peers running reference RNS 1.6.x with
/// enforcement drop a link request whose key does not meet it. `LearnedDestinationRow` restores the
/// PATH after a relaunch but not this table, so without it the cost is forgotten: the first link to
/// an enforcing peer goes out unstamped and fails until that peer announces again.
///
/// **Write policy.** The same debounced full-snapshot write as `LearnedDestinationRow`: written
/// alongside the learned table by the ~30 s debounce (`._flushLearnedDestinations`) and by the
/// immediate flush on `.backgrounded`. See `LearnedDestinationRow` for why this is debounced, not
/// per-event.
///
/// **Expiry.** `knownDestinations` is swept by `Transport.maintenanceTick` on
/// `Transport.knownDestinationExpiry`. This table is pruned at launch, BEFORE the read, on the same
/// cutoff, so a destination heard once does not stay on disk forever.
/// `Transport.rehydrateKnownDestinations` applies the cutoff again, drops future-dated rows and rows
/// for our own destinations, and never overwrites a fresher live entry.
@Table
public struct KnownDestinationRow: Equatable, Sendable {
    /// Destination hash (16 bytes, hex-encoded). Primary key.
    public var destinationHashHex: String
    /// The destination's public key (64 bytes, hex-encoded). Used to reconstruct `Identity`.
    public var publicKeyHex: String
    /// App data from the most recent announce, hex-encoded, or nil.
    public var appDataHex: String?
    /// When the most recent valid announce was heard. Used for expiry.
    public var lastHeard: Date
    /// The link-request stamp cost the destination announced, or nil.
    public var linkCost: Double?
    /// The value of the most recent announce's network stamp, or nil.
    public var stampValue: Double?

    public init(destinationHashHex: String, publicKeyHex: String, appDataHex: String?,
                lastHeard: Date, linkCost: Double?, stampValue: Double?) {
        self.destinationHashHex = destinationHashHex
        self.publicKeyHex = publicKeyHex
        self.appDataHex = appDataHex
        self.lastHeard = lastHeard
        self.linkCost = linkCost
        self.stampValue = stampValue
    }
}

extension KnownDestinationRow {
    /// Build a row from a destination hash and its `KnownDestination`. Nil if the hash is not
    /// 16 bytes.
    init?(hash: Data, destination: KnownDestination) {
        guard hash.count == 16 else { return nil }
        self.init(
            destinationHashHex: hash.hexString,
            publicKeyHex: destination.identity.publicKey.hexString,
            appDataHex: destination.appData.map(\.hexString),
            lastHeard: destination.lastHeard,
            linkCost: destination.linkCost,
            stampValue: destination.stampValue
        )
    }

    /// Reconstruct a `KnownDestination` from this row. Nil if the hash or public key is malformed.
    func toKnownDestination() -> (hash: Data, destination: KnownDestination)? {
        guard let hashData = Data(hexString: destinationHashHex),
              hashData.count == 16,
              let publicKeyData = Data(hexString: publicKeyHex),
              let identity = Identity(publicKey: publicKeyData)
        else { return nil }
        let destination = KnownDestination(
            identity: identity,
            appData: appDataHex.flatMap { Data(hexString: $0) },
            lastHeard: lastHeard,
            linkCost: linkCost,
            stampValue: stampValue
        )
        return (hash: hashData, destination: destination)
    }
}
