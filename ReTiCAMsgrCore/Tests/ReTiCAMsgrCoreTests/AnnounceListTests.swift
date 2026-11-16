import Testing
import Foundation
@testable import ReTiCAMsgrCore
import ReTiCA
import ReTiCANode

private let announceNow = Date(timeIntervalSince1970: 1_800_000_000)

/// Sixteen bytes starting with `first`, so a test reads its hashes, their byte order and their hex
/// from one number: `announceHash(0xA0)` is "a0" followed by fifteen "11".
private func announceHash(_ first: UInt8) -> Data {
    Data([first] + [UInt8](repeating: 0x11, count: 15))
}

private func announceHex(_ first: UInt8) -> String {
    String(format: "%02x", first) + String(repeating: "11", count: 15)
}

private func announcedPeer(_ name: String?, heardAgo seconds: TimeInterval) -> LXMFNode.LearnedPeer {
    LXMFNode.LearnedPeer(displayName: name, stampCost: 8, supportsCompression: true,
                         learnedAt: announceNow.addingTimeInterval(-seconds))
}

private func announceLink(_ first: UInt8, name: String) -> ContactLink {
    ContactLink(peerHex: announceHex(first), contactIdentifier: "contact-\(first)", cachedName: name,
                source: ContactLinkSource.manual, discoveredViaHex: nil, discoveredSessionId: nil,
                discoveredAt: nil, confirmationsJSON: "[]", verified: true, promptDismissed: false,
                conflictedAt: nil, conflictPeerHex: nil, createdAt: announceNow, updatedAt: announceNow)
}

/// A state whose learned-peer table holds `peers`.
@MainActor
private func announceState(_ peers: [UInt8: LXMFNode.LearnedPeer]) -> AppFeature.State {
    var state = AppFeature.State(identity: Identity())
    for (first, peer) in peers { state.node.client.learnedPeers[announceHash(first)] = peer }
    return state
}

private let alice: UInt8 = 0xA0
private let bob: UInt8 = 0xB0
private let carol: UInt8 = 0xC0
private let dave: UInt8 = 0xD0
private let erin: UInt8 = 0xE0

@MainActor
private func threePeers() -> AppFeature.State {
    announceState([alice: announcedPeer("Alice", heardAgo: 10),
                   bob: announcedPeer("Bob", heardAgo: 20),
                   carol: announcedPeer(nil, heardAgo: 30)])
}

private func ids(_ list: AnnounceList) -> [Data] { list.rows.map(\.id) }

// MARK: - Order

@MainActor @Test func theOrderCapturedOnOpeningIsNewestFirst() {
    let state = threePeers()
    #expect(AnnounceList.Order(of: state).hashes == [alice, bob, carol].map(announceHash))
    // Before an order is captured, the list itself is newest first.
    #expect(ids(AnnounceList(from: state, order: AnnounceList.Order())) == [alice, bob, carol].map(announceHash))
}

// The sheet's reason for freezing the order: a row must not move when its peer announces again.
@MainActor @Test func aListedPeerThatAnnouncesAgainKeepsItsPlace() {
    var state = threePeers()
    let order = AnnounceList.Order(of: state)
    state.node.client.learnedPeers[announceHash(carol)]?.learnedAt = announceNow

    let list = AnnounceList(from: state, order: order)
    #expect(ids(list) == [alice, bob, carol].map(announceHash))
    // The row still shows when the peer was last heard.
    #expect(list.rows.last?.learnedAt == announceNow)
}

@MainActor @Test func aPeerHeardAfterOpeningGoesAfterTheListedOnesNewestFirst() {
    var state = threePeers()
    let order = AnnounceList.Order(of: state)
    // Both are newer than everyone listed. Erin is the newer of the two.
    state.node.client.learnedPeers[announceHash(dave)] = announcedPeer("Dave", heardAgo: 2)
    state.node.client.learnedPeers[announceHash(erin)] = announcedPeer("Erin", heardAgo: 1)

    let list = AnnounceList(from: state, order: order)
    #expect(ids(list) == [alice, bob, carol, erin, dave].map(announceHash))
    #expect(list.known == 5)
}

@MainActor @Test func peersHeardAtTheSameMomentAreOrderedByAddress() {
    let state = announceState([carol: announcedPeer("C", heardAgo: 5),
                               alice: announcedPeer("A", heardAgo: 5),
                               bob: announcedPeer("B", heardAgo: 5)])
    #expect(AnnounceList.Order(of: state).hashes == [alice, bob, carol].map(announceHash))
    #expect(ids(AnnounceList(from: state, order: AnnounceList.Order())) == [alice, bob, carol].map(announceHash))
}

@MainActor @Test func aListedPeerThatLeftTheTableIsDropped() {
    var state = threePeers()
    let order = AnnounceList.Order(of: state)
    state.node.client.learnedPeers[announceHash(bob)] = nil

    let list = AnnounceList(from: state, order: order)
    #expect(ids(list) == [alice, carol].map(announceHash))
    #expect(list.known == 2)
}

// MARK: - Blocked peers

@MainActor @Test func aBlockedPeerIsNeitherListedNorCounted() {
    var state = threePeers()
    state.blockedPeers = [announceHex(bob)]
    #expect(AnnounceList.Order(of: state).hashes == [alice, carol].map(announceHash))

    // Blocked while the sheet is open: the order still names the peer, the list does not.
    let orderFromBefore = AnnounceList.Order(of: threePeers())
    let list = AnnounceList(from: state, order: orderFromBefore)
    #expect(ids(list) == [alice, carol].map(announceHash))
    #expect(list.known == 2)
    #expect(list.matching == 2)

    // And not as a peer heard later either.
    #expect(ids(AnnounceList(from: state, order: AnnounceList.Order())) == [alice, carol].map(announceHash))
}

@MainActor @Test func whenEveryoneHeardIsBlockedNobodyIsKnown() {
    var state = threePeers()
    state.blockedPeers = Set([alice, bob, carol].map(announceHex))
    let list = AnnounceList(from: state, order: AnnounceList.Order(of: state))
    #expect(list.rows.isEmpty)
    #expect(list.known == 0)
}

// MARK: - Rows

@MainActor @Test func aRowCarriesTheAddressTheContactNameAndTheAnnouncedName() {
    var state = threePeers()
    state.contactLinks[announceHex(bob)] = announceLink(bob, name: "Robert")
    // A link whose cached name is empty names nobody.
    state.contactLinks[announceHex(carol)] = announceLink(carol, name: "")

    let rows = AnnounceList(from: state, order: AnnounceList.Order(of: state)).rows
    #expect(rows.map(\.hex) == [alice, bob, carol].map(announceHex))
    #expect(rows.map(\.contactName) == [nil, "Robert", nil])
    #expect(rows.map(\.announcedName) == ["Alice", "Bob", nil])
    #expect(rows.map(\.learnedAt) == [10, 20, 30].map { announceNow.addingTimeInterval(-$0) })
}

// MARK: - Search

@MainActor @Test func searchMatchesTheAnnouncedNameTheContactNameOrTheAddress() {
    var state = threePeers()
    state.contactLinks[announceHex(bob)] = announceLink(bob, name: "Robert")
    let order = AnnounceList.Order(of: state)
    func found(_ search: String) -> [Data] { ids(AnnounceList(from: state, order: order, search: search)) }

    #expect(found("") == [alice, bob, carol].map(announceHash))
    #expect(found("   ") == [alice, bob, carol].map(announceHash))
    // Names, whatever the case, with the spaces around the text ignored.
    #expect(found("ali") == [announceHash(alice)])
    #expect(found(" ALICE ") == [announceHash(alice)])
    #expect(found("robert") == [announceHash(bob)])
    #expect(found("bob") == [announceHash(bob)])
    // An address, as typed or as copied with its brackets and spaces.
    #expect(found("c011") == [announceHash(carol)])
    #expect(found("<C011 1111>") == [announceHash(carol)])
    #expect(found("1111") == [alice, bob, carol].map(announceHash))
    // Text that is neither a name nor hex.
    #expect(found("zed").isEmpty)
}

@MainActor @Test func aSearchThatFindsNobodyStillKnowsPeopleWereHeard() {
    let state = threePeers()
    let list = AnnounceList(from: state, order: AnnounceList.Order(of: state), search: "zed")
    #expect(list.rows.isEmpty)
    #expect(list.matching == 0)
    #expect(list.known == 3)
}

// MARK: - Row limit

// The cause of the frozen screen was work that followed the size of the table. The rows the
// sheet builds do not: there are at most `rowLimit` of them, and a count of the rest.
@MainActor @Test func theRowLimitKeepsTheFirstRowsAndCountsTheRest() {
    var peers: [UInt8: LXMFNode.LearnedPeer] = [:]
    for index in 0..<30 { peers[UInt8(index)] = announcedPeer("Peer \(index)", heardAgo: TimeInterval(index)) }
    let state = announceState(peers)
    let order = AnnounceList.Order(of: state)

    let whole = AnnounceList(from: state, order: order)
    #expect(whole.rows.count == 30)
    #expect(whole.more == 0)

    let limited = AnnounceList(from: state, order: order, rowLimit: 10)
    #expect(limited.rows == Array(whole.rows.prefix(10)))
    #expect(limited.known == 30)
    #expect(limited.matching == 30)
    #expect(limited.more == 20)

    // The search covers every peer, not only the rows shown: "Peer 2" and "Peer 20" to "Peer 29".
    let searched = AnnounceList(from: state, order: order, search: "peer 2", rowLimit: 4)
    #expect(searched.rows.map(\.announcedName) == ["Peer 2", "Peer 20", "Peer 21", "Peer 22"])
    #expect(searched.matching == 11)
    #expect(searched.more == 7)

    // A peer heard later counts towards the rest when the limit is already reached.
    var later = state
    later.node.client.learnedPeers[announceHash(0xF0)] = announcedPeer("Late", heardAgo: 0)
    let withLater = AnnounceList(from: later, order: order, rowLimit: 10)
    #expect(withLater.rows == limited.rows)
    #expect(withLater.more == 21)
}

// MARK: - Hex

@Test func hexStringIsTwoLowercaseDigitsPerByte() {
    let everyByte = Data((0...255).map { UInt8($0) })
    #expect(everyByte.hexString == (0...255).map { String(format: "%02x", $0) }.joined())
    #expect(Data().hexString == "")
    #expect(Data([0x00, 0x0F, 0xF0, 0xAB]).hexString == "000ff0ab")
    #expect(Data(hexString: everyByte.hexString) == everyByte)
}
