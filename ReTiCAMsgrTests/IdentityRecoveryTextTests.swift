import Foundation
import Testing
import ReTiCAMsgrCore
@testable import ReTiCAMsgr

@Test func identityRecoveryTextPerState() {
    let expected = Data(repeating: 0xAB, count: 16)
    let got = Data(repeating: 0xCD, count: 16)
    let missing = IdentityRecoveryText.screen(for: .missing(expected: expected))
    #expect(missing.showsRestore && !missing.showsAccept && !missing.showsCreate)
    #expect(missing.message.contains("Expected ID: abababab"))
    #expect(missing.detail == nil)
    let noAnchor = IdentityRecoveryText.screen(for: .missing(expected: nil))
    #expect(!noAnchor.showsRestore)
    #expect(noAnchor.showsCreate)
    #expect(noAnchor.message.contains("no record"))
    let changed = IdentityRecoveryText.screen(for: .identityChanged(expected: expected, got: got))
    #expect(changed.showsAccept && !changed.showsRestore && !changed.showsCreate)
    #expect(changed.message.contains("Expected abababab, found cdcdcdcd."))
    #expect(changed.detail == nil)
    let locked = IdentityRecoveryText.screen(for: .unavailable(.locked))
    #expect(locked.message.contains("Unlock your device"))
    #expect(!locked.showsRestore && !locked.showsAccept)
    let stray = IdentityRecoveryText.screen(for: .unavailable(.strayItem("2 items at reticulum.identity")))
    #expect(stray.detail == "2 items at reticulum.identity")
    #expect(IdentityRecoveryText.screen(for: .unavailable(.accessDenied)).message.contains("not your data"))
    #expect(IdentityRecoveryText.screen(for: .unavailable(.other(-50))).detail == "OSStatus -50")
    #expect(IdentityRecoveryText.restore(.rejected(.mismatch(got: got, expected: expected)))
            == "That backup is identity cdcdcdcd, but your conversations belong to abababab.")
    #expect(IdentityRecoveryText.restore(.rejected(.wrongLength(65))) == "That backup is 65 bytes; an identity is 64.")
    #expect(IdentityRecoveryText.restore(.refused(.identityPresent(service: "x")))?.contains("Nothing was changed") == true)
    #expect(IdentityRecoveryText.restore(.restored(got)) == nil)
    #expect(IdentityRecoveryText.restore(.refused(.notMissing)) == nil)
}
