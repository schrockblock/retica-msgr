import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode

/// A radio slot replacement in flight (spec 2026-10-16 Contract 3, amended): the old slot was
/// sent `.stop` and is dropped only at its `.radioOffline`, which the interface reports once
/// `driver.stop()` has returned. Then `next` (nil: no radio) is installed.
public struct MeshtasticSlotSwap: Equatable, Sendable {
    public var next: MeshtasticDriverConfig?
    /// Start `next` once installed. Disconnect clears it, so a swap finishing after a Disconnect
    /// leaves the new radio stopped until the next Connect.
    public var startNext: Bool

    public init(next: MeshtasticDriverConfig?, startNext: Bool) {
        self.next = next
        self.startNext = startNext
    }
}

extension AppFeature.State {
    /// A Meshtastic radio will dial at Connect / foreground: the setting is on AND a radio is chosen.
    var meshtasticWillDial: Bool { meshtasticEnabled && meshtasticRadioUUID != nil }

    /// The stored hop limit, clamped into `MeshtasticHopLimit.range`.
    public var meshtasticHopLimitValue: Int {
        min(max(meshtasticHopLimit, MeshtasticHopLimit.range.lowerBound), MeshtasticHopLimit.range.upperBound)
    }

    /// What the radio slot should run: the chosen radio with the hop limit while
    /// `meshtasticWillDial`, else nil. `syncMeshtasticSlot` replaces a slot whose config differs
    /// from this, so a new hop limit takes effect like a new radio (Connect or Apply changes).
    var meshtasticWantedConfig: MeshtasticDriverConfig? {
        let hopLimit = UInt32(meshtasticHopLimitValue)
        return meshtasticWillDial
            ? meshtasticRadioUUID.map { MeshtasticDriverConfig(radio: $0, hopLimit: hopLimit) } : nil
    }

    /// Amendment A10 ("only show Connecting… when something will actually dial"), now including
    /// the radios. The single definition behind onLaunch, Connect and the foreground re-dial. A
    /// MeshCore radio held back by a policy failure, or an RNode by a failure only the user can fix,
    /// won't dial on a re-dial, so it doesn't count (Connect clears both flags before reading this).
    /// An AutoInterface slot denied the local network doesn't count either (spec 2026-11-10 §8.4).
    var somethingWillDial: Bool {
        !enabledNodes.isEmpty || listenEnabled || bleEnabled || meshtasticWillDial
            || (meshCoreWillDial && !meshCorePolicyFailed) || (rnodeWillDial && !rnodeNeedsUserAction)
            || autoInterfaceWillDial
    }
}

/// Makes the radio slot follow `meshtasticEnabled` + `meshtasticRadioUUID` (spec §7 lane E).
/// Called from `syncEndpointNodes`; the caller runs the returned effect before any dial.
func syncMeshtasticSlot(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    // Read the @Shared settings into locals first: mutating `state.node…` while reading a shared
    // value in the same statement is an exclusive-access violation.
    let wanted = state.meshtasticWantedConfig
    if state.meshtasticSwap != nil {
        // A stop is already in flight: only retarget what replaces the old slot. Another `.stop`
        // or a `.start` now would race the in-flight `driver.stop()`.
        state.meshtasticSwap = MeshtasticSlotSwap(next: wanted, startNext: true)
        return .none
    }
    let current = state.node.client.endpoint.meshtastic
    guard current?.interface.config != wanted else { return .none }
    guard let current, !current.interface.isIdle else {
        // No slot, or one with nothing running (never started, or stopped and its `driver.stop()`
        // returned): replace it now.
        return installMeshtasticSlot(&state, wanted, start: true)
    }
    state.meshtasticSwap = MeshtasticSlotSwap(next: wanted, startNext: true)
    return .send(.node(.client(.endpoint(.meshtastic(.stop)))))
}

/// At `.radioOffline`: completes a pending swap once the old slot is idle. A slot that is NOT idle
/// at its `.radioOffline` has a restart QUEUED (a `.start` reached it mid-stop; since ReTiCA
/// 0cd3fef the interface queues the restart behind this offline rather than running it). Stopping
/// it again clears that queue and the swap completes at the next `.radioOffline` — Contract 3:
/// only an idle slot is dropped.
func finishMeshtasticSwap(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    guard let swap = state.meshtasticSwap else { return .none }
    if let slot = state.node.client.endpoint.meshtastic, !slot.interface.isIdle {
        return .send(.node(.client(.endpoint(.meshtastic(.stop)))))
    }
    state.meshtasticSwap = nil
    let install = installMeshtasticSlot(&state, swap.next, start: swap.startNext)
    // The old radio's drop may have emptied `connectedInterfaces` and shown "Disconnected" with a
    // Connect button; a new radio starting now is a dial in progress, so show Connecting… (as
    // Connect does, and as lane D's picker dismiss does for BLE). Not after a Disconnect
    // (`startNext` false): the new radio stays stopped and "Disconnected" is right.
    if swap.startNext, swap.next != nil, state.connectedInterfaces.isEmpty {
        state.connection = .connecting
    }
    return install
}

/// Replaces the radio slot. Callers guarantee the current slot is absent or idle. The old slot's
/// counters are carried, and the per-radio status fields reset.
func installMeshtasticSlot(_ state: inout AppFeature.State, _ config: MeshtasticDriverConfig?,
                           start: Bool) -> Effect<AppFeature.Action> {
    if let old = state.node.client.endpoint.meshtastic {
        state.meshtasticRetiredCounters += MeshtasticStatus.Counters(old.counters)
    }
    state.node.client.endpoint.meshtastic = config.map { MeshtasticEndpoint.State(config: $0) }
    state.meshtasticStatus = MeshtasticStatus(counters: state.meshtasticRetiredCounters)
    guard config != nil, start else { return .none }
    return .send(.node(.client(.endpoint(.meshtastic(.start)))))
}

/// The radio's delegates (spec Contract 3) → `MeshtasticStatus`, swap completion at
/// `.radioOffline`, and the counters refreshed on EVERY radio action (they change with each
/// fragment, and no delegate reports them). Composed into `AppFeature.body` after
/// `MeshtasticSettingsReducer`.
struct MeshtasticRadioReducer: Reducer {
    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            guard case let .node(.client(.endpoint(.meshtastic(radioAction)))) = action else { return .none }
            var effect: Effect<AppFeature.Action> = .none
            switch radioAction {
            case let .delegate(.radioOnline(myNodeNum, modemPreset)):
                state.meshtasticStatus.online = true
                state.meshtasticStatus.myNodeNum = myNodeNum
                state.meshtasticStatus.modemPreset = modemPreset
                state.meshtasticStatus.offlineReason = nil
                state.meshtasticStatus.adapterUnavailable = nil
            case let .delegate(.radioOffline(reason)):
                state.meshtasticStatus.online = false
                state.meshtasticStatus.offlineReason = reason
                effect = finishMeshtasticSwap(&state)
            case let .delegate(.adapterUnavailable(cause)):
                state.meshtasticStatus.online = false
                state.meshtasticStatus.adapterUnavailable = cause
            default:
                break
            }
            let live = state.node.client.endpoint.meshtastic.map { MeshtasticStatus.Counters($0.counters) }
                ?? MeshtasticStatus.Counters()
            let total = state.meshtasticRetiredCounters + live
            if state.meshtasticStatus.counters != total {
                state.meshtasticStatus.counters = total
            }
            return effect
        }
    }
}
