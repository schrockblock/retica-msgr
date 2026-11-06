//
//  QRCodeImage.swift
//  ReTiCAMsgr
//
//  Created by Elliot Schrock on 8/18/26.
//

import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#endif

enum QRCodeImage {
    /// Renders `string` as a QR code image, scaled up so modules stay crisp on screen.
    static func generate(from string: String, scale: CGFloat = 8) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)

        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }

        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return PlatformImage(cgImage: cgImage)
    }
}
