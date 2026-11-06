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
import struct ReTiCAMsgrCore.Attachment

// MARK: - Helpers

@MainActor
private func makeStore(_ db: any DatabaseWriter, identity: Identity,
                       avatars: AvatarStore,
                       clock: (any Clock<Duration>)? = nil,
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: identity)
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.badge = .ignored
        $0.defaultDatabase = db
        $0.attachmentStore = AttachmentStore.testValue
        $0.avatarStore = avatars
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = clock ?? ImmediateClock()
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { }
        )
        $0.tcpListener = TCPListener(
            listen: { _ in AsyncStream { _ in } },
            send: { _, _ in },
            close: { _ in },
            stop: { }
        )
        $0.bleDriver = BLEDriver(
            start: { _ in AsyncStream { _ in } },
            readIdentity: { _ in },
            openChannel: { _ in },
            send: { _, _ in },
            closeChannel: { _ in },
            stop: { }
        )
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
    }
    store.exhaustivity = .off
    return store
}

// MARK: - Tests

@MainActor @Test func pickingAPhotoStoresItAndSetsTheVersion() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let store = makeStore(db, identity: Identity(), avatars: avatars)
    await store.send(.profilePhotoPicked(TestImages.jpeg(width: 400, height: 300)))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let stored = try #require(avatars.mine())
    #expect(store.state.myPhotoVersion == ProfileWire.version(of: stored).hexString)
    #expect(store.state.myPhotoVersion.count == 16)
    let size = try #require(ImageEncoder.dimensions(of: stored))
    #expect(size.width == 256 && size.height == 256)
    #expect(store.state.profilePhotoError == nil)
}

@MainActor @Test func pickingAnUnusablePhotoSetsTheError() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let store = makeStore(db, identity: Identity(), avatars: avatars)
    await store.send(.profilePhotoPicked(Data("x".utf8)))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.profilePhotoError != nil)
    #expect(store.state.myPhotoVersion == "")
    #expect(avatars.mine() == nil)
}

@MainActor @Test func removingThePhotoClearsVersionAndFile() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let store = makeStore(db, identity: Identity(), avatars: avatars)
    await store.send(.profilePhotoPicked(TestImages.jpeg(width: 300, height: 300)))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.myPhotoVersion != "")
    #expect(avatars.mine() != nil)
    await store.send(.removeProfilePhotoTapped)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.myPhotoVersion == "")
    #expect(avatars.mine() == nil)
}

@MainActor @Test func removingDuringAPickLeavesNoPhoto() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let clock = TestClock()
    let store = makeStore(db, identity: Identity(), avatars: avatars, clock: clock)
    await store.send(.profilePhotoPicked(TestImages.jpeg(width: 300, height: 300)))
    await store.send(.removeProfilePhotoTapped)
    // Let a surviving pick run to completion: it would store the file and set the version.
    await Task.yield()
    await clock.advance(by: .milliseconds(10))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.myPhotoVersion == "")
    #expect(avatars.mine() == nil)
    #expect(store.state.profilePhotoError == nil)
}

@MainActor @Test func launchLoadsPeerProfiles() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let hex = String(repeating: "c", count: 32)
    // The file is on disk: launch keeps a row whose photo file exists (final review 5b).
    let path = try avatars.storePeer(Data([1, 2, 3]), peerHex: hex, version: "0123456789abcdef")
    let row = PeerProfile(peerHex: hex, photoVersion: "0123456789abcdef", photoPath: path,
                          iconName: "star", iconFg: "ffffff", iconBg: "000000",
                          updatedAt: Date(timeIntervalSince1970: 1700000000))
    try await db.write { try PeerProfile.insert { row }.execute($0) }
    let store = makeStore(db, identity: Identity(), avatars: avatars, clock: TestClock())
    await store.send(.onLaunch)
    await store.receive { if case .peerProfilesLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.peerProfiles[hex] == row)
}

@MainActor @Test func photoMayRideOnlyWithANonMeshtasticInterface() {
    var state = AppFeature.State(identity: Identity())
    #expect(state.profilePhotoMayRide == false)
    state.connectedInterfaces = [InterfaceID("meshtastic:X")]
    #expect(state.profilePhotoMayRide == false)
    state.connectedInterfaces = [InterfaceID("meshtastic:X"), InterfaceID("tcp:h:1")]
    #expect(state.profilePhotoMayRide == true)
}

// MARK: - Sending (Task 6)

private let sendPeer = String(repeating: "a", count: 32)
private let sendMemberC = String(repeating: "c", count: 32)
private let sendMemberD = String(repeating: "d", count: 32)
private let sendGroupHex = String(repeating: "1a", count: 16)
private let tcpInterface = InterfaceID("tcp:h:1")

/// The send tests run on a `TestClock` that only `setMyPhoto` advances: under `ImmediateClock` the
/// router's retry timers for these unreachable test peers exhaust at once and report
/// `deliveryFailed`, which would settle the pending photo before a test could read it.
/// A store with `sendPeer` open and a TCP interface up (so the image may ride), unless `configure`
/// says otherwise.
@MainActor
private func peerStore(_ db: any DatabaseWriter, avatars: AvatarStore, clock: TestClock<Duration>,
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    makeStore(db, identity: Identity(), avatars: avatars, clock: clock) { s in
        s.openPeerHex = sendPeer
        s.chatVisible = true
        s.connectedInterfaces = [tcpInterface]
        configure?(&s)
    }
}

/// Picks a photo through the real action and returns my new version. The pick sleeps 1 ms on the
/// clock first; the clock is nudged until the saved version lands (the sleep may register after
/// the first advance).
@MainActor
private func setMyPhoto(_ store: TestStoreOf<AppFeature>, _ clock: TestClock<Duration>) async -> String {
    await store.send(.profilePhotoPicked(TestImages.jpeg(width: 300, height: 300)))
    for _ in 0..<400 where store.state.myPhotoVersion.isEmpty {
        await clock.advance(by: .milliseconds(1))
        try? await Task.sleep(for: .milliseconds(5))
    }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.myPhotoVersion.count == 16)
    return store.state.myPhotoVersion
}

/// Types `text`, taps Send and returns the message handed to the node.
@MainActor
private func sendText(_ store: TestStoreOf<AppFeature>, _ text: String) async -> LXMessage? {
    var sent: LXMessage? = nil
    await store.send(.binding(.set(\.draft, text)))
    await store.send(.sendTapped)
    await store.receive { a in
        if case let .node(.client(.sendMessage(m, _))) = a { sent = m; return true }
        return false
    }
    return sent
}

private func deliveryRow(_ db: any DatabaseWriter, _ peerHex: String) async throws -> ProfilePhotoDelivery? {
    try await db.read { try ProfilePhotoDelivery.fetch(peerHex, $0) }
}

/// Polls the database until `condition` holds (an outcome's write lands in its own effect).
private func waitForDelivery(_ db: any DatabaseWriter, _ peerHex: String,
                             _ condition: @Sendable (ProfilePhotoDelivery?) -> Bool) async throws {
    for _ in 0..<400 {
        if condition(try await deliveryRow(db, peerHex)) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("delivery row for \(peerHex) never reached the expected state")
}

private func hasProfileField(_ m: LXMessage?) -> Bool {
    m?.fields.contains { $0.key == ProfileWire.fieldProfilePhoto } ?? false
}

@MainActor @Test func firstSendCarriesThePhoto() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let clock = TestClock()
    let store = peerStore(db, avatars: avatars, clock: clock)
    let version = await setMyPhoto(store, clock)
    let jpeg = try #require(avatars.mine())
    let sent = try #require(await sendText(store, "hi"))
    #expect(ProfileWire.decode(sent.fields) == .photo(version: try #require(Data(hexString: version)), jpeg: jpeg))
    let row = try #require(try await deliveryRow(db, sendPeer))
    #expect(row.pendingVersion == version)
    #expect(row.pendingHash == sent.hash.hexString)
    #expect(row.deliveredVersion == nil)
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func secondSendBeforeConfirmCarriesTagOnly() async throws {
    let db = try AppDatabase.makeInMemory()
    let clock = TestClock()
    let store = peerStore(db, avatars: AvatarStore.testValue, clock: clock)
    let version = await setMyPhoto(store, clock)
    let first = try #require(await sendText(store, "one"))
    let second = try #require(await sendText(store, "two"))
    let v = try #require(Data(hexString: version))
    guard case .photo = ProfileWire.decode(first.fields) else { Issue.record("first send had no photo"); return }
    #expect(ProfileWire.decode(second.fields) == .tag(version: v))
    // The pending pair still waits on the first message.
    #expect(try await deliveryRow(db, sendPeer)?.pendingHash == first.hash.hexString)
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func confirmedSendMakesNextSendTagOnly() async throws {
    let db = try AppDatabase.makeInMemory()
    let clock = TestClock()
    let store = peerStore(db, avatars: AvatarStore.testValue, clock: clock)
    let version = await setMyPhoto(store, clock)
    let first = try #require(await sendText(store, "one"))
    await store.send(.node(.client(.delegate(.deliveryConfirmed(messageHash: first.hash)))))
    try await waitForDelivery(db, sendPeer) { $0?.deliveredVersion == version }
    let row = try await deliveryRow(db, sendPeer)
    #expect(row?.deliveredVersion == version)
    #expect(row?.pendingVersion == nil)
    let next = try #require(await sendText(store, "two"))
    #expect(ProfileWire.decode(next.fields) == .tag(version: try #require(Data(hexString: version))))
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func propagatedCountsAsConfirmed() async throws {
    let db = try AppDatabase.makeInMemory()
    let clock = TestClock()
    let store = peerStore(db, avatars: AvatarStore.testValue, clock: clock)
    let version = await setMyPhoto(store, clock)
    let first = try #require(await sendText(store, "one"))
    await store.send(.node(.client(.delegate(.propagationAccepted(messageHash: first.hash)))))
    try await waitForDelivery(db, sendPeer) { $0?.deliveredVersion == version }
    let row = try await deliveryRow(db, sendPeer)
    #expect(row?.deliveredVersion == version)
    #expect(row?.pendingHash == nil)
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func sendAfterPhotoFailureAttachesAgain() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let clock = TestClock()
    let store = peerStore(db, avatars: avatars, clock: clock)
    let version = await setMyPhoto(store, clock)
    let first = try #require(await sendText(store, "one"))
    await store.send(.node(.client(.delegate(.deliveryFailed(messageHash: first.hash)))))
    try await waitForDelivery(db, sendPeer) { $0?.pendingHash == nil }
    #expect(try await deliveryRow(db, sendPeer)?.deliveredVersion == nil)
    let next = try #require(await sendText(store, "two"))
    let jpeg = try #require(avatars.mine())
    #expect(ProfileWire.decode(next.fields) == .photo(version: try #require(Data(hexString: version)), jpeg: jpeg))
    #expect(try await deliveryRow(db, sendPeer)?.pendingHash == next.hash.hexString)
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func sendOverMeshtasticOnlyOmitsImage() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let clock = TestClock()
    let store = peerStore(db, avatars: avatars, clock: clock) { s in
        s.connectedInterfaces = [InterfaceID("meshtastic:X")]
    }
    let version = await setMyPhoto(store, clock)
    let v = try #require(Data(hexString: version))
    let slow = try #require(await sendText(store, "over the radio"))
    #expect(ProfileWire.decode(slow.fields) == .tag(version: v))
    #expect(try await deliveryRow(db, sendPeer) == nil)
    // A TCP interface comes up: the next send carries the image.
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(tcpInterface, .tcp))))))
    #expect(store.state.profilePhotoMayRide == true)
    let fast = try #require(await sendText(store, "over tcp"))
    #expect(ProfileWire.decode(fast.fields) == .photo(version: v, jpeg: try #require(avatars.mine())))
    #expect(try await deliveryRow(db, sendPeer)?.pendingVersion == version)
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func noPhotoSendsNoProfileField() async throws {
    let db = try AppDatabase.makeInMemory()
    let clock = TestClock()
    let store = peerStore(db, avatars: AvatarStore.testValue, clock: clock)
    #expect(store.state.myPhotoVersion == "")
    let sent = try #require(await sendText(store, "plain"))
    #expect(!hasProfileField(sent))
    #expect(try await deliveryRow(db, sendPeer) == nil)
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func groupPostCopiesCarryThePhotoPerMember() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let group = ChatGroup(groupHex: sendGroupHex, name: "Mutual Aid", creatorHex: myHex, revision: 1,
                          state: GroupState.active, updatedAt: Date(timeIntervalSince1970: 1700000000))
    let roster = [sendMemberC, sendMemberD, myHex].sorted()
    try await db.write { db in
        try ChatGroup.upsert(group, db)
        try GroupMember.replace(sendGroupHex, with: roster, db)
    }
    let clock = TestClock()
    let store = makeStore(db, identity: me, avatars: avatars, clock: clock) { s in
        s.openPeerHex = sendGroupHex
        s.openConversationKind = .group
        s.chatVisible = true
        s.openGroup = group
        s.openGroupMembers = roster.map { GroupMember(groupHex: sendGroupHex, memberHex: $0) }
        s.reachablePeers = [sendMemberC, sendMemberD]
        s.connectedInterfaces = [tcpInterface]
    }
    let version = await setMyPhoto(store, clock)
    let v = try #require(Data(hexString: version))
    let jpeg = try #require(avatars.mine())
    // Keyed by hash: the receive predicate can be evaluated more than once per action.
    var byHash: [Data: LXMessage] = [:]
    await store.send(.binding(.set(\.draft, "to the group")))
    await store.send(.sendTapped)
    for _ in 0..<2 {
        await store.receive { a in
            if case let .node(.client(.sendMessage(m, _))) = a { byHash[m.hash] = m; return true }
            return false
        }
    }
    await store.skipReceivedActions(strict: false)
    let copies = Array(byHash.values)
    #expect(copies.count == 2)
    for copy in copies {
        #expect(ProfileWire.decode(copy.fields) == .photo(version: v, jpeg: jpeg))
        let member = copy.destinationHash.hexString
        let row = try await deliveryRow(db, member)
        #expect(row?.pendingVersion == version)
        #expect(row?.pendingHash == copy.hash.hexString)
    }
    #expect(Set(copies.map { $0.destinationHash.hexString }) == [sendMemberC, sendMemberD])
}

@MainActor @Test func reactionsCarryNoProfileField() async throws {
    let db = try AppDatabase.makeInMemory()
    let clock = TestClock()
    let store = peerStore(db, avatars: AvatarStore.testValue, clock: clock)
    _ = await setMyPhoto(store, clock)
    var sent: LXMessage? = nil
    await store.send(.reactionSelected(messageHash: String(repeating: "5e", count: 32), emoji: "👍"))
    await store.receive { a in
        if case let .node(.client(.sendMessage(m, _))) = a { sent = m; return true }
        return false
    }
    #expect(sent != nil)
    #expect(!hasProfileField(sent))
    #expect(try await deliveryRow(db, sendPeer) == nil)
    await store.skipReceivedActions(strict: false)
}

// MARK: - Receiving (Task 7)

/// Copied from AppFeatureTests: a message from `sender` to `me`, packed and unpacked like the wire.
private func wireMessage(from sender: Identity, to me: Identity, at ts: Double, title: String = "",
                         content: String = "hi", fields: [MsgPackValue.IntPair] = []) -> LXMessage {
    let built = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                 timestamp: ts, title: Data(title.utf8), content: Data(content.utf8),
                                 fields: fields)
    return LXMessage.unpack(built.packed)!
}

@MainActor
private func receive(_ store: TestStoreOf<AppFeature>, _ m: LXMessage, validated: Bool = true) async {
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: validated,
                                                              method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// The file names in the avatar directory (none when it was never created).
private func avatarFiles(_ avatars: AvatarStore) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: avatars.baseDirectory.path)) ?? []).sorted()
}

private func storedBodies(_ db: any DatabaseWriter) async throws -> [String] {
    try await db.read { try Message.all.fetchAll($0) }.map(\.body).sorted()
}

private let jpegOne = TestImages.jpeg(width: 256, height: 256)
private let jpegTwo = TestImages.jpeg(width: 200, height: 200)

@MainActor @Test func receivingAPhotoStoresItForThePeer() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let me = Identity()
    let store = makeStore(db, identity: me, avatars: avatars)
    let version = ProfileWire.version(of: jpegOne)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "hi",
                        fields: ProfileWire.encodePhoto(version: version, jpeg: jpegOne))
    let hex = m.sourceHash.hexString
    await receive(store, m)
    let profile = try #require(store.state.peerProfiles[hex])
    #expect(profile.photoVersion == version.hexString)
    let path = try #require(profile.photoPath)
    #expect(try Data(contentsOf: avatars.url(forRelativePath: path)) == jpegOne)
    #expect(try await db.read { try PeerProfile.fetch(hex, $0) } == profile)
    #expect(try await storedBodies(db) == ["hi"])
}

@MainActor @Test func receivingANewerPhotoDeletesTheOld() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me, avatars: avatars)
    let v1 = ProfileWire.version(of: jpegOne)
    let v2 = ProfileWire.version(of: jpegTwo)
    let first = wireMessage(from: sender, to: me, at: 1699999900, content: "one",
                            fields: ProfileWire.encodePhoto(version: v1, jpeg: jpegOne))
    let hex = first.sourceHash.hexString
    await receive(store, first)
    #expect(avatarFiles(avatars) == ["\(hex)-\(v1.hexString).jpg"])
    await receive(store, wireMessage(from: sender, to: me, at: 1699999901, content: "two",
                                     fields: ProfileWire.encodePhoto(version: v2, jpeg: jpegTwo)))
    #expect(store.state.peerProfiles[hex]?.photoVersion == v2.hexString)
    #expect(avatarFiles(avatars) == ["\(hex)-\(v2.hexString).jpg"])
}

@MainActor @Test func receivingRemovalClearsThePhoto() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me, avatars: avatars)
    let first = wireMessage(from: sender, to: me, at: 1699999900, content: "one",
                            fields: ProfileWire.encodePhoto(version: ProfileWire.version(of: jpegOne), jpeg: jpegOne))
    let hex = first.sourceHash.hexString
    await receive(store, first)
    #expect(store.state.peerProfiles[hex]?.photoVersion != nil)
    await receive(store, wireMessage(from: sender, to: me, at: 1699999901, content: "bye",
                                     fields: ProfileWire.encodeRemoved()))
    let profile = try #require(store.state.peerProfiles[hex])
    #expect(profile.photoVersion == nil)
    #expect(profile.photoPath == nil)
    #expect(try await db.read { try PeerProfile.fetch(hex, $0) }?.photoVersion == nil)
    #expect(avatarFiles(avatars).isEmpty)
    #expect(try await storedBodies(db) == ["bye", "one"])
}

/// Review Focus 3: an unsigned sender cannot set a photo, and its message is still kept.
@MainActor @Test func unsignedPhotoIsIgnored() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let me = Identity()
    let store = makeStore(db, identity: me, avatars: avatars)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "hi",
                        fields: ProfileWire.encodePhoto(version: ProfileWire.version(of: jpegOne), jpeg: jpegOne))
    let hex = m.sourceHash.hexString
    await receive(store, m, validated: false)
    #expect(store.state.peerProfiles[hex] == nil)
    #expect(try await db.read { try PeerProfile.fetch(hex, $0) } == nil)
    #expect(avatarFiles(avatars).isEmpty)
    #expect(try await storedBodies(db) == ["hi"])
}

/// Review Focus 3: an image whose hash does not match its version is dropped; the text and the
/// avatar already held stay.
@MainActor @Test func forgedPhotoKeepsTextAndOldAvatar() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me, avatars: avatars)
    let v1 = ProfileWire.version(of: jpegOne)
    let v2 = ProfileWire.version(of: jpegTwo)
    let first = wireMessage(from: sender, to: me, at: 1699999900, content: "one",
                            fields: ProfileWire.encodePhoto(version: v1, jpeg: jpegOne))
    let hex = first.sourceHash.hexString
    await receive(store, first)
    let forged: [MsgPackValue.IntPair] = [.init(ProfileWire.fieldProfilePhoto, .array([.bin(v2), .bin(jpegOne)]))]
    await receive(store, wireMessage(from: sender, to: me, at: 1699999901, content: "two", fields: forged))
    let profile = try #require(store.state.peerProfiles[hex])
    #expect(profile.photoVersion == v1.hexString)
    #expect(avatarFiles(avatars) == ["\(hex)-\(v1.hexString).jpg"])
    #expect(try Data(contentsOf: avatars.url(forRelativePath: try #require(profile.photoPath))) == jpegOne)
    #expect(try await storedBodies(db) == ["one", "two"])
}

/// Review Focus 5: Sideband's icon-only message sets the icon and makes no bubble.
@MainActor @Test func iconOnlyMessageMakesNoBubble() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me, avatars: AvatarStore.testValue)
    let icon: [MsgPackValue.IntPair] = [.init(IconAppearanceWire.fieldIconAppearance,
                                              .array([.string("star"), .bin(Data([0xff, 0x80, 0x00])),
                                                      .bin(Data([0x00, 0x00, 0x20]))]))]
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "", fields: icon)
    let hex = m.sourceHash.hexString
    await receive(store, m)
    let profile = try #require(store.state.peerProfiles[hex])
    #expect(profile.iconName == "star")
    #expect(profile.iconFg == "ff8000")
    #expect(profile.iconBg == "000020")
    #expect(try await db.read { try PeerProfile.fetch(hex, $0) } == profile)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(store.state.conversations.isEmpty)
}

/// Review Focus 5: an empty body with an attachment is still a message.
@MainActor @Test func emptyMessageWithAttachmentIsStillStored() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me, avatars: AvatarStore.testValue)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "",
                        fields: AttachmentWire.encodeFile(name: "notes.pdf", data: Data("%PDF-1.4 x".utf8)))
    await receive(store, m)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.count == 1)
    #expect(store.state.conversations.count == 1)
}

@MainActor @Test func emptyTelemetryOnlyMessageMakesNoBubble() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me, avatars: AvatarStore.testValue)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "",
                        fields: [.init(0x02, .bin(Data([0x01, 0x02, 0x03])))])
    await receive(store, m)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.map(\.hashHex) == [m.hash.hexString])
    #expect(store.state.conversations.isEmpty)
}

// MARK: - Final review fixes

private func storedMessages(_ db: any DatabaseWriter) async throws -> [Message] {
    try await db.read { try Message.all.fetchAll($0) }
}

/// Final review 3: a Sideband/Columba voice message (0x07, empty content) is kept with a
/// placeholder instead of being dropped.
@MainActor @Test func emptyVoiceMessageIsStoredWithAPlaceholder() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me, avatars: AvatarStore.testValue)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "",
                        fields: [.init(0x07, .array([.uint(1), .bin(Data([0x01, 0x02]))]))])
    await receive(store, m)
    #expect(try await storedMessages(db).map(\.body) == ["Voice message (not supported)"])
    #expect(store.state.conversations.count == 1)
}

/// Final review 3: an image field AttachmentWire cannot decode keeps the message.
@MainActor @Test func emptyUndecodableImageIsStoredAsUnsupported() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me, avatars: AvatarStore.testValue)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "",
                        fields: [.init(AttachmentWire.fieldImage, .bin(Data([0x01, 0x02])))])
    await receive(store, m)
    #expect(try await storedMessages(db).map(\.body) == ["Unsupported message"])
}

/// Final review 3: an empty reply is still a message, shown as the reply (no placeholder).
@MainActor @Test func emptyReplyIsStoredWithoutAPlaceholder() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me, avatars: AvatarStore.testValue)
    let target = Data(repeating: 0x5e, count: 32)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "",
                        fields: ReplyWire.encode(replyTo: target, quote: "earlier"))
    await receive(store, m)
    let rows = try await storedMessages(db)
    #expect(rows.count == 1)
    #expect(rows.first?.body == "")
    #expect(rows.first?.replyToHash == target.hexString)
}

/// Final review 3: a timer-change message (empty content, only the app's 0xFD) is its line.
@MainActor @Test func emptyTimerChangeIsStored() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me, avatars: AvatarStore.testValue)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "",
                        fields: ExpiryWire.encodeChange(seconds: 3600))
    await receive(store, m)
    let rows = try await storedMessages(db)
    #expect(rows.count == 1)
    #expect(rows.first?.isTimerChange == true)
}

/// Final review 3: a non-empty title counts as content, as before.
@MainActor @Test func titleOnlyMessageIsStored() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me, avatars: AvatarStore.testValue)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, title: "Subject", content: "")
    await receive(store, m)
    let rows = try await storedMessages(db)
    #expect(rows.count == 1)
    #expect(rows.first?.body == "")
}

/// Final review 2: a propagated older photo arriving after a newer direct one does not roll back.
@MainActor @Test func olderPhotoAfterNewerKeepsTheNewer() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me, avatars: avatars)
    let v1 = ProfileWire.version(of: jpegOne)
    let v2 = ProfileWire.version(of: jpegTwo)
    let newer = wireMessage(from: sender, to: me, at: 1699999901, content: "two",
                            fields: ProfileWire.encodePhoto(version: v2, jpeg: jpegTwo))
    let hex = newer.sourceHash.hexString
    await receive(store, newer)
    await receive(store, wireMessage(from: sender, to: me, at: 1699999900, content: "one",
                                     fields: ProfileWire.encodePhoto(version: v1, jpeg: jpegOne)))
    #expect(store.state.peerProfiles[hex]?.photoVersion == v2.hexString)
    #expect(try await db.read { try PeerProfile.fetch(hex, $0) }?.photoVersion == v2.hexString)
    #expect(avatarFiles(avatars) == ["\(hex)-\(v2.hexString).jpg"])
    #expect(try await storedBodies(db) == ["one", "two"])
}

/// Final review 2: an older removal arriving after a newer photo keeps the photo.
@MainActor @Test func olderRemovalAfterNewerPhotoKeepsThePhoto() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me, avatars: avatars)
    let v1 = ProfileWire.version(of: jpegOne)
    let photo = wireMessage(from: sender, to: me, at: 1699999901, content: "photo",
                            fields: ProfileWire.encodePhoto(version: v1, jpeg: jpegOne))
    let hex = photo.sourceHash.hexString
    await receive(store, photo)
    await receive(store, wireMessage(from: sender, to: me, at: 1699999900, content: "old removal",
                                     fields: ProfileWire.encodeRemoved()))
    #expect(store.state.peerProfiles[hex]?.photoVersion == v1.hexString)
    #expect(try await db.read { try PeerProfile.fetch(hex, $0) }?.photoVersion == v1.hexString)
    #expect(avatarFiles(avatars) == ["\(hex)-\(v1.hexString).jpg"])
}

/// Final review 2: the stored time is capped at arrival, so a future-dated photo cannot lock the
/// avatar: a later photo still applies.
@MainActor @Test func futureDatedPhotoIsCappedAtArrival() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me, avatars: avatars)
    let v1 = ProfileWire.version(of: jpegOne)
    let v2 = ProfileWire.version(of: jpegTwo)
    let future = wireMessage(from: sender, to: me, at: 1800000000, content: "from the future",
                             fields: ProfileWire.encodePhoto(version: v1, jpeg: jpegOne))
    let hex = future.sourceHash.hexString
    await receive(store, future)
    #expect(store.state.peerProfiles[hex]?.photoVersion == v1.hexString)
    store.dependencies.date = .constant(Date(timeIntervalSince1970: 1700000100))
    await receive(store, wireMessage(from: sender, to: me, at: 1700000050, content: "later",
                                     fields: ProfileWire.encodePhoto(version: v2, jpeg: jpegTwo)))
    #expect(store.state.peerProfiles[hex]?.photoVersion == v2.hexString)
}

/// Final review 1: the router's pending deliveries do not survive a kill, so launch clears every
/// pending pair (the delivered version stays) and the next message carries the photo again.
@MainActor @Test func launchClearsPendingPhotoDeliveries() async throws {
    let db = try AppDatabase.makeInMemory()
    let peer = String(repeating: "e", count: 32)
    try await db.write { db in
        try ProfilePhotoDelivery.insert {
            ProfilePhotoDelivery(peerHex: peer, deliveredVersion: "1111111111111111",
                                 pendingVersion: "2222222222222222", pendingHash: "hash")
        }.execute(db)
    }
    let store = makeStore(db, identity: Identity(), avatars: AvatarStore.testValue, clock: TestClock())
    await store.send(.onLaunch)
    await store.receive { if case .peerProfilesLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    let row = try await deliveryRow(db, peer)
    #expect(row?.deliveredVersion == "1111111111111111")
    #expect(row?.pendingVersion == nil)
    #expect(row?.pendingHash == nil)
}

/// Final review 5a: after a restore `me.jpg` (excluded from backup) is gone while the version
/// survives; launch resets the version.
@MainActor @Test func launchResetsMyVersionWhenThePhotoIsMissing() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity(), avatars: AvatarStore.testValue, clock: TestClock()) { s in
        s.$myPhotoVersion.withLock { $0 = "0123456789abcdef" }
    }
    await store.send(.onLaunch)
    await store.receive { if case .peerProfilesLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.myPhotoVersion == "")
}

/// Final review 5a: a file that does not hash to the version resets it too; a matching one stays.
@MainActor @Test func launchKeepsMyVersionOnlyWhenTheFileMatches() async throws {
    let mismatched = AvatarStore.testValue
    try mismatched.storeMine(jpegOne)
    let badStore = makeStore(try AppDatabase.makeInMemory(), identity: Identity(), avatars: mismatched,
                             clock: TestClock()) { s in
        s.$myPhotoVersion.withLock { $0 = ProfileWire.version(of: jpegTwo).hexString }
    }
    await badStore.send(.onLaunch)
    await badStore.receive { if case .peerProfilesLoaded = $0 { return true }; return false }
    await badStore.skipReceivedActions(strict: false)
    #expect(badStore.state.myPhotoVersion == "")

    let matching = AvatarStore.testValue
    try matching.storeMine(jpegOne)
    let version = ProfileWire.version(of: jpegOne).hexString
    let goodStore = makeStore(try AppDatabase.makeInMemory(), identity: Identity(), avatars: matching,
                              clock: TestClock()) { s in
        s.$myPhotoVersion.withLock { $0 = version }
    }
    await goodStore.send(.onLaunch)
    await goodStore.receive { if case .peerProfilesLoaded = $0 { return true }; return false }
    await goodStore.skipReceivedActions(strict: false)
    #expect(goodStore.state.myPhotoVersion == version)
}

/// Final review 5b: a peer row whose photo file is missing loses its photo at launch (so the
/// avatar falls through to contact, icon, initials); the icon stays.
@MainActor @Test func launchClearsPeerPhotosWhoseFileIsMissing() async throws {
    let db = try AppDatabase.makeInMemory()
    let avatars = AvatarStore.testValue
    let hex = String(repeating: "f", count: 32)
    let row = PeerProfile(peerHex: hex, photoVersion: "0123456789abcdef", photoPath: "\(hex)-0123456789abcdef.jpg",
                          iconName: "star", iconFg: "ffffff", iconBg: "000000",
                          updatedAt: Date(timeIntervalSince1970: 1700000000))
    try await db.write { try PeerProfile.insert { row }.execute($0) }
    let store = makeStore(db, identity: Identity(), avatars: avatars, clock: TestClock())
    await store.send(.onLaunch)
    await store.receive { if case .peerProfilesLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    let loaded = try #require(store.state.peerProfiles[hex])
    #expect(loaded.photoVersion == nil)
    #expect(loaded.photoPath == nil)
    #expect(loaded.iconName == "star")
    #expect(try await db.read { try PeerProfile.fetch(hex, $0) } == loaded)
}
