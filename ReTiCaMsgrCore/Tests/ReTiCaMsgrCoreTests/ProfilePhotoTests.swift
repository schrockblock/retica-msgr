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
