//
//  QRCodeImageTests.swift
//  ReTiCAMsgrTests
//
//  Created by Elliot Schrock on 8/18/26.
//

import CoreImage
#if canImport(UIKit)
import UIKit
#endif
import Testing
@testable import ReTiCAMsgr

struct QRCodeImageTests {

    @Test func generatedQRDecodesBackToOriginalAddress() throws {
        let address = "0123456789abcdef0123456789abcdef"

        let image = try #require(QRCodeImage.generate(from: address))
        let ciImage = try #require(CIImage(cgImage: try #require(image.cgImage)))

        let detector = try #require(
            CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)
        )
        let features = detector.features(in: ciImage)

        #expect(features.count == 1)
        let message = (features.first as? CIQRCodeFeature)?.messageString
        #expect(message == address)
    }

}
