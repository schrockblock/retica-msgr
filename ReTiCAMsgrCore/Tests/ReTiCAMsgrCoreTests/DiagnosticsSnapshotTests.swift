import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCAMsgrCore

// MARK: - Fixtures

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
private let gaefuID = DefaultNode.entry.interfaceID

/// A state whose SOCKET layer is healthy: app connected, interface online, interface registered.
/// Fixtures here are built COHERENTLY on purpose — seeding `learned` without `interfaces`
/// produces a state the runtime cannot reach, and that incoherence is itself one of the
/// conditions under test (see the paths cross-check in a later task).
@MainActor
private func healthyState() -> AppFeature.State {
    var state = AppFeature.State(identity: Identity())
    state.connection = .connected
    // One slot, the default node's, as `syncEndpointNodes` would build it; its socket online and
    // its interface registered on the shared router.
    state.node.client.endpoint.tcpClients.append(
        TCPEndpoint.State(host: DefaultNode.host, port: UInt16(DefaultNode.port), reconnectOnDrop: true,
                          interfaceID: gaefuID))
    state.node.client.endpoint.tcpClients[id: gaefuID]?.interface.status = .online
    state.node.client.endpoint.transport.interfaces[gaefuID] = .tcp
    state.node.client.deliveryDestinationHash = Data(repeating: 0xAA, count: 16)
    return state
}

/// Reaches the shared `TransportEndpoint` of a state for in-place edits (router, link plane). It
/// builds no slot: set a node's socket status with `setNodeStatus`, which traps when the slot
/// was never built instead of silently no-oping through `tcpClients[id:]?`.
@MainActor
private func withEndpoint(_ state: inout AppFeature.State,
                          _ body: (inout TransportEndpoint.State) -> Void) {
    body(&state.node.client.endpoint)
}

/// A node's socket status; traps instead of silently no-oping when the slot was never built.
@MainActor
private func setNodeStatus(_ state: inout AppFeature.State, _ id: InterfaceID, _ status: TCPClientInterface.Status) {
    precondition(state.node.client.endpoint.tcpClients[id: id] != nil, "no slot for \(id.rawValue)")
    state.node.client.endpoint.tcpClients[id: id]?.interface.status = status
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
    setNodeStatus(&state, gaefuID, .connecting)
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.health == .problem)
    #expect(socket.reason == "app reports connected, nodes report gaefu.ddns.net:4242=connecting")
}

@MainActor @Test func socketIsAProblemWhenInterfaceIsOnlineButTransportHasNoInterfaces() {
    var state = healthyState()
    withEndpoint(&state) { $0.transport.interfaces = [:] }
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.health == .problem)
    #expect(socket.reason == "socket is up but Transport has no registered interface")
}

@MainActor @Test func socketWarnsWhileBothAgreeConnecting() {
    var state = healthyState()
    state.connection = .connecting
    setNodeStatus(&state, gaefuID, .connecting)
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
    #expect(socket.reason == "app reports connecting, nodes report gaefu.ddns.net:4242=online")
}

// MARK: - Paths (F8 cross-check)

private let peerHash = Data(repeating: 0xBB, count: 16)

@MainActor @Test func pathsWarnWhenALearnedPathNamesAnInterfaceThatIsGone() {
    var state = healthyState()
    withEndpoint(&state) { tcp in
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
    withEndpoint(&state) { tcp in
        tcp.transport.learned[peerHash] = LearnedDestination(
            identity: Identity(), appData: nil, ratchet: nil,
            interfaceID: gaefuID, hops: 0, nextHop: nil, announceEmitted: 0)
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
    withEndpoint(&state) { tcp in
        tcp.tcpClients[id: gaefuID]?.interface.status = .disconnected
        tcp.transport.learned[peerHash] = LearnedDestination(
            identity: Identity(), appData: nil, ratchet: nil,
            interfaceID: gaefuID, hops: 0, nextHop: nil, announceEmitted: 0)
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
    withEndpoint(&state) { tcp in
        tcp.tcpClients[id: gaefuID]?.interface.status = .disconnected
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
    withEndpoint(&state) { tcp in
        tcp.transport.learned[peerHash] = LearnedDestination(
            identity: Identity(), appData: nil, ratchet: nil,
            interfaceID: gaefuID, hops: 0, nextHop: nil, announceEmitted: 0)
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
    state.node.client.router.pendingDeliveries[.delivery(messageHash)] = LXMFRouter.PendingDelivery(
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
    state.node.client.router.pendingDeliveries[.delivery(messageHash)] = LXMFRouter.PendingDelivery(
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
    state.node.client.router.pendingDeliveries[.delivery(messageHash)] = LXMFRouter.PendingDelivery(
        resend: .direct(destinationHash: peerHash, data: Data(), asResource: false), attempts: 2)
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason == "1 message pending with no active link to its destination")
}

// CLAUSE 1, third method. `.propagated` links to the PROPAGATION NODE, so it needs one too.
@MainActor @Test func deliveryWarnsWhenAPropagatedSendIsPendingWithNoLinkToThePropagationNode() {
    var state = healthyState()
    state.node.client.router.outboundPropagationNode = otherPeerHash
    state.node.client.router.pendingDeliveries[.propagated(messageHash)] = LXMFRouter.PendingDelivery(
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
    state.node.client.router.pendingDeliveries[.delivery(messageHash)] = LXMFRouter.PendingDelivery(
        resend: .direct(destinationHash: peerHash, data: Data(), asResource: false), attempts: 1)
    state.node.client.router.pendingDeliveries[.delivery(messageHash2)] = LXMFRouter.PendingDelivery(
        resend: .direct(destinationHash: otherPeerHash, data: Data(), asResource: false), attempts: 1)
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason == "2 messages pending with no active link to their destination")
}

// CLAUSE 2 — correlation. A link to Alice says nothing about a message stranded to Bob. The old
// rule asked only "is ANY link active anywhere", so this state read green.
@MainActor @Test func deliveryWarnsWhenTheActiveLinkIsToADifferentDestinationThanThePendingSend() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[.delivery(messageHash)] = LXMFRouter.PendingDelivery(
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
    state.node.client.router.pendingDeliveries[.delivery(messageHash)] = LXMFRouter.PendingDelivery(
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
    state.node.client.router.pendingDeliveries[.delivery(messageHash)] = LXMFRouter.PendingDelivery(
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
    var state = healthyState()
    state.autoInterfaceAvailable = true
    let snapshot = DiagnosticsSnapshot(from: state, at: fixedDate)
    #expect(snapshot.layers.map(\.title)
            == ["Socket", "AutoInterface", "Bluetooth", "Meshtastic", "MeshCore", "RNode", "Identity", "Paths",
                "Peers", "Links", "Delivery"])
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
    withEndpoint(&state) { tcp in
        var link = LinkSession.State(
            initiatorTo: Identity(), destinationHash: peerHash, interfaceID: gaefuID)
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
    withEndpoint(&state) { tcp in
        var link1 = LinkSession.State(
            initiatorTo: Identity(), destinationHash: peerHash, interfaceID: gaefuID)
        link1.linkID = Data(repeating: 0x0C, count: 16)
        link1.requestedAt = fixedDate.addingTimeInterval(-5).timeIntervalSince1970
        var link2 = LinkSession.State(
            initiatorTo: Identity(), destinationHash: otherPeerHash, interfaceID: gaefuID)
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
    withEndpoint(&state) { tcp in
        var link = LinkSession.State(
            responderFor: Identity(), destinationHash: peerHash, interfaceID: gaefuID)
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
    setNodeStatus(&state, gaefuID, .connecting)
    let text = DiagnosticsSnapshot(from: state, at: fixedDate).text

    #expect(text.contains("ReTiCAMsgr diagnostics"))
    #expect(text.contains("2023-11-14"))              // fixedDate in ISO 8601
    #expect(text.contains("SOCKET  [problem]"))
    #expect(text.contains("app reports connected, nodes report gaefu.ddns.net:4242=connecting"))
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

    withEndpoint(&state) { tcp in
        var link = LinkSession.State(
            responderFor: owning,
            destinationHash: peerHash,
            interfaceID: gaefuID,
            ephemeral: ephemeral)
        link.sessionKey = sessionKey
        link.status = .active
        link.linkID = linkID
        tcp.linkPlane.links.append(link)

        var profile = InterfaceProfile.tcp
        profile.ifac = ifac
        tcp.transport.interfaces[gaefuID] = profile
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

// MARK: - Nodes on the Socket layer (spec 2026-10-10 §3 "Diagnostics")

private let piID = InterfaceID("tcp:pi.local:4243")

private func withPi(_ state: inout AppFeature.State, status: TCPClientInterface.Status) {
    state.node.client.endpoint.tcpClients.append(
        TCPEndpoint.State(host: "pi.local", port: 4243, reconnectOnDrop: true, interfaceID: piID))
    state.node.client.endpoint.tcpClients[id: piID]?.interface.status = status
}

@MainActor @Test func nodeDiagSocketListsEveryNodeWithItsStatus() {
    var state = healthyState()
    withPi(&state, status: .connecting)
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    let nodeRows = socket.rows.filter { $0.label.hasPrefix("node ") }
    #expect(nodeRows == [
        DiagnosticsSnapshot.Row("node gaefu.ddns.net:4242", "online"),
        DiagnosticsSnapshot.Row("node pi.local:4243", "connecting"),
    ])
}

@MainActor @Test func nodeDiagSocketIsOkWhenAnyNodeIsOnline() {
    var state = healthyState()
    withPi(&state, status: .disconnected)   // one node down, the other up and registered
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.health == .ok)
    #expect(socket.reason == nil)
}

@MainActor @Test func nodeDiagSocketWithNoNodesSaysNoneEnabled() {
    var state = AppFeature.State(identity: Identity())
    state.connection = .disconnected
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.rows.contains(DiagnosticsSnapshot.Row("nodes", "(none enabled)")))
    #expect(socket.health == .warn)
    #expect(socket.reason == "disconnected")
}

/// Backlog 17: the app says connected while no node slot exists at all (a BLE peer, say) — the
/// disagreement names the empty node set rather than an empty string.
@MainActor @Test func nodeDiagSocketReportsNoneWhenConnectedWithoutSlots() {
    var state = AppFeature.State(identity: Identity())
    state.connection = .connected
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.health == .problem)
    #expect(socket.reason == "app reports connected, nodes report none")
}

// MARK: - Meshtastic (spec 2026-10-16 §7 lane D)

private let meshRadio = UUID(uuidString: "6A1B2C3D-0000-4000-8000-00000000AB01")!

/// Non-fatal lookup: a missing layer fails the assertion instead of crashing the suite.
private func meshLayer(_ snap: DiagnosticsSnapshot) -> DiagnosticsSnapshot.Layer? {
    snap.layers.first { $0.title == "Meshtastic" }
}

private func meshRow(_ layer: DiagnosticsSnapshot.Layer?, _ label: String) -> String? {
    layer?.rows.first { $0.label == label }?.value
}

/// A healthy state with the Meshtastic settings set, its `@Shared(.appStorage)` keys in a fresh
/// suite so no test sees another's.
@MainActor
private func meshState(enabled: Bool = true, radio: UUID? = meshRadio, name: String? = "Base camp",
                       status: MeshtasticStatus = MeshtasticStatus()) -> AppFeature.State {
    var state = withDependencies { $0.defaultAppStorage = .inMemory } operation: { healthyState() }
    state.$meshtasticEnabled.withLock { $0 = enabled }
    state.$meshtasticRadioID.withLock { $0 = radio?.uuidString }
    state.$meshtasticRadioName.withLock { $0 = name }
    state.meshtasticStatus = status
    return state
}

/// Off by choice is not a fault, like Bluetooth.
@MainActor @Test func meshDiagIsOffAndOkWhenDisabled() {
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(enabled: false), at: fixedDate))
    #expect(layer?.health == .ok)
    #expect(meshRow(layer, "meshtastic") == "off")
}

@MainActor @Test func meshDiagWarnsWhenNoRadioIsChosen() {
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(radio: nil), at: fixedDate))
    #expect(layer?.health == .warn)
    #expect(layer?.reason?.contains("no radio") == true)
}

@MainActor @Test func meshDiagWarnsWhileTheRadioIsOffline() {
    let status = MeshtasticStatus(online: false, offlineReason: "link lost")
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(layer?.health == .warn)
    #expect(layer?.reason == "radio not connected")
    #expect(meshRow(layer, "offline reason") == "link lost")
}

@MainActor @Test func meshDiagIsOkWhenOnline() {
    let status = MeshtasticStatus(online: true, modemPreset: 6, myNodeNum: 0xABCD)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(layer?.health == .ok)
    #expect(layer?.reason == nil)
}

/// Meshtastic names nodes `!` + 8 lowercase hex digits. Matching it lets a reader find the same
/// node in the Meshtastic app.
@MainActor @Test func meshDiagShowsTheNodeNumberInMeshtasticForm() {
    let status = MeshtasticStatus(online: true, myNodeNum: 0x0000_ABCD)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(meshRow(layer, "node") == "!0000abcd")
}

@MainActor @Test func meshDiagNamesThePreset() {
    let status = MeshtasticStatus(online: true, modemPreset: 6)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(meshRow(layer, "preset") == "ShortFast (6)")
}

/// A preset newer than this build still shows its raw value, never a guess.
@MainActor @Test func meshDiagShowsAnUnknownPresetRaw() {
    let status = MeshtasticStatus(online: true, modemPreset: 9)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(meshRow(layer, "preset") == "unknown (9)")
}

@MainActor @Test func meshDiagAdapterUnavailableIsAProblem() {
    let status = MeshtasticStatus(online: false, adapterUnavailable: .unauthorized)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(layer?.health == .problem)
}

/// Contract 2's liveValue is loud on purpose: its message must reach the screen.
@MainActor @Test func meshDiagShowsTheUninstalledDriverMessage() {
    let status = MeshtasticStatus(online: false, adapterUnavailable: .other("ReTiCAMeshtasticLive not installed"))
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(meshRow(layer, "adapter") == "other: ReTiCAMeshtasticLive not installed")
}

@MainActor @Test func meshDiagRendersEveryCounter() {
    let counters = MeshtasticStatus.Counters(malformed: 1, evicted: 2, timedOut: 3, oversize: 4,
                                             completed: 5, queueFull: 6, sendFailed: 7)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: MeshtasticStatus(counters: counters)),
                                              at: fixedDate))
    #expect(meshRow(layer, "malformed") == "1")
    #expect(meshRow(layer, "evicted") == "2")
    #expect(meshRow(layer, "timed out") == "3")
    #expect(meshRow(layer, "oversize") == "4")
    #expect(meshRow(layer, "reassembled") == "5")
    #expect(meshRow(layer, "queue full") == "6")
    #expect(meshRow(layer, "send failed") == "7")
}

/// Review Focus 3: the advertised name is attacker-controlled. Rows are escaped by `text`, the
/// reason is not, so the name must never reach a reason. Same shape as
/// `aHostilePeerDisplayNameCannotForgeLinesInTheExport`.
@MainActor @Test func meshDiagAHostileRadioNameCannotForgeLines() {
    let forged = "SOCKET  [ok] all good"
    let hostile = meshState(name: "Mallory\n  \(forged)")
    let benign = meshState(name: "Mallory")
    // Precondition: the hostile name really reached a row.
    #expect(meshLayer(DiagnosticsSnapshot(from: hostile, at: fixedDate))?
        .rows.contains { $0.value.contains("\n") } == true)
    let text = DiagnosticsSnapshot(from: hostile, at: fixedDate).text
    let control = DiagnosticsSnapshot(from: benign, at: fixedDate).text
    #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count
            == control.split(separator: "\n", omittingEmptySubsequences: false).count)
    #expect(!text.contains("\n  \(forged)"))
    #expect(text.contains("Mallory\\n"))
}

// MARK: - MeshCore (spec 2026-11-07 §6, lane C)

private let mcDiagRadio = UUID(uuidString: "C1C1C1C1-0000-4000-8000-0000000000C1")!

/// Non-fatal lookup: a missing layer fails the assertion instead of crashing the suite.
private func mcDiagLayer(_ snap: DiagnosticsSnapshot) -> DiagnosticsSnapshot.Layer? {
    snap.layers.first { $0.title == "MeshCore" }
}

private func mcDiagRow(_ layer: DiagnosticsSnapshot.Layer?, _ label: String) -> String? {
    layer?.rows.first { $0.label == label }?.value
}

/// A healthy state with the MeshCore settings set, its `@Shared(.appStorage)` keys in a fresh suite
/// so no test sees another's. Defaults describe a configured radio that is not yet connected.
@MainActor
private func mcDiagState(enabled: Bool = true, radio: UUID? = mcDiagRadio, name: String? = "Hilltop",
                         presence: MeshCoreKeyPresence = .present,
                         status: MeshCoreStatus = MeshCoreStatus()) -> AppFeature.State {
    var state = withDependencies { $0.defaultAppStorage = .inMemory } operation: { healthyState() }
    state.$meshCoreEnabled.withLock { $0 = enabled }
    state.$meshCoreRadioID.withLock { $0 = radio?.uuidString }
    state.$meshCoreRadioName.withLock { $0 = name }
    state.meshCoreKeyPresence = presence
    state.meshCoreStatus = status
    return state
}

/// Off by choice is not a fault, like Bluetooth and Meshtastic.
@MainActor @Test func mcDiagIsOffAndOkWhenDisabled() {
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(enabled: false, presence: .absent),
                                                at: fixedDate))
    #expect(layer?.health == .ok)
    #expect(layer?.reason == nil)
    #expect(mcDiagRow(layer, "meshcore") == "off")
}

/// The Release gate hides the layer, not just its rows.
@MainActor @Test func mcDiagLayerIsAbsentWithTheGateOff() {
    var state = mcDiagState()
    state.meshCoreAvailable = false
    let titles = DiagnosticsSnapshot(from: state, at: fixedDate).layers.map(\.title)
    #expect(!titles.contains("MeshCore"))
    // Precondition: the rest of the snapshot is still there.
    #expect(titles.contains("Meshtastic"))
}

@MainActor @Test func mcDiagLayerFollowsMeshtastic() {
    let titles = DiagnosticsSnapshot(from: mcDiagState(), at: fixedDate).layers.map(\.title)
    guard let meshtastic = titles.firstIndex(of: "Meshtastic"), meshtastic + 1 < titles.count else {
        Issue.record("no layer after Meshtastic in \(titles)")
        return
    }
    #expect(titles[meshtastic + 1] == "MeshCore")
}

@MainActor @Test func mcDiagWarnsWithoutAChannelKey() {
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(presence: .absent), at: fixedDate))
    #expect(layer?.health == .warn)
    #expect(layer?.reason == "no channel key — set one in Settings")
    #expect(mcDiagRow(layer, "channel key") == "not set")
}

@MainActor @Test func mcDiagWarnsWhenTheKeyCannotBeRead() {
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(presence: .unreadable), at: fixedDate))
    #expect(layer?.health == .warn)
    #expect(layer?.reason == "the channel key can't be read")
    #expect(mcDiagRow(layer, "channel key") == "can't be read")
}

@MainActor @Test func mcDiagWarnsWhenNoRadioIsChosen() {
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(radio: nil), at: fixedDate))
    #expect(layer?.health == .warn)
    #expect(layer?.reason == "no radio chosen — choose one in Settings")
    #expect(mcDiagRow(layer, "radio") == "(none chosen)")
}

@MainActor @Test func mcDiagAdapterUnavailableIsAProblem() {
    let status = MeshCoreStatus(online: false, adapterUnavailable: .unauthorized)
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(status: status), at: fixedDate))
    #expect(layer?.health == .problem)
    #expect(layer?.reason == "the Bluetooth path to the radio is unavailable")
    #expect(mcDiagRow(layer, "adapter") == "unauthorized")
}

/// Lane D's driver reports a full radio as `.other`; its text must reach the screen.
@MainActor @Test func mcDiagShowsTheNoFreeSlotMessage() {
    let status = MeshCoreStatus(online: false, adapterUnavailable: .other("No free channel slot on this radio"))
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(status: status), at: fixedDate))
    #expect(mcDiagRow(layer, "adapter") == "other: No free channel slot on this radio")
}

@MainActor @Test func mcDiagWarnsWhileTheRadioIsOffline() {
    let status = MeshCoreStatus(online: false, offlineReason: "link lost")
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(status: status), at: fixedDate))
    #expect(layer?.health == .warn)
    #expect(layer?.reason == "radio not connected")
    #expect(mcDiagRow(layer, "status") == "offline")
    #expect(mcDiagRow(layer, "offline reason") == "link lost")
}

@MainActor @Test func mcDiagIsOkWhenOnline() {
    let status = MeshCoreStatus(online: true, radioName: "Hilltop")
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(status: status), at: fixedDate))
    #expect(layer?.health == .ok)
    #expect(layer?.reason == nil)
    #expect(mcDiagRow(layer, "status") == "online")
    #expect(mcDiagRow(layer, "channel key") == "set")
    #expect(mcDiagRow(layer, "radio id") == mcDiagRadio.uuidString)
}

@MainActor @Test func mcDiagShowsLoRaParams() {
    let params = MeshCoreStatus.LoRaParams(spreadingFactor: 10, bandwidthHz: 250_000, codingRate: 5)
    let status = MeshCoreStatus(online: true, params: params)
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(status: status), at: fixedDate))
    #expect(mcDiagRow(layer, "LoRa") == "SF10 / 250 kHz / CR5")
}

@MainActor @Test func mcDiagShowsFirmwareAndSlot() {
    let status = MeshCoreStatus(online: true, firmwareCode: 11, channelSlot: 3)
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(status: status), at: fixedDate))
    #expect(mcDiagRow(layer, "firmware code") == "11")
    #expect(mcDiagRow(layer, "channel slot") == "3")
}

@MainActor @Test func mcDiagShowsUnknownsBeforeAConnection() {
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(), at: fixedDate))
    #expect(mcDiagRow(layer, "LoRa") == "unknown")
    #expect(mcDiagRow(layer, "firmware code") == "unknown")
    #expect(mcDiagRow(layer, "channel slot") == "unknown")
}

@MainActor @Test func mcDiagRendersEveryCounter() {
    let counters = MeshCoreStatus.Counters(malformed: 1, notAddressed: 2, evicted: 3, timedOut: 4,
                                           oversize: 5, completed: 6, queueFull: 7, sendFailed: 8,
                                           announcesLimited: 9, pathRequestsLimited: 10)
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(status: MeshCoreStatus(counters: counters)),
                                                at: fixedDate))
    let expected: [(String, String)] = [
        ("reassembled", "6"), ("malformed", "1"), ("not addressed", "2"), ("evicted", "3"),
        ("timed out", "4"), ("oversize", "5"), ("queue full", "7"), ("send failed", "8"),
        ("announces limited", "9"), ("path requests limited", "10"),
    ]
    for (label, value) in expected {
        #expect(mcDiagRow(layer, label) == value, "\(label)")
    }
    // The ten counter rows close the layer, in this order.
    #expect(layer?.rows.suffix(10).map(\.label) == expected.map(\.0))
}

/// The radio's name is attacker-controlled, from the settings (picked from an advertisement) and
/// from the radio itself. Rows are escaped by `text`, the reason is not, so neither name may reach
/// a reason. Same shape as `meshDiagAHostileRadioNameCannotForgeLines`.
@MainActor @Test func mcDiagAHostileRadioNameCannotForgeLines() {
    let hostileName = "x\nPROBLEM [problem] forged"
    let hostile = mcDiagState(name: hostileName, status: MeshCoreStatus(radioName: hostileName))
    let benign = mcDiagState(name: "x", status: MeshCoreStatus(radioName: "x"))
    let snap = DiagnosticsSnapshot(from: hostile, at: fixedDate)
    // Precondition: the hostile name really reached both rows.
    #expect(mcDiagRow(mcDiagLayer(snap), "radio") == hostileName)
    #expect(mcDiagRow(mcDiagLayer(snap), "radio name") == hostileName)
    let lines = snap.text.split(separator: "\n", omittingEmptySubsequences: false)
    let control = DiagnosticsSnapshot(from: benign, at: fixedDate).text
        .split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == control.count)
    #expect(!lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("PROBLEM") })
    #expect(snap.text.contains("x\\nPROBLEM [problem] forged"))
}

@MainActor @Test func mcDiagOffShowsAChannelLeftOnTheRadio() {
    let status = MeshCoreStatus(channelLeftOnRadio: true)
    let layer = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(enabled: false, status: status), at: fixedDate))
    #expect(mcDiagRow(layer, "channel left on radio") == "yes")
    // Without the flag there is no row at all.
    let clean = mcDiagLayer(DiagnosticsSnapshot(from: mcDiagState(enabled: false), at: fixedDate))
    #expect(mcDiagRow(clean, "channel left on radio") == nil)
}

/// Review Focus 5: the export is pasted into bug reports. With a real key in the store, and the store
/// installed while the snapshot is built, no form of the key reaches `text`.
@MainActor @Test func mcDiagTextCarriesNoChannelKey() {
    let (_, keyStore) = mcKeychain()
    #expect(keyStore.paste(MeshCoreKeyText(mcHexA)) == .changed)
    // Positive control: the store really holds the key the assertions look for.
    #expect(keyStore.exportText()?.reveal() == mcHexA)
    let status = MeshCoreStatus(online: true, radioName: "Hilltop",
                                params: .init(spreadingFactor: 10, bandwidthHz: 250_000, codingRate: 5),
                                firmwareCode: 11, channelSlot: 3)
    let state = mcDiagState(presence: .present, status: status)
    let text = withDependencies {
        $0.meshCoreKeyStore = keyStore
    } operation: {
        DiagnosticsSnapshot(from: state, at: fixedDate).text
    }
    // Precondition: the layer rendered as a connected, keyed radio.
    #expect(text.contains("MESHCORE  [ok]"))
    #expect(!text.contains(mcHexA.lowercased()))
    #expect(!text.contains(mcHexA.uppercased()))
    #expect(!text.lowercased().contains("reveal"))
}

/// Settings shows the driver's own text for `.other` (R12).
@MainActor @Test func mcDiagUserMessageShowsDriverText() {
    #expect(MeshCoreStatus(adapterUnavailable: .other("x")).userMessage == "x")
}

// MARK: - RNode (spec 2026-11-08 §6, lane C)

private let rnDiagRadio = UUID(uuidString: "D1D1D1D1-0000-4000-8000-0000000000D1")!

/// Non-fatal lookup: a missing layer fails the assertion instead of crashing the suite.
private func rnDiagLayer(_ snap: DiagnosticsSnapshot) -> DiagnosticsSnapshot.Layer? {
    snap.layers.first { $0.title == "RNode" }
}

private func rnDiagRow(_ layer: DiagnosticsSnapshot.Layer?, _ label: String) -> String? {
    layer?.rows.first { $0.label == label }?.value
}

/// A state with the RNode settings set, its `@Shared(.appStorage)` keys in a fresh suite so no test
/// sees another's. Defaults describe a dial-ready radio that is not yet connected: on, 868.1 MHz with
/// the default bandwidth, SF, CR and power, a radio chosen.
@MainActor
private func rnDiagState(enabled: Bool = true, frequencyHz: Int? = 868_100_000, radio: UUID? = rnDiagRadio,
                         name: String? = "RNode 1A2B", status: RNodeStatus = RNodeStatus()) -> AppFeature.State {
    var state = withDependencies { $0.defaultAppStorage = .inMemory } operation: { healthyState() }
    state.$rnodeEnabled.withLock { $0 = enabled }
    state.$rnodeFrequencyHz.withLock { $0 = frequencyHz }
    state.$rnodeRadioID.withLock { $0 = radio?.uuidString }
    state.$rnodeRadioName.withLock { $0 = name }
    state.rnodeStatus = status
    return state
}

@MainActor private func rnDiagLayer(_ state: AppFeature.State) -> DiagnosticsSnapshot.Layer? {
    rnDiagLayer(DiagnosticsSnapshot(from: state, at: fixedDate))
}

/// Off by choice is not a fault, and the layer says nothing more than that.
@MainActor @Test func rnDiagOffIsOkWithOneRow() {
    let layer = rnDiagLayer(rnDiagState(enabled: false, status: RNodeStatus(online: true, radioName: "x")))
    #expect(layer?.health == .ok)
    #expect(layer?.reason == nil)
    #expect(layer?.rows == [DiagnosticsSnapshot.Row("rnode", "off")])
}

/// Settings come first: with no frequency and no radio, the reason is the settings one.
@MainActor @Test func rnDiagIncompleteSettingsWarn() {
    let layer = rnDiagLayer(rnDiagState(frequencyHz: nil, radio: nil))
    #expect(layer?.health == .warn)
    #expect(layer?.reason == "radio settings incomplete — set them in Settings")
    #expect(rnDiagRow(layer, "settings") == "incomplete")
}

@MainActor @Test func rnDiagNoRadioWarns() {
    let layer = rnDiagLayer(rnDiagState(radio: nil))
    #expect(layer?.health == .warn)
    #expect(layer?.reason == "no radio chosen — choose one in Settings")
    #expect(rnDiagRow(layer, "radio") == "(none chosen)")
    #expect(rnDiagRow(layer, "radio id") == nil)
}

@MainActor @Test func rnDiagOfflineWarns() {
    let layer = rnDiagLayer(rnDiagState(status: RNodeStatus(online: false, offlineReason: "link lost")))
    #expect(layer?.health == .warn)
    #expect(layer?.reason == "radio not connected")
    #expect(rnDiagRow(layer, "status") == "offline")
    #expect(rnDiagRow(layer, "offline reason") == "link lost")
}

@MainActor @Test func rnDiagAdapterUnavailableIsAProblem() {
    let status = RNodeStatus(online: false, adapterUnavailable: .other("RNode firmware too old"))
    let layer = rnDiagLayer(rnDiagState(status: status))
    #expect(layer?.health == .problem)
    #expect(layer?.reason == "the Bluetooth path to the radio is unavailable")
    #expect(rnDiagRow(layer, "adapter") == "other: RNode firmware too old")
}

@MainActor @Test func rnDiagOnlineIsOk() {
    let layer = rnDiagLayer(rnDiagState(status: RNodeStatus(online: true)))
    #expect(layer?.health == .ok)
    #expect(layer?.reason == nil)
    #expect(rnDiagRow(layer, "status") == "online")
    #expect(rnDiagRow(layer, "radio") == "RNode 1A2B")
    #expect(rnDiagRow(layer, "radio id") == rnDiagRadio.uuidString)
}

@MainActor @Test func rnDiagRowsShowTheSettingsAndTheReport() {
    let reported = RNodeStatus.Params(frequencyHz: 868_100_000, bandwidthHz: 62_500, spreadingFactor: 8,
                                      codingRate: 6, txPowerDBm: 0)
    let layer = rnDiagLayer(rnDiagState(status: RNodeStatus(online: true, firmware: "1.86", reported: reported)))
    #expect(rnDiagRow(layer, "settings") == "868.1 MHz / 62.5 kHz / SF8 / CR6 / 0 dBm")
    #expect(rnDiagRow(layer, "reported") == "868.1 MHz / 62.5 kHz / SF8 / CR6 / 0 dBm")
    #expect(rnDiagRow(layer, "firmware") == "1.86")
    // Before a connection, every report row reads unknown.
    let before = rnDiagLayer(rnDiagState())
    for label in ["radio name", "firmware", "platform", "reported", "bitrate", "last RSSI", "last SNR",
                  "channel load", "airtime", "noise floor"] {
        #expect(rnDiagRow(before, label) == "unknown", "\(label)")
    }
}

@MainActor @Test func rnDiagRowsShowTelemetry() {
    let status = RNodeStatus(online: true, bitrate: 1302, lastRSSI: -97, lastSNR: 6.25,
                             channelLoadShort: 2.15, channelLoadLong: 0.8,
                             airtimeShort: 1.5, airtimeLong: 0.25, noiseFloor: -117)
    let layer = rnDiagLayer(rnDiagState(status: status))
    #expect(rnDiagRow(layer, "last RSSI") == "-97 dBm")
    #expect(rnDiagRow(layer, "last SNR") == "6.25 dB")
    #expect(rnDiagRow(layer, "channel load") == "2.15% / 0.80%")
    // Distinct from the channel load values, so crossed fields fail.
    #expect(rnDiagRow(layer, "airtime") == "1.50% / 0.25%")
    #expect(rnDiagRow(layer, "noise floor") == "-117 dBm")
    #expect(rnDiagRow(layer, "bitrate") == "1302 bps")
}

/// Only one side of a pair known: that side shows, the other reads unknown.
@MainActor @Test func rnDiagHalfKnownPercentPairShowsTheKnownSide() {
    let status = RNodeStatus(online: true, channelLoadShort: 2.15, channelLoadLong: nil,
                             airtimeShort: nil, airtimeLong: 0.25)
    let layer = rnDiagLayer(rnDiagState(status: status))
    #expect(rnDiagRow(layer, "channel load") == "2.15% / unknown")
    #expect(rnDiagRow(layer, "airtime") == "unknown / 0.25%")
}

@MainActor @Test func rnDiagPlatformNames() {
    func platform(_ value: UInt8?) -> String? {
        rnDiagRow(rnDiagLayer(rnDiagState(status: RNodeStatus(platform: value))), "platform")
    }
    #expect(platform(0x80) == "ESP32")
    #expect(platform(0x70) == "nRF52")
    #expect(platform(0x90) == "unknown (0x90)")
    #expect(platform(0x0A) == "unknown (0x0A)")
    #expect(platform(nil) == "unknown")
}

@MainActor @Test func rnDiagHardwareErrorNames() {
    func error(_ value: UInt8?) -> String? {
        rnDiagRow(rnDiagLayer(rnDiagState(status: RNodeStatus(lastHardwareError: value))), "last hardware error")
    }
    #expect(error(0x01) == "radio init failed")
    #expect(error(0x02) == "transmit failed")
    #expect(error(0x03) == "EEPROM locked")
    #expect(error(0x04) == "queue full")
    #expect(error(0x05) == "memory low")
    #expect(error(0x06) == "modem timeout")
    #expect(error(0x42) == "code 0x42")
    #expect(error(0x0B) == "code 0x0B")
    // Only when set.
    #expect(error(nil) == nil)
}

@MainActor @Test func rnDiagCountersAreListed() {
    let counters = RNodeStatus.Counters(received: 1, sent: 2, oversize: 3, queueFull: 4, sendFailed: 5,
                                        hardwareErrors: 6)
    let layer = rnDiagLayer(rnDiagState(status: RNodeStatus(lastHardwareError: 0x01, counters: counters)))
    let expected: [(String, String)] = [
        ("received", "1"), ("sent", "2"), ("oversize", "3"), ("queue full", "4"), ("send failed", "5"),
        ("hardware errors", "6"),
    ]
    for (label, value) in expected {
        #expect(rnDiagRow(layer, label) == value, "\(label)")
    }
    // The six counter rows close the layer, in this order.
    #expect(layer?.rows.suffix(6).map(\.label) == expected.map(\.0))
    // `Counters()` is all zero, and `+` / `+=` add field by field (lane D sums retired slots).
    #expect(RNodeStatus.Counters() == RNodeStatus.Counters(received: 0, sent: 0, oversize: 0, queueFull: 0,
                                                           sendFailed: 0, hardwareErrors: 0))
    var sum = counters
    sum += counters
    #expect(sum == counters + counters)
    #expect(sum == RNodeStatus.Counters(received: 2, sent: 4, oversize: 6, queueFull: 8, sendFailed: 10,
                                        hardwareErrors: 12))
}

/// The Release gate hides the layer, not just its rows.
@MainActor @Test func rnDiagLayerIsAbsentWithTheGateOff() {
    var state = rnDiagState()
    state.rnodeAvailable = false
    let titles = DiagnosticsSnapshot(from: state, at: fixedDate).layers.map(\.title)
    #expect(!titles.contains("RNode"))
    // Precondition: the rest of the snapshot is still there.
    #expect(titles.contains("MeshCore"))
}

/// Review Focus 4: the radio's name is attacker-controlled, from the settings (picked from an
/// advertisement) and from the radio itself. Rows are escaped by `text`, the reason is not, so neither
/// name may reach a reason. The fixture is dial-ready and offline, so the reason comes from
/// `radioLinkLayer` rather than the fixed settings text. Same shape as
/// `mcDiagAHostileRadioNameCannotForgeLines`.
@MainActor @Test func rnDiagAHostileRadioNameCannotForgeLines() {
    let hostileName = "RNode \n[ok] x"
    let hostile = rnDiagState(name: hostileName, status: RNodeStatus(online: false, radioName: hostileName))
    let benign = rnDiagState(name: "RNode", status: RNodeStatus(online: false, radioName: "RNode"))
    let snap = DiagnosticsSnapshot(from: hostile, at: fixedDate)
    // Precondition: the hostile name really reached both rows, and the layer has a reason.
    #expect(rnDiagRow(rnDiagLayer(snap), "radio") == hostileName)
    #expect(rnDiagRow(rnDiagLayer(snap), "radio name") == hostileName)
    #expect(rnDiagLayer(snap)?.reason == "radio not connected")
    let lines = snap.text.split(separator: "\n", omittingEmptySubsequences: false)
    let control = DiagnosticsSnapshot(from: benign, at: fixedDate).text
        .split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == control.count)
    #expect(!lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[ok] x") })
    #expect(snap.text.contains("RNode \\n[ok] x"))
}

/// Settings' sentence for each cause: the same wording as MeshCore's (one shared mapping), and the
/// driver's own text for `.other`.
@MainActor @Test func rnDiagUserMessageForEachCause() {
    #expect(RNodeStatus(adapterUnavailable: .poweredOff).userMessage
            == "Bluetooth is off. Turn it on to reach the radio.")
    #expect(RNodeStatus(adapterUnavailable: .unauthorized).userMessage
            == "Bluetooth permission is off for this app. Allow it in Settings.")
    #expect(RNodeStatus(adapterUnavailable: .unsupported).userMessage
            == "This device has no Bluetooth LE radio.")
    #expect(RNodeStatus(adapterUnavailable: .other("x")).userMessage == "x")
    #expect(RNodeStatus(adapterUnavailable: .other(nil)).userMessage
            == "The Bluetooth path to the radio is unavailable.")
    #expect(RNodeStatus().userMessage == nil)
}
