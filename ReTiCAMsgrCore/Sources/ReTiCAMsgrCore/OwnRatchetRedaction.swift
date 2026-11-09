import Foundation
import ComposableArchitecture
import ReTiCATransport

// Our own ratchet ring (X25519 private keys) sits in `AppFeature.State` at
// `node.client.endpoint.transport.ownRatchets`. Every generic printing path (`description`,
// `debugDescription`, `Mirror`, so `dump` and `customDump`, which TestStore failure diffs use)
// shows the ring as a key count, never the keys, as `MeshCoreSecrets` does for the channel key.
// (`Data`'s own printing already shows only a byte count; this keeps that true whatever prints the
// ring.) Retroactive: the type is ReTiCA's. If ReTiCA gives `OwnRatchets` these conformances
// itself, this file must go.
extension Transport.State.OwnRatchets: @retroactive CustomStringConvertible,
                                       @retroactive CustomDebugStringConvertible,
                                       @retroactive CustomReflectable,
                                       @retroactive CustomDumpReflectable {
    private var redactedRing: String { "<redacted, \(ring.count) keys>" }

    public var description: String {
        "OwnRatchets(ring: \(redactedRing), lastRotation: \(lastRotation.map { "\($0)" } ?? "nil"), enforce: \(enforce))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["ring": redactedRing, "lastRotation": lastRotation as Any, "enforce": enforce],
               displayStyle: .struct)
    }

    public var customDumpMirror: Mirror { customMirror }
}
