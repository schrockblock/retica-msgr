import Testing
import Foundation
import ComposableArchitecture
import Sharing
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
@testable import ReTiCaMsgrCore

// MARK: - Helpers (dependency block mirrors AppFeatureTests.makeStore, plus the contacts fake)

private let linkPeerA = String(repeating: "a", count: 32)
private let linkPeerB = String(repeating: "b", count: 32)
private let linkT0 = Date(timeIntervalSince1970: 1_700_000_000)
private let jane = ContactSummary(identifier: "CN-1", name: "Jane Doe", hasPhoto: false)
private let bob = ContactSummary(identifier: "CN-2", name: "Bob Ray", hasPhoto: true)

@MainActor
func makeLinkStore(_ db: any DatabaseWriter, fake: FakeContacts,
                   configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: Identity())
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.attachmentStore = AttachmentStore.testValue
        $0.date = .constant(linkT0)
        $0.transportDate = .constant(linkT0)
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in }, close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in }, openChannel: { _ in },
                                 send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
        $0.contactsClient = fake.client
    }
    store.exhaustivity = .off
    return store
}

/// A link row as `ContactLinking.newLink` would write it at `linkT0`.
func linkRow(_ peer: String, _ contact: ContactSummary, source: String = ContactLinkSource.manual,
             verified: Bool? = nil) -> ContactLink {
    ContactLink(peerHex: peer, contactIdentifier: contact.identifier, cachedName: contact.name, source: source,
                discoveredViaHex: nil, discoveredSessionId: nil, discoveredAt: nil, confirmationsJSON: "[]",
                verified: verified ?? (source == ContactLinkSource.manual || source == ContactLinkSource.scanned),
                conflictedAt: nil, conflictPeerHex: nil, createdAt: linkT0, updatedAt: linkT0)
}

/// Seed rows straight into the table and into state, as a launch would.
@MainActor
func seedLinks(_ db: any DatabaseWriter, _ store: TestStoreOf<AppFeature>, _ rows: [ContactLink]) async throws {
    try await db.write { db in for row in rows { try ContactLink.insertReplacing(row, db) } }
    await store.send(.contactLinksLoaded(rows))
}

@MainActor
func pick(_ store: TestStoreOf<AppFeature>, _ peer: String, _ contact: ContactSummary,
          source: String = ContactLinkSource.manual) async {
    await store.send(.contactPicked(peerHex: peer, identifier: contact.identifier, name: contact.name, source: source))
}

@MainActor
func receiveLinks(_ store: TestStoreOf<AppFeature>) async {
    await store.receive { if case .contactLinksLoaded = $0 { return true }; return false }
}

private func rows(_ db: any DatabaseWriter) throws -> [ContactLink] {
    try db.read { try ContactLink.all($0) }
}

// MARK: - Linking

@MainActor @Test func linkActLinkFromChatIsManualAndVerified() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    await store.send(.linkContactTapped(peerHex: linkPeerA, source: ContactLinkSource.manual)) {
        $0.contactsAuthorization = .full
        $0.linkPickerTarget = LinkPickerTarget(peerHex: linkPeerA, source: ContactLinkSource.manual)
    }
    await pick(store, linkPeerA, jane)
    #expect(store.state.linkPickerTarget == nil)
    await receiveLinks(store)
    #expect(store.state.contactLinks[linkPeerA] == linkRow(linkPeerA, jane))
    #expect(try rows(db) == [linkRow(linkPeerA, jane)])
    await store.finish()
}

@MainActor @Test func linkActLinkFromScanIsScanned() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    await pick(store, linkPeerA, jane, source: ContactLinkSource.scanned)
    await receiveLinks(store)
    #expect(store.state.contactLinks[linkPeerA]?.source == ContactLinkSource.scanned)
    #expect(store.state.contactLinks[linkPeerA]?.verified == true)
    await store.finish()
}

@MainActor @Test func linkActRequestsAccessWhenNotDetermined() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(authorization: .notDetermined, grantOnRequest: .full, contacts: [jane])
    let store = makeLinkStore(db, fake: fake)
    await store.send(.linkContactTapped(peerHex: linkPeerA, source: ContactLinkSource.manual)) {
        $0.contactsAuthorization = .notDetermined
    }
    await store.receive(.contactsAccessResolved(.full, peerHex: linkPeerA, source: ContactLinkSource.manual)) {
        $0.contactsAuthorization = .full
        $0.linkPickerTarget = LinkPickerTarget(peerHex: linkPeerA, source: ContactLinkSource.manual)
    }
    await store.finish()
}

@MainActor @Test func linkActDeniedAccessShowsNoPickerAndKeepsLinks() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(authorization: .denied)
    let store = makeLinkStore(db, fake: fake)
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    store.exhaustivity = .on
    await store.send(.linkContactTapped(peerHex: linkPeerB, source: ContactLinkSource.manual)) {
        $0.contactsAuthorization = .denied
    }
    #expect(store.state.linkPickerTarget == nil)
    #expect(store.state.peerDisplayName(linkPeerA) == "Jane Doe", "names keep working from the cached name")
}

@MainActor @Test func linkActRepickingTheSameContactIsANoOp() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    store.exhaustivity = .on
    await pick(store, linkPeerA, jane)   // exhaustive: no state change, no effect
    #expect(try rows(db).count == 1)
}

@MainActor @Test func linkActCollisionOnPeerAsksToReplace() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane, bob]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await pick(store, linkPeerA, bob)
    let collision = store.state.pendingLinkCollision
    #expect(collision?.kind == .peerAlreadyLinked)
    #expect(collision?.existing == linkRow(linkPeerA, jane))
    #expect(collision?.identifier == "CN-2")
    #expect(try rows(db) == [linkRow(linkPeerA, jane)], "nothing is written until Replace")
    await store.finish()
}

@MainActor @Test func linkActCollisionOnContactAsksToReplace() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await pick(store, linkPeerB, jane)
    #expect(store.state.pendingLinkCollision?.kind == .contactAlreadyLinked)
    #expect(store.state.pendingLinkCollision?.existing.peerHex == linkPeerA)
    #expect(try rows(db).count == 1)
    await store.finish()
}

@MainActor @Test func linkActReplaceSwapsTheRow() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await pick(store, linkPeerB, jane)
    await store.send(.replaceLinkConfirmed) { $0.pendingLinkCollision = nil }
    await receiveLinks(store)
    #expect(try rows(db) == [linkRow(linkPeerB, jane)])
    #expect(store.state.contactLinks[linkPeerA] == nil)
    await store.finish()
}

@MainActor @Test func linkActCancelLeavesLinks() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await pick(store, linkPeerB, jane)
    store.exhaustivity = .on
    await store.send(.cancelLinkCollision) { $0.pendingLinkCollision = nil }
    #expect(try rows(db) == [linkRow(linkPeerA, jane)])
}

@MainActor @Test func linkActUnlinkDeletes() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await store.send(.unlinkContact(peerHex: linkPeerA))
    await receiveLinks(store)
    #expect(store.state.contactLinks.isEmpty)
    #expect(try rows(db).isEmpty)
    await store.finish()
}

// MARK: - Verification, confirmations, conflicts

@MainActor @Test func linkActMarkVerified() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane, source: ContactLinkSource.discovered)])
    #expect(store.state.contactLinks[linkPeerA]?.verified == false)
    await store.send(.markContactVerified(peerHex: linkPeerA))
    await receiveLinks(store)
    #expect(store.state.contactLinks[linkPeerA]?.verified == true)
    #expect(try rows(db).first?.verified == true)
    await store.finish()
}

@MainActor @Test func linkActConfirmationPromptsAndDoesNotVerify() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane, source: ContactLinkSource.discovered)])
    let confirmation = ContactConfirmation(peerHex: linkPeerB, sessionId: "s1", date: linkT0)
    await store.send(.confirmationReceived(peerHex: linkPeerA, confirmation: confirmation)) {
        $0.pendingVerifyPrompts = [linkPeerA]
    }
    await receiveLinks(store)
    #expect(store.state.contactLinks[linkPeerA]?.confirmations == [confirmation])
    #expect(store.state.contactLinks[linkPeerA]?.verified == false, "the app asks; it never verifies by itself")
    await store.send(.markContactVerified(peerHex: linkPeerA)) { $0.pendingVerifyPrompts = [] }
    await receiveLinks(store)
    #expect(store.state.contactLinks[linkPeerA]?.verified == true)
    await store.finish()
}

@MainActor @Test func linkActConfirmationOnVerifiedLinkRecordsWithoutPrompt() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    let confirmation = ContactConfirmation(peerHex: linkPeerB, sessionId: "s1", date: linkT0)
    await store.send(.confirmationReceived(peerHex: linkPeerA, confirmation: confirmation))
    await receiveLinks(store)
    #expect(store.state.pendingVerifyPrompts.isEmpty)
    #expect(store.state.contactLinks[linkPeerA]?.confirmations == [confirmation])
    await store.finish()
}

@MainActor @Test func linkActConflictSetsAndResolveClears() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    // The exchange's cross-check: a report naming a different contact for this peer is stale.
    store.exhaustivity = .on
    await store.send(.conflictReported(peerHex: linkPeerA, contactIdentifier: "CN-9", otherPeerHex: linkPeerB, at: linkT0))
    await store.finish()
    store.exhaustivity = .off
    #expect(try rows(db).first?.conflictedAt == nil, "a report naming the wrong contact must not write")
    #expect(store.state.contactLinks[linkPeerA]?.conflictedAt == nil)
    await store.send(.conflictReported(peerHex: linkPeerA, contactIdentifier: "CN-1", otherPeerHex: linkPeerB, at: linkT0))
    await receiveLinks(store)
    #expect(store.state.contactLinks[linkPeerA]?.conflictedAt == linkT0)
    #expect(store.state.contactLinks[linkPeerA]?.conflictPeerHex == linkPeerB)
    await store.send(.resolveConflict(peerHex: linkPeerA))
    await receiveLinks(store)
    #expect(store.state.contactLinks[linkPeerA]?.conflictedAt == nil)
    #expect(store.state.contactLinks[linkPeerA]?.conflictPeerHex == nil)
    await store.finish()
}

@MainActor @Test func linkActNameRefreshUpdatesCache() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await store.send(.contactNameRefreshed(peerHex: linkPeerA, name: "Jane Doe-Smith"))
    await receiveLinks(store)
    #expect(store.state.contactLinks[linkPeerA]?.cachedName == "Jane Doe-Smith")
    #expect(try rows(db).first?.cachedName == "Jane Doe-Smith")
    // Same name, or an empty one: nothing happens.
    store.exhaustivity = .on
    await store.send(.contactNameRefreshed(peerHex: linkPeerA, name: "Jane Doe-Smith"))
    await store.send(.contactNameRefreshed(peerHex: linkPeerA, name: ""))
}

// MARK: - Names

@MainActor
private func announce(_ store: TestStoreOf<AppFeature>, _ hex: String, _ name: String) async {
    let peer = LXMFNode.LearnedPeer(displayName: name, stampCost: nil, supportsCompression: false, learnedAt: linkT0)
    await store.send(.rehydrateLearnedPeers([Data(hexString: hex)!: peer]))
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func linkNameLinkedNameWins() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    await announce(store, linkPeerA, "jane_on_the_mesh")
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    #expect(store.state.peerDisplayName(linkPeerA) == "Jane Doe")
    #expect(store.state.peerAnnounceName(linkPeerA) == "jane_on_the_mesh")
    #expect(store.state.contactName(linkPeerA) == "Jane Doe")
    #expect(store.state.groupMemberName(linkPeerA) == "Jane Doe")
}

@MainActor @Test func linkNameFallsBackToAnnounceWhenUnlinked() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts())
    await announce(store, linkPeerA, "jane_on_the_mesh")
    #expect(store.state.peerDisplayName(linkPeerA) == "jane_on_the_mesh")
    #expect(store.state.contactName(linkPeerA) == nil)
    #expect(store.state.peerDisplayName(linkPeerB) == nil)
}

@MainActor @Test func linkNameLinksLoadAtLaunch() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { try ContactLink.insertReplacing(linkRow(linkPeerA, jane), $0) }
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    await store.send(.onLaunch)
    await receiveLinks(store)
    #expect(store.state.contactLinks[linkPeerA] == linkRow(linkPeerA, jane))
    await store.skipReceivedActions(strict: false)
}

// MARK: - Contact-card mirror and import (spec §3)

private let linkPeerC = String(repeating: "c", count: 32)

@MainActor
private func mirrorStore(_ db: any DatabaseWriter, fake: FakeContacts, on: Bool = true) -> TestStoreOf<AppFeature> {
    makeLinkStore(db, fake: fake) { $0.$contactMirrorEnabled.withLock { $0 = on } }
}

@MainActor @Test func linkMirrorWritesOnLinkWithFullAccess() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [jane])
    let store = mirrorStore(db, fake: fake)
    await pick(store, linkPeerA, jane)
    await receiveLinks(store)
    await store.finish()
    #expect(fake.writes == [FakeContacts.Write(identifier: "CN-1", peerHex: linkPeerA)])
    #expect(fake.clears.isEmpty)
}

@MainActor @Test func linkMirrorNoWriteUnderLimitedAccess() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(authorization: .limited, contacts: [jane])
    let store = mirrorStore(db, fake: fake)
    await pick(store, linkPeerA, jane)
    await receiveLinks(store)
    await store.finish()
    #expect(fake.writes.isEmpty, "limited access cannot update cards")
    #expect(store.state.contactLinks[linkPeerA] != nil, "the link itself still happens")
}

@MainActor @Test func linkMirrorOffWritesNothingOnLink() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [jane])
    let store = mirrorStore(db, fake: fake, on: false)
    await pick(store, linkPeerA, jane)
    await receiveLinks(store)
    await store.finish()
    #expect(fake.writes.isEmpty)
}

@MainActor @Test func linkMirrorClearsOnUnlink() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [jane])
    let store = mirrorStore(db, fake: fake)
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await store.send(.unlinkContact(peerHex: linkPeerA))
    await receiveLinks(store)
    await store.finish()
    #expect(fake.clears == ["CN-1"])
}

@MainActor @Test func linkMirrorReplaceClearsTheOldCardAndWritesTheNew() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [jane, bob])
    let store = mirrorStore(db, fake: fake)
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await pick(store, linkPeerA, bob)            // peer already linked to Jane → collision
    await store.send(.replaceLinkConfirmed) { $0.pendingLinkCollision = nil }
    await receiveLinks(store)
    await store.finish()
    #expect(fake.clears == ["CN-1"])
    #expect(fake.writes == [FakeContacts.Write(identifier: "CN-2", peerHex: linkPeerA)])
}

@MainActor @Test func linkMirrorToggleOnWritesEveryExistingLinkOnce() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [jane, bob])
    let store = mirrorStore(db, fake: fake, on: false)
    try await seedLinks(db, store, [linkRow(linkPeerA, jane), linkRow(linkPeerB, bob)])
    await store.send(.setContactMirror(true)) { $0.$contactMirrorEnabled.withLock { $0 = true } }
    await store.skipReceivedActions(strict: false)
    await store.finish()
    #expect(Set(fake.writes) == [FakeContacts.Write(identifier: "CN-1", peerHex: linkPeerA),
                                 FakeContacts.Write(identifier: "CN-2", peerHex: linkPeerB)])
    #expect(fake.writes.count == 2)
}

@MainActor @Test func linkMirrorToggleOffWritesNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [jane])
    let store = mirrorStore(db, fake: fake)
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    store.exhaustivity = .on
    await store.send(.setContactMirror(false)) { $0.$contactMirrorEnabled.withLock { $0 = false } }
    #expect(fake.writes.isEmpty)
    #expect(fake.clears.isEmpty, "cards already written stay as they are")
}

@MainActor @Test func linkMirrorImportCreatesUnverifiedLinksAndSkipsCollisions() async throws {
    let db = try AppDatabase.makeInMemory()
    // CN-1 is already linked to peer A; CN-2's card points at peer B (new); CN-3's card points at
    // peer A (the address is taken) — only CN-2 is importable.
    let fake = FakeContacts(contacts: [jane, bob, ContactSummary(identifier: "CN-3", name: "Cy", hasPhoto: false)],
                            addresses: ["CN-1": linkPeerA, "CN-2": linkPeerB, "CN-3": linkPeerA])
    let store = mirrorStore(db, fake: fake)
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await store.send(.contactLinkSheetAppeared)
    await store.receive(.importCandidatesFound([ImportCandidate(identifier: "CN-2", name: "Bob Ray", peerHex: linkPeerB)])) {
        $0.importCandidates = [ImportCandidate(identifier: "CN-2", name: "Bob Ray", peerHex: linkPeerB)]
    }
    await store.send(.importContactLinks) { $0.importCandidates = [] }
    await receiveLinks(store)
    await store.finish()
    #expect(store.state.contactLinks[linkPeerB] == linkRow(linkPeerB, bob, source: ContactLinkSource.imported, verified: false))
    #expect(store.state.contactLinks[linkPeerA] == linkRow(linkPeerA, jane), "the existing link is untouched")
    #expect(fake.writes.isEmpty, "an imported address is already on its card")
}

@MainActor @Test func linkMirrorImportDropsMalformedAddresses() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [jane, bob], addresses: ["CN-1": "zzz", "CN-2": String(linkPeerB.dropLast())])
    let store = mirrorStore(db, fake: fake)
    store.exhaustivity = .on
    await store.send(.contactLinkSheetAppeared)
    await store.receive(.importCandidatesFound([]))
}

@MainActor @Test func linkMirrorOffDoesNotScan() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [bob], addresses: ["CN-2": linkPeerB])
    let store = mirrorStore(db, fake: fake, on: false)
    store.exhaustivity = .on
    await store.send(.contactLinkSheetAppeared)   // exhaustive: nothing happens with the mirror off
}
