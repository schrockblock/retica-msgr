import Foundation

/// The LXMF address inside a scanned QR payload or link: 32 hex chars (16 bytes), case-insensitive,
/// surrounding whitespace ignored. Accepts every form `ContactURI.parse` does — a bare address,
/// `lxmf://` or `lxmf@` plus an address, and `lxma://` with or without a public key — and returns
/// the lowercased address. A payload whose key doesn't belong to its address is rejected.
public enum ScannedAddress {
    public static func parse(_ payload: String) -> String? {
        ContactURI.parse(payload)?.addressHex
    }
}
