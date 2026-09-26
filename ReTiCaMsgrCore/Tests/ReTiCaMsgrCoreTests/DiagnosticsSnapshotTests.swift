import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCaMsgrCore

// MARK: - Fixtures

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

/// A state whose SOCKET layer is healthy: app connected, interface online, interface registered.
/// Fixtures here are built COHERENTLY on purpose — seeding `learned` without `interfaces`
/// produces a state the runtime cannot reach, and that incoherence is itself one of the
/// conditions under test (see the paths cross-check in a later task).
@MainActor
private func healthyState() -> AppFeature.State {
    var state = AppFeature.State(identity: Identity())
    state.connection = .connected
    guard state.node.client.endpoint.tcpClient != nil else {
        fatalError("fixture assumes a TCP-client endpoint slot")
    }
    state.node.client.endpoint.tcpClient?.interface.status = .online
    // `transport` is now SHARED at the container level (Task 1b), no longer owned by the tcpClient
    // driver. Register the interface directly on the shared router.
    let interfaceID = state.node.client.endpoint.tcpClient!.interfaceID
    state.node.client.endpoint.transport.interfaces[interfaceID] = .tcp
    state.node.client.deliveryDestinationHash = Data(repeating: 0xAA, count: 16)
    return state
}

/// Mutate the shared `TransportEndpoint` of a state in place.
///
/// Since Task 1b the endpoint is a STRUCT product: the router (`transport`) and link plane
/// (`linkPlane`, whose `links` are surfaced as `endpoint.links`) are SHARED at the container level,
/// while the TCP-client `interface`/`interfaceID` live on the optional `tcpClient` slot. This helper
/// hands the whole endpoint to the closure so a fixture can set `transport`/`linkPlane` fields and
/// the tcpClient interface in one place.
@MainActor
private func withTCP(_ state: inout AppFeature.State,
                     _ body: (inout TransportEndpoint.State) -> Void) {
    guard state.node.client.endpoint.tcpClient != nil else {
        fatalError("fixture assumes a TCP-client endpoint slot")
    }
    body(&state.node.client.endpoint)
}

private func layer(_ snapshot: DiagnosticsSnapshot, _ title: String) -> DiagnosticsSnapshot.Layer {
    guard let found = snapshot.layers.first(where: { $0.title == title }) else {
        fatalError("no layer titled \(title)")
    }
    return found
}

// MARK: - Socket

@MainActor @Test func socketIsOkWhenAppAndInterfaceAgreeAndInterfaceIsRegistered() {
    let snapshot = DiagnosticsSnapshot(from: healthyState(), at: fixedDate)
    let socket = layer(snapshot, "Socket")
    #expect(socket.health == .ok)
    #expect(socket.reason == nil)
}

// The two rows that disagreed for the whole duration of the stale-callback reconnect bug.
// Reported as a DISAGREEMENT, not masked by the milder "connecting" rule beneath it.
@MainActor @Test func socketIsAProblemWhenAppSaysConnectedButInterfaceIsNot() {
    var state = healthyState()
    withTCP(&state) { $0.tcpClient?.interface.status = .connecting }
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.health == .problem)
    #expect(socket.reason == "app reports connected, interface reports connecting")
}

@MainActor @Test func socketIsAProblemWhenInterfaceIsOnlineButTransportHasNoInterfaces() {
    var state = healthyState()
    withTCP(&state) { $0.transport.interfaces = [:] }
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.health == .problem)
    #expect(socket.reason == "socket is up but Transport has no registered interface")
}

@MainActor @Test func socketWarnsWhileBothAgreeConnecting() {
    var state = healthyState()
    state.connection = .connecting
    withTCP(&state) { $0.tcpClient?.interface.status = .connecting }
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.health == .warn)
    #expect(socket.reason == "connecting")
}

// MARK: - Identity

@MainActor @Test func identityIsAProblemWhenNoDeliveryDestinationIsRegistered() {
    var state = healthyState()
    state.node.client.deliveryDestinationHash = nil
    let identity = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Identity")
    #expect(identity.health == .problem)
    #expect(identity.reason == "no delivery destination registered — nothing can reach us")
}

@MainActor @Test func identityIsOkWhenDeliveryDestinationIsRegistered() {
    let identity = layer(DiagnosticsSnapshot(from: healthyState(), at: fixedDate), "Identity")
    #expect(identity.health == .ok)
    #expect(identity.reason == nil)
}

// MARK: - Socket ordering

// The disagreement rule must run BEFORE the milder "connecting" warn so that when app=.connecting
// and interface=.online, the conflict is surfaced as a disagreement (.problem), not silenced as a
// routine "connecting" warn. This test fails if the two rules are swapped.
@MainActor @Test func socketDisagreementBeatsConnectingWarnWhenAppIsConnectingButInterfaceIsOnline() {
    var state = healthyState()
    state.connection = .connecting
    // interface stays .online (as set by healthyState)
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.health == .problem)
    #expect(socket.reason == "app reports connecting, interface reports online")
}

// MARK: - Paths (F8 cross-check)

private let peerHash = Data(repeating: 0xBB, count: 16)

@MainActor @Test func pathsWarnWhenALearnedPathNamesAnInterfaceThatIsGone() {
    var state = healthyState()
    withTCP(&state) { tcp in
        // A path heard on an interface that no longer exists. `learned` is non-destructive,
        // so this is the ORDINARY state after a socket drop — not a contrived one.
        tcp.transport.learned[peerHash] = LearnedDestination(
            identity: Identity(), appData: nil, ratchet: nil,
            interfaceID: InterfaceID("gone"), hops: 1, nextHop: nil, announceEmitted: 0)
    }
    let paths = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Paths")
    #expect(paths.health == .warn)
    #expect(paths.reason == "1 path names an interface that is gone")
    #expect(paths.rows.contains { $0.value.contains("reachable=NO") })
}

@MainActor @Test func pathsAreOkWhenEveryPathNamesALiveInterface() {
    var state = healthyState()
    withTCP(&state) { tcp in
        tcp.transport.learned[peerHash] = LearnedDestination(
            identity: Identity(), appData: nil, ratchet: nil,
            interfaceID: tcp.tcpClient!.interfaceID, hops: 0, nextHop: nil, announceEmitted: 0)
    }
    let paths = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Paths")
    #expect(paths.health == .ok)
    #expect(paths.reason == nil)
    #expect(paths.rows.contains { $0.value.contains("reachable=yes") })
}

// I4. `interfaces` empties on EVERY socket drop, so the F8 test above would mark every learned
// path unreachable and blame a missing interface — when the interface is not gone, the socket
// is down, and Socket already says so. Reachability is not "no" here, it is unknowable.
//
// This is the ordinary disconnect, so the fixture is a coherent one: app disconnected,
// interface disconnected, interfaces deregistered, learned NOT purged (it never is).
@MainActor @Test func pathsDoNotBlameTheInterfaceWhenTheSocketIsDownAndNoInterfacesRemain() {
    var state = healthyState()
    state.connection = .disconnected
    withTCP(&state) { tcp in
        tcp.tcpClient?.interface.status = .disconnected
        tcp.transport.learned[peerHash] = LearnedDestination(
            identity: Identity(), appData: nil, ratchet: nil,
            interfaceID: tcp.tcpClient!.interfaceID, hops: 0, nextHop: nil, announceEmitted: 0)
        tcp.transport.interfaces = [:]
    }
    let snapshot = DiagnosticsSnapshot(from: state, at: fixedDate)
    // Precondition: the path really is present and really does name an absent interface, so
    // the old rule WOULD have fired here.
    #expect(state.node.client.endpoint.learned.count == 1)
    #expect(state.node.client.endpoint.interfaces.isEmpty)

    let paths = layer(snapshot, "Paths")
    #expect(paths.reason == "no interfaces registered — reachability is unknowable; see Socket")
    #expect(paths.rows.contains { $0.value.contains("reachable=?") })
    #expect(!paths.rows.contains { $0.value.contains("reachable=NO") })
    // Socket is the layer that owns this fault, and it is not silent about it.
    #expect(layer(snapshot, "Socket").health != .ok)
}

// The mirror of the above: with no paths the rows are empty, but the warn is equally true —
// reachability is unknowable whether or not anything was ever learned. Both branches should
// report the same health so a reader cannot misread "Paths ok" as "routes fine".
@MainActor @Test func pathsWarnWhenTheSocketIsDownEvenIfNothingWasEverLearned() {
    var state = healthyState()
    state.connection = .disconnected
    withTCP(&state) { tcp in
        tcp.tcpClient?.interface.status = .disconnected
        tcp.transport.interfaces = [:]
    }
    let paths = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Paths")
    #expect(paths.health == .warn)
    #expect(paths.reason == "no interfaces registered — reachability is unknowable; see Socket")
}

// MARK: - Peers (F20 cross-check)

@MainActor @Test func peersWarnWhenAKnownPeerHasNoPath() {
    var state = healthyState()
    // Exactly what a cold launch produces: learnedPeers is rehydrated from disk, the path
    // table is not, so the peer is listed but cannot be messaged.
    state.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: "Sideband", stampCost: 8, supportsCompression: true, learnedAt: fixedDate)
    let peers = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Peers")
    #expect(peers.health == .warn)
    #expect(peers.reason == "1 peer has no path — known but not reachable")
    #expect(peers.rows.contains { $0.value.contains("path=NO") })
}

@MainActor @Test func peersAreOkWhenEveryPeerHasAPath() {
    var state = healthyState()
    state.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: "Sideband", stampCost: 8, supportsCompression: true, learnedAt: fixedDate)
    withTCP(&state) { tcp in
        tcp.transport.learned[peerHash] = LearnedDestination(
            identity: Identity(), appData: nil, ratchet: nil,
            interfaceID: tcp.tcpClient!.interfaceID, hops: 0, nextHop: nil, announceEmitted: 0)
    }
    let peers = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Peers")
    #expect(peers.health == .ok)
    #expect(peers.reason == nil)
    #expect(peers.rows.contains { $0.value.contains("path=yes") })
}

@MainActor @Test func peersWarnWithPluralGrammarWhenMultiplePeersHaveNoPath() {
    var state = healthyState()
    let peerHash2 = Data(repeating: 0xCC, count: 16)
    state.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: "Alice", stampCost: 8, supportsCompression: true, learnedAt: fixedDate)
    state.node.client.learnedPeers[peerHash2] = LXMFNode.LearnedPeer(
        displayName: "Bob", stampCost: 8, supportsCompression: true, learnedAt: fixedDate)
    let peers = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Peers")
    #expect(peers.health == .warn)
    #expect(peers.reason == "2 peers have no path — known but not reachable")
}

// M8. `learnedAt` is what separates "announced 3s ago" from "restored from disk 40 days ago",
// which is exactly the discrimination the F20 cross-check above is about — a peer with no path
// heard seconds ago is a race, the same peer heard six weeks ago is a ghost. The two ages here
// are BOTH derived from the injected date; a `Date()` in the builder would render neither.
@MainActor @Test func peersRowsCarryTheAgeSincePeerWasHeardDerivedFromTheInjectedDate() {
    var state = healthyState()
    let freshHash = Data(repeating: 0xB1, count: 16)
    let staleHash = Data(repeating: 0xB2, count: 16)
    state.node.client.learnedPeers[freshHash] = LXMFNode.LearnedPeer(
        displayName: "Fresh", stampCost: 8, supportsCompression: true,
        learnedAt: fixedDate.addingTimeInterval(-3))
    state.node.client.learnedPeers[staleHash] = LXMFNode.LearnedPeer(
        displayName: "Ghost", stampCost: 8, supportsCompression: true,
        learnedAt: fixedDate.addingTimeInterval(-40 * 86_400))
    let peers = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Peers")
    #expect(peers.rows.contains { $0.label == "Fresh" && $0.value.contains("heard=3s") })
    #expect(peers.rows.contains { $0.label == "Ghost" && $0.value.contains("heard=40d") })
}

// MARK: - Delivery
//
// The rule under test (see `deliveryLayer`): a pending send needs a link only if its OWN method
// needs one; `.direct`/`.propagated` are correlated against their OWN destination; and a
// destination parked in `.awaitingPath`/`.establishing` warns on its own. One test per clause.

private let messageHash = Data(repeating: 0x01, count: 32)
private let otherPeerHash = Data(repeating: 0xDD, count: 16)

// CLAUSE 1 — the false warn on every normal send. `pendingDeliveries` is armed by EVERY send
// including opportunistic, this app sends ONLY opportunistic (`LXMFNode.sendMessage` passes
// `method: .opportunistic`), and there is no opportunistic delivery receipt — so the entry sits
// there for all five retry attempts. The old rule made Delivery yellow for ~40-50s after every
// message on a perfectly healthy app, which is exactly the "yellow means nothing" outcome the
// screen must avoid.
@MainActor @Test func deliveryIsOkWhenTheOnlyPendingSendIsOpportunisticAndNeedsNoLink() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[messageHash] = LXMFRouter.PendingDelivery(
        resend: .opportunistic(destinationHash: peerHash, payload: Data()), attempts: 2)
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .ok)
    #expect(delivery.reason == nil)
}

// Opportunistic sends are structurally unobservable — there is no delivery receipt, so an
// entry sits in `pendingDeliveries` for the full retry saga whether or not the message arrived.
// An informational row (NOT a warn) must appear so the reader of a pasted export understands
// that green here means "no evidence of failure", not "confirmed delivery". The health MUST
// stay `.ok`; this test pins that the row cannot escalate to a false alarm.
@MainActor @Test func deliveryAddsAnInformationalNoteWhenOpportunisticSendsArePendingAndHealthStaysOk() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[messageHash] = LXMFRouter.PendingDelivery(
        resend: .opportunistic(destinationHash: peerHash, payload: Data()), attempts: 2)
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    // Health must not change — the row is informational, not a health signal.
    #expect(delivery.health == .ok)
    // The "note" row must be present and must mention that opportunistic is unacknowledged.
    let note = delivery.rows.first { $0.label == "note" }
    #expect(note != nil)
    #expect(note?.value.contains("opportunistic") == true)
    #expect(note?.value.contains("unacknowledged") == true)
}

// CLAUSE 1, other half — a method that DOES need a link still warns without one.
@MainActor @Test func deliveryWarnsWhenADirectSendIsPendingWithNoLinkAtAll() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[messageHash] = LXMFRouter.PendingDelivery(
        resend: .direct(destinationHash: peerHash, data: Data(), asResource: false), attempts: 2)
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason == "1 message pending with no active link to its destination")
}

// CLAUSE 1, third method. `.propagated` links to the PROPAGATION NODE, so it needs one too.
@MainActor @Test func deliveryWarnsWhenAPropagatedSendIsPendingWithNoLinkToThePropagationNode() {
    var state = healthyState()
    state.node.client.router.outboundPropagationNode = otherPeerHash
    state.node.client.router.pendingDeliveries[messageHash] = LXMFRouter.PendingDelivery(
        resend: .propagated(destinationHash: otherPeerHash, data: Data()), attempts: 1)
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason == "1 message pending with no active link to its destination")
}

// CLAUSE 1 plural. The same rule must use plural grammar when two direct sends are stranded.
// "its destination" with a plural subject was found and fixed here; this test pins the fix.
private let messageHash2 = Data(repeating: 0x02, count: 32)

@MainActor @Test func deliveryWarnsWithPluralGrammarWhenMultipleDirectSendsAreStranded() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[messageHash] = LXMFRouter.PendingDelivery(
        resend: .direct(destinationHash: peerHash, data: Data(), asResource: false), attempts: 1)
    state.node.client.router.pendingDeliveries[messageHash2] = LXMFRouter.PendingDelivery(
        resend: .direct(destinationHash: otherPeerHash, data: Data(), asResource: false), attempts: 1)
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason == "2 messages pending with no active link to their destination")
}

// CLAUSE 2 — correlation. A link to Alice says nothing about a message stranded to Bob. The old
// rule asked only "is ANY link active anywhere", so this state read green.
@MainActor @Test func deliveryWarnsWhenTheActiveLinkIsToADifferentDestinationThanThePendingSend() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[messageHash] = LXMFRouter.PendingDelivery(
        resend: .direct(destinationHash: peerHash, data: Data(), asResource: false), attempts: 1)
    state.node.client.router.directLinks[otherPeerHash] =
        .active(linkID: Data(repeating: 0x0C, count: 16))
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason == "1 message pending with no active link to its destination")
}

// CLAUSE 2, the satisfied case: the link is to the pending message's OWN destination.
@MainActor @Test func deliveryIsOkWhenTheActiveLinkIsToThePendingSendsOwnDestination() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[messageHash] = LXMFRouter.PendingDelivery(
        resend: .direct(destinationHash: peerHash, data: Data(), asResource: false), attempts: 1)
    state.node.client.router.directLinks[peerHash] =
        .active(linkID: Data(repeating: 0x0C, count: 16))
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .ok)
    #expect(delivery.reason == nil)
}

// CLAUSE 3 — the false GREEN on the real fault, and the reason this clause cannot be folded into
// the pending-delivery scan. A `.direct` send with no active link does NOT enter
// `pendingDeliveries`: it goes to `outboundQueue` (internal to the library, invisible here) and
// the destination parks at `.awaitingPath`. So `pendingDeliveries` is EMPTY, and a rule keyed
// off it reported green for the whole duration of a failing send to an unreachable peer.
@MainActor @Test func deliveryWarnsWhenADestinationIsParkedAwaitingPathWithNothingPending() {
    var state = healthyState()
    state.node.client.router.directLinks[peerHash] = .awaitingPath
    // Precondition: this is the state that used to read green — nothing pending at all.
    #expect(state.node.client.router.pendingDeliveries.isEmpty)
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason
            == "1 destination waiting for a link (awaiting path or establishing)")
}

@MainActor @Test func deliveryWarnsWhenADestinationIsParkedEstablishingWithNothingPending() {
    var state = healthyState()
    state.node.client.router.directLinks[peerHash] = .establishing
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason
            == "1 destination waiting for a link (awaiting path or establishing)")
}

// CLAUSE 3 plural. Two parked destinations must produce plural grammar.
@MainActor @Test func deliveryWarnsWithPluralGrammarWhenMultipleDestinationsAreParked() {
    var state = healthyState()
    state.node.client.router.directLinks[peerHash] = .awaitingPath
    state.node.client.router.directLinks[otherPeerHash] = .establishing
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason == "2 destinations waiting for a link (awaiting path or establishing)")
}

@MainActor @Test func deliveryIsOkWithNothingPending() {
    let delivery = layer(DiagnosticsSnapshot(from: healthyState(), at: fixedDate), "Delivery")
    #expect(delivery.health == .ok)
    #expect(delivery.reason == nil)
}

// Both clauses at once must both be STATED. A verdict that drops half its evidence is the
// wrong-reason failure this screen keeps hitting.
@MainActor @Test func deliveryStatesBothClausesWhenAStrandedMessageAndAParkedDestinationCoexist() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[messageHash] = LXMFRouter.PendingDelivery(
        resend: .direct(destinationHash: peerHash, data: Data(), asResource: false), attempts: 3)
    state.node.client.router.directLinks[peerHash] = .establishing
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason == "1 message pending with no active link to its destination; "
                               + "1 destination waiting for a link (awaiting path or establishing)")
}

// M6. `active (<hex>)` failed the view's hex test because of the parentheses, so the full 32-char
// link id escaped truncation on screen. `key=value` is what every other layer emits and what
// `shorten` already handles; parentheses in this snapshot mean PLACEHOLDER, not data.
@MainActor @Test func deliveryRendersAnActiveLinkAsAKeyValueTokenTheViewCanShorten() {
    var state = healthyState()
    let linkID = Data(repeating: 0x0C, count: 16)
    state.node.client.router.directLinks[peerHash] = .active(linkID: linkID)
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.rows.contains { $0.label == peerHash.hexString
                                     && $0.value == "active link=\(linkID.hexString)" })
}

// MARK: - Links

@MainActor @Test func linksLayerReportsNoLinksOnAQuietState() {
    let links = layer(DiagnosticsSnapshot(from: healthyState(), at: fixedDate), "Links")
    #expect(links.health == .ok)
    #expect(links.rows.contains { $0.label == "(none)" })
}

@MainActor @Test func snapshotHasAllLayersInOrder() {
    let snapshot = DiagnosticsSnapshot(from: healthyState(), at: fixedDate)
    #expect(snapshot.layers.map(\.title)
            == ["Socket", "Bluetooth", "Identity", "Paths", "Peers", "Links", "Delivery"])
}

// C1. `.pending`, not `.handshake`. The two statuses are ROLE-DISJOINT in `LinkSession`:
// `.handshake` is assigned in exactly one place, inside `case .acceptRequest` behind
// `guard state.role == .responder`, while `case .establish` never touches `status` — an
// initiator stays `.pending` until a proof makes it `.active`. The original
// `role == .initiator && status == .handshake` was therefore UNSATISFIABLE, and the Links layer
// reported green for every stuck outbound link, which is the one fault it was added to report.
//
// The link is built through the library's own initiator initialiser, so if that role/status
// pairing ever changes this test changes with it rather than pinning a fiction.
@MainActor @Test func linksWarnWhenAnOutboundLinkIsStillPendingEstablishment() {
    var state = healthyState()
    withTCP(&state) { tcp in
        var link = LinkSession.State(
            initiatorTo: Identity(), destinationHash: peerHash, interfaceID: tcp.tcpClient!.interfaceID)
        link.linkID = Data(repeating: 0x0C, count: 16)
        link.requestedAt = fixedDate.addingTimeInterval(-12).timeIntervalSince1970
        tcp.linkPlane.links.append(link)
    }
    // Precondition: the library really does leave a freshly-requested initiator in `.pending`.
    #expect(state.node.client.endpoint.links.first?.role == .initiator)
    #expect(state.node.client.endpoint.links.first?.status == .pending)

    let links = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Links")
    #expect(links.health == .warn)
    #expect(links.reason == "1 outbound link still establishing")
    // A pending initiator has nil `activatedAt`/`lastInbound`/`lastData`, so `requestedAt` is
    // the ONLY age it has — without it the row reads `up=- in=- data=-` and cannot tell
    // "in flight" from "about to blow the 15s deadline".
    #expect(links.rows.contains { $0.value.contains("req=12s") })
}

@MainActor @Test func linksWarnWithPluralGrammarWhenMultipleOutboundLinksAreStillEstablishing() {
    var state = healthyState()
    withTCP(&state) { tcp in
        var link1 = LinkSession.State(
            initiatorTo: Identity(), destinationHash: peerHash, interfaceID: tcp.tcpClient!.interfaceID)
        link1.linkID = Data(repeating: 0x0C, count: 16)
        link1.requestedAt = fixedDate.addingTimeInterval(-5).timeIntervalSince1970
        var link2 = LinkSession.State(
            initiatorTo: Identity(), destinationHash: otherPeerHash, interfaceID: tcp.tcpClient!.interfaceID)
        link2.linkID = Data(repeating: 0x0E, count: 16)
        link2.requestedAt = fixedDate.addingTimeInterval(-8).timeIntervalSince1970
        tcp.linkPlane.links.append(contentsOf: [link1, link2])
    }
    let links = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Links")
    #expect(links.health == .warn)
    #expect(links.reason == "2 outbound links still establishing")
}

// The other half of the role/status split: a responder in `.pending` is a link SOMEONE ELSE is
// establishing with us, has no 15s outbound deadline of ours attached, and must not warn.
// A predicate that dropped the role clause would pass the test above and fail here.
@MainActor @Test func linksAreOkWhenAPendingLinkIsInboundNotOutbound() {
    var state = healthyState()
    withTCP(&state) { tcp in
        var link = LinkSession.State(
            responderFor: Identity(), destinationHash: peerHash, interfaceID: tcp.tcpClient!.interfaceID)
        link.linkID = Data(repeating: 0x0D, count: 16)
        tcp.linkPlane.links.append(link)
    }
    #expect(state.node.client.endpoint.links.first?.role == .responder)
    #expect(state.node.client.endpoint.links.first?.status == .pending)

    let links = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Links")
    #expect(links.health == .ok)
    #expect(links.reason == nil)
}

// MARK: - Export

@MainActor @Test func textIncludesTheTimestampLayerTitlesAndHealthMarkers() {
    var state = healthyState()
    withTCP(&state) { $0.tcpClient?.interface.status = .connecting }
    let text = DiagnosticsSnapshot(from: state, at: fixedDate).text

    #expect(text.contains("ReTiCaMsgr diagnostics"))
    #expect(text.contains("2023-11-14"))              // fixedDate in ISO 8601
    #expect(text.contains("SOCKET  [problem]"))
    #expect(text.contains("app reports connected, interface reports connecting"))
    #expect(text.contains("IDENTITY  [ok]"))
    #expect(text.contains("app connection"))
}

@MainActor @Test func textCarriesFullIdentifiersNotTruncatedOnes() {
    var state = healthyState()
    // Add only a peer (NO path): peersLayer renders the hash in the ROW VALUE as
    // "Alice  bbbb...bbbb cost=... path=NO". Without a learned path, the hash does NOT
    // appear as a row LABEL elsewhere, so truncating row values to prefix(8) would lose it.
    state.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: "Alice", stampCost: 8, supportsCompression: true, learnedAt: fixedDate)
    let text = DiagnosticsSnapshot(from: state, at: fixedDate).text
    // Full 32-char hex, because this gets correlated against rnsd logs and the other client.
    #expect(text.contains(peerHash.hexString))
    #expect(peerHash.hexString.count == 32)
}

// NOT a correctness test — a safety one, and it pins the CLASS rather than one field. This text
// is designed to be pasted into bug reports, and the state it is built from is full of key
// material on more than one layer:
//
//   * `LinkSession.State.sessionKey`      — the live link's symmetric key
//   * `LinkSession.State.ephemeral`       — the per-link keypair (private half)
//   * `LinkSession.State.owningIdentity`  — our LONG-TERM local private key for a served
//                                           destination; worse to leak than an ephemeral
//   * `InterfaceProfile.ifac`             — `IFAC`'s derived network key and Ed25519 seed,
//                                           reachable from `socketLayer` via `interfaces`
//
// Each gets a DISTINCT recognisable pattern so a failure names which one leaked. Every plant is
// asserted PRESENT before absence is asserted of the output: a safety test that silently
// exercises an empty collection passes for the wrong reason and is worse than no test at all.
@MainActor @Test func textCarriesNoKeyMaterialFromAnyLayer() {
    var state = healthyState()
    let sessionKey = Data(repeating: 0x5E, count: 32)
    let ephemeralPrivate = Data(repeating: 0xE1, count: 64)
    let owningPrivate = Data(repeating: 0x0D, count: 64)
    let linkID = Data(repeating: 0x0C, count: 16)

    // `IFAC` derives and privately stores its key; recompute the same derivation here rather
    // than pretend a planted constant, so the bytes asserted absent are the REAL ones.
    //
    // HONEST LIMIT, so nobody over-reads this: `IFAC.key` and `IFAC.seed` are `private let` in
    // ReTiCA, so today NO change to this file could leak those bytes and the two byte-level
    // `#expect`s below cannot be falsified by mutation. They are kept for the day that storage
    // becomes reachable. What IS live for the IFAC clause is the field-NAME check at the end:
    // rendering `ifac=…` from `socketLayer` fails this test.
    let ifacName = "diagnostics-deny-list-net"
    let ifacPass = "diagnostics-deny-list-key"
    let ifacOrigin = Crypto.fullHash(Data(ifacName.utf8)) + Crypto.fullHash(Data(ifacPass.utf8))
    let ifacKey = Crypto.hkdf(length: 64, derivedFrom: Crypto.fullHash(ifacOrigin),
                              salt: IFAC.salt, context: nil)
    let ifacSeed = Data(ifacKey.suffix(32))

    guard let ephemeral = Identity(privateKey: ephemeralPrivate),
          let owning = Identity(privateKey: owningPrivate),
          let ifac = IFAC(networkName: ifacName, passphrase: ifacPass, size: 16)
    else { fatalError("fixture could not build its key material") }

    withTCP(&state) { tcp in
        var link = LinkSession.State(
            responderFor: owning,
            destinationHash: peerHash,
            interfaceID: tcp.tcpClient!.interfaceID,
            ephemeral: ephemeral)
        link.sessionKey = sessionKey
        link.status = .active
        link.linkID = linkID
        tcp.linkPlane.links.append(link)

        var profile = InterfaceProfile.tcp
        profile.ifac = ifac
        tcp.transport.interfaces[tcp.tcpClient!.interfaceID] = profile
    }

    let snapshot = DiagnosticsSnapshot(from: state, at: fixedDate)

    // PRECONDITIONS — every secret is really in the state the snapshot was built from, and the
    // layers that could leak them really did render something.
    let links = state.node.client.endpoint.links
    #expect(links.count == 1)
    #expect(links.first?.sessionKey == sessionKey)
    #expect(links.first?.ephemeral.privateKey == ephemeralPrivate)
    #expect(links.first?.owningIdentity?.privateKey == owningPrivate)
    #expect(state.node.client.endpoint.interfaces.values.contains { $0.ifac != nil })
    #expect(layer(snapshot, "Links").rows.first?.label == linkID.hexString)
    #expect(layer(snapshot, "Socket").rows.contains { $0.value.contains("tcp") })

    // The link id IS rendered, so the text is not trivially free of hex.
    let text = snapshot.text
    #expect(text.contains(linkID.hexString))

    // No secret BYTES, in any of the forms this file emits.
    #expect(!text.contains(sessionKey.hexString))
    #expect(!text.contains(ephemeralPrivate.hexString))
    #expect(!text.contains(Data(ephemeralPrivate.prefix(32)).hexString))
    #expect(!text.contains(owningPrivate.hexString))
    #expect(!text.contains(Data(owningPrivate.prefix(32)).hexString))
    #expect(!text.contains(ifacKey.hexString))
    #expect(!text.contains(ifacSeed.hexString))

    // No secret FIELD NAMES either — a leak usually arrives labelled.
    let lowered = text.lowercased()
    for banned in ["sessionkey", "ephemeral", "owningidentity", "privatekey", "ifac", "seed"] {
        #expect(!lowered.contains(banned), "text names the deny-listed field \(banned)")
    }
}

// M7. `peer.displayName` is UNAUTHENTICATED announce data — the library flags `LearnedPeer` as
// "Unauthenticated, potentially hostile" — and `LXMFAnnounceData` trims it with `.whitespaces`,
// which does NOT include newlines. So a hostile peer could embed `\n` and forge whole lines in
// an artifact people paste into bug reports and read as evidence.
@MainActor @Test func aHostilePeerDisplayNameCannotForgeLinesInTheExport() {
    var state = healthyState()
    let forged = "SOCKET  [ok] all good"
    state.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: "Mallory\n  \(forged)", stampCost: 8, supportsCompression: true,
        learnedAt: fixedDate)

    var benign = healthyState()
    benign.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: "Mallory", stampCost: 8, supportsCompression: true, learnedAt: fixedDate)

    let text = DiagnosticsSnapshot(from: state, at: fixedDate).text
    let control = DiagnosticsSnapshot(from: benign, at: fixedDate).text

    // Precondition: the hostile name really did reach a row label.
    #expect(layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Peers")
            .rows.contains { $0.label.contains("\n") })

    // Same number of lines as the benign rendering — the newline bought no structure.
    #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count
            == control.split(separator: "\n", omittingEmptySubsequences: false).count)
    #expect(!text.contains("\n  \(forged)"))
    // Escaped, not dropped: the reader still sees exactly what the peer claimed to be called.
    #expect(text.contains("Mallory\\n"))
    #expect(text.contains(forged))
}

// M7, second half. `String.padding(toLength:)` counts UTF-16 while `count` counts Characters, so
// `padding(toLength: max(label.count, 20))` silently TRUNCATED any label whose UTF-16 length
// exceeded its Character count — 25 emoji came out as 12 emoji and a replacement character.
// Also asserts the PADDING half: a short label (fewer than 20 characters) must be padded to
// the column width so the export's columns align. Removing the padding expression entirely left
// all 34 tests green — this assertion is what distinguishes the real code from `let padded = label`.
@MainActor @Test func aShortLabelIsPaddedToColumnWidthAndALongMultiByteLabelIsNotTruncatedInTheExport() {
    // PART 1 — short label is padded to column width (20 chars).
    var shortState = healthyState()
    let shortName = "Hi"   // 2 characters, well under the 20-char column width
    // Precondition: the label really is shorter than the column width.
    #expect(shortName.count < 20)
    shortState.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: shortName, stampCost: 8, supportsCompression: true, learnedAt: fixedDate)
    let shortText = DiagnosticsSnapshot(from: shortState, at: fixedDate).text
    // The row is rendered as "  <padded-label> <value>\n".
    // A 2-char label padded to 20 produces 18 trailing spaces before the value.
    #expect(shortText.contains("  \(shortName)\(String(repeating: " ", count: 18))"))

    // PART 2 — a label whose UTF-16 length exceeds max(Character count, 20) is not truncated.
    var longState = healthyState()
    let longName = String(repeating: "🙂", count: 25)
    #expect(longName.count == 25)
    #expect(longName.utf16.count == 50)
    longState.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: longName, stampCost: 8, supportsCompression: true, learnedAt: fixedDate)
    let longText = DiagnosticsSnapshot(from: longState, at: fixedDate).text
    #expect(longText.contains(longName))
    #expect(!longText.contains("\u{FFFD}"))
}

// MARK: - Bluetooth (A4-diagnostics)

/// Non-fatal layer lookup so a missing layer fails the assertion rather than crashing the suite.
private func bluetoothLayer(_ snap: DiagnosticsSnapshot) -> DiagnosticsSnapshot.Layer? {
    snap.layers.first { $0.title == "Bluetooth" }
}

@MainActor
private func bleEnabledState(status: BLEInterfaceStatus, peers: [Data] = []) -> AppFeature.State {
    var state = healthyState()
    state.$bleEnabled.withLock { $0 = true }
    var ble = BLEEndpoint.State(localIdentity: state.identity.hash)
    ble.ble.status = status
    state.node.client.endpoint.ble = ble
    for token in peers {
        state.node.client.endpoint.transport.interfaces[bleInterfaceID(token)] = .ble
    }
    return state
}

/// BLE off by default: the layer is present, healthy, and says so — not a fault, a choice.
@MainActor @Test func bluetoothLayerIsOffAndOkWhenDisabled() {
    let snap = DiagnosticsSnapshot(from: healthyState(), at: fixedDate)   // bleEnabled defaults false
    let ble = bluetoothLayer(snap)
    #expect(ble?.health == .ok)
    #expect(ble?.rows.contains { $0.label == "bluetooth" && $0.value == "off" } == true)
}

/// Online with peers: healthy, and each connected BLE peer (a `ble:`-prefixed registered interface)
/// is listed with a count. This is the whole point of A4-diagnostics — BLE peers were invisible.
@MainActor @Test func bluetoothLayerListsConnectedPeersWhenOnline() {
    let tokenA = Data(repeating: 0xA1, count: 16)
    let tokenB = Data(repeating: 0xB2, count: 16)
    let snap = DiagnosticsSnapshot(from: bleEnabledState(status: .online, peers: [tokenA, tokenB]),
                                   at: fixedDate)
    let ble = bluetoothLayer(snap)
    #expect(ble?.health == .ok)
    #expect(ble?.rows.contains { $0.label == "interface status" && $0.value == "online" } == true)
    #expect(ble?.rows.contains { $0.label == "connected peers" && $0.value == "2" } == true)
    #expect(ble?.rows.contains { $0.label == bleInterfaceID(tokenA).rawValue } == true)
    #expect(ble?.rows.contains { $0.label == bleInterfaceID(tokenB).rawValue } == true)
}

/// `waitingForAdapter` (now only transient causes like Bluetooth being off) warns — actionable, but
/// not a hard fault: the user can turn Bluetooth on.
@MainActor @Test func bluetoothLayerWarnsWhileWaitingForAdapter() {
    let snap = DiagnosticsSnapshot(from: bleEnabledState(status: .waitingForAdapter), at: fixedDate)
    let ble = bluetoothLayer(snap)
    #expect(ble?.health == .warn)
    #expect(ble?.reason != nil)
}

/// A terminal `unauthorized` (S6) is a PROBLEM with an actionable reason — permission denied, open
/// Settings. This is the precise cause the pre-S6 combined message could not state.
@MainActor @Test func bluetoothLayerFlagsPermissionDeniedAsProblem() {
    let snap = DiagnosticsSnapshot(from: bleEnabledState(status: .unavailable(.unauthorized)),
                                   at: fixedDate)
    let ble = bluetoothLayer(snap)
    #expect(ble?.health == .problem)
    #expect(ble?.reason?.contains("Settings") == true)
    #expect(ble?.rows.contains { $0.label == "interface status" && $0.value.contains("unauthorized") } == true)
}

/// A terminal `unsupported` is a distinct problem — no radio, nothing to grant.
@MainActor @Test func bluetoothLayerFlagsUnsupportedAsProblem() {
    let snap = DiagnosticsSnapshot(from: bleEnabledState(status: .unavailable(.unsupported)),
                                   at: fixedDate)
    let ble = bluetoothLayer(snap)
    #expect(ble?.health == .problem)
    #expect(ble?.reason != nil)
}

/// The layer reaches the shared `text` export (the bug-report artifact), like every other layer.
@MainActor @Test func bluetoothLayerAppearsInTextExport() {
    let snap = DiagnosticsSnapshot(from: bleEnabledState(status: .online), at: fixedDate)
    #expect(snap.text.contains("BLUETOOTH"))
}
