import Testing
import Foundation
import CoreText
@testable import ReTiCaMsgrCore

@Test func mdiKnowsSidebandDefault() {
    #expect(MDIIcons.codepoint(for: "account") == Character(UnicodeScalar(0xF0004)!))
}

@Test func mdiUnknownNameIsNil() {
    #expect(MDIIcons.codepoint(for: "no-such-icon") == nil)
}

@Test func mdiFontIsBundled() {
    #expect(Bundle.module.url(forResource: "materialdesignicons-webfont", withExtension: "ttf") != nil)
}

@Test func mdiFontRegistersAndResolvesByName() {
    MDIIcons.registerFont()
    MDIIcons.registerFont()  // idempotent
    let font = CTFontCreateWithName(MDIIcons.fontName as CFString, 20, nil)
    let ps = CTFontCopyPostScriptName(font) as String
    #expect(ps == MDIIcons.fontName)
}
