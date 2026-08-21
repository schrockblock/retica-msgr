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
