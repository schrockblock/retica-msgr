//
//  MenuBarPresenceTests.swift
//  ReTiCAMsgrTests
//

#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import ReTiCAMsgr

@MainActor
struct MenuBarPresenceTests {

    private final class FakeLoginItem: LoginItemService {
        var isEnabled = false
        var registerCalls = 0
        var failRegister = false
        struct Refused: Error {}

        func register() throws {
            registerCalls += 1
            if failRegister { throw Refused() }
            isEnabled = true
        }
        func unregister() throws { isEnabled = false }
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "MenuBarPresenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func firstRunAddsTheLoginItem() {
        let defaults = scratchDefaults()
        let service = FakeLoginItem()
        LaunchAtLogin.registerOnFirstRun(defaults: defaults, service: service)
        #expect(service.isEnabled)
        #expect(defaults.bool(forKey: LaunchAtLogin.didSetDefaultKey))
    }

    @Test func turnedOffInSystemSettingsStaysOff() {
        let defaults = scratchDefaults()
        let service = FakeLoginItem()
        LaunchAtLogin.registerOnFirstRun(defaults: defaults, service: service)
        try? service.unregister()
        LaunchAtLogin.registerOnFirstRun(defaults: defaults, service: service)
        #expect(!service.isEnabled)
        #expect(service.registerCalls == 1)
    }

    @Test func aRefusedRegistrationIsTriedAgainNextLaunch() {
        let defaults = scratchDefaults()
        let service = FakeLoginItem()
        service.failRegister = true
        LaunchAtLogin.registerOnFirstRun(defaults: defaults, service: service)
        #expect(!defaults.bool(forKey: LaunchAtLogin.didSetDefaultKey))
        service.failRegister = false
        LaunchAtLogin.registerOnFirstRun(defaults: defaults, service: service)
        #expect(service.isEnabled)
        #expect(service.registerCalls == 2)
    }

    @Test func dotOnlyWhileSomethingIsUnread() {
        #expect(!MenuBarIcon.hasUnread([:]))
        #expect(!MenuBarIcon.hasUnread(["a": 0, "b": 0]))
        #expect(MenuBarIcon.hasUnread(["a": 0, "b": 2]))
    }

    /// The plain icon follows the menu bar's look; the dotted one draws a red dot top right.
    @Test func dottedIconHasARedDot() throws {
        #expect(MenuBarIcon.image(hasUnread: false).isTemplate)
        let dotted = MenuBarIcon.image(hasUnread: true)
        #expect(!dotted.isTemplate)
        let cg = try #require(dotted.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        // Top-right corner, a couple of pixels in: inside the 7pt dot at any scale.
        let x = bitmap.pixelsWide - 1 - bitmap.pixelsWide / 20
        let y = bitmap.pixelsHigh / 20 + 1
        let colour = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        // Red, not the grey of the label colour (systemRed's green is ~0.4 once it lands in sRGB).
        #expect(colour.redComponent > 0.8)
        #expect(colour.redComponent - colour.greenComponent > 0.4)
        #expect(colour.alphaComponent > 0.9)
    }
}
#endif
