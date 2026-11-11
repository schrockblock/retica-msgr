import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import Sharing
import SQLiteData
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
@testable import ReTiCAMsgrCore

// The propagation sync state the library reports is stored as reported and described in Settings.
// The app never resets it itself. Each test names its mutation.

private typealias PState = LXMFRouter.PropagationTransferState

@MainActor
private func freshStore() throws -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: Identity())
    initial.autoInterfaceAvailable = false
    initial.connection = .connected
    let db = try AppDatabase.makeInMemory()
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
        $0.badge = .ignored
        $0.defaultDatabase = db
        $0.attachmentStore = AttachmentStore.testValue
        $0.localNotifications = .recording(into: LockIsolated([]), removed: LockIsolated([]))
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in }, close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in }, openChannel: { _ in },
                                 send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
    }
    store.exhaustivity = .off
    return store
}

private func report(_ s: PState, _ n: Int? = nil) -> AppFeature.Action {
    .node(.client(.delegate(.propagationTransferStateChanged(s, lastResult: n))))
}

@Suite("Propagation sync state")
struct PropagationSyncStateTests {
    @Test("every reported state and result is stored as reported") @MainActor
    func storesReport() async throws {
        let store = try freshStore()
        let all: [PState] = [.idle, .pathRequested, .linkEstablishing, .linkEstablished, .requestSent, .receiving,
                             .responseReceived, .complete, .noPath, .linkFailed, .transferFailed,
                             .noIdentityReceived, .noAccess, .failed]
        for (i, s) in all.enumerated() {
            await store.send(report(s, i))
            #expect(store.state.propagationSyncState == s)
            #expect(store.state.propagationSyncLastResult == i)
        }
        await store.send(report(.noAccess, nil))
        #expect(store.state.propagationSyncLastResult == nil)
    }

    @Test("the text for each state is the exact copy; in-progress states have none")
    func text() {
        #expect(PropagationSyncText.describe(.noAccess, lastResult: nil)
                == "This propagation node only serves approved users. Ask its operator to add your address.")
        #expect(PropagationSyncText.describe(.noIdentityReceived, lastResult: nil)
                == "The propagation node did not receive your identity. Try syncing again.")
        #expect(PropagationSyncText.describe(.noPath, lastResult: nil) == "Couldn't find a route to the propagation node.")
        #expect(PropagationSyncText.describe(.linkFailed, lastResult: nil) == "Couldn't connect to the propagation node.")
        #expect(PropagationSyncText.describe(.transferFailed, lastResult: nil)
                == "The download from the propagation node was interrupted.")
        #expect(PropagationSyncText.describe(.complete, lastResult: 5) == "Last sync: 5 new messages.")
        #expect(PropagationSyncText.describe(.complete, lastResult: 1) == "Last sync: 1 new message.")
        #expect(PropagationSyncText.describe(.complete, lastResult: 0) == "Last sync: 0 new messages.")
        for s in [PState.idle, .pathRequested, .linkEstablishing, .linkEstablished, .requestSent, .receiving,
                  .responseReceived, .failed] {
            #expect(PropagationSyncText.describe(s, lastResult: 3) == nil)
        }
    }

    @Test("syncTapped and foregrounding leave a reported state unchanged") @MainActor
    func appNeverResets() async throws {
        let store = try freshStore()
        await store.send(report(.noAccess, nil))
        await store.send(.syncTapped)
        #expect(store.state.propagationSyncState == .noAccess)
        await store.send(.foregrounded)
        #expect(store.state.propagationSyncState == .noAccess)
        await store.send(.backgrounded)
        #expect(store.state.propagationSyncState == .noAccess)
        await store.send(report(.complete, 2))
        #expect(store.state.propagationSyncState == .complete)
        #expect(store.state.propagationSyncLastResult == 2)
        await store.send(.syncTapped)
        #expect(store.state.propagationSyncState == .complete)
        #expect(store.state.propagationSyncLastResult == 2)
        await store.skipReceivedActions()
    }

    @Test("interfaceConnected leaves a reported state unchanged") @MainActor
    func connectNeverResets() async throws {
        let store = try freshStore()
        await store.send(report(.linkFailed, nil))
        await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(DefaultNode.entry.interfaceID, .tcp))))))
        #expect(store.state.propagationSyncState == .linkFailed)
        await store.skipReceivedActions()
    }
}
