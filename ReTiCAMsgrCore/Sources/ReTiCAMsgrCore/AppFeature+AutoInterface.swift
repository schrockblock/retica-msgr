import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode

// AutoInterface in the app (spec 2026-11-10-autointerface §5.8, §6, §8): the slot follows
// `autoInterfaceWanted`, a running slot is kept across syncs, removal is `.removeAuto`, iOS stops
// it in the background and starts it afresh in the foreground, and the interface's hatch-only
// delegates become `autoInterfaceNotices` and the Local Network alert.

extension AppFeature.State {
    /// The slot should exist: the setting is on and this platform may run it (spec §9 R1).
    public var autoInterfaceWanted: Bool { autoInterfaceAvailable && autoInterfaceEnabled }

    /// The slot counts toward `somethingWillDial`: wanted, and not known to be denied the local
    /// network (spec §8.4). A denied slot keeps running but would never bring anything up, so it
    /// must not hold the app at Connecting….
    var autoInterfaceWillDial: Bool { autoInterfaceWanted && !autoInterfaceNotices.localNetworkDenied }

    /// Live peers: the slot's own map. A stop sends no per-peer `peerRemoved`, so counting delegates
    /// would drift.
    public var autoInterfacePeerCount: Int { node.client.endpoint.auto?.peerInterfaces.count ?? 0 }

    /// NICs whose data port another program holds right now, sorted. A NIC drops out once its data
    /// socket has bound after all (the interface retries every peer-job tick, spec §5.6 D3), for
    /// example after the user quit NomadNet.
    public var autoInterfaceDataPortInUse: [String] {
        let nics = node.client.endpoint.auto?.interface.nics ?? [:]
        return autoInterfaceNotices.dataPortInUse.filter { nics[$0]?.failed.contains(.data) == true }.sorted()
    }

    /// The slot runs but found no NIC it can use (no Wi-Fi or Ethernet with an IPv6 link-local
    /// address). Read from the interface's live status, which leaves this state when a NIC appears.
    public var autoInterfaceNoUsableInterfaces: Bool {
        node.client.endpoint.auto?.interface.status == .noUsableInterfaces
    }

    /// Spec §9 R5: multicast works (some NIC hears its own echo) yet no peer has appeared for over
    /// `autoInterfaceNoPeersHintDelay` seconds. Either nobody else runs Reticulum here, or the access
    /// point blocks device-to-device traffic (guest and enterprise Wi-Fi). No fix exists; the UI
    /// says so. Measured from the earliest echo of this session.
    public func autoInterfaceNoPeersHint(at now: Date) -> Bool {
        guard let auto = node.client.endpoint.auto, auto.peerInterfaces.isEmpty,
              let firstEcho = auto.interface.nics.values.compactMap(\.firstEcho).min() else { return false }
        return now.timeIntervalSince(firstEcho) > AppFeature.autoInterfaceNoPeersHintDelay
    }
}

extension AppFeature {
    /// Spec §9 R5's 30 s.
    public static let autoInterfaceNoPeersHintDelay: TimeInterval = 30
}

/// Makes the AutoInterface slot follow `autoInterfaceWanted`. Called from `syncEndpointNodes`.
/// A slot that exists is KEPT: a fresh `AutoEndpoint.State` would drop every live peer (as BLE's
/// note in `syncEndpointNodes` explains). Removal is `.removeAuto`, which deregisters the peers and
/// stops the driver before the slot goes; never `auto = nil` (spec §5.7). A slot whose removal is
/// still waiting for the driver is left to finish: `autoInterfaceRemovalFinished` recreates it if
/// the setting came back on meanwhile.
func syncAutoInterfaceSlot(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    let wanted = state.autoInterfaceWanted
    let current = state.node.client.endpoint.auto
    if wanted {
        guard current == nil else { return .none }
        state.node.client.endpoint.auto = AutoEndpoint.State(config: AutoInterfaceConfig())
        state.autoInterfaceNotices = AutoInterfaceNotices()
        return .none
    }
    guard let current, !current.removalPending else { return .none }
    state.autoInterfaceNotices = AutoInterfaceNotices()
    state.localNetworkAlert = nil
    return .send(.node(.client(.endpoint(.removeAuto))))
}

/// A start is about to reach a stopped slot (Connect, foreground): that is a fresh session, which
/// reports everything again, so the old notices go now. A running slot keeps its notices: its
/// `.start` is a no-op and it will not report them a second time.
func resetAutoInterfaceNoticesIfStopped(_ state: inout AppFeature.State) {
    guard state.node.client.endpoint.auto?.interface.status == .stopped else { return }
    state.autoInterfaceNotices = AutoInterfaceNotices()
}

/// The `.foregrounded` restart (spec §8.5): a stopped slot starts afresh, rebinding and
/// re-announcing, so peers come back within about 3.5 s. Not from `.pushWake`: a background wake
/// must not start it on iOS. A running slot (the Mac, which never stops it) is left alone, and so
/// is one being removed.
func autoInterfaceForegroundStart(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    guard let auto = state.node.client.endpoint.auto, !auto.removalPending,
          auto.interface.status == .stopped else { return .none }
    resetAutoInterfaceNoticesIfStopped(&state)
    return .send(.node(.client(.endpoint(.auto(.start)))))
}

/// The `.backgrounded` stop on iOS (spec §8.5): there is no background mode for UDP, the sockets
/// may be reclaimed while suspended, and the remote side evicts us after 22-26 s anyway. The Mac
/// keeps running.
func autoInterfaceBackgroundStop(_ state: AppFeature.State) -> Effect<AppFeature.Action> {
    guard state.autoInterfaceStopsInBackground, let auto = state.node.client.endpoint.auto,
          !auto.removalPending, auto.interface.status != .stopped else { return .none }
    return .send(.node(.client(.endpoint(.auto(.stop)))))
}

/// A removal's `driver.stop()` returned and the container dropped the slot. If the setting came back
/// on while it ran, put a fresh slot in and start it, so the toggle does not need a second Connect.
func autoInterfaceRemovalFinished(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    guard state.node.client.endpoint.auto == nil, state.autoInterfaceWanted else { return .none }
    state.node.client.endpoint.auto = AutoEndpoint.State(config: AutoInterfaceConfig())
    state.autoInterfaceNotices = AutoInterfaceNotices()
    return .send(.node(.client(.endpoint(.auto(.start)))))
}

/// The interface's hatch-only delegates (spec §6). Peer registration itself is the endpoint's;
/// the app sees each peer as an `interfaceConnected` like any other interface.
func reduceAutoInterfaceDelegate(_ delegate: AutoInterface.Action.Delegate,
                                 _ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    switch delegate {
    case .peerAdded:
        // Someone answered: the local network is plainly not denied.
        state.autoInterfaceNotices.localNetworkDenied = false
    case let .carrierLost(nic):
        state.autoInterfaceNotices.carrierLost.insert(nic)
    case let .carrierRecovered(nic):
        // An echo arrived, so multicast works on this NIC after all.
        state.autoInterfaceNotices.carrierLost.remove(nic)
        state.autoInterfaceNotices.multicastUnavailable.remove(nic)
    case let .multicastUnavailable(nic):
        state.autoInterfaceNotices.multicastUnavailable.insert(nic)
        // The alert only when multicast fails on EVERY adopted NIC: one dead NIC (an unplugged
        // Thunderbolt bridge) next to a working Wi-Fi is not a permission problem.
        let adopted = Set(state.node.client.endpoint.auto?.interface.nics.keys.map { $0 } ?? [])
        if adopted.isSubset(of: state.autoInterfaceNotices.multicastUnavailable) {
            presentLocalNetworkAlert(.multicastUnavailable, &state)
        }
    case let .dataPortInUse(nic):
        state.autoInterfaceNotices.dataPortInUse.insert(nic)
    case .localNetworkDenied:
        state.autoInterfaceNotices.localNetworkDenied = true
        presentLocalNetworkAlert(.denied, &state)
        // The slot no longer counts toward `somethingWillDial`. If it was all that held the app at
        // Connecting…, stop showing that: nothing is going to come up.
        if state.connection == .connecting, state.connectedInterfaces.isEmpty, !state.somethingWillDial {
            state.connection = .disconnected
        }
    case .peerRemoved, .packetReceived, .noUsableInterfaces:
        // Peer departures are the endpoint's (`interfaceDisconnected`); no usable NIC is read from
        // the interface's live status (`autoInterfaceNoUsableInterfaces`).
        break
    }
    return .none
}

/// At most once per launch: a denied permission is reported again by every restart.
private func presentLocalNetworkAlert(_ alert: LocalNetworkAlert, _ state: inout AppFeature.State) {
    guard !state.localNetworkAlertShown else { return }
    state.localNetworkAlertShown = true
    state.localNetworkAlert = alert
}
