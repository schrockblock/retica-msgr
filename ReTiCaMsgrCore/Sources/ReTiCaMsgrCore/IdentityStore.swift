import Foundation
import Dependencies
import ReTiCA
#if canImport(Security)
import Security
#endif

// Data.hexString in ReTiCA is internal; provide a local equivalent.
private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// Loads the persistent user Identity: from Keychain if present, else generates + stores one.
public struct IdentityStore: Sendable {
    public var load: @Sendable () -> Identity
}

/// The user's shareable LXMF address = their lxmf.delivery destination hash, hex-encoded.
public func lxmfAddressHex(_ identity: Identity) -> String {
    LXMessage.deliveryHash(identityHash: identity.hash).hexString
}

extension IdentityStore: DependencyKey {
    public static var liveValue: IdentityStore {
        IdentityStore(load: {
            #if canImport(Security)
            if let data = KeychainIdentity.read(), let id = Identity(privateKey: data) { return id }
            let id = Identity()
            if let pk = id.privateKey { KeychainIdentity.write(pk) }
            return id
            #else
            return Identity()
            #endif
        })
    }
    public static var testValue: IdentityStore {
        // Deterministic-enough for tests: a fixed in-process identity.
        let id = Identity()
        return IdentityStore(load: { id })
    }
}

public extension DependencyValues {
    var identityStore: IdentityStore {
        get { self[IdentityStore.self] }
        set { self[IdentityStore.self] = newValue }
    }
}

#if canImport(Security)
enum KeychainIdentity {
    static let service = "com.reticamsgr.identity"
    static let account = "primary"
    static func read() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    static func write(_ data: Data) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}
#endif
