import Testing
import Foundation
@testable import ReTiCaMsgrCore

private let hex = "0123456789abcdef0123456789abcdef"
private let me = "ffffffffffffffffffffffffffffffff"

/// Each link run in the attributed body, as (linked text, URL string).
private func links(_ body: String) -> [(String, String)] {
    let attributed = MessageLinks.attributed(body)
    return attributed.runs.compactMap { run in
        run.link.map { (String(attributed[run.range].characters), $0.absoluteString) }
    }
}

@Test func messageLinksLeavesPlainTextUnlinked() {
    #expect(links("hello there").isEmpty)
    #expect(String(MessageLinks.attributed("hello there").characters) == "hello there")
}

@Test func messageLinksLinksAWebAddress() {
    let found = links("see https://example.com/page now")
    #expect(found.count == 1)
    #expect(found.first?.0 == "https://example.com/page")
    #expect(found.first?.1 == "https://example.com/page")
}

@Test func messageLinksLinksAPhoneNumber() {
    let found = links("call +1 415 555 0100 later")
    #expect(found.count == 1)
    #expect(found.first?.1.hasPrefix("tel:") == true)
}

@Test func messageLinksLinksAnLxmfSchemeAddress() {
    let found = links("me: lxmf://\(hex) ok")
    #expect(found.count == 1)
    #expect(found.first?.0 == "lxmf://\(hex)")
    #expect(found.first?.1 == "lxmf://\(hex)")
}

@Test func messageLinksLinksAnLxmfAtAddress() {
    let found = links("me: lxmf@\(hex)")
    #expect(found.count == 1)
    #expect(found.first?.0 == "lxmf@\(hex)")
    #expect(found.first?.1 == "lxmf://\(hex)")
}

@Test func messageLinksLinksABareAddressAndLowercasesIt() {
    let found = links("try \(hex.uppercased()).")
    #expect(found.count == 1)
    #expect(found.first?.0 == hex.uppercased())
    #expect(found.first?.1 == "lxmf://\(hex)")
}

@Test func messageLinksIgnoresHexRunsThatAreNotExactly32Long() {
    #expect(links(hex + "0").isEmpty)
    #expect(links(String(hex.dropLast())).isEmpty)
    #expect(links("x" + hex).isEmpty)
}

@Test func messageLinksLeavesHexInsideAWebAddressToTheWebLink() {
    let found = links("https://example.com/\(hex)/x")
    #expect(found.count == 1)
    #expect(found.first?.1 == "https://example.com/\(hex)/x")
}

@Test func messageLinksUnderlinesLinks() {
    let attributed = MessageLinks.attributed("go https://example.com")
    let linkRun = attributed.runs.first { $0.link != nil }
    #expect(linkRun?.underlineStyle == .single)
}

@Test func messageLinksConversationTargetForAnLxmfLink() {
    #expect(MessageLinks.conversationTarget(for: URL(string: "lxmf://\(hex)")!, ownAddress: me) == hex)
}

@Test func messageLinksNoConversationTargetForOwnAddress() {
    #expect(MessageLinks.conversationTarget(for: URL(string: "lxmf://\(me)")!, ownAddress: me.uppercased()) == nil)
}

@Test func messageLinksNoConversationTargetForAWebLink() {
    #expect(MessageLinks.conversationTarget(for: URL(string: "https://example.com/\(hex)")!, ownAddress: me) == nil)
}

@Test func messageLinksIsLxmfOnlyForTheLxmfScheme() {
    #expect(MessageLinks.isLxmf(URL(string: "LXMF://\(me)")!))
    #expect(!MessageLinks.isLxmf(URL(string: "https://example.com")!))
}
