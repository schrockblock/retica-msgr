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
import struct ReTiCaMsgrCore.Attachment

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
    let hex = String(repeating: "c", count: 32)
    let row = PeerProfile(peerHex: hex, photoVersion: "0123456789abcdef", photoPath: "\(hex)-0123456789abcdef.jpg",
                          iconName: "star", iconFg: "ffffff", iconBg: "000000",
                          updatedAt: Date(timeIntervalSince1970: 1700000000))
    try await db.write { try PeerProfile.insert { row }.execute($0) }
    let store = makeStore(db, identity: Identity(), avatars: AvatarStore.testValue, clock: TestClock())
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
