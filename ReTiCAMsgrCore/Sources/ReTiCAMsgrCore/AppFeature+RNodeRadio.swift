import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode

/// An RNode slot replacement in flight (spec 2026-11-08 Contract 3): the old slot was sent `.stop`
/// and is dropped only at its `.radioOffline`, which the interface reports once `driver.stop()` has
/// returned. Then `next` (nil: no radio) is installed. Meshtastic's swap, with RNode names.
public struct RNodeSlotSwap: Equatable, Sendable {
    public var next: RNodeDriverConfig?
    /// Start `next` once installed. Disconnect clears it, so a swap finishing after a Disconnect
    /// leaves the new radio stopped until the next Connect.
    public var startNext: Bool

    public init(next: RNodeDriverConfig?, startNext: Bool) {
        self.next = next
        self.startNext = startNext
    }
}

extension RNodeLoRaParams {
    /// Lane C's settings in ReTiCA's types. Nil without a frequency, or when any value doesn't fit
    /// its type (`UInt32` for hertz, `UInt8` for the rest). `rnodeWillDial` already range-checks a
    /// complete value, so the checked conversions guard only against a future range change.
    init?(_ settings: RNodeRadioSettings) {
        guard let frequency = settings.frequencyHz,
              let frequencyHz = UInt32(exactly: frequency),
              let bandwidthHz = UInt32(exactly: settings.bandwidthHz),
              let txPowerDBm = UInt8(exactly: settings.txPowerDBm),
              let spreadingFactor = UInt8(exactly: settings.spreadingFactor),
              let codingRate = UInt8(exactly: settings.codingRate)
        else { return nil }
        self.init(frequencyHz: frequencyHz, bandwidthHz: bandwidthHz, txPowerDBm: txPowerDBm,
                  spreadingFactor: spreadingFactor, codingRate: codingRate)
    }
}

extension AppFeature.State {
    /// What the RNode slot should run: the chosen radio with the stored parameters while
    /// `rnodeWillDial`, else nil.
    var rnodeWantedConfig: RNodeDriverConfig? {
        guard rnodeWillDial, let radio = rnodeRadioUUID, let params = RNodeLoRaParams(rnodeSettings) else {
            return nil
        }
        return RNodeDriverConfig(radio: radio, params: params)
    }
}

/// Makes the RNode slot follow `rnodeWantedConfig` (spec 2026-11-08 §6, lane D). Any `config` change,
/// radio or parameters, replaces the slot, as Meshtastic's does. Called from `syncEndpointNodes`
/// (Connect, foreground, push wake, launch, node edits); the caller runs the returned effect before
/// any dial. Settings edits alone never call it, so a change waits for one of those.
func syncRNodeSlot(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    // Read the @Shared settings into a local first: mutating `state.node…` while reading a shared
    // value in the same statement is an exclusive-access violation.
    let wanted = state.rnodeWantedConfig
    if state.rnodeSwap != nil {
        // A stop is already in flight: only retarget what replaces the old slot. Another `.stop`
        // or a `.start` now would race the in-flight `driver.stop()`.
        state.rnodeSwap = RNodeSlotSwap(next: wanted, startNext: true)
        return .none
    }
    let current = state.node.client.endpoint.rnode
    guard current?.interface.config != wanted else { return .none }
    guard let current, !current.interface.isIdle else {
        // No slot, or one with nothing running (never started, or stopped and its `driver.stop()`
        // returned): replace it now. No `.stop` goes to a slot that doesn't exist or is idle.
        return installRNodeSlot(&state, wanted, start: true)
    }
    state.rnodeSwap = RNodeSlotSwap(next: wanted, startNext: true)
    return .send(.node(.client(.endpoint(.rnode(.stop)))))
}

/// At `.radioOffline`: completes a pending swap once the old slot is idle. A slot NOT idle at its
/// offline has a restart queued (Connect's `.endpoint(.start)` reached it mid-stop), so stop it
/// again and finish at the next offline (Contract 3: only an idle slot is dropped).
func finishRNodeSwap(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    guard let swap = state.rnodeSwap else { return .none }
    if let slot = state.node.client.endpoint.rnode, !slot.interface.isIdle {
        return .send(.node(.client(.endpoint(.rnode(.stop)))))
    }
    state.rnodeSwap = nil
    let install = installRNodeSlot(&state, swap.next, start: swap.startNext)
    // The old radio's drop may have emptied `connectedInterfaces`; a new radio starting now is a
    // dial in progress, so show Connecting… Not after a Disconnect (`startNext` false).
    if swap.startNext, swap.next != nil, state.connectedInterfaces.isEmpty {
        state.connection = .connecting
    }
    return install
}

/// Replaces the RNode slot. Callers guarantee the current slot is absent or idle. The old slot's
/// counters are carried into `rnodeRetiredCounters`, and the per-radio status resets. The profile
/// is the default one: no IFAC on the RNode (spec §5.8).
func installRNodeSlot(_ state: inout AppFeature.State, _ config: RNodeDriverConfig?,
                      start: Bool) -> Effect<AppFeature.Action> {
    if let old = state.node.client.endpoint.rnode {
        state.rnodeRetiredCounters += RNodeStatus.Counters(old.counters)
    }
    state.node.client.endpoint.rnode = config.map { RNodeEndpoint.State(config: $0) }
    state.rnodeStatus = RNodeStatus(counters: state.rnodeRetiredCounters)
    guard config != nil, start else { return .none }
    return .send(.node(.client(.endpoint(.rnode(.start)))))
}

/// The RNode slot's app-side arms: swap completion at `.radioOffline`. The other delegates come in
/// lane D Task 9. There is no immediate turn-off arm: like Meshtastic, every change waits for
/// Connect. Composed into `AppFeature.body` after `MeshCoreRadioReducer`.
struct RNodeRadioReducer: Reducer {
    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            switch action {
            case .node(.client(.endpoint(.rnode(.delegate(.radioOffline))))):
                return finishRNodeSwap(&state)
            default:
                return .none
            }
        }
    }
}
