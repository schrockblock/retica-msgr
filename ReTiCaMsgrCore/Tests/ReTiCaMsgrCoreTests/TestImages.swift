import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Images drawn in-test, so no fixture files: the left half is red, the right half blue, which
/// makes an orientation change visible in the pixels. Each half is a vertical gradient (bright at
/// the top, half brightness at the bottom), so a JPEG's size depends on its quality — a flat image
/// is almost all DC and encodes to nearly the same size at 0.75 and 0.92. Pixel checks read the
/// bright top rows of the SOURCE image.
enum TestImages {
    static func cgImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CG's origin is the bottom-left, so y = height is the TOP of the image.
        let top = CGPoint(x: 0, y: CGFloat(height))
        let bottom = CGPoint(x: 0, y: 0)
        let halves: [(CGRect, [CGFloat])] = [
            // RGBA bright, then RGBA half brightness.
            (CGRect(x: 0, y: 0, width: width / 2, height: height), [1, 0, 0, 1, 0.5, 0, 0, 1]),
            (CGRect(x: width / 2, y: 0, width: width - width / 2, height: height), [0, 0, 1, 1, 0, 0, 0.5, 1]),
        ]
        for (rect, components) in halves {
            let gradient = CGGradient(colorSpace: space, colorComponents: components, locations: [0, 1], count: 2)!
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(gradient, start: top, end: bottom, options: [])
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    static func png(width: Int, height: Int) -> Data {
        encode(cgImage(width: width, height: height), type: UTType.png, properties: [:])
    }

    /// `orientation` is the EXIF/TIFF value (1 = up, 6 = rotate 90° CW to display).
    static func jpeg(width: Int, height: Int, orientation: UInt32? = nil, withGPS: Bool = false) -> Data {
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if withGPS {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any]
        }
        return encode(cgImage(width: width, height: height), type: UTType.jpeg, properties: properties)
    }

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// The colour at (x, y) of the DISPLAYED image (orientation applied by ImageIO's transform).
    static func pixel(in data: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 100_000,
              ] as CFDictionary)
        else { return nil }
        let w = image.width, h = image.height
        guard x < w, y < h else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // A bitmap context's MEMORY row 0 is the TOP of the drawn image (CG's y axis points up,
        // but the backing buffer is stored top row first), so y indexes the buffer directly.
        let i = (y * w + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2])
    }
}
