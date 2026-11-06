import Foundation
import ReTiCA
import ReTiCAKeychain

/// Restore input handling (spec §5.3). Pure. Key material passes through as arguments and
/// results only — never stored, never logged (`describe` prints kinds and hashes).
public enum IdentityRestore {
    public enum Rejection: Error, Equatable, Sendable {
        case badEncoding
        case wrongLength(Int)
        case invalidKey
        case mismatch(got: Data, expected: Data)
        /// No anchor: nothing to match against, so nothing is accepted.
        case noExpectedIdentity
    }

    /// Far above the 64-byte identity file; anything bigger isn't a backup and isn't read.
    public static let maxFileBytes = 4096

    /// The Sideband / `rnid -B` text form: base32 (padding optional), surrounding whitespace ignored.
    public static func key(fromText text: String) -> Result<Data, Rejection> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = IdentityBackup.decodeBase32(trimmed) else { return .failure(.badEncoding) }
        guard data.count == Identity.keySize else { return .failure(.wrongLength(data.count)) }
        return .success(data)
    }

    /// The raw `identity` file (NomadNet / `rnid -i`): exactly 64 bytes.
    public static func key(fromFile data: Data) -> Result<Data, Rejection> {
        guard data.count == Identity.keySize else { return .failure(.wrongLength(data.count)) }
        return .success(data)
    }

    /// Strict: the key's identity must equal the anchor. No override.
    public static func validate(privateKey: Data, expected: Data?) -> Result<Identity, Rejection> {
        guard privateKey.count == Identity.keySize else { return .failure(.wrongLength(privateKey.count)) }
        guard let identity = Identity(privateKey: privateKey) else { return .failure(.invalidKey) }
        guard let expected else { return .failure(.noExpectedIdentity) }
        guard identity.hash == expected else { return .failure(.mismatch(got: identity.hash, expected: expected)) }
        return .success(identity)
    }

    /// Reads a user-picked file (security-scoped when it comes from `fileImporter`), refusing
    /// anything larger than `maxBytes` before reading it. nil when unreadable or too large.
    public static func readKeyFile(at url: URL, maxBytes: Int = IdentityRestore.maxFileBytes) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Log-safe: kinds and public hashes only.
    public static func describe(_ rejection: Rejection) -> String {
        switch rejection {
        case .badEncoding: return "badEncoding"
        case let .wrongLength(count): return "wrongLength \(count)"
        case .invalidKey: return "invalidKey"
        case let .mismatch(got, expected): return "mismatch got=\(got.hexString) expected=\(expected.hexString)"
        case .noExpectedIdentity: return "noExpectedIdentity"
        }
    }
}

public enum RestoreRefusal: Equatable, Sendable {
    /// The identity is no longer `.missing` (e.g. Retry already loaded one).
    case notMissing
    /// An identity item appeared somewhere (e.g. Nbhd wrote the shared item): nothing written.
    case identityPresent(service: String)
}

public enum RestoreResult: Equatable, Sendable {
    case restored(Data)
    case rejected(IdentityRestore.Rejection)
    case refused(RestoreRefusal)
    case failed(IdentityFailureReason)
}
