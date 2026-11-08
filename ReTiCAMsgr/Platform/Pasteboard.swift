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

    /// How long a copied secret stays on the iOS pasteboard.
    static let secretLifetime: TimeInterval = 120

    /// Copies a secret (the MeshCore channel key, ruling R8). On iOS the item is local-only, so
    /// Universal Clipboard never sends it to another device, and it expires after `secretLifetime`.
    /// macOS has no equivalent options, so there it is a plain copy.
    static func copySecret(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: string]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(secretLifetime)])
        #else
        copy(string)
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
