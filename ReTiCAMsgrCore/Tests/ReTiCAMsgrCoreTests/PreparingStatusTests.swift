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

// "Preparing…" while a send waits for the peer's stamp cost or computes its stamp. The set is in
// memory, cleared by `.handedOver` and by every terminal outcome. Each test names its mutation.

private let hash = Data(repeating: 0xAB, count: 32)
private let hashHex = String(repeating: "ab", count: 32)
private let otherHash = Data(repeating: 0xCD, count: 32)
private let dest = Data(repeating: 0xEE, count: 16)

@MainActor
private func freshStore() throws -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(identity: Identity())
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

private func preparing(_ hash: Data, _ phase: LXMFNode.PreparingPhase) -> AppFeature.Action {
    .node(.client(.delegate(.deliveryPreparing(messageHash: hash, phase: phase))))
}

private func sendingRow(hashHex: String = hashHex, status: String = MessageStatus.sending) -> Message {
    Message(id: UUID(), peerHex: dest.hexString, isOutgoing: true, body: "hi", timestamp: Date(timeIntervalSince1970: 0),
            status: status, validated: false, messageHash: hashHex)
}

private func copy(_ hex: String?, _ status: String) -> GroupDelivery {
    GroupDelivery(messageId: UUID(), memberHex: UUID().uuidString, messageHash: hex, status: status,
                  storedAt: nil, deliveredAt: nil, failedAt: nil)
}

/// Mutation: ignore `.waitingForPeer`, or ignore `.stamping`; or never clear on `.handedOver`.
@MainActor @Test func waitingAndStampingMarkPreparingAndHandOverClears() async throws {
    let store = try freshStore()
    await store.send(preparing(hash, .waitingForPeer))
    #expect(store.state.preparingHashes == [hashHex])
    #expect(store.state.sendStage(for: sendingRow())?.label == "Preparing…")
    await store.send(preparing(hash, .stamping))
    #expect(store.state.preparingHashes == [hashHex])
    await store.send(preparing(hash, .handedOver))
    #expect(store.state.preparingHashes.isEmpty)
    #expect(store.state.sendStage(for: sendingRow())?.label == "Sending…")
}

/// A re-stamp after a late announce reports `.stamping` again after `.handedOver`.
/// Mutation: make `.handedOver` permanent for the hash.
@MainActor @Test func restampAfterHandOverIsPreparingAgain() async throws {
    let store = try freshStore()
    await store.send(preparing(hash, .waitingForPeer))
    await store.send(preparing(hash, .handedOver))
    await store.send(preparing(hash, .stamping))
    #expect(store.state.sendStage(for: sendingRow())?.label == "Preparing…")
    await store.send(preparing(hash, .handedOver))
    #expect(store.state.sendStage(for: sendingRow())?.label == "Sending…")
}

/// Every terminal outcome clears its hash and only its hash.
/// Mutation: drop the removal from any one of the terminal branches.
@MainActor @Test func everyTerminalClearsOnlyItsHash() async throws {
    let terminals: [AppFeature.Action] = [
        .node(.client(.delegate(.deliveryFailed(messageHash: hash)))),
        .node(.client(.delegate(.deliveryRejected(messageHash: hash)))),
        .node(.client(.delegate(.deliveryCancelled(messageHash: hash)))),
        .node(.client(.delegate(.propagationAccepted(messageHash: hash)))),
        .node(.client(.delegate(.deliveryConfirmed(messageHash: hash)))),
    ]
    for terminal in terminals {
        let store = try freshStore()
        await store.send(preparing(hash, .stamping))
        await store.send(preparing(otherHash, .waitingForPeer))
        await store.send(terminal)
        #expect(store.state.preparingHashes == [otherHash.hexString], "\(terminal)")
        await store.finish()
    }
}

/// Mutation: the label ignores the row's status (a stored row would read Preparing…).
@Test func onlyASendingRowReadsPreparing() {
    #expect(MessageStatusLabel.text(for: MessageStatus.sending, preparing: true) == "Preparing…")
    #expect(MessageStatusLabel.text(for: MessageStatus.sending, preparing: false) == "Sending…")
    #expect(MessageStatusLabel.text(for: MessageStatus.delivered, preparing: true) == "Delivered")
    var state = AppFeature.State(identity: Identity())
    state.connection = .connected
    state.preparingHashes = [hashHex]
    #expect(state.sendStage(for: sendingRow(status: MessageStatus.propagated)) == nil)
    #expect(state.sendStage(for: sendingRow(hashHex: String(repeating: "01", count: 32)))?.label == "Sending…")
}

/// A relaunch is a fresh state: nothing is preparing, so the row reads Sending….
/// Mutation: persist/seed the set (here: default it to non-empty).
@Test func freshStateShowsSending() {
    var state = AppFeature.State(identity: Identity())
    state.connection = .connected
    #expect(state.preparingHashes.isEmpty)
    #expect(state.sendStage(for: sendingRow())?.label == "Sending…")
}

/// A group post reads Preparing… only when every unfinished copy is preparing.
/// Mutation: use `contains` (any) instead of all; or count finished copies as unfinished.
@Test func groupPostPreparingNeedsEveryUnfinishedCopy() {
    let a = String(repeating: "a1", count: 32), b = String(repeating: "b2", count: 32)
    let sending = [copy(a, MessageStatus.sending), copy(b, MessageStatus.sending)]
    #expect(GroupRoster.statusLabel(sending, preparing: [a, b]) == "Preparing…")
    #expect(GroupRoster.statusLabel(sending, preparing: [a]) == "Sending…")
    #expect(GroupRoster.statusLabel(sending) == "Sending…")
    // A copy that already failed does not hold the post back from Preparing….
    let mixed = [copy(a, MessageStatus.sending), copy(b, MessageStatus.failed)]
    #expect(GroupRoster.statusLabel(mixed, preparing: [a]) == "Preparing…")
    // A copy still waiting has no hash yet, so it is not preparing.
    let waiting = [copy(a, MessageStatus.sending), copy(nil, GroupDeliveryStatus.waiting)]
    #expect(GroupRoster.statusLabel(waiting, preparing: [a]) == "Sending…")
    // Once the post is no longer "sending", the preparing set changes nothing.
    let done = [copy(a, MessageStatus.delivered), copy(b, MessageStatus.delivered)]
    #expect(GroupRoster.statusLabel(done, preparing: [a, b]) == "Delivered")
}
