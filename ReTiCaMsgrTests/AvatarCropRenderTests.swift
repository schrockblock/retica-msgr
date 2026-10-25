//
//  AvatarCropRenderTests.swift
//  ReTiCaMsgrTests
//

import CoreGraphics
import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif
import Testing
@testable import ReTiCaMsgr

struct AvatarCropRenderTests {

    /// A scale-1, `width` x `height` image whose pixels come from `color(x, y)` (origin top-left).
    private func makeImage(width: Int, height: Int,
                           color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> PlatformImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PlatformImage(cgImage: cg)
    }

    private let red: (UInt8, UInt8, UInt8) = (255, 0, 0)
    private let blue: (UInt8, UInt8, UInt8) = (0, 0, 255)

    private func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The RGB of the pixel at (x, y), origin top-left.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    @Test func rendersRequestedSquare() throws {
        let image = try makeImage(width: 200, height: 100) { x, _ in x < 100 ? red : blue }

        let data = try #require(AvatarCropView.renderSquareJPEG(
            image, crop: CGRect(x: 0, y: 0, width: 100, height: 100), outputSide: 512))

        let decoded = try decode(data)
        #expect(decoded.width == 512)
        #expect(decoded.height == 512)
    }

    @Test func cropTakesTopContent() throws {
        let image = try makeImage(width: 100, height: 100) { _, y in y < 50 ? red : blue }

        let data = try #require(AvatarCropView.renderSquareJPEG(
            image, crop: CGRect(x: 0, y: 0, width: 50, height: 50), outputSide: 512))

        let centre = try pixel(try decode(data), x: 256, y: 256)
        #expect(centre.r > 200)
        #expect(centre.b < 60)
    }

    @Test func cropTakesBottomContent() throws {
        let image = try makeImage(width: 100, height: 100) { _, y in y < 50 ? red : blue }

        let data = try #require(AvatarCropView.renderSquareJPEG(
            image, crop: CGRect(x: 0, y: 50, width: 50, height: 50), outputSide: 512))

        let centre = try pixel(try decode(data), x: 256, y: 256)
        #expect(centre.b > 200)
        #expect(centre.r < 60)
    }
}
