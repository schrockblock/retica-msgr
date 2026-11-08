import Foundation
import Dependencies
import ReTiCAKeychain

// The MeshCore channel key and its retired keys (spec 2026-11-07 §6, Contract 3). The key lives only
// in the Keychain. Outside this store it exists only inside a `MeshCoreKeyText` (a sheet's view state)
// or a `MeshCoreSecrets` (lane D's driver start), both of which print as `<redacted>`. It is never
// put in `AppFeature.State` or an `AppFeature.Action`, and never logged.

/// A channel key as 32 hex characters, for the paste and share sheets. Every printing path
/// (`description`, `debugDescription`, `Mirror`, so `dump` and `customDump` too) shows `<redacted>`.
/// `reveal()` is the only way to read it.
public struct MeshCoreKeyText: Equatable, Sendable, Identifiable, CustomStringConvertible,
                               CustomDebugStringConvertible, CustomReflectable {
    private let hex: String

    public init(_ hex: String) {
        self.hex = hex
    }

    public func reveal() -> String {
        hex
    }

    /// Constant, for `.sheet(item:)`: nothing about the key may leak through an identity.
    public var id: Int { 0 }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// What the driver needs at start: the current key and the keys to clear from the radio's slots.
/// Redacted like `MeshCoreKeyText`. `retired` never contains `current`.
public struct MeshCoreSecrets: Equatable, Sendable, CustomStringConvertible,
                               CustomDebugStringConvertible, CustomReflectable {
    public let current: Data
    public let retired: [Data]

    public init(current: Data, retired: [Data]) {
        self.current = current
        self.retired = retired.filter { $0 != current }
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

public enum MeshCoreKeyChangeResult: Equatable, Sendable {
    case changed
    /// The new key is the current key: nothing was written and nothing retired.
    case unchanged
    /// The pasted text is not an acceptable key. Nothing was written.
    case invalid
    case storageFailed
}

/// What a pasted key must look like (spec §6): 32 hex characters, surrounding whitespace and
/// uppercase allowed, and never a secret that is public or hard-coded elsewhere.
public enum MeshCoreKeyRules {
    /// Lowercase hex.
    static let refusedSecrets: Set<String> = [
        // An empty slot's secret (and MeshCore_Raw_Interface.py:898's default).
        "00000000000000000000000000000000",
        // MeshCore Public: PUBLIC_GROUP_PSK in MyMesh.cpp:114, base64 izOH6cXN6mrJ5e26oRXNcg==.
        "8b3387e9c5cdea6ac9e5edbaa115cd72",
        // The secret in ScotMesh's MeshCore_Channel_Interface.py:77 docs.
        "c4d2b6c8254e3b11200f57e95dcb1197",
    ]

    /// The 16 key bytes, or nil when the text is not an acceptable key.
    public static func parse(_ text: String) -> Data? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // ASCII only: `Character.isHexDigit` would also accept fullwidth digits.
        let scalars = hex.unicodeScalars
        guard scalars.count == 32,
              scalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        else { return nil }
        guard !refusedSecrets.contains(hex) else { return nil }
        return Data(hexString: hex)
    }

    static func isAcceptable(_ key: Data) -> Bool {
        key.count == MeshCoreKeyStore.keyLength && !refusedSecrets.contains(key.hexString)
    }
}

/// The channel key store. Every closure reads or writes the Keychain synchronously.
public struct MeshCoreKeyStore: Sendable {
    public var presence: @Sendable () -> MeshCoreKeyPresence
    public var generate: @Sendable () -> MeshCoreKeyChangeResult
    public var paste: @Sendable (MeshCoreKeyText) -> MeshCoreKeyChangeResult
    public var exportText: @Sendable () -> MeshCoreKeyText?
    /// Read only by lane D's driver wrapper at `driver.start`.
    public var secrets: @Sendable () -> MeshCoreSecrets?
    /// Drops these keys from the retired list once the radio no longer holds them.
    public var forgetRetired: @Sendable ([Data]) -> Void

    public init(presence: @escaping @Sendable () -> MeshCoreKeyPresence,
                generate: @escaping @Sendable () -> MeshCoreKeyChangeResult,
                paste: @escaping @Sendable (MeshCoreKeyText) -> MeshCoreKeyChangeResult,
                exportText: @escaping @Sendable () -> MeshCoreKeyText?,
                secrets: @escaping @Sendable () -> MeshCoreSecrets?,
                forgetRetired: @escaping @Sendable ([Data]) -> Void) {
        self.presence = presence
        self.generate = generate
        self.paste = paste
        self.exportText = exportText
        self.secrets = secrets
        self.forgetRetired = forgetRetired
    }

    public static let keyLength = 16

    /// The current key: 16 bytes. In the identity's access group, which both entitlement files
    /// already list. `IdentityKeychain` probes by service, so this can't collide with the identity.
    public static let keyLocation = IdentityKeychain.Location(
        service: "co.lithobyte.reticamsgr.meshcore.channel-key",
        accessGroup: SharedIdentityLocation.accessGroup)

    /// Retired keys, concatenated 16-byte keys. Trailing partial bytes are ignored.
    public static let retiredLocation = IdentityKeychain.Location(
        service: "co.lithobyte.reticamsgr.meshcore.retired-channel-keys",
        accessGroup: SharedIdentityLocation.accessGroup)

    /// 16 bytes from the system's cryptographically secure generator.
    public static func systemRandomKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<keyLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// A store that holds nothing and touches no Keychain: the test value, and `AppRuntime`'s
    /// default so a runtime built without one never reaches the real Keychain.
    public static let inert = MeshCoreKeyStore(
        presence: { .absent },
        generate: { .storageFailed },
        paste: { _ in .storageFailed },
        exportText: { nil },
        secrets: { nil },
        forgetRetired: { _ in })

    public static func live(ops: KeychainOps,
                            randomKey: @escaping @Sendable () -> Data = { MeshCoreKeyStore.systemRandomKey() })
        -> MeshCoreKeyStore {
        MeshCoreKeyStore(
            presence: {
                switch ops.read(keyLocation) {
                case let .found(data, _):
                    // A wrong-length item is not a usable key, but it is not "no key" either.
                    return data.count == keyLength ? .present : .unreadable
                case .notFound:
                    return .absent
                case .failed, .rejected:
                    return .unreadable
                }
            },
            generate: {
                let key = randomKey()
                guard MeshCoreKeyRules.isAcceptable(key) else { return .storageFailed }
                return change(to: key, ops: ops)
            },
            paste: { text in
                guard let key = MeshCoreKeyRules.parse(text.reveal()) else { return .invalid }
                return change(to: key, ops: ops)
            },
            exportText: {
                guard case let .found(data, _) = ops.read(keyLocation), data.count == keyLength else { return nil }
                return MeshCoreKeyText(data.hexString)
            },
            secrets: {
                guard case let .found(current, _) = ops.read(keyLocation), current.count == keyLength,
                      let retired = readRetired(ops)
                else { return nil }
                // A crash between the retire write and the key write leaves the current key on the
                // retired list; it must never be reported as retired, or the driver would clear it.
                return MeshCoreSecrets(current: current, retired: retired)
            },
            forgetRetired: { keys in
                guard let retired = readRetired(ops) else { return }
                let kept = retired.filter { !keys.contains($0) }
                guard kept != retired else { return }
                _ = writeRetired(kept, ops: ops)
            })
    }

    /// (1) Read the current key; a failed read refuses the change, since overwriting a key it can't
    /// read would lose its retired entry. (2) Write the retired list: old retired, minus the new key,
    /// plus the old key. (3) Replace the current item. Crash-safe in that order (see `secrets`).
    private static func change(to key: Data, ops: KeychainOps) -> MeshCoreKeyChangeResult {
        let old: Data?
        switch ops.read(keyLocation) {
        case let .found(data, _):
            // A wrong-length item is not a key the radio can hold: replace it, retire nothing.
            old = data.count == keyLength ? data : nil
        case .notFound:
            old = nil
        case .failed, .rejected:
            return .storageFailed
        }
        if old == key { return .unchanged }

        // An unreadable retired list aborts the change: writing over it would forget retired keys.
        guard let retired = readRetired(ops) else { return .storageFailed }
        var next = retired.filter { $0 != key }
        if let old, !next.contains(old) { next.append(old) }
        if next != retired {
            guard writeRetired(next, ops: ops) else { return .storageFailed }
        }

        switch ops.delete(keyLocation) {
        case .deleted, .notFound: break
        case .failed: return .storageFailed
        }
        guard ops.add(keyLocation, key) == .added else { return .storageFailed }
        return .changed
    }

    /// The retired keys, [] when there is no item, nil when the read fails.
    private static func readRetired(_ ops: KeychainOps) -> [Data]? {
        switch ops.read(retiredLocation) {
        case let .found(data, _):
            let bytes = [UInt8](data)
            return stride(from: 0, to: bytes.count - bytes.count % keyLength, by: keyLength).map {
                Data(bytes[$0 ..< $0 + keyLength])
            }
        case .notFound:
            return []
        case .failed, .rejected:
            return nil
        }
    }

    /// `KeychainOps` has no update: delete, then add. An empty list deletes the item.
    private static func writeRetired(_ keys: [Data], ops: KeychainOps) -> Bool {
        switch ops.delete(retiredLocation) {
        case .deleted, .notFound: break
        case .failed: return false
        }
        guard !keys.isEmpty else { return true }
        return ops.add(retiredLocation, keys.reduce(Data(), +)) == .added
    }
}

extension MeshCoreKeyStore: DependencyKey {
    public static var liveValue: MeshCoreKeyStore { live(ops: .live) }
    /// Benign, not `unimplemented`: `.onLaunch` reads presence, and every `AppFeature` test sends it.
    public static var testValue: MeshCoreKeyStore { inert }
    public static var previewValue: MeshCoreKeyStore { inert }
}

public extension DependencyValues {
    var meshCoreKeyStore: MeshCoreKeyStore {
        get { self[MeshCoreKeyStore.self] }
        set { self[MeshCoreKeyStore.self] = newValue }
    }
}
