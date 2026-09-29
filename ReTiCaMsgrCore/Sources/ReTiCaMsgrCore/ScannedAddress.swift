import Foundation

/// The LXMF address inside a scanned QR payload: 32 hex chars (16 bytes), case-insensitive,
/// surrounding whitespace ignored, an optional `lxmf://` or `lxmf@` prefix tolerated.
public enum ScannedAddress {
    public static func parse(_ payload: String) -> String? {
        var body = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = body.lowercased()
        for prefix in ["lxmf://", "lxmf@"] {
            if lowered.hasPrefix(prefix) {
                body = String(body.dropFirst(prefix.count))
                break
            }
        }
        // Reuse the package's existing 16-byte hex validation (see Conversation.swift's
        // isValidPeerAddress) rather than duplicating hex-digit / length logic here.
        guard let data = Data(hexString: body), data.count == 16 else { return nil }
        return body.lowercased()
    }
}
