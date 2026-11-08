import Testing
import Foundation
import ReTiCA
@testable import ReTiCAMsgrCore

// A real identity: `conversationTarget` validates an lxma:// key against its address.
private let carol = Identity()
private let carolAddress = lxmfAddressHex(carol)
private let carolKey = carol.publicKey.hexString
/// What other apps write and what appears in a message.
private let carolURI = "lxma://\(carolAddress):\(carolKey)"
/// What the link carries: Foundation reads `host:port`, and a 128-hex port is not a URL, so the
/// link uses the `.` separator (Retichat's alternative, which `ContactURI.parse` accepts).
private let carolLink = "lxma://\(carolAddress).\(carolKey)"

private func links(_ body: String) -> [(String, String)] {
    let attributed = MessageLinks.attributed(body)
    return attributed.runs.compactMap { run in
        run.link.map { (String(attributed[run.range].characters), $0.absoluteString) }
    }
}

@Test func colonFormLxmaIsNotAFoundationURL() {
    // Pins the reason for the `.` link form: if this ever parses, the link could carry `:` as-is.
    #expect(URL(string: carolURI) == nil)
}

@Test func linksLxmaURIWithKeyAsOneLink() {
    let found = links("add me \(carolURI) thanks")
    #expect(found.count == 1)
    #expect(found.first?.0 == carolURI)
    #expect(found.first?.1 == carolLink)
}

@Test func linksDotFormLxmaURI() {
    let found = links("add me \(carolLink) thanks")
    #expect(found.count == 1)
    #expect(found.first?.0 == carolLink)
    #expect(found.first?.1 == carolLink)
}

@Test func lxmaLinkOpensConversation() throws {
    let url = try #require(URL(string: carolLink))
    #expect(MessageLinks.conversationTarget(for: url, ownAddress: "ffffffffffffffffffffffffffffffff") == carolAddress)
}

@Test func isLxmfAcceptsLxma() throws {
    #expect(MessageLinks.isLxmf(try #require(URL(string: "lxma://\(carolAddress)"))))
}
