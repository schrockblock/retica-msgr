import Foundation
import Dependencies
import ReTiCA
import ReTiCAKeychain

/// The identity that signs ReTiCA's tunnel-synthesis packets: on each TCP connect the transport
/// sends one, so a reference hub restores its paths to us at once instead of waiting for our
/// re-announce, which hubs rate-limit. It is NOT the LXMF identity and NOT a transport identity
/// (setting it leaves the node a leaf, ReTiCA Ruling 9b). It must stay the same across launches,
/// because the hub files the tunnel under a hash of its public key: a new one each launch would
/// restore nothing.
///
/// Minted once into its own Keychain item and loaded from it ever after, through
/// `IdentityKeychain.loadOrCreate`, so it gets the identity's guarantees: add-only, never
/// overwritten, and nothing minted while a read fails (a prewarm launch before first unlock gets
/// nil, and the tunnel waits for the next launch rather than rotating).
public struct TunnelIdentityStore: Sendable {
    /// The tunnel identity, minted on first use. Nil when the Keychain could not be read or written.
    public var load: @Sendable () -> Identity?

    public init(load: @escaping @Sendable () -> Identity?) {
        self.load = load
    }

    /// In the identity's access group, which every entitlement file lists, under this app's own
    /// service: `IdentityKeychain` probes by service, so it can't collide with the shared identity.
    public static let location = IdentityKeychain.Location(
        service: "co.lithobyte.reticamsgr.tunnel-identity",
        accessGroup: SharedIdentityLocation.accessGroup)

    /// Holds nothing and touches no Keychain: the test value, and `AppRuntime`'s default. No
    /// tunnel identity means no synthesis packets; everything else works as before.
    public static let inert = TunnelIdentityStore(load: { nil })

    public static func live(ops: KeychainOps) -> TunnelIdentityStore {
        TunnelIdentityStore(load: {
            IdentityKeychain.loadOrCreate(shared: location, legacy: [], ops: ops).identity
        })
    }
}

extension TunnelIdentityStore: DependencyKey {
    public static var liveValue: TunnelIdentityStore { live(ops: .live) }
    /// Benign, not `unimplemented`: every `AppFeature` test sends `.onLaunch`, which reads it.
    public static var testValue: TunnelIdentityStore { inert }
    public static var previewValue: TunnelIdentityStore { inert }
}

public extension DependencyValues {
    var tunnelIdentityStore: TunnelIdentityStore {
        get { self[TunnelIdentityStore.self] }
        set { self[TunnelIdentityStore.self] = newValue }
    }
}
