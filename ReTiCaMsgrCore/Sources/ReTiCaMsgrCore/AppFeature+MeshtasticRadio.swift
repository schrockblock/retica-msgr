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

    /// Amendment A10 ("only show Connecting… when something will actually dial"), now including
    /// the radio. The single definition behind onLaunch, Connect and the foreground re-dial.
    var somethingWillDial: Bool { !enabledNodes.isEmpty || listenEnabled || bleEnabled || meshtasticWillDial }
}

/// Makes the radio slot follow `meshtasticEnabled` + `meshtasticRadioUUID` (spec §7 lane E).
/// Called from `syncEndpointNodes`; the caller runs the returned effect before any dial.
func syncMeshtasticSlot(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    // Read the @Shared settings into locals first: mutating `state.node…` while reading a shared
    // value in the same statement is an exclusive-access violation.
    let willDial = state.meshtasticWillDial
    let radio = state.meshtasticRadioUUID
    let wanted: MeshtasticDriverConfig? = willDial ? radio.map { MeshtasticDriverConfig(radio: $0) } : nil
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
/// was restarted after the stop (a `.start` reached it mid-stop and ran when the stop returned —
/// the interface reports offline before that restart): stop it again; the swap completes at the
/// next `.radioOffline`.
func finishMeshtasticSwap(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    guard let swap = state.meshtasticSwap else { return .none }
    if let slot = state.node.client.endpoint.meshtastic, !slot.interface.isIdle {
        return .send(.node(.client(.endpoint(.meshtastic(.stop)))))
    }
    state.meshtasticSwap = nil
    return installMeshtasticSlot(&state, swap.next, start: swap.startNext)
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
            state.meshtasticStatus.counters = state.meshtasticRetiredCounters + live
            return effect
        }
    }
}
