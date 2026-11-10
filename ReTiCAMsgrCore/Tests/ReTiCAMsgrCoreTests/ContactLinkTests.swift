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
@testable import ReTiCAMsgrCore

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
    initial.autoInterfaceAvailable = false   // hermetic: no AutoInterface slot
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.badge = .ignored
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
                promptDismissed: false, conflictedAt: nil, conflictPeerHex: nil, createdAt: linkT0, updatedAt: linkT0)
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
        $0.showingContactsDenied = true   // the root alert explains (backlog item 2)
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
    #expect(collision?.kinds == [.peerAlreadyLinked])
    #expect(collision?.existing == [linkRow(linkPeerA, jane)])
    #expect(collision?.identifier == "CN-2")
    #expect(try rows(db) == [linkRow(linkPeerA, jane)], "nothing is written until Replace")
    await store.finish()
}

@MainActor @Test func linkActCollisionOnContactAsksToReplace() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await pick(store, linkPeerB, jane)
    #expect(store.state.pendingLinkCollision?.kinds == [.contactAlreadyLinked])
    #expect(store.state.pendingLinkCollision?.existing.map(\.peerHex) == [linkPeerA])
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
    await store.send(.confirmationReceived(peerHex: linkPeerA, confirmation: confirmation))
    await receiveLinks(store)
    #expect(store.state.pendingVerifyPrompts == [linkPeerA])
    #expect(store.state.contactLinks[linkPeerA]?.confirmations == [confirmation])
    #expect(store.state.contactLinks[linkPeerA]?.verified == false, "the app asks; it never verifies by itself")
    await store.send(.markContactVerified(peerHex: linkPeerA))
    await receiveLinks(store)
    #expect(store.state.pendingVerifyPrompts.isEmpty)
    #expect(store.state.contactLinks[linkPeerA]?.verified == true)
    await store.finish()
}

/// Backlog 3: "Not now" is persisted — a relaunch does not ask again.
@MainActor @Test func linkFixDismissedPromptSurvivesRelaunch() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane, source: ContactLinkSource.discovered)])
    await store.send(.confirmationReceived(peerHex: linkPeerA,
                                           confirmation: ContactConfirmation(peerHex: linkPeerB, sessionId: "s1", date: linkT0)))
    await receiveLinks(store)
    #expect(store.state.pendingVerifyPrompts == [linkPeerA])
    await store.send(.dismissVerifyPrompt(peerHex: linkPeerA))
    await receiveLinks(store)
    #expect(store.state.pendingVerifyPrompts.isEmpty)
    await store.finish()
    let relaunched = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    await relaunched.send(.onLaunch)
    await receiveLinks(relaunched)
    #expect(relaunched.state.contactLinks[linkPeerA]?.confirmations.count == 1)
    #expect(relaunched.state.pendingVerifyPrompts.isEmpty)
    await relaunched.skipReceivedActions(strict: false)
}

/// A NEW confirmation after a dismissal asks again.
@MainActor @Test func linkFixNewConfirmationReasksAfterDismissal() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    var dismissed = linkRow(linkPeerA, jane, source: ContactLinkSource.discovered)
    dismissed.confirmations = [ContactConfirmation(peerHex: linkPeerB, sessionId: "s1", date: linkT0)]
    dismissed.promptDismissed = true
    try await seedLinks(db, store, [dismissed])
    #expect(store.state.pendingVerifyPrompts.isEmpty)
    await store.send(.confirmationReceived(peerHex: linkPeerA,
                                           confirmation: ContactConfirmation(peerHex: linkPeerB, sessionId: "s2", date: linkT0)))
    await receiveLinks(store)
    #expect(store.state.pendingVerifyPrompts == [linkPeerA])
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
    // The table is the real check: the exhaustive send above already proved no state change
    // and no reload, so state still holds the seeded row whatever the reducer wrote.
    #expect(try rows(db).first?.conflictedAt == nil, "a report naming the wrong contact must not write")
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
    await store.send(.setContactMirror(false)) {
        $0.$contactMirrorEnabled.withLock { $0 = false }
        $0.contactsAuthorization = .full   // the toggle refreshes access either way (backlog item 5)
    }
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

@MainActor @Test func linkMirrorImportKeepsOneCandidatePerAddress() async throws {
    let db = try AppDatabase.makeInMemory()
    // Two cards (CN-1, CN-2) carry the same reticulum: address; only the lowest identifier imports.
    let fake = FakeContacts(contacts: [jane, bob], addresses: ["CN-1": linkPeerB, "CN-2": linkPeerB])
    let store = mirrorStore(db, fake: fake)
    await store.send(.contactLinkSheetAppeared)
    await store.receive(.importCandidatesFound([ImportCandidate(identifier: "CN-1", name: "Jane Doe", peerHex: linkPeerB)])) {
        $0.importCandidates = [ImportCandidate(identifier: "CN-1", name: "Jane Doe", peerHex: linkPeerB)]
    }
    await store.send(.importContactLinks) { $0.importCandidates = [] }
    await receiveLinks(store)
    await store.finish()
    #expect(store.state.contactLinks[linkPeerB]?.contactIdentifier == "CN-1")
    #expect(try rows(db).count == 1)
}

@MainActor @Test func linkMirrorImportDropsMalformedAddresses() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [jane, bob], addresses: ["CN-1": "zzz", "CN-2": String(linkPeerB.dropLast())])
    let store = mirrorStore(db, fake: fake)
    store.exhaustivity = .on
    // `.contactLinkSheetAppeared` also refreshes `contactsAuthorization` now (Review Focus F3);
    // the fake's default is `.full`.
    await store.send(.contactLinkSheetAppeared) { $0.contactsAuthorization = .full }
    await store.receive(.importCandidatesFound([]))
}

@MainActor @Test func linkMirrorOffDoesNotScan() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [bob], addresses: ["CN-2": linkPeerB])
    let store = mirrorStore(db, fake: fake, on: false)
    store.exhaustivity = .on
    // `.contactLinkSheetAppeared` also refreshes `contactsAuthorization` now (Review Focus F3);
    // the mirror stays off, so still no scan.
    await store.send(.contactLinkSheetAppeared) { $0.contactsAuthorization = .full }
}

// MARK: - Final fix wave (whole-branch review, spec 2026-10-11)

@MainActor @Test func linkFinalDoubleCollisionNamesBothAndReplaceLeavesOneRow() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane, bob]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane), linkRow(linkPeerB, bob)])
    await pick(store, linkPeerA, bob)
    let collision = store.state.pendingLinkCollision
    #expect(collision?.existing.map(\.peerHex) == [linkPeerA, linkPeerB])
    #expect(collision?.kinds == [.peerAlreadyLinked, .contactAlreadyLinked])
    await store.send(.replaceLinkConfirmed) { $0.pendingLinkCollision = nil }
    await receiveLinks(store)
    #expect(try rows(db) == [linkRow(linkPeerA, bob)])
    await store.finish()
}

@MainActor @Test func linkFinalReplaceClearsPromptsForEveryDeletedPeer() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane, bob]))
    var asking = linkRow(linkPeerB, bob, source: ContactLinkSource.discovered)
    asking.confirmations = [ContactConfirmation(peerHex: linkPeerA, sessionId: "s1", date: linkT0)]
    try await seedLinks(db, store, [linkRow(linkPeerA, jane), asking])
    #expect(store.state.pendingVerifyPrompts == [linkPeerB])
    await pick(store, linkPeerA, bob)
    await store.send(.replaceLinkConfirmed) { $0.pendingLinkCollision = nil }
    await receiveLinks(store)
    #expect(store.state.pendingVerifyPrompts.isEmpty, "the prompt died with its row")
    await store.finish()
}

@MainActor @Test func linkFinalMirrorReplaceClearsEveryReplacedCard() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [jane, bob])
    let store = mirrorStore(db, fake: fake)
    try await seedLinks(db, store, [linkRow(linkPeerA, jane), linkRow(linkPeerB, bob)])
    await pick(store, linkPeerA, bob)
    await store.send(.replaceLinkConfirmed) { $0.pendingLinkCollision = nil }
    await receiveLinks(store)
    await store.finish()
    #expect(Set(fake.clears) == ["CN-1"])
    #expect(fake.writes.last == FakeContacts.Write(identifier: "CN-2", peerHex: linkPeerA))
}

@MainActor @Test func linkFinalSheetAppearedRefreshesAuthorization() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(authorization: .limited)
    let store = mirrorStore(db, fake: fake, on: false)
    store.exhaustivity = .on
    await store.send(.contactLinkSheetAppeared) { $0.contactsAuthorization = .limited }
}

@MainActor @Test func linkFinalEmptyCachedNameDoesNotBlankTheName() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts())
    await announce(store, linkPeerA, "jane_on_the_mesh")
    var blankNamed = linkRow(linkPeerA, jane)
    blankNamed.cachedName = ""
    try await seedLinks(db, store, [blankNamed])
    #expect(store.state.contactName(linkPeerA) == nil)
    #expect(store.state.peerDisplayName(linkPeerA) == "jane_on_the_mesh")
}

// MARK: - Follow-ups (backlog 2026-10-11)

/// Backlog 7: a conflict report is applied only if the row STILL names the reported contact at
/// write time (a Replace can land between the state check and the write).
@MainActor @Test func linkFixConflictIgnoresARowThatChangedUnderneath() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane, bob]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    // The table moved on without the reducer hearing about it yet.
    try await db.write { try ContactLink.insertReplacing(linkRow(linkPeerA, bob), $0) }
    await store.send(.conflictReported(peerHex: linkPeerA, contactIdentifier: "CN-1", otherPeerHex: linkPeerB, at: linkT0))
    await receiveLinks(store)
    #expect(store.state.contactLinks[linkPeerA]?.contactIdentifier == "CN-2")
    #expect(store.state.contactLinks[linkPeerA]?.conflictedAt == nil, "the report was about Jane's row, which is gone")
    await store.finish()
}

/// Backlog 2: a denied tap raises the explanation, from any entry point.
@MainActor @Test func linkFixDeniedTapShowsThePrompt() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(authorization: .denied))
    store.exhaustivity = .on
    await store.send(.linkContactTapped(peerHex: linkPeerA, source: ContactLinkSource.scanned)) {
        $0.contactsAuthorization = .denied
        $0.showingContactsDenied = true
    }
    await store.send(.dismissContactsDenied) { $0.showingContactsDenied = false }
}

@MainActor @Test func linkFixDeniedOnFirstRequestShowsThePrompt() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(authorization: .notDetermined, grantOnRequest: .denied))
    await store.send(.linkContactTapped(peerHex: linkPeerA, source: ContactLinkSource.manual)) {
        $0.contactsAuthorization = .notDetermined
    }
    await store.receive(.contactsAccessResolved(.denied, peerHex: linkPeerA, source: ContactLinkSource.manual)) {
        $0.contactsAuthorization = .denied
        $0.showingContactsDenied = true
    }
    await store.finish()
}

/// Backlog 5: turning the mirror on refreshes what Contacts reports, so Settings can explain
/// why nothing is written.
@MainActor @Test func linkFixMirrorToggleRefreshesAuthorization() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(authorization: .denied))
    store.exhaustivity = .on
    await store.send(.setContactMirror(true)) {
        $0.$contactMirrorEnabled.withLock { $0 = true }
        $0.contactsAuthorization = .denied
    }
}

/// Backlog 11: the `.notDetermined` branch of the mirror toggle asks once and then applies.
@MainActor @Test func linkFixMirrorToggleAsksForAccessThenWrites() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(authorization: .notDetermined, grantOnRequest: .full, contacts: [jane])
    let store = makeLinkStore(db, fake: fake)
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await store.send(.setContactMirror(true)) {
        $0.$contactMirrorEnabled.withLock { $0 = true }
        $0.contactsAuthorization = .notDetermined
    }
    await store.receive(.setContactMirror(true)) { $0.contactsAuthorization = .full }
    await store.skipReceivedActions(strict: false)
    await store.finish()
    #expect(fake.writes == [FakeContacts.Write(identifier: "CN-1", peerHex: linkPeerA)])
}

/// Backlog 11: a missing contact keeps its cached name on every surface.
@MainActor @Test func linkFixRowAppearedMissingContactFallsBackToTheCachedName() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts())          // Jane's card is gone
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await store.send(.contactRowAppeared(peerHex: linkPeerA))
    await store.receive(.contactCardLoaded(contactIdentifier: "CN-1", .missing)) {
        $0.contactCards["CN-1"] = .missing
    }
    #expect(store.state.peerDisplayName(linkPeerA) == "Jane Doe")
}

@MainActor @Test func linkFixRowAppearedLoadsTheCardForItsContact() async throws {
    let db = try AppDatabase.makeInMemory()
    let renamed = ContactSummary(identifier: "CN-2", name: "Robert Ray", hasPhoto: true)
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [renamed]))
    try await seedLinks(db, store, [linkRow(linkPeerA, bob)])   // cached "Bob Ray", no photo known
    await store.send(.contactRowAppeared(peerHex: linkPeerA))
    await store.receive(.contactNameRefreshed(peerHex: linkPeerA, name: "Robert Ray"))
    // The name refresh's reload and the card load are two independent effects with no ordering
    // guarantee between them: let both finish, then read the state they produced.
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.contactCards["CN-2"] == .available(thumbnail: Data([0xFF, 0xD8])))
    #expect(store.state.contactLinks[linkPeerA]?.cachedName == "Robert Ray")
}

@MainActor @Test func linkFixRowAppearedForAnUnlinkedPeerDoesNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    store.exhaustivity = .on
    await store.send(.contactRowAppeared(peerHex: linkPeerA))
}

/// Backlog 11: a contact-side Replace with the mirror on keeps the card (it is rewritten, not cleared).
@MainActor @Test func linkFixMirrorContactSideReplaceDoesNotClearTheCard() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [jane])
    let store = mirrorStore(db, fake: fake)
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await pick(store, linkPeerB, jane)                            // Jane already linked to A → contactAlreadyLinked
    await store.send(.replaceLinkConfirmed) { $0.pendingLinkCollision = nil }
    await receiveLinks(store)
    await store.finish()
    #expect(fake.clears.isEmpty, "the same card is about to be rewritten, never cleared")
    #expect(fake.writes == [FakeContacts.Write(identifier: "CN-1", peerHex: linkPeerB)])
}

/// Backlog 11: the pick's source survives a Replace.
@MainActor @Test func linkFixScannedSourceSurvivesReplace() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeLinkStore(db, fake: FakeContacts(contacts: [jane]))
    try await seedLinks(db, store, [linkRow(linkPeerA, jane)])
    await pick(store, linkPeerB, jane, source: ContactLinkSource.scanned)
    await store.send(.replaceLinkConfirmed) { $0.pendingLinkCollision = nil }
    await receiveLinks(store)
    #expect(store.state.contactLinks[linkPeerB]?.source == ContactLinkSource.scanned)
    await store.finish()
}

@MainActor @Test func linkFinalImportLowercasesAddresses() async throws {
    let db = try AppDatabase.makeInMemory()
    let fake = FakeContacts(contacts: [bob], addresses: ["CN-2": linkPeerB.uppercased()])
    let store = mirrorStore(db, fake: fake)
    await store.send(.contactLinkSheetAppeared)
    await store.receive(.importCandidatesFound([ImportCandidate(identifier: "CN-2", name: "Bob Ray", peerHex: linkPeerB)])) {
        $0.importCandidates = [ImportCandidate(identifier: "CN-2", name: "Bob Ray", peerHex: linkPeerB)]
    }
}
