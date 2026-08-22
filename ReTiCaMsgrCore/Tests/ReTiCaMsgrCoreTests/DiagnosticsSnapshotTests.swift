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
    guard case var .tcp(tcp) = state.node.client.endpoint else {
        fatalError("fixture assumes a TCP endpoint")
    }
    tcp.interface.status = .online
    tcp.transport.interfaces[tcp.interfaceID] = .tcp
    state.node.client.endpoint = .tcp(tcp)
    state.node.client.deliveryDestinationHash = Data(repeating: 0xAA, count: 16)
    return state
}

/// Mutate the TCP endpoint of a state in place.
@MainActor
private func withTCP(_ state: inout AppFeature.State, _ body: (inout TCPEndpoint.State) -> Void) {
    guard case var .tcp(tcp) = state.node.client.endpoint else {
        fatalError("fixture assumes a TCP endpoint")
    }
    body(&tcp)
    state.node.client.endpoint = .tcp(tcp)
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
    withTCP(&state) { $0.interface.status = .connecting }
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
    withTCP(&state) { $0.interface.status = .connecting }
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
            interfaceID: tcp.interfaceID, hops: 0, nextHop: nil, announceEmitted: 0)
    }
    let paths = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Paths")
    #expect(paths.health == .ok)
    #expect(paths.reason == nil)
    #expect(paths.rows.contains { $0.value.contains("reachable=yes") })
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
            interfaceID: tcp.interfaceID, hops: 0, nextHop: nil, announceEmitted: 0)
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

// MARK: - Delivery

@MainActor @Test func deliveryWarnsWhenMessagesArePendingWithNoActiveLink() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[Data(repeating: 0x01, count: 32)] =
        LXMFRouter.PendingDelivery(
            resend: .opportunistic(destinationHash: peerHash, payload: Data()), attempts: 2)
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason == "1 message pending with no active link")
}

@MainActor @Test func deliveryIsOkWhenPendingMessagesHaveAnActiveLink() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[Data(repeating: 0x01, count: 32)] =
        LXMFRouter.PendingDelivery(
            resend: .opportunistic(destinationHash: peerHash, payload: Data()), attempts: 1)
    state.node.client.router.directLinks[peerHash] = .active(linkID: Data(repeating: 0x0C, count: 16))
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .ok)
    #expect(delivery.reason == nil)
}

@MainActor @Test func deliveryIsOkWithNothingPending() {
    let delivery = layer(DiagnosticsSnapshot(from: healthyState(), at: fixedDate), "Delivery")
    #expect(delivery.health == .ok)
}

// MARK: - Links

@MainActor @Test func linksLayerReportsNoLinksOnAQuietState() {
    let links = layer(DiagnosticsSnapshot(from: healthyState(), at: fixedDate), "Links")
    #expect(links.health == .ok)
    #expect(links.rows.contains { $0.label == "(none)" })
}

@MainActor @Test func snapshotHasAllSixLayersInOrder() {
    let snapshot = DiagnosticsSnapshot(from: healthyState(), at: fixedDate)
    #expect(snapshot.layers.map(\.title)
            == ["Socket", "Identity", "Paths", "Peers", "Links", "Delivery"])
}

// MARK: - Delivery (non-active link does not suppress warn)

// The production check is `if case .active = $0` — a precise enum-case match. A future
// broadening to `directLinks[dest] != nil` would silently restore the crypto-amplification
// vector with all tests still green. This test prevents that regression.
@MainActor @Test func deliveryStillWarnsWhenDirectLinkIsEstablishingNotActive() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[Data(repeating: 0x01, count: 32)] =
        LXMFRouter.PendingDelivery(
            resend: .opportunistic(destinationHash: peerHash, payload: Data()), attempts: 2)
    state.node.client.router.directLinks[peerHash] = .establishing
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason == "1 message pending with no active link")
}

// MARK: - Export

@MainActor @Test func textIncludesTheTimestampLayerTitlesAndHealthMarkers() {
    var state = healthyState()
    withTCP(&state) { $0.interface.status = .connecting }
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

// NOT a correctness test — a safety one. `LinkSession.State` carries `sessionKey` and an
// `ephemeral` keypair, and this text is designed to be pasted into bug reports. This is what
// stops a later "just render all the fields" change from leaking key material.
//
// The link is built with a REAL LinkSession.State and asserted to be present before the
// no-leak check. A safety test that silently exercises an empty collection passes for the
// wrong reason and is worse than no test at all.
@MainActor @Test func textNeverContainsALinkSessionKey() {
    var state = healthyState()
    let secret = Data(repeating: 0x5E, count: 32)
    withTCP(&state) { tcp in
        var link = LinkSession.State(
            responderFor: Identity(),
            destinationHash: peerHash,
            interfaceID: tcp.interfaceID)
        link.sessionKey = secret
        link.status = .active
        link.linkID = Data(repeating: 0x0C, count: 16)
        tcp.links.append(link)
    }

    let snapshot = DiagnosticsSnapshot(from: state, at: fixedDate)
    // Precondition: the fixture really does contain a link carrying the secret.
    #expect(state.node.client.endpoint.links.count == 1)
    #expect(snapshot.layers.first { $0.title == "Links" }?.rows.first?.label
            == Data(repeating: 0x0C, count: 16).hexString)

    let text = snapshot.text
    #expect(!text.contains(secret.hexString))
    #expect(!text.lowercased().contains("sessionkey"))
}
