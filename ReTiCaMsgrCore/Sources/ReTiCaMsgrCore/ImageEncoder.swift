import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns picked image bytes into the JPEG we send (spec 2026-09-28 §2). ImageIO only — no UIKit —
/// so it lives in the core package and `swift test` covers it on macOS.
///
/// Both presets bake the EXIF orientation into the pixels (Sideband ignores orientation tags) and
/// write NO metadata (no GPS leaves the phone). `standard` scales the long edge to at most
/// `standardMaxPixels`, never upscaling; `original` keeps the source size.
public enum ImageEncoder {
    public enum Preset: Equatable, Sendable {
        case standard
        case original
    }

    public static let standardMaxPixels = 1280
    public static let standardQuality = 0.75
    public static let originalQuality = 0.92

    public struct Encoded: Equatable, Sendable {
        public var data: Data
        public var width: Int
        public var height: Int

        public init(data: Data, width: Int, height: Int) {
            self.data = data
            self.width = width
            self.height = height
        }
    }

    public enum Failure: Error, Equatable {
        /// ImageIO could not read the bytes as an image.
        case undecodable
        case encodingFailed
    }

    public static func encodeJPEG(_ source: Data, preset: Preset) throws -> Encoded {
        guard let src = CGImageSourceCreateWithData(source as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let dims = dimensions(of: source)
        else { throw Failure.undecodable }
        let longEdge = max(dims.width, dims.height)
        let maxPixels: Int
        switch preset {
        case .standard: maxPixels = min(standardMaxPixels, longEdge)
        case .original: maxPixels = longEdge
        }
        // "Thumbnail" here is ImageIO's scaled, orientation-applied decode of the full image; with
        // a max size equal to the long edge it is the full image, oriented.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw Failure.undecodable
        }
        let quality = preset == .standard ? standardQuality : originalQuality
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        // Only the quality: no properties dictionary is copied from the source, so EXIF/GPS/TIFF
        // are gone and the orientation is 1 (the pixels are already transformed).
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encodingFailed }
        return Encoded(data: out as Data, width: image.width, height: image.height)
    }

    /// The displayed pixel size from the container's properties (no pixel decode): orientation
    /// values 5–8 swap width and height. nil when the bytes are not an image.
    public static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    public static func isDecodable(_ data: Data) -> Bool {
        dimensions(of: data) != nil
    }

    /// The container's UTType identifier, e.g. `public.jpeg`, `public.png`, `org.webmproject.webp`.
    public static func containerType(of data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src)
        else { return nil }
        return type as String
    }

    /// True when the container carries a GPS dictionary or an orientation other than 1.
    public static func hasLocationOrOrientationMetadata(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return false }
        if props[kCGImagePropertyGPSDictionary] != nil { return true }
        if let orientation = props[kCGImagePropertyOrientation] as? UInt32, orientation != 1 { return true }
        return false
    }
}
