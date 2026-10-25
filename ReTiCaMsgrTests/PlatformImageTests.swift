//
//  PlatformImageTests.swift
//  ReTiCaMsgrTests
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import ReTiCaMsgr

@MainActor
struct PlatformImageTests {

    /// A solid-red 40x20 bitmap, so the pixel size is known independent of any scale factor.
    private func makeRedCGImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        return try #require(context.makeImage())
    }

    @Test func cgImageRoundTripKeepsPixelSize() throws {
        let image = PlatformImage(cgImage: try makeRedCGImage())

        #expect(image.cgImage?.width == 40)
        #expect(image.cgImage?.height == 20)
    }

    @Test func jpegDataDecodesBackToSameSize() throws {
        let image = PlatformImage(cgImage: try makeRedCGImage())

        let data = try #require(image.jpegData(compressionQuality: 0.9))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        #expect(decoded.width == 40)
        #expect(decoded.height == 20)
    }

    @Test func pasteboardCopyIsReadBack() {
        Pasteboard.copy("abc123")

        #if canImport(UIKit)
        #expect(UIPasteboard.general.string == "abc123")
        #else
        #expect(NSPasteboard.general.string(forType: .string) == "abc123")
        #endif
    }

}
