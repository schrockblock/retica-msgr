import Foundation
import ReTiCA

/// What a scanned QR code or tapped link names: an LXMF address, and the peer's 64-byte identity
/// public key when the payload carried one (and it was proven to belong to that address).
public struct ScannedContact: Equatable, Sendable {
    /// Lowercase 32-hex LXMF delivery address.
    public let addressHex: String
    /// The identity public key (X25519 ‖ Ed25519, 64 bytes), or nil when the payload had none.
    public let publicKey: Data?

    public init(addressHex: String, publicKey: Data?) {
        self.addressHex = addressHex
        self.publicKey = publicKey
    }
}

/// The `lxma://<address>:<public key>` contact format that Columba introduced and MeshChatX and
/// Retichat share (Columba `IdentityQrCodeUtils`, MeshChatX `lxma_contact.py`, Retichat
/// `IdentityShareFormat`), plus the address-only forms earlier ReTiCAMsgr builds produced and accept.
public enum ContactURI {
    private static let lxmaPrefix = "lxma://"
    private static let addressOnlyPrefixes = ["lxmf://", "lxmf@"]

    /// `lxma://<address>:<public key>`, lowercase. The address is the identity's lxmf.delivery hash.
    public static func encode(_ identity: Identity) -> String {
        lxmaPrefix + lxmfAddressHex(identity) + ":" + identity.publicKey.hexString
    }

    /// Accepts a bare 32-hex address, `lxmf://` or `lxmf@` plus an address, and `lxma://` plus an
    /// address with an optional `:` or `.` separated key (Retichat also writes `.`). Case and
    /// surrounding whitespace are ignored. A key must be a valid 64-byte RNS identity key whose
    /// lxmf.delivery hash is the address, as MeshChatX requires; otherwise the payload is rejected
    /// whole, never accepted as address-only.
    public static func parse(_ payload: String) -> ScannedContact? {
        var body = payload.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowsKey: Bool
        if body.hasPrefix(lxmaPrefix) {
            body.removeFirst(lxmaPrefix.count)
            allowsKey = true
        } else if let prefix = addressOnlyPrefixes.first(where: body.hasPrefix) {
            body.removeFirst(prefix.count)
            allowsKey = false
        } else {
            allowsKey = false
        }

        let address: String
        var keyHex: String?
        if let separator = body.firstIndex(where: { $0 == ":" || $0 == "." }) {
            guard allowsKey else { return nil }
            address = String(body[..<separator])
            keyHex = String(body[body.index(after: separator)...])
        } else {
            address = body
        }
        guard isValidPeerAddress(address) else { return nil }

        guard let keyHex else { return ScannedContact(addressHex: address, publicKey: nil) }
        guard keyHex.count == 128,
              let key = Data(hexString: keyHex), key.count == 64,
              let identity = Identity(publicKey: key),
              lxmfAddressHex(identity) == address
        else { return nil }
        return ScannedContact(addressHex: address, publicKey: key)
    }
}
