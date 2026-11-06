import Foundation
import Dependencies
import ReTiCA
import ReTiCAKeychain
import Security

/// The one Keychain item every app on the team reads (spec 2026-09-29 §5.2). Nbhd wrote it first;
/// this app never uses its own `SecItem` code, so its copy collides and dedupes with Nbhd's.
public enum SharedIdentityLocation {
    public static let service = "reticulum.identity"
    /// Must equal `$(AppIdentifierPrefix)co.lithobyte.reticulum.identity` in ReTiCAMsgr.entitlements.
    public static let accessGroup = "HK6WSAR793.co.lithobyte.reticulum.identity"
    public static let shared = IdentityKeychain.Location(service: service, accessGroup: accessGroup)
}

/// Whether launch may mint (spec §5.3).
public enum LoadPolicy: Sendable, Equatable {
    /// No local state tied to an identity: a fresh install may mint.
    case loadOrCreate
    /// Messages exist: never mint; `.absent` means the key was lost.
    case loadOnly
}

/// User-facing class of a Keychain failure. Public facts only, never key material.
public enum IdentityFailureReason: Sendable, Equatable {
    /// errSecInteractionNotAllowed / errSecNotAvailable: e.g. a prewarm launch before first unlock.
    case locked
    /// errSecMissingEntitlement on read or add: a signing or configuration problem.
    case accessDenied
    /// An item exists where it should not, or several do, or one is iCloud-synchronizable.
    case strayItem(String)
    case corrupt
    case other(Int32?)
}

public enum IdentityLoad: Sendable, Equatable {
    case ready(Identity)
    /// Nothing exists anywhere. Only under `.loadOnly` (`.loadOrCreate` would have minted).
    case absent
    case failed(IdentityFailureReason)
}

public enum RestoreOutcome: Sendable, Equatable {
    case restored(Identity)
    case identityPresent(service: String)
    case invalidKey
    case failed(IdentityFailureReason)
}

/// The single seam to the shared identity: load under a policy, or restore a backup.
public struct IdentityStore: Sendable {
    public var load: @Sendable (LoadPolicy) -> IdentityLoad
    public var restore: @Sendable (_ privateKey: Data) -> RestoreOutcome

    public init(load: @escaping @Sendable (LoadPolicy) -> IdentityLoad,
                restore: @escaping @Sendable (_ privateKey: Data) -> RestoreOutcome) {
        self.load = load
        self.restore = restore
    }

    /// `IdentityKeychain` over the given ops. `shared` is overridable only so a hosted test can
    /// use a test-prefixed service in the real access group.
    public static func live(ops: KeychainOps, shared: IdentityKeychain.Location = SharedIdentityLocation.shared) -> IdentityStore {
        IdentityStore(
            load: { policy in
                switch policy {
                case .loadOrCreate:
                    switch IdentityKeychain.loadOrCreate(shared: shared, legacy: [], ops: ops) {
                    case let .loaded(identity), let .created(identity), let .migrated(identity):
                        return .ready(identity)
                    case let .failed(failure):
                        return .failed(reason(for: failure))
                    }
                case .loadOnly:
                    switch IdentityKeychain.load(shared: shared, legacy: [], ops: ops) {
                    case let .loaded(identity), let .migrated(identity):
                        return .ready(identity)
                    case .absent:
                        return .absent
                    case let .failed(failure):
                        return .failed(reason(for: failure))
                    }
                }
            },
            restore: { privateKey in
                switch IdentityKeychain.importIdentity(privateKey: privateKey, shared: shared, legacy: [], ops: ops) {
                case let .imported(identity): return .restored(identity)
                case let .identityPresent(service): return .identityPresent(service: service)
                case .invalidKey: return .invalidKey
                case let .failed(failure): return .failed(reason(for: failure))
                }
            }
        )
    }

    /// Pure mapping, mirroring Nbhd's so both apps read the same way (spec §5.2).
    public static func reason(for failure: IdentityKeychain.Failure) -> IdentityFailureReason {
        switch failure {
        case let .readFailed(_, status):
            switch status {
            case errSecMissingEntitlement: return .accessDenied
            case errSecInteractionNotAllowed, errSecNotAvailable: return .locked
            default: return .other(status)
            }
        case let .addFailed(status):
            return status == errSecMissingEntitlement ? .accessDenied : .other(status)
        case let .verifyFailed(status):
            return .other(status)
        case .mintFailed, .invalidLocation:
            return .other(nil)
        case .corrupt:
            return .corrupt
        case let .unexpectedItem(service):
            return .strayItem(service)
        case let .ambiguousItems(location, count):
            return .strayItem("\(count) items at \(location.service)")
        case let .synchronizableItem(location):
            return .strayItem("synchronizable item at \(location.service)")
        }
    }
}

/// The user's shareable LXMF address = their lxmf.delivery destination hash, hex-encoded.
public func lxmfAddressHex(_ identity: Identity) -> String {
    LXMessage.deliveryHash(identityHash: identity.hash).hexString
}

extension IdentityStore: DependencyKey {
    public static var liveValue: IdentityStore { live(ops: .live) }
    public static var testValue: IdentityStore {
        // Deterministic-enough for tests: a fixed in-process identity, never the Keychain.
        let identity = Identity()
        return IdentityStore(load: { _ in .ready(identity) }, restore: { _ in .identityPresent(service: "test") })
    }
}

public extension DependencyValues {
    var identityStore: IdentityStore {
        get { self[IdentityStore.self] }
        set { self[IdentityStore.self] = newValue }
    }
}
