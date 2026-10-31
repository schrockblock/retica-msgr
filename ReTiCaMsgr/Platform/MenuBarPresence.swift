#if os(macOS)
import AppKit
import ServiceManagement

/// The part of `SMAppService` that launch-at-login uses, so tests can stand in for it.
protocol LoginItemService {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {
    var isEnabled: Bool { status == .enabled }
}

/// Start at login (brief 2026-10-31): on by default, added once on the first run of a build that
/// has it. After that the app never touches the setting again, so turning it off in System
/// Settings sticks.
enum LaunchAtLogin {
    static let didSetDefaultKey = "launchAtLoginDefaultSet"

    static func registerOnFirstRun(defaults: UserDefaults, service: LoginItemService) {
        guard !defaults.bool(forKey: didSetDefaultKey) else { return }
        // Not marked done on failure, so the next launch tries again.
        guard (try? service.register()) != nil else { return }
        defaults.set(true, forKey: didSetDefaultKey)
    }

    /// True when the system opened the app as a login item: it then starts in the menu bar only.
    /// Read in `applicationWillFinishLaunching`, while the launch event is the current one.
    static func launchEventIsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// The menu bar icon: a speech bubble, with a red dot while anything is unread.
enum MenuBarIcon {
    static func hasUnread(_ counts: [String: Int]) -> Bool {
        counts.values.contains { $0 > 0 }
    }

    static func image(hasUnread: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let glyph = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "ReTiCaMsgr")!
            .withSymbolConfiguration(config)!
        guard hasUnread else {
            // A template follows the menu bar's light or dark look by itself.
            glyph.isTemplate = true
            return glyph
        }
        // Red can't live in a template, so this one draws the bubble itself, in the label colour of
        // whatever appearance is current when the menu bar draws it.
        let size = NSSize(width: glyph.size.width + 3, height: glyph.size.height + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            let bubble = NSRect(x: 0, y: 0, width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: bubble)
            NSColor.labelColor.set()
            bubble.fill(using: .sourceAtop)
            let d: CGFloat = 7
            let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.accessibilityDescription = "ReTiCaMsgr, unread messages"
        return image
    }
}
#endif
