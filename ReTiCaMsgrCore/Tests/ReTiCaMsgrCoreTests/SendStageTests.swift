import Testing
import Foundation
import ReTiCA
@testable import ReTiCANode
@testable import ReTiCaMsgrCore

// The live send stage a one-to-one bubble shows (spec 2026-10-22). Each test names the mutation of
// the code under test that it must catch.

private let h = Data(repeating: 0xAB, count: 32)
private let dest = Data(repeating: 0xCD, count: 16)
private let hashHex = String(repeating: "ab", count: 32)
private let destHexUpper = String(repeating: "CD", count: 16)

private func freshClient() -> LXMFNode.State { AppFeature.State(identity: Identity()).node.client }

private func stage(_ client: LXMFNode.State, _ connection: AppFeature.Connection = .connected) -> SendStage {
    SendStage.current(messageHash: h, recipient: dest, client: client, connection: connection)
}

private func pending(_ phase: LXMFRouter.Phase, attempts: Int) -> LXMFRouter.PendingDelivery {
    LXMFRouter.PendingDelivery(resend: .direct(destinationHash: dest, data: Data(), asResource: true),
                               attempts: attempts, phase: phase)
}

private func row(peerHex: String = destHexUpper, isOutgoing: Bool = true, status: String = MessageStatus.sending,
                 isTimerChange: Bool = false, groupHex: String? = nil) -> Message {
    Message(id: UUID(), peerHex: peerHex, isOutgoing: isOutgoing, body: "hi", timestamp: Date(timeIntervalSince1970: 0),
            status: status, validated: false, messageHash: hashHex, isTimerChange: isTimerChange, groupHex: groupHex)
}

/// Mutation: skip the transferring rule.
@Test func transferringDeliveryShowsPercent() {
    var c = freshClient()
    c.router.pendingDeliveries[.delivery(h)] = pending(.transferring, attempts: 1)
    c.transferProgress[.delivery(h)] = 0.4
    #expect(stage(c) == .sending(fraction: 0.4))
    #expect(stage(c).label == "Sending 40%")
}

/// Mutation: skip the establishing rule.
@Test func establishingLinkShowsConnecting() {
    var c = freshClient()
    c.router.directLinks[dest] = .establishing
    #expect(stage(c) == .connecting)
    #expect(stage(c).label == "Connecting…")
}

/// Mutation: skip the awaiting-path rule.
@Test func awaitingPathShowsLookingForThem() {
    var c = freshClient()
    c.router.directLinks[dest] = .awaitingPath
    #expect(stage(c) == .lookingForThem)
    #expect(stage(c).label == "Looking for them…")
}

/// Mutation: skip the pickup rule.
@Test func pickupCopyShowsLeavingForPickup() {
    var c = freshClient()
    c.router.pendingPropagatedCopies = [h]
    #expect(stage(c) == .leavingForPickup(fraction: nil))
    #expect(stage(c).label == "Leaving it for pickup…")
}

/// Mutation: check the link rules before the pickup rule (final review I1: the router hands the
/// pickup copy over mid-establishment, while the recipient's link is still parked or opening).
@Test func pickupBeatsALinkStillOpening() {
    var c = freshClient()
    c.router.pendingPropagatedCopies = [h]
    c.router.directLinks[dest] = .awaitingPath
    #expect(stage(c) == .leavingForPickup(fraction: nil))
    c.router.directLinks[dest] = .establishing
    #expect(stage(c) == .leavingForPickup(fraction: nil))
}

/// Mutation: check the retry rule before the pickup rule.
@Test func pickupBeatsDeliveryRetry() {
    var c = freshClient()
    c.router.pendingDeliveries[.delivery(h)] = pending(.retrying, attempts: 3)
    c.router.pendingDeliveries[.propagated(h)] = pending(.transferring, attempts: 1)
    c.transferProgress[.propagated(h)] = 0.5
    #expect(stage(c) == .leavingForPickup(fraction: 0.5))
    #expect(stage(c).label == "Leaving it for pickup 50%")
}

/// Mutation: count a retry from the first attempt (`attempts >= 1`).
@Test func secondAttemptShowsTryingAgain() {
    var c = freshClient()
    c.router.pendingDeliveries[.delivery(h)] = pending(.retrying, attempts: 2)
    #expect(stage(c) == .tryingAgain(attempt: 2, of: 5))
    #expect(stage(c).label == "Trying again (2 of 5)")
}

/// Mutation: count a retry from the first attempt (`attempts >= 1`).
@Test func firstAttemptIsNotARetry() {
    var c = freshClient()
    c.router.pendingDeliveries[.delivery(h)] = pending(.retrying, attempts: 1)
    #expect(stage(c) == .inProgress)
}

/// Mutation: skip the waiting rule.
@Test func disconnectedShowsWaiting() {
    #expect(stage(freshClient(), .disconnected) == .waitingForConnection)
    #expect(stage(freshClient(), .disconnected).label == "Waiting for a connection…")
}

/// Mutation: drop the `held` clause.
@Test func heldShowsWaiting() {
    var c = freshClient()
    c.router.held = true
    #expect(stage(c) == .waitingForConnection)
}

/// Mutation: skip the stamp-search rule.
@Test func stampSearchShowsPreparing() {
    var c = freshClient()
    c.inFlightDeliveryStamps = [h]
    #expect(stage(c) == .preparing)
    #expect(stage(c).label == "Preparing…")
}

/// Mutation: return `.preparing` as the fallback.
@Test func unknownHashFallsBackToSending() {
    #expect(stage(freshClient()) == .inProgress)
    #expect(stage(freshClient()).label == "Sending…")
    #expect(SendStage.inProgress.topic == .sending)
}

/// Mutation: remove the clamp.
@Test func progressIsClampedAndOptional() {
    var c = freshClient()
    c.router.pendingDeliveries[.delivery(h)] = pending(.transferring, attempts: 1)
    #expect(stage(c).label == "Sending…")
    c.transferProgress[.delivery(h)] = 1.7
    #expect(stage(c).label == "Sending 100%")
}

/// Mutation: accept only a lowercase peer hex (the parser is case-insensitive; this pins that).
@Test func uppercaseRecipientStillMatches() {
    var state = AppFeature.State(identity: Identity())
    state.connection = .connected
    state.node.client.router.directLinks[dest] = .establishing
    #expect(state.sendStage(for: row()) == .connecting)
}

/// Mutation: treat a hex that doesn't parse as empty Data.
@Test func malformedHexGivesNoStage() {
    let state = AppFeature.State(identity: Identity())
    #expect(state.sendStage(for: row(peerHex: "xyz")) == nil)
}

/// Mutation: drop the `groupHex == nil` check.
@Test func onlySendingOneToOneRowsGetAStage() {
    var state = AppFeature.State(identity: Identity())
    state.connection = .connected
    #expect(state.sendStage(for: row()) == .inProgress)
    #expect(state.sendStage(for: row(groupHex: String(repeating: "1a", count: 16))) == nil)
    #expect(state.sendStage(for: row(isOutgoing: false)) == nil)
    #expect(state.sendStage(for: row(status: MessageStatus.delivered)) == nil)
    #expect(state.sendStage(for: row(isTimerChange: true)) == nil)
}
