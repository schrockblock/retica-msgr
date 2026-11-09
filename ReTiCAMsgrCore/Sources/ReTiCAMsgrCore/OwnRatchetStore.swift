import Foundation
import Dependencies
import ReTiCAKeychain

/// The own ratchet ring of a destination of ours: X25519 PRIVATE keys, newest first, as ReTiCA
/// reports them with `.ratchetsChanged` and takes them back with `.enableRatchets` (ReTiCA README,
/// "Own ratchets"). The ring lives in the Keychain, one item per destination. Outside this store it
/// is in the actions that carry it and in Transport's state. The app never logs it.
///
/// **Format: the keys concatenated, 32 bytes each, newest first.** Every entry has the same fixed
/// length, so no framing is needed. It is the format `MeshCoreKeyStore`'s retired-key item already
/// uses, and reading it back involves no decoder. A trailing partial key is ignored, and ReTiCA
/// drops any entry that is not a usable key, so a damaged item cannot trap the read. At ReTiCA's cap
/// of 512 keys (`Transport.ratchetCount`) the item is 16 KiB.
public struct OwnRatchetStore: Sendable {
    /// The saved ring for a destination hash: `[]` when there is no item, nil when the Keychain
    /// read failed (or matched an item it refuses to pick). Nil is never "no ring": treating it
    /// that way would start a new ring and the next rotation would overwrite the saved one.
    public var load: @Sendable (_ destinationHash: Data) -> [Data]?
    /// Replaces the saved ring for a destination hash. False when the write failed.
    public var save: @Sendable (_ destinationHash: Data, _ ring: [Data]) -> Bool

    public init(load: @escaping @Sendable (Data) -> [Data]?,
                save: @escaping @Sendable (Data, [Data]) -> Bool) {
        self.load = load
        self.save = save
    }

    public static let keyLength = 32

    /// One item per destination, in the identity's access group (which both entitlement files
    /// already list). The service names the destination, so it can't collide with the identity's
    /// item or the MeshCore keys.
    public static func location(destinationHash: Data) -> IdentityKeychain.Location {
        IdentityKeychain.Location(
            service: "co.lithobyte.reticamsgr.ratchets.\(destinationHash.hexString)",
            accessGroup: SharedIdentityLocation.accessGroup)
    }

    /// Holds nothing and touches no Keychain: the test value, and `AppRuntime`'s default. Its
    /// `load` reports a failed read, so a store built with it never enables ratchets.
    public static let inert = OwnRatchetStore(load: { _ in nil }, save: { _, _ in false })

    public static func live(ops: KeychainOps) -> OwnRatchetStore {
        // `KeychainOps` has no update, so a save is a delete then an add. The lock keeps a load from
        // landing between the two and reading "no ring".
        let lock = NSLock()
        @Sendable func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
        return OwnRatchetStore(
            load: { hash in
                locked { read(location(destinationHash: hash), ops: ops) }
            },
            save: { hash, ring in
                locked { write(ring, to: location(destinationHash: hash), ops: ops) }
            })
    }

    static func read(_ location: IdentityKeychain.Location, ops: KeychainOps) -> [Data]? {
        switch ops.read(location) {
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

    /// Delete, then add. When the add fails, the ring the item held is re-added, best effort, so a
    /// failed write does not lose the saved ring. A crash between the delete and the add does lose
    /// it; `KeychainOps` offers no atomic replace.
    static func write(_ ring: [Data], to location: IdentityKeychain.Location, ops: KeychainOps) -> Bool {
        let previous = ops.read(location).data
        switch ops.delete(location) {
        case .deleted, .notFound: break
        case .failed: return false
        }
        guard !ring.isEmpty else { return true }
        guard ops.add(location, ring.reduce(Data(), +)) == .added else {
            if let previous { _ = ops.add(location, previous) }
            return false
        }
        return true
    }
}

extension OwnRatchetStore: DependencyKey {
    public static var liveValue: OwnRatchetStore { live(ops: .live) }
    /// Benign, not `unimplemented`: every `AppFeature` test sends `.onLaunch`, which reads it.
    public static var testValue: OwnRatchetStore { inert }
    public static var previewValue: OwnRatchetStore { inert }
}

public extension DependencyValues {
    var ownRatchetStore: OwnRatchetStore {
        get { self[OwnRatchetStore.self] }
        set { self[OwnRatchetStore.self] = newValue }
    }
}
