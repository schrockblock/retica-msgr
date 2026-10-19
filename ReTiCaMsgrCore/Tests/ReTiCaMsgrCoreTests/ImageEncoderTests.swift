import Testing
import Foundation
import ImageIO
import CoreGraphics
@testable import ReTiCaMsgrCore

private func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8)?) -> Bool { (p?.r ?? 0) > 200 && (p?.b ?? 255) < 60 }
private func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8)?) -> Bool { (p?.b ?? 0) > 200 && (p?.r ?? 255) < 60 }

@Test func imageEncoderConstantsMatchSpec() {
    #expect(ImageEncoder.standardMaxPixels == 1280)
    #expect(ImageEncoder.standardQuality == 0.75)
    #expect(ImageEncoder.originalQuality == 0.92)
}

@Test func imageEncoderStandardDownscalesTo1280LongEdge() throws {
    let out = try ImageEncoder.encodeJPEG(TestImages.png(width: 3000, height: 2000), preset: .standard)
    #expect(out.width == 1280)
    #expect(out.height == 853)
    #expect(ImageEncoder.containerType(of: out.data) == "public.jpeg")
    let d = try #require(ImageEncoder.dimensions(of: out.data))
    #expect(d.width == 1280)
    #expect(d.height == 853)
    // Portrait sources scale on the long edge too.
    let tall = try ImageEncoder.encodeJPEG(TestImages.png(width: 1000, height: 4000), preset: .standard)
    #expect(tall.width == 320)
    #expect(tall.height == 1280)
}

@Test func imageEncoderNeverUpscales() throws {
    let small = try ImageEncoder.encodeJPEG(TestImages.png(width: 100, height: 80), preset: .standard)
    #expect(small.width == 100)
    #expect(small.height == 80)
    let exact = try ImageEncoder.encodeJPEG(TestImages.png(width: 1280, height: 720), preset: .standard)
    #expect(exact.width == 1280)
    #expect(exact.height == 720)
}

@Test func imageEncoderOriginalKeepsDimensions() throws {
    let out = try ImageEncoder.encodeJPEG(TestImages.png(width: 3000, height: 2000), preset: .original)
    #expect(out.width == 3000)
    #expect(out.height == 2000)
    #expect(ImageEncoder.containerType(of: out.data) == "public.jpeg")
    // Original is the higher quality: same image, more bytes than the standard preset at the
    // same size would give — compare against a standard encode forced to full size by a source
    // that is already ≤ 1280 on its long edge. The gradients in `TestImages` give the quantiser
    // something to drop, so the two sizes differ by more than header noise.
    let source = TestImages.png(width: 1200, height: 800)
    let standard = try ImageEncoder.encodeJPEG(source, preset: .standard)
    let original = try ImageEncoder.encodeJPEG(source, preset: .original)
    #expect(original.width == standard.width && original.height == standard.height)
    #expect(original.data.count > standard.data.count)
}

/// Review Focus 8: a phone photo stored landscape with orientation 6 displays as portrait. The
/// sent JPEG must have those pixels rotated, because Sideband ignores orientation tags.
@Test func imageEncoderBakesOrientationIntoPixels() throws {
    // Stored 3000×2000, left half red, bright at the stored top. Orientation 6 = rotate 90° CW to
    // display: 2000×3000 with the RED half on TOP and the stored top rows (bright) on the RIGHT.
    let source = TestImages.jpeg(width: 3000, height: 2000, orientation: 6)
    // Self-check of the helper, independent of the encoder: `pixel` applies the orientation, so
    // the source itself reads red on top and blue below. If this fails, `TestImages.pixel`'s row
    // arithmetic is wrong — not `ImageEncoder`.
    #expect(isRed(TestImages.pixel(in: source, x: 1900, y: 300)))
    #expect(isBlue(TestImages.pixel(in: source, x: 1900, y: 2700)))
    let out = try ImageEncoder.encodeJPEG(source, preset: .standard)
    #expect(out.width == 853)
    #expect(out.height == 1280)
    // The output carries no orientation tag (or 1), and the raw pixels are already rotated, so
    // they read red on top with no transform to apply.
    #expect(!ImageEncoder.hasLocationOrOrientationMetadata(out.data))
    #expect(isRed(TestImages.pixel(in: out.data, x: 800, y: 300)))
    #expect(isBlue(TestImages.pixel(in: out.data, x: 800, y: 980)))
    // Sanity: an untagged source keeps left = red (read in the bright top rows).
    let plain = try ImageEncoder.encodeJPEG(TestImages.png(width: 400, height: 200), preset: .standard)
    #expect(isRed(TestImages.pixel(in: plain.data, x: 100, y: 20)))
    #expect(isBlue(TestImages.pixel(in: plain.data, x: 300, y: 20)))
}

/// Review Focus 8: GPS never leaves the phone, in either preset.
@Test func imageEncoderStripsMetadata() throws {
    let source = TestImages.jpeg(width: 800, height: 600, orientation: 3, withGPS: true)
    // The source really carries GPS (not merely the orientation that also satisfies the helper),
    // so the strip below is tested against a location it had to remove.
    let sourceProps = try #require(CGImageSourceCreateWithData(source as CFData, nil)
        .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
    #expect(sourceProps[kCGImagePropertyGPSDictionary] != nil)
    #expect(ImageEncoder.hasLocationOrOrientationMetadata(source))
    let standard = try ImageEncoder.encodeJPEG(source, preset: .standard)
    let original = try ImageEncoder.encodeJPEG(source, preset: .original)
    #expect(!ImageEncoder.hasLocationOrOrientationMetadata(standard.data))
    #expect(!ImageEncoder.hasLocationOrOrientationMetadata(original.data))
}

@Test func imageEncoderPNGBecomesJPEG() throws {
    let source = TestImages.png(width: 640, height: 480)
    #expect(ImageEncoder.containerType(of: source) == "public.png")
    let out = try ImageEncoder.encodeJPEG(source, preset: .original)
    #expect(ImageEncoder.containerType(of: out.data) == "public.jpeg")
    #expect(out.width == 640 && out.height == 480)
}

@Test func imageEncoderRejectsUndecodableData() {
    let junk = Data("not an image at all".utf8)
    #expect(ImageEncoder.dimensions(of: junk) == nil)
    #expect(!ImageEncoder.isDecodable(junk))
    #expect(ImageEncoder.containerType(of: junk) == nil)
    #expect(throws: ImageEncoder.Failure.undecodable) {
        try ImageEncoder.encodeJPEG(junk, preset: .standard)
    }
    #expect(throws: ImageEncoder.Failure.undecodable) {
        try ImageEncoder.encodeJPEG(Data(), preset: .original)
    }
}

/// `dimensions(of:)` reports the DISPLAYED size: orientation 5–8 swap width and height.
@Test func imageEncoderDimensionsHonourOrientation() throws {
    let up = try #require(ImageEncoder.dimensions(of: TestImages.jpeg(width: 3000, height: 2000)))
    #expect(up.width == 3000)
    #expect(up.height == 2000)
    let rotated = try #require(ImageEncoder.dimensions(of: TestImages.jpeg(width: 3000, height: 2000, orientation: 6)))
    #expect(rotated.width == 2000)
    #expect(rotated.height == 3000)
    let upsideDown = try #require(ImageEncoder.dimensions(of: TestImages.jpeg(width: 3000, height: 2000, orientation: 3)))
    #expect(upsideDown.width == 3000)
    #expect(upsideDown.height == 2000)
    let png = try #require(ImageEncoder.dimensions(of: TestImages.png(width: 10, height: 20)))
    #expect(png.width == 10)
    #expect(png.height == 20)
    #expect(ImageEncoder.isDecodable(TestImages.png(width: 10, height: 20)))
}

// MARK: - Avatars

private func noisyPNG(side: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    var state: UInt64 = 0x9E3779B97F4A7C15
    for i in 0..<bytes.count {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        bytes[i] = i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state >> 33)
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let image = bytes.withUnsafeMutableBytes { raw -> CGImage in
        let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: side * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    return TestImages.encode(image, type: .png, properties: [:])
}

private func thirdsPNG(width: Int, height: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let third = width / 3
    let colours: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
    for (i, c) in colours.enumerated() {
        ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        ctx.fill(CGRect(x: i * third, y: 0, width: third, height: height))
    }
    return TestImages.encode(ctx.makeImage()!, type: .png, properties: [:])
}

@Test func avatarIsSquare256() throws {
    let out = try ImageEncoder.encodeAvatar(TestImages.png(width: 800, height: 400))
    #expect(out.width == 256)
    #expect(out.height == 256)
    let d = try #require(ImageEncoder.dimensions(of: out.data))
    #expect(d.width == 256)
    #expect(d.height == 256)
}

@Test func avatarFitsTheByteCap() throws {
    let out = try ImageEncoder.encodeAvatar(noisyPNG(side: 2000))
    #expect(out.data.count <= ImageEncoder.avatarMaxBytes)
    #expect(ImageEncoder.avatarMaxBytes == 24_000)
    #expect(ImageEncoder.avatarPixels == 256)
}

@Test func avatarStripsLocation() throws {
    let source = TestImages.jpeg(width: 600, height: 400, orientation: 6, withGPS: true)
    #expect(ImageEncoder.hasLocationOrOrientationMetadata(source))
    let out = try ImageEncoder.encodeAvatar(source)
    #expect(!ImageEncoder.hasLocationOrOrientationMetadata(out.data))
}

@Test func avatarCropsTheCentre() throws {
    let out = try ImageEncoder.encodeAvatar(thirdsPNG(width: 300, height: 100))
    let p = try #require(TestImages.pixel(in: out.data, x: 128, y: 128))
    #expect(p.g > 200 && p.r < 60 && p.b < 60)
    // A true centre crop is green edge to edge; squashing the whole 300x100 source would put red
    // and blue near the left and right edges.
    for x in [10, 245] {
        let edge = try #require(TestImages.pixel(in: out.data, x: x, y: 128))
        #expect(edge.g > 200 && edge.r < 60 && edge.b < 60)
    }
}

@Test func avatarRejectsNonImage() {
    #expect(throws: ImageEncoder.Failure.self) { try ImageEncoder.encodeAvatar(Data("x".utf8)) }
}
