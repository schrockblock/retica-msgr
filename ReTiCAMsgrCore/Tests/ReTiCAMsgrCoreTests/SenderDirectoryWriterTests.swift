import Testing
import Foundation
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
import ReTiCAPushCore
@testable import ReTiCAMsgrCore

// The app-group sender directory writer (spec 2026-11-05 §4): after a debounced change to the
// inputs, the whole directory is rewritten through `SenderDirectoryWriter`. Each test reads the
// directory back from the store's temporary `PushStorage`.

/// `makeBlockStore` with the writer enabled, a fixed contact thumbnail, an `AvatarStore` the test
/// can write into, and a `TestClock` the test advances.
@MainActor
private func makeDirectoryStore(_ db: any DatabaseWriter, clock: TestClock<Duration>,
                                writer: SenderDirectoryWriter = .liveValue,
                                avatarStore: AvatarStore = .testValue,
                                thumbnails: [String: Data] = [:],
                                configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: Identity(), pushStorage: .temporary())
    configure?(&initial)
    var contacts = FakeContacts().client
    contacts.thumbnail = { id in thumbnails[id] }
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.badge = .ignored
        $0.defaultDatabase = db
        $0.attachmentStore = AttachmentStore.testValue
        $0.date = .constant(blockT0)
        $0.transportDate = .constant(blockT0)
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in }, close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in }, openChannel: { _ in },
                                 send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
        $0.senderDirectoryWriter = writer
        $0.avatarStore = avatarStore
        $0.contactsClient = contacts
    }
    store.exhaustivity = .off
    return store
}

/// A peer the router knows (so it has a public key) and whose announce named it `name`.
private func knowPeer(_ identity: Identity, announcing name: String?, in state: inout AppFeature.State) {
    let hash = Data(hexString: lxmfAddressHex(identity))!
    state.node.client.router.knownIdentities[hash] = identity
    if let name {
        state.node.client.learnedPeers[hash] = LXMFNode.LearnedPeer(
            displayName: name, stampCost: nil, supportsCompression: false, learnedAt: blockT0)
    }
}

/// One incoming message from `hex`, so the peer has a conversation.
private func seedMessage(from hex: String, _ db: any DatabaseWriter) async throws {
    try await db.write { db in
        try Message.insert {
            Message(id: UUID(), peerHex: hex, isOutgoing: false, body: "hi", timestamp: blockT0,
                    status: MessageStatus.received, validated: true, messageHash: "")
        }.execute(db)
    }
}

/// The reload the app sends after a message write: every message, grouped into the list.
@MainActor
private func reloadConversationList(_ store: TestStoreOf<AppFeature>, _ db: any DatabaseWriter) async throws {
    let rows = try await conversationRows(db)
    await store.send(.conversationsLoaded(rows))
}

private func conversationRows(_ db: any DatabaseWriter) async throws -> [Conversation] {
    let (messages, groups) = try await db.read { db in
        (try Message.fetchAll(db), try ChatGroup.all.fetchAll(db))
    }
    return Conversation.list(from: messages, groups: Dictionary(uniqueKeysWithValues: groups.map { ($0.groupHex, $0) }))
}

@MainActor
private func directory(_ store: TestStoreOf<AppFeature>) -> SenderDirectory {
    store.state.push.storage.senderDirectory.load()
}

@MainActor @Test func senderDirectoryWritesNamedPeersAfterTheDebounce() async throws {
    let db = try AppDatabase.makeInMemory()
    let alice = Identity()
    let aliceHex = lxmfAddressHex(alice)
    try await seedMessage(from: aliceHex, db)
    let clock = TestClock()
    let store = makeDirectoryStore(db, clock: clock) { knowPeer(alice, announcing: "Alice", in: &$0) }

    try await reloadConversationList(store, db)
    await clock.advance(by: .milliseconds(999))
    #expect(directory(store).entries.isEmpty)

    await clock.advance(by: .milliseconds(1))
    await store.finish()
    let entry = directory(store).entries[aliceHex]
    #expect(entry?.name == "Alice")
    // The key comes from `senderPublicKey` (the router's known identities).
    #expect(entry?.publicKey == alice.publicKey)
}

@MainActor @Test func senderDirectoryIncludesGroupMembersFromTheDatabase() async throws {
    let db = try AppDatabase.makeInMemory()
    let dana = Identity()
    let danaHex = lxmfAddressHex(dana)
    let me = Identity()
    let meHex = lxmfAddressHex(me)
    let groupHex = String(repeating: "9", count: 32)
    try await db.write { db in
        try ChatGroup.upsert(ChatGroup(groupHex: groupHex, name: "Climbing", creatorHex: meHex, revision: 1,
                                       state: GroupState.active, updatedAt: blockT0), db)
        try GroupMember.replace(groupHex, with: [meHex, danaHex], db)
        // The group's own line is mine, so Dana has no conversation of her own.
        try Message.insert {
            AppFeature.groupEventRow(groupHex: groupHex, me: meHex, body: "Created", control: GroupControl.roster,
                                     now: blockT0)
        }.execute(db)
    }
    let clock = TestClock()
    var initial = AppFeature.State(identity: me, pushStorage: .temporary())
    knowPeer(dana, announcing: "Dana", in: &initial)
    let store = makeDirectoryStore(db, clock: clock) { $0 = initial }
    #expect(store.state.openGroupMembers.isEmpty)

    try await reloadConversationList(store, db)
    #expect(!store.state.conversations.contains { $0.peerHex == danaHex })
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(directory(store).entries[danaHex]?.name == "Dana")
    #expect(directory(store).entries[danaHex]?.publicKey == dana.publicKey)
    #expect(directory(store).entries[meHex] == nil)
}

@MainActor @Test func senderDirectoryDropsAPeerOnceBlocked() async throws {
    let db = try AppDatabase.makeInMemory()
    let alice = Identity()
    let aliceHex = lxmfAddressHex(alice)
    try await seedMessage(from: aliceHex, db)
    let clock = TestClock()
    let store = makeDirectoryStore(db, clock: clock) { knowPeer(alice, announcing: "Alice", in: &$0) }
    try await reloadConversationList(store, db)
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(directory(store).entries[aliceHex]?.name == "Alice")

    await store.send(.blockPeer(aliceHex))
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(store.state.isBlocked(aliceHex))
    #expect(directory(store).entries[aliceHex] == nil)
}

@MainActor @Test func senderDirectoryCopiesAReceivedPhoto() async throws {
    let db = try AppDatabase.makeInMemory()
    let alice = Identity()
    let aliceHex = lxmfAddressHex(alice)
    try await seedMessage(from: aliceHex, db)
    let avatars = AvatarStore.testValue
    let jpeg = TestImages.jpeg(width: 256, height: 256)
    let path = try avatars.storePeer(jpeg, peerHex: aliceHex, version: "v1")
    let clock = TestClock()
    let store = makeDirectoryStore(db, clock: clock, avatarStore: avatars) { state in
        knowPeer(alice, announcing: "Alice", in: &state)
        state.peerProfiles[aliceHex] = PeerProfile(peerHex: aliceHex, photoVersion: "v1", photoPath: path,
                                                   photoSetAt: blockT0, updatedAt: blockT0)
    }

    try await reloadConversationList(store, db)
    await clock.advance(by: .seconds(1))
    await store.finish()
    let sender = store.state.push.storage.senderDirectory
    let entry = try #require(directory(store).entries[aliceHex])
    let url = try #require(sender.imageURL(for: entry))
    #expect(try Data(contentsOf: url) == jpeg)
}

@MainActor @Test func senderDirectoryUsesTheLinkedContactThumbnail() async throws {
    let db = try AppDatabase.makeInMemory()
    let alice = Identity()
    let aliceHex = lxmfAddressHex(alice)
    let thumbnail = TestImages.jpeg(width: 600, height: 400)
    let clock = TestClock()
    let store = makeDirectoryStore(db, clock: clock, thumbnails: ["c1": thumbnail]) { state in
        knowPeer(alice, announcing: nil, in: &state)
    }
    #expect(store.state.contactCards.isEmpty)

    // A contact-linked peer is a candidate with no conversation; the link load is the change.
    let link = ContactLinking.newLink(peerHex: aliceHex, identifier: "c1", name: "Alice Liddell",
                                      source: ContactLinkSource.manual, now: blockT0)
    await store.send(.contactLinksLoaded([link]))
    await clock.advance(by: .seconds(1))
    await store.finish()
    let sender = store.state.push.storage.senderDirectory
    let entry = try #require(directory(store).entries[aliceHex])
    #expect(entry.name == "Alice Liddell")
    let url = try #require(sender.imageURL(for: entry))
    let dimensions = ImageEncoder.dimensions(of: try Data(contentsOf: url))
    #expect(dimensions?.width == 256)
    #expect(dimensions?.height == 256)
}

@MainActor @Test func senderDirectoryDisabledWriterDoesNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let alice = Identity()
    let aliceHex = lxmfAddressHex(alice)
    try await seedMessage(from: aliceHex, db)
    let clock = TestClock()
    let store = makeDirectoryStore(db, clock: clock, writer: .testValue) { knowPeer(alice, announcing: "Alice", in: &$0) }
    store.exhaustivity = .on

    let rows = try await conversationRows(db)
    // Only the list changes: no fingerprint is stored and no write is scheduled.
    await store.send(.conversationsLoaded(rows)) { $0.conversations = rows }
    await store.finish()
    #expect(directory(store).entries.isEmpty)
}
