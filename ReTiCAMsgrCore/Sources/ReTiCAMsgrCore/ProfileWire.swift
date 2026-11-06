import Foundation
import CryptoKit
import ReTiCA

/// Wire codec for the profile-photo field (`0xA0`), our own key (not 0x04, 0x06 or the custom
/// trio). The value is an array:
/// - `[bin(version)]`: a tag, "my photo is this version" (8 bytes).
/// - `[bin(version), bin(jpeg)]`: the tag plus the image.
/// - `[bin(empty)]`: the sender has no photo (removed).
///
/// Receive is strict about the image and lenient about the message: an image that is too large,
/// undecodable, too many pixels or whose hash does not match the version is dropped, and the
/// version tag alone is returned.
public enum ProfileWire {
    public static let fieldProfilePhoto = 0xA0
    public static let versionLength = 8
    public static let maxImageBytes = 65_536
    public static let maxImagePixels = 512

    public enum Decoded: Equatable, Sendable {
        case tag(version: Data)
        case photo(version: Data, jpeg: Data)
        case removed
    }

    /// The first 8 bytes of the JPEG's SHA-256.
    public static func version(of jpeg: Data) -> Data {
        Data(SHA256.hash(data: jpeg).prefix(versionLength))
    }

    public static func encodeTag(version: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldProfilePhoto, .array([.bin(version)]))]
    }

    public static func encodePhoto(version: Data, jpeg: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldProfilePhoto, .array([.bin(version), .bin(jpeg)]))]
    }

    public static func encodeRemoved() -> [MsgPackValue.IntPair] {
        [.init(fieldProfilePhoto, .array([.bin(Data())]))]
    }

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded? {
        guard let value = fields.first(where: { $0.key == fieldProfilePhoto })?.value,
              case let .array(parts) = value,
              parts.count == 1 || parts.count == 2,
              case let .bin(version) = parts[0]
        else { return nil }
        if parts.count == 1 {
            if version.isEmpty { return .removed }
            return version.count == versionLength ? .tag(version: version) : nil
        }
        guard version.count == versionLength, case let .bin(jpeg) = parts[1] else { return nil }
        guard jpeg.count <= maxImageBytes,
              ProfileWire.version(of: jpeg) == version,
              let size = ImageEncoder.dimensions(of: jpeg),
              size.width <= maxImagePixels, size.height <= maxImagePixels
        else { return .tag(version: version) }
        return .photo(version: version, jpeg: jpeg)
    }
}
