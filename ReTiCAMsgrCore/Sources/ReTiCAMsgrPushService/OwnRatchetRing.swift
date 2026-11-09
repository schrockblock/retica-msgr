import Foundation
import ReTiCAKeychain

/// Where and how the app keeps a destination's own ratchet ring in the Keychain, and the READ-ONLY
/// half of it. It lives here, not beside `OwnRatchetStore` in ReTiCAMsgrCore, so the Notification
/// Service Extension can read the ring (to attribute packets encrypted to our ratchets, see
/// `BlockedSenderFilter`) without linking TCA. Only the app writes the ring (`OwnRatchetStore`);
/// nothing here writes.
///
/// **Format: the keys concatenated, 32 bytes each, newest first.** Every entry has the same fixed
/// length, so no framing is needed (the format of `MeshCoreKeyStore`'s retired-key item). A
/// trailing partial key is ignored, and ReTiCA drops any entry that is not a usable key, so a
/// damaged item cannot trap the read. At ReTiCA's cap of 512 keys the item is 16 KiB.
public enum OwnRatchetRing {
    public static let keyLength = 32

    /// One item per destination, in `accessGroup` (the app passes the identity's group, which both
    /// the app's and the extension's entitlements list). The service names the destination, so it
    /// can't collide with the identity's item or the MeshCore keys.
    public static func location(destinationHash: Data, accessGroup: String?) -> IdentityKeychain.Location {
        let hex = destinationHash.map { String(format: "%02x", $0) }.joined()
        return IdentityKeychain.Location(service: "co.lithobyte.reticamsgr.ratchets.\(hex)",
                                         accessGroup: accessGroup)
    }

    /// The saved ring: `[]` when there is no item, nil when the read fails or matches an item it
    /// refuses to pick. Nil is never "no ring".
    public static func read(_ location: IdentityKeychain.Location, ops: KeychainOps) -> [Data]? {
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

    /// The extension's reader: the ring for a delivery hash, or nil when there is none or it can't
    /// be read (both mean "attribute with the identity key only").
    public static func reader(accessGroup: String?, ops: KeychainOps = .live)
        -> @Sendable (_ deliveryHash: Data) -> [Data]? {
        { hash in
            guard let ring = read(location(destinationHash: hash, accessGroup: accessGroup), ops: ops),
                  !ring.isEmpty
            else { return nil }
            return ring
        }
    }
}
