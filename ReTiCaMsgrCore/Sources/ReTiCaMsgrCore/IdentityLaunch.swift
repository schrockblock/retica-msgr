import Foundation
import GRDB
import ReTiCA

public extension LoadPolicy {
    /// Messages exist → never mint. A failed count is "unknown", which is never a fresh install.
    static func forLaunch(database: any DatabaseWriter) -> LoadPolicy {
        let hasMessages = (try? AppDatabase.hasMessages(database)) ?? true
        return hasMessages ? .loadOnly : .loadOrCreate
    }
}

/// The identity hash this device's conversations belong to (spec §5.3). Public, not secret. It
/// survives exactly the restores that lose the Keychain (an unencrypted backup keeps defaults).
public struct IdentityAnchor: @unchecked Sendable {
    public static let key = "reticamsgr.expectedIdentityHash"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// nil when unset or malformed (anything but 32 hex chars).
    public func expected() -> Data? {
        guard let hex = defaults.string(forKey: Self.key), let data = Data(hexString: hex), data.count == 16 else { return nil }
        return data
    }

    /// Writes only when no anchor exists. A differing anchor is kept: the caller refuses ready.
    public func recordReady(_ hash: Data) {
        guard expected() == nil else { return }
        defaults.set(hash.hexString, forKey: Self.key)
    }

    /// The explicit "Use the new identity" path.
    public func replace(with hash: Data) {
        defaults.set(hash.hexString, forKey: Self.key)
    }
}

public enum IdentityState: Equatable, Sendable {
    case loading
    case ready(Data)
    /// `load` returned `.absent` with messages present: the key was lost.
    case missing(expected: Data?)
    /// The shared item holds a different identity from the anchor.
    case identityChanged(expected: Data, got: Data)
    case unavailable(IdentityFailureReason)
}

public enum LaunchIdentity {
    /// One decision for launch, Retry and Restore. Returns the identity only in `.ready`.
    public static func resolve(policy: LoadPolicy, anchor: IdentityAnchor, store: IdentityStore) -> (state: IdentityState, identity: Identity?) {
        switch store.load(policy) {
        case let .failed(reason):
            return (.unavailable(reason), nil)
        case .absent:
            return (.missing(expected: anchor.expected()), nil)
        case let .ready(identity):
            guard let expected = anchor.expected() else {
                anchor.recordReady(identity.hash)
                return (.ready(identity.hash), identity)
            }
            guard expected == identity.hash else {
                return (.identityChanged(expected: expected, got: identity.hash), nil)
            }
            return (.ready(identity.hash), identity)
        }
    }
}

/// The first 8 hex characters of an identity hash, as every recovery screen shows it.
public func shortID(_ hash: Data) -> String {
    String(hash.hexString.prefix(8))
}
