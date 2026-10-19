import Testing
import Foundation
import GRDB
@testable import ReTiCaMsgrCore

private let profTablePeer = String(repeating: "c", count: 32)
private let profTableT0 = Date(timeIntervalSince1970: 1_700_000_000)
private let profTableIcon = IconAppearance(name: "star", fg: "ffffff", bg: "112233")

@Test func peerProfileSetPhotoReturnsReplacedPath() throws {
    let db = try AppDatabase.makeInMemory()
    let first = try db.write { try PeerProfile.setPhoto(profTablePeer, version: "v1", path: "p1", at: profTableT0, $0) }
    #expect(first == nil)
    let second = try db.write { try PeerProfile.setPhoto(profTablePeer, version: "v2", path: "p2", at: profTableT0 + 1, $0) }
    #expect(second == "p1")
    let row = try db.read { try PeerProfile.fetch(profTablePeer, $0) }
    #expect(row?.photoVersion == "v2")
    #expect(row?.photoPath == "p2")
}

@Test func peerProfileSetPhotoSamePathReturnsNil() throws {
    let db = try AppDatabase.makeInMemory()
    _ = try db.write { try PeerProfile.setPhoto(profTablePeer, version: "v1", path: "p1", at: profTableT0, $0) }
    let again = try db.write { try PeerProfile.setPhoto(profTablePeer, version: "v1", path: "p1", at: profTableT0 + 1, $0) }
    #expect(again == nil)
    let row = try db.read { try PeerProfile.fetch(profTablePeer, $0) }
    #expect(row?.photoPath == "p1")
    #expect(row?.photoVersion == "v1")
}

@Test func peerProfileClearPhotoKeepsIcon() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try PeerProfile.setIcon(profTablePeer, profTableIcon, at: profTableT0, $0) }
    try db.write { _ = try PeerProfile.setPhoto(profTablePeer, version: "v1", path: "p", at: profTableT0, $0) }
    let removed = try db.write { try PeerProfile.clearPhoto(profTablePeer, at: profTableT0 + 1, $0) }
    #expect(removed == "p")
    let row = try db.read { try PeerProfile.fetch(profTablePeer, $0) }
    #expect(row?.photoVersion == nil)
    #expect(row?.photoPath == nil)
    #expect(row?.iconName == "star")
    #expect(row?.iconFg == "ffffff")
    #expect(row?.iconBg == "112233")
}

@Test func peerProfileSetIconKeepsPhoto() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { _ = try PeerProfile.setPhoto(profTablePeer, version: "v1", path: "p", at: profTableT0, $0) }
    try db.write { try PeerProfile.setIcon(profTablePeer, profTableIcon, at: profTableT0 + 1, $0) }
    let row = try db.read { try PeerProfile.fetch(profTablePeer, $0) }
    #expect(row?.photoVersion == "v1")
    #expect(row?.photoPath == "p")
    #expect(row?.iconName == "star")
    #expect(try db.read { try PeerProfile.all($0) }.count == 1)
}

@Test func deliveryMarkPendingKeepsDelivered() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try ProfilePhotoDelivery.markPending(profTablePeer, version: "a", hash: "h1", $0) }
    try db.write { try ProfilePhotoDelivery.applyOutcome(hash: "h1", confirmed: true, $0) }
    try db.write { try ProfilePhotoDelivery.markPending(profTablePeer, version: "b", hash: "h2", $0) }
    let row = try db.read { try ProfilePhotoDelivery.fetch(profTablePeer, $0) }
    #expect(row?.deliveredVersion == "a")
    #expect(row?.pendingVersion == "b")
    #expect(row?.pendingHash == "h2")
}

@Test func deliveryConfirmedPromotesPending() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try ProfilePhotoDelivery.markPending(profTablePeer, version: "v", hash: "h", $0) }
    try db.write { try ProfilePhotoDelivery.applyOutcome(hash: "h", confirmed: true, $0) }
    let row = try db.read { try ProfilePhotoDelivery.fetch(profTablePeer, $0) }
    #expect(row?.deliveredVersion == "v")
    #expect(row?.pendingVersion == nil)
    #expect(row?.pendingHash == nil)
}

@Test func deliveryFailedClearsPendingOnly() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try ProfilePhotoDelivery.markPending(profTablePeer, version: "a", hash: "h1", $0) }
    try db.write { try ProfilePhotoDelivery.applyOutcome(hash: "h1", confirmed: true, $0) }
    try db.write { try ProfilePhotoDelivery.markPending(profTablePeer, version: "b", hash: "h", $0) }
    try db.write { try ProfilePhotoDelivery.applyOutcome(hash: "h", confirmed: false, $0) }
    let row = try db.read { try ProfilePhotoDelivery.fetch(profTablePeer, $0) }
    #expect(row?.deliveredVersion == "a")
    #expect(row?.pendingVersion == nil)
    #expect(row?.pendingHash == nil)
}

@Test func deliveryOutcomeForOtherHashIsIgnored() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try ProfilePhotoDelivery.markPending(profTablePeer, version: "v", hash: "h", $0) }
    try db.write { try ProfilePhotoDelivery.applyOutcome(hash: "other", confirmed: true, $0) }
    let row = try db.read { try ProfilePhotoDelivery.fetch(profTablePeer, $0) }
    #expect(row?.deliveredVersion == nil)
    #expect(row?.pendingVersion == "v")
    #expect(row?.pendingHash == "h")
}

@Test func avatarStoreRoundTripsMineAndPeer() throws {
    let store = AvatarStore.testValue
    #expect(store.mine() == nil)
    let mine = Data([1, 2, 3])
    try store.storeMine(mine)
    #expect(store.mine() == mine)
    #expect(store.myPhotoURL.lastPathComponent == "me.jpg")
    let bytes = Data([9, 8, 7, 6])
    let path = try store.storePeer(bytes, peerHex: profTablePeer, version: "abcd")
    #expect(path == "\(profTablePeer)-abcd.jpg")
    #expect(try Data(contentsOf: store.url(forRelativePath: path)) == bytes)
    try store.delete(path)
    #expect(!FileManager.default.fileExists(atPath: store.url(forRelativePath: path).path))
    try store.delete(path)
    try store.deleteMine()
    #expect(store.mine() == nil)
    try store.deleteMine()
}
