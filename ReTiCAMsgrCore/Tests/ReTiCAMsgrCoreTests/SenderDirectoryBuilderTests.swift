import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAPush
import ReTiCAPushCore
@testable import ReTiCAMsgrCore

private let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
private let c = String(repeating: "c", count: 32), me = String(repeating: "e", count: 32)
private let key = Data(repeating: 9, count: 64)

@Test func senderDirectoryBuilderKeepsNamedPeersWithKeys() {
    let out = SenderDirectoryBuilder.inputs(candidates: [a], me: me, blocked: [],
        name: { _ in "Alice" }, publicKey: { _ in key }, picture: { _ in nil })
    #expect(out == [a: .init(name: "Alice", publicKey: key, imageData: nil)])
}

@Test func senderDirectoryBuilderCarriesTheLinkedContactIdentifier() {
    let out = SenderDirectoryBuilder.inputs(candidates: [a, b], me: me, blocked: [],
        name: { _ in "X" }, publicKey: { _ in key }, picture: { _ in nil },
        contactIdentifier: { $0 == a ? "CN-A" : nil })
    #expect(out[a]?.contactIdentifier == "CN-A")
    #expect(out[b]?.contactIdentifier == nil)
}

@Test func senderDirectoryBuilderSkipsPeersWithoutAKey() {
    let out = SenderDirectoryBuilder.inputs(candidates: [a], me: me, blocked: [],
        name: { _ in "Alice" }, publicKey: { _ in nil }, picture: { _ in nil })
    #expect(out.isEmpty)
}

@Test func senderDirectoryBuilderSkipsBlockedAndMe() {
    let out = SenderDirectoryBuilder.inputs(candidates: [a, b, me], me: me, blocked: [b],
        name: { _ in "X" }, publicKey: { _ in key }, picture: { _ in nil })
    #expect(Set(out.keys) == [a])
}

@Test func senderDirectoryBuilderSkipsPeersWithNothingToShow() {
    let out = SenderDirectoryBuilder.inputs(candidates: [a, b], me: me, blocked: [],
        name: { _ in nil }, publicKey: { _ in key }, picture: { $0 == b ? Data([1]) : nil })
    #expect(Set(out.keys) == [b])
    #expect(out[b]?.name == nil)
}

@Test func senderDirectoryBuilderLowercases() {
    let out = SenderDirectoryBuilder.inputs(candidates: [a.uppercased()], me: me, blocked: [],
        name: { _ in "A" }, publicKey: { _ in key }, picture: { _ in nil })
    #expect(out.keys.first == a)
}

@Test func senderDirectoryCandidatesUnionsPeersLinksAndGroupMembers() {
    var state = AppFeature.State(identity: Identity(), pushStorage: .temporary())
    state.conversations = [Conversation(peerHex: a, lastBody: "", lastTimestamp: .now),
                           Conversation(peerHex: c, kind: .group, title: "G", lastBody: "", lastTimestamp: .now)]
    state.contactLinks[b] = ContactLink(
        peerHex: b, contactIdentifier: "id", cachedName: "B", source: "manual",
        discoveredViaHex: nil, discoveredSessionId: nil, discoveredAt: nil,
        confirmationsJSON: "[]", verified: true, promptDismissed: false, conflictedAt: nil,
        conflictPeerHex: nil, createdAt: .now, updatedAt: .now)
    let members = [String(repeating: "d", count: 32)]
    #expect(state.senderDirectoryCandidates(groupMembers: members) == [a, b, members[0]])   // not the group key c
}
