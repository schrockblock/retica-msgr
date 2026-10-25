import SwiftUI

#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage
#else
import AppKit

typealias PlatformImage = NSImage

/// The three UIImage members the app's image code uses, so call sites compile unchanged
/// once they are retyped to `PlatformImage`.
extension NSImage {
    /// Size is the pixel size, matching a scale-1 `UIImage`.
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
