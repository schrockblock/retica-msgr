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
        let maxPixels: (Int) -> Int = { longEdge in
            switch preset {
            case .standard: return min(standardMaxPixels, longEdge)
            case .original: return longEdge
            }
        }
        let image = try orientedImage(source, maxPixels: maxPixels)
        let quality = preset == .standard ? standardQuality : originalQuality
        let data = try jpegData(image, quality: quality)
        return Encoded(data: data, width: image.width, height: image.height)
    }

    public static let avatarPixels = 256
    public static let avatarMaxBytes = 24_000

    /// A square `avatarPixels` JPEG of the picture's centre, at most `avatarMaxBytes`: quality steps
    /// down from 0.8 to 0.3 until it fits. Orientation baked and metadata stripped as `encodeJPEG`.
    public static func encodeAvatar(_ source: Data) throws -> Encoded {
        let image = try orientedImage(source, maxPixels: { $0 })
        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: crop) else { throw Failure.undecodable }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: avatarPixels, height: avatarPixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.encodingFailed }
        ctx.interpolationQuality = .high
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: avatarPixels, height: avatarPixels))
        guard let scaled = ctx.makeImage() else { throw Failure.encodingFailed }
        for step in 0...5 {
            let quality = 0.8 - Double(step) * 0.1
            let data = try jpegData(scaled, quality: quality)
            if data.count <= avatarMaxBytes {
                return Encoded(data: data, width: scaled.width, height: scaled.height)
            }
        }
        throw Failure.encodingFailed
    }

    /// The orientation-applied decode of the first image; `maxPixels` maps the source's displayed
    /// long edge to the size limit.
    private static func orientedImage(_ source: Data, maxPixels: (Int) -> Int) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(source as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let dims = dimensions(of: source)
        else { throw Failure.undecodable }
        // "Thumbnail" here is ImageIO's scaled, orientation-applied decode of the full image; with
        // a max size equal to the long edge it is the full image, oriented.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels(max(dims.width, dims.height)),
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw Failure.undecodable
        }
        return image
    }

    private static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        // Only the quality: no properties dictionary is copied from the source, so EXIF/GPS/TIFF
        // are gone and the orientation is 1 (the pixels are already transformed).
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encodingFailed }
        return out as Data
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
