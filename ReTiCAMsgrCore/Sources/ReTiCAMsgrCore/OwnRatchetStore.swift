import Foundation
import Dependencies
import ReTiCAKeychain
import ReTiCAMsgrPushService

/// The own ratchet ring of a destination of ours: X25519 PRIVATE keys, newest first, as ReTiCA
/// reports them with `.ratchetsChanged` and takes them back with `.enableRatchets` (ReTiCA README,
/// "Own ratchets"). The ring lives in the Keychain, one item per destination; the location and
/// the format are `OwnRatchetRing`'s, shared with the Notification Service Extension, which only
/// reads it. Outside the Keychain it is in the actions that carry it and in Transport's state
/// (redacted when printed, by ReTiCA's `Transport.State.OwnRatchets`). The app never logs it.
public struct OwnRatchetStore: Sendable {
    /// The saved ring for a destination hash: `[]` when there is no item, nil when the Keychain
    /// read failed (or matched an item it refuses to pick). Nil is never "no ring": treating it
    /// that way would start a new ring and the next rotation would overwrite the saved one.
    public var load: @Sendable (_ destinationHash: Data) -> [Data]?
    /// Replaces the saved ring for a destination hash. False when the write failed, or when the
    /// ring is empty (refused, see `write`).
    public var save: @Sendable (_ destinationHash: Data, _ ring: [Data]) -> Bool

    public init(load: @escaping @Sendable (Data) -> [Data]?,
                save: @escaping @Sendable (Data, [Data]) -> Bool) {
        self.load = load
        self.save = save
    }

    public static var keyLength: Int { OwnRatchetRing.keyLength }

    /// In the identity's access group, which both entitlement files list.
    public static func location(destinationHash: Data) -> IdentityKeychain.Location {
        OwnRatchetRing.location(destinationHash: destinationHash, accessGroup: SharedIdentityLocation.accessGroup)
    }

    /// Holds nothing and touches no Keychain: the test value, and `AppRuntime`'s default. Its
    /// `load` reports a failed read, so a store built with it never enables ratchets.
    public static let inert = OwnRatchetStore(load: { _ in nil }, save: { _, _ in false })

    public static func live(ops: KeychainOps) -> OwnRatchetStore {
        // Serialises this process's writes, so an update and its add-if-missing can't interleave
        // with another save. Explicit lock/unlock: `Mutex` needs iOS 18.
        let lock = NSLock()
        @Sendable func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
        return OwnRatchetStore(
            load: { hash in
                locked { OwnRatchetRing.read(location(destinationHash: hash), ops: ops) }
            },
            save: { hash, ring in
                locked { write(ring, to: location(destinationHash: hash), ops: ops) }
            })
    }

    /// Update in place, and add only when there is no item yet (`.notFound`). An update replaces
    /// the data without the item ever being missing, so a kill mid-write leaves the old ring or the
    /// new one, never none (a delete-then-add left none between the two calls). A failed update or
    /// add changes nothing, so no restore is needed: the previous ring stays as it was.
    ///
    /// An empty ring is refused, so it can never erase a saved one. Transport never reports one
    /// (each rotation inserts a key), so an empty ring here would be a defect elsewhere.
    static func write(_ ring: [Data], to location: IdentityKeychain.Location, ops: KeychainOps) -> Bool {
        guard !ring.isEmpty else { return false }
        let data = ring.reduce(Data(), +)
        switch ops.update(location, data) {
        case .updated:
            return true
        case .failed:
            return false
        case .notFound:
            // First save. `.duplicate` means an item appeared between the update and the add (not
            // from this process, which holds the lock): report failure rather than overwrite it.
            return ops.add(location, data) == .added
        }
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
