import Testing
import Foundation
import ComposableArchitecture
import Sharing
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCaMsgrCore

@MainActor
@Test func onLaunchConnectsThenRegistersOnInterfaceUp() async {
    let db = try! AppDatabase.makeInMemory()
    let identity = Identity()
    let store = TestStore(initialState: AppFeature.State(identity: identity)) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { }
        )
    }
    store.exhaustivity = .off
    await store.send(.onLaunch)
    await store.receive { if case .node(.endpoint(.connect)) = $0 { return true }; return false }
    #expect(store.state.connection == .connecting)
    await store.send(.node(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"))))))
    #expect(store.state.connection == .connected)
    await store.receive { if case .node(.registerDelivery) = $0 { return true }; return false }
}

@MainActor
@Test func sendPersistsOutgoingAndDispatchesNodeSend() async {
    let db = try! AppDatabase.makeInMemory()
    let identity = Identity()
    let peerHex = "aa" + String(repeating: "bb", count: 15)
    var initial = AppFeature.State(identity: identity)
    initial.$peerAddressHex.withLock { $0 = peerHex }
    initial.draft = "hello"
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { }
        )
    }
    store.exhaustivity = .off
    await store.send(.sendTapped)
    await store.receive { action in
        if case let .node(.send(dest, _, content, method)) = action {
            #expect(dest == Data(hexString: peerHex))
            #expect(content == Data("hello".utf8))
            #expect(method == .opportunistic)
            return true
        }
        return false
    }
    let rows = try! await db.read { try Message.where { $0.peerHex.eq(peerHex) }.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.isOutgoing == true)
    #expect(rows.first?.body == "hello")
}

@MainActor
@Test func deliveryFailedUpdatesMessageStatusAndReloadsMessages() async {
    let db = try! AppDatabase.makeInMemory()
    let identity = Identity()
    let peerHex = "aa" + String(repeating: "bb", count: 15)
    var initial = AppFeature.State(identity: identity)
    initial.$peerAddressHex.withLock { $0 = peerHex }
    initial.draft = "hello"
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { }
        )
    }
    store.exhaustivity = .off

    // Send a message so an outgoing row exists in the DB.
    await store.send(.sendTapped)
    await store.receive { action in
        if case .node(.send(_, _, _, _)) = action { return true }
        return false
    }

    // Read the persisted messageHash back from the DB.
    let rows = try! await db.read { try Message.where { $0.peerHex.eq(peerHex) }.fetchAll($0) }
    let hashHex = rows.first!.messageHash
    let hashData = Data(hexString: hashHex)!

    // Fire deliveryFailed and wait for the reload to reach the store.
    await store.send(.node(.delegate(.deliveryFailed(messageHash: hashData))))
    await store.receive { action in
        if case .messagesLoaded(_) = action { return true }
        return false
    }

    // The in-memory messages array must reflect the failed status.
    let failed = store.state.messages.first(where: { $0.messageHash == hashHex })
    #expect(failed?.status == MessageStatus.failed)
}

@MainActor
@Test func receivedMessagePersistsIncomingRow() async {
    let db = try! AppDatabase.makeInMemory()
    let sender = Identity()
    let me = Identity()
    let msg = LXMessage.create(
        source: sender,
        destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1700000000.5,
        title: Data(),
        content: Data("incoming".utf8)
    )
    let store = TestStore(initialState: AppFeature.State(identity: me)) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { }
        )
    }
    store.exhaustivity = .off
    await store.send(.node(.delegate(.messageReceived(message: msg, signatureValidated: true))))
    let rows = try! await db.read { try Message.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.isOutgoing == false)
    #expect(rows.first?.body == "incoming")
    #expect(rows.first?.validated == true)
}
