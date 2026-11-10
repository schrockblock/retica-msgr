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
private func seedMessage(from hex: String, _ db: any DatabaseWriter, body: String = "hi",
                         at timestamp: Date = blockT0) async throws {
    try await db.write { db in
        try Message.insert {
            Message(id: UUID(), peerHex: hex, isOutgoing: false, body: body, timestamp: timestamp,
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

/// For flows whose other effects never finish (launch, a receive, a group edit), so
/// `store.finish()` can't be used: polls the directory for up to 3 s of real time.
@MainActor
private func eventually(_ store: TestStoreOf<AppFeature>, _ condition: (SenderDirectory) -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition(directory(store)) { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition(directory(store))
}

@MainActor
private func receiveGroupsChanged(_ store: TestStoreOf<AppFeature>) async {
    await store.receive { if case .senderDirectoryGroupsChanged = $0 { return true }; return false }
}

/// An incoming roster for `groupHex` exactly as it arrives off the wire (packed, then unpacked).
private func rosterWire(from sender: Identity, to me: Identity, groupHex: String, members: [String]) -> LXMessage {
    let built = LXMessage.create(
        source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash), timestamp: 1_700_000_000.5,
        title: Data("Climbing".utf8), content: Data("someone invited you to the group Climbing".utf8),
        fields: GroupWire.encodeRoster(groupId: Data(hexString: groupHex)!, name: "Climbing",
                                       members: members.map { Data(hexString: $0)! }, revision: 1))
    return LXMessage.unpack(built.packed)!
}

private let directoryGroupHex = String(repeating: "9", count: 32)

/// A group I created, with `members` (me included) in the database and the "created" line.
private func seedGroup(me meHex: String, members: [String], _ db: any DatabaseWriter) async throws {
    try await db.write { db in
        try ChatGroup.upsert(ChatGroup(groupHex: directoryGroupHex, name: "Climbing", creatorHex: meHex, revision: 1,
                                       state: GroupState.active, updatedAt: blockT0), db)
        try GroupMember.replace(directoryGroupHex, with: members, db)
        // The group's own line is mine, so no member has a conversation of their own.
        try Message.insert {
            AppFeature.groupEventRow(groupHex: directoryGroupHex, me: meHex, body: "Created",
                                     control: GroupControl.roster, now: blockT0)
        }.execute(db)
    }
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
    try await seedGroup(me: meHex, members: [meHex, danaHex], db)
    let clock = TestClock()
    var initial = AppFeature.State(identity: me, pushStorage: .temporary())
    knowPeer(dana, announcing: "Dana", in: &initial)
    let store = makeDirectoryStore(db, clock: clock) { $0 = initial }
    #expect(store.state.openGroupMembers.isEmpty)

    try await reloadConversationList(store, db)
    #expect(!store.state.conversations.contains { $0.peerHex == danaHex })
    // The roster signal is the fingerprint change (a group conversation is not a peer one).
    await store.send(.senderDirectoryGroupsChanged)
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

// MARK: - Fix round 1

@MainActor @Test func senderDirectoryDownscalesALargeReceivedPhoto() async throws {
    // The wire accepts received photos up to 512 px; the directory holds at most 256.
    let db = try AppDatabase.makeInMemory()
    let alice = Identity()
    let aliceHex = lxmfAddressHex(alice)
    try await seedMessage(from: aliceHex, db)
    let avatars = AvatarStore.testValue
    let jpeg = TestImages.jpeg(width: 512, height: 512)
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
    let dimensions = try #require(ImageEncoder.dimensions(of: try Data(contentsOf: url)))
    #expect(max(dimensions.width, dimensions.height) <= ImageEncoder.avatarPixels)
}

@MainActor @Test func senderDirectoryWritesAConversationPeerOnceItsKeyIsLearned() async throws {
    // Spec §4 trigger: "an identity learned for a conversation peer".
    let db = try AppDatabase.makeInMemory()
    let bob = Identity()
    let bobHex = lxmfAddressHex(bob)
    let bobHash = Data(hexString: bobHex)!
    try await seedMessage(from: bobHex, db)
    let clock = TestClock()
    let store = makeDirectoryStore(db, clock: clock) { state in
        state.node.client.learnedPeers[bobHash] = LXMFNode.LearnedPeer(
            displayName: "Bob", stampCost: nil, supportsCompression: false, learnedAt: blockT0)
    }
    try await reloadConversationList(store, db)
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(directory(store).entries[bobHex] == nil, "no key yet, so no entry")

    await store.send(.node(.client(.router(.learnedIdentity(destinationHash: bobHash, identity: bob)))))
    #expect(store.state.node.client.router.knownIdentities[bobHash] != nil)
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(directory(store).entries[bobHex]?.name == "Bob")
    #expect(directory(store).entries[bobHex]?.publicKey == bob.publicKey)
}

@MainActor @Test func senderDirectoryIgnoresANewMessageInAnExistingConversation() async throws {
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

    try await seedMessage(from: aliceHex, db, body: "second", at: blockT0.addingTimeInterval(60))
    let rows = try await conversationRows(db)
    #expect(rows != store.state.conversations, "the list row's last body and time changed")
    store.exhaustivity = .on
    // Only the list changes: the fingerprint is the same, so nothing is scheduled.
    await store.send(.conversationsLoaded(rows)) { $0.conversations = rows }
    await store.finish()
}

@MainActor @Test func senderDirectoryRewritesAfterAnIncomingRoster() async throws {
    // A roster invites me to a group with Dana: only the database knows her, and no peer
    // conversation changes, so the roster signal from the receive is what schedules the write.
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let meHex = lxmfAddressHex(me)
    let cy = Identity()
    let cyHex = lxmfAddressHex(cy)
    let dana = Identity()
    let danaHex = lxmfAddressHex(dana)
    let clock = TestClock()
    var initial = AppFeature.State(identity: me, pushStorage: .temporary())
    knowPeer(dana, announcing: "Dana", in: &initial)
    let store = makeDirectoryStore(db, clock: clock) { $0 = initial }

    let roster = rosterWire(from: cy, to: me, groupHex: directoryGroupHex, members: [cyHex, meHex, danaHex])
    await store.send(.node(.client(.delegate(.messageReceived(message: roster, signatureValidated: true,
                                                              method: .opportunistic)))))
    await receiveGroupsChanged(store)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    #expect(!store.state.conversations.contains { $0.kind == .peer })
    await clock.advance(by: .seconds(1))
    #expect(await eventually(store) { $0.entries[danaHex]?.name == "Dana" })
}

@MainActor @Test func senderDirectoryRewritesAfterAddingAGroupMember() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let meHex = lxmfAddressHex(me)
    let carol = Identity()
    let carolHex = lxmfAddressHex(carol)
    let dana = Identity()
    let danaHex = lxmfAddressHex(dana)
    try await seedGroup(me: meHex, members: [meHex, carolHex], db)
    let clock = TestClock()
    var initial = AppFeature.State(identity: me, pushStorage: .temporary())
    knowPeer(dana, announcing: "Dana", in: &initial)
    initial.openPeerHex = directoryGroupHex
    initial.openConversationKind = .group
    initial.openGroup = ChatGroup(groupHex: directoryGroupHex, name: "Climbing", creatorHex: meHex, revision: 1,
                                  state: GroupState.active, updatedAt: blockT0)
    initial.openGroupMembers = [meHex, carolHex].map { GroupMember(groupHex: directoryGroupHex, memberHex: $0) }
    let store = makeDirectoryStore(db, clock: clock) { $0 = initial }

    await store.send(.addGroupMembers([danaHex]))
    await receiveGroupsChanged(store)
    await clock.advance(by: .seconds(1))
    #expect(await eventually(store) { $0.entries[danaHex]?.name == "Dana" })
}

@MainActor @Test func senderDirectoryRewritesAfterCreatingAGroup() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let dana = Identity()
    let danaHex = lxmfAddressHex(dana)
    let clock = TestClock()
    var initial = AppFeature.State(identity: me, pushStorage: .temporary())
    knowPeer(dana, announcing: "Dana", in: &initial)
    let store = makeDirectoryStore(db, clock: clock) { $0 = initial }

    await store.send(.createGroup(name: "Climbing", members: [danaHex]))
    await receiveGroupsChanged(store)
    await clock.advance(by: .seconds(1))
    #expect(await eventually(store) { $0.entries[danaHex]?.name == "Dana" })
}

@MainActor @Test func senderDirectoryRewritesAtLaunchForGroupOnlyMembers() async throws {
    // Launch is a roster signal: a user whose only contacts are group members still gets a directory.
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let meHex = lxmfAddressHex(me)
    let dana = Identity()
    let danaHex = lxmfAddressHex(dana)
    try await seedGroup(me: meHex, members: [meHex, danaHex], db)
    let clock = TestClock()
    var initial = AppFeature.State(identity: me, pushStorage: .temporary())
    knowPeer(dana, announcing: "Dana", in: &initial)
    let store = makeDirectoryStore(db, clock: clock) { $0 = initial }

    await store.send(.onLaunch)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await clock.advance(by: .seconds(1))
    #expect(await eventually(store) { $0.entries[danaHex]?.name == "Dana" })
}
