import Foundation

#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
#endif

enum Pasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    /// How long a copied secret stays on the pasteboard.
    static let secretLifetime: TimeInterval = 120

    #if !canImport(UIKit)
    /// The nspasteboard.org markers: clipboard managers skip concealed items and don't keep
    /// transient ones in their history.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    #endif

    /// Copies a secret (the MeshCore channel key, ruling R8 as amended). Universal Clipboard never
    /// sends it to another device, and it is cleared after `secretLifetime`.
    /// - iOS: a local-only item with an expiration date.
    /// - macOS: current-host-only contents, marked concealed and transient, cleared after
    ///   `secretLifetime` unless something else has been copied since.
    static func copySecret(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: string]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(secretLifetime)])
        #else
        let pasteboard = NSPasteboard.general
        // Clears the pasteboard like `clearContents()`, and keeps these contents off Universal Clipboard.
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(string, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
        pasteboard.setData(Data(), forType: transientType)
        // Recorded after the writes, so only a later copy by anyone stops the clear.
        let copiedCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + secretLifetime) {
            if NSPasteboard.general.changeCount == copiedCount {
                NSPasteboard.general.clearContents()
            }
        }
        #endif
    }
}

enum SystemSettings {
    /// Where the user can change privacy permissions. Callers open it with `openURL`.
    static var url: URL? {
        #if canImport(UIKit)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")
        #endif
    }
}
