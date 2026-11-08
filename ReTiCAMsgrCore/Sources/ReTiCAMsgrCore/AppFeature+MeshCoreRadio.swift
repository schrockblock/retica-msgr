import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCAMeshCoreLive
import ReTiCANode

/// What a MeshCore slot was built for (spec 2026-11-07 §6, lane D). Decides whether the slot must
/// restart, instead of `config ==`: the reducer never sees the key, and retired keys change without
/// needing a restart. Only a different `radio` replaces the slot; a new `keyGeneration` on the same
/// radio stops and restarts the existing one, so its limiter budgets and stamps, packet ID, dedupe
/// keys and `BIND` stamp carry over.
public struct MeshCoreSlotIdentity: Equatable, Sendable {
    public var radio: UUID
    public var keyGeneration: Int

    public init(radio: UUID, keyGeneration: Int) {
        self.radio = radio
        self.keyGeneration = keyGeneration
    }
}

/// A MeshCore slot stop in flight. The slot was sent `.stop` (or `.removeChannel` first, on a
/// turn-off) and is kept, restarted or replaced only at its `.radioOffline`.
public struct MeshCoreSlotSwap: Equatable, Sendable {
    /// What the slot should be once the old one is down (nil: no radio).
    public var next: MeshCoreSlotIdentity?
    /// Start `next` once it's in place. A going-true sync after a Disconnect clears it, so the
    /// radio stays stopped until the next Connect.
    public var startNext: Bool
    /// A turn-off's `.removeChannel` hasn't answered yet. The `.stop` follows its
    /// `.channelRemoved`, so the driver sees `removeChannel` then `stop`, never a stop and restart
    /// while the removal is in flight.
    public var removingChannel: Bool

    public init(next: MeshCoreSlotIdentity?, startNext: Bool, removingChannel: Bool) {
        self.next = next
        self.startNext = startNext
        self.removingChannel = removingChannel
    }
}

/// `.node(.client(.endpoint(.meshCore(action))))`.
private func meshCore(_ action: MeshCoreEndpoint.Action) -> Effect<AppFeature.Action> {
    .send(.node(.client(.endpoint(.meshCore(action)))))
}

/// Makes the MeshCore slot follow `meshCoreWillDial` (setting on, radio chosen, key present, gate
/// open) and the key generation. Called from `syncEndpointNodes` (Connect, foreground, push wake,
/// launch, node edits) and from the turn-off binding; the caller runs the returned effect before
/// any dial. First matching rule wins.
func syncMeshCoreSlot(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    // Read presence again on every sync, so a foreground recovers a key that was `.unreadable`
    // while the device was locked.
    @Dependency(\.meshCoreKeyStore) var keyStore
    state.meshCoreKeyPresence = keyStore.presence()
    // Read the @Shared settings into locals first: mutating `state.node…` while reading a shared
    // value in the same statement is an exclusive-access violation.
    let willDial = state.meshCoreWillDial
    let radio = state.meshCoreRadioUUID
    let keyGeneration = state.meshCoreKeyGeneration
    let wanted = willDial ? radio.map { MeshCoreSlotIdentity(radio: $0, keyGeneration: keyGeneration) } : nil

    // 1. A stop (or removal) is already in flight: only retarget what follows it. Another `.stop`
    // or a `.start` now would race it. A removal keeps going; its `.channelRemoved` sends the stop.
    if state.meshCoreSwap != nil {
        state.meshCoreSwap?.next = wanted
        state.meshCoreSwap?.startNext = true
        return .none
    }
    // 2. Nothing to change.
    guard state.meshCoreSlotIdentity != wanted else { return .none }

    let slot = state.node.client.endpoint.meshCore
    // 3. No slot, or one with nothing running (never started, or stopped and its `driver.stop()`
    // returned): act now.
    if slot == nil || slot?.interface.isIdle == true {
        if wanted == nil, slot != nil {
            // An idle slot can't reach the radio, so our channel stays on it.
            state.meshCoreStatus.channelLeftOnRadio = true
        }
        if slot != nil, let wanted, wanted.radio == state.meshCoreSlotIdentity?.radio {
            // An idle slot whose key changed: restart it as it is.
            keepMeshCoreSlot(&state, wanted)
            return meshCore(.start)
        }
        return installMeshCoreSlot(&state, wanted, start: true)
    }
    // An `.unavailable` slot (a policy failure, Bluetooth off) is neither idle nor online: rules 5
    // and 6 send it `.stop`, and its offline completes the swap.
    let online = slot?.interface.isOnline == true
    if wanted == nil, online {
        // 4. Turned off with the radio reachable: clear our channel from it first, then stop.
        state.meshCoreSwap = MeshCoreSlotSwap(next: nil, startNext: true, removingChannel: true)
        return meshCore(.removeChannel)
    }
    if wanted == nil {
        // 5. Turned off while the radio isn't online: the channel can't be removed.
        state.meshCoreStatus.channelLeftOnRadio = true
    }
    // 5 and 6. Stop, and finish at `.radioOffline`. A key change never removes the channel.
    state.meshCoreSwap = MeshCoreSlotSwap(next: wanted, startNext: true, removingChannel: false)
    return meshCore(.stop)
}

/// At `.radioOffline`: completes a pending swap once the old slot is idle. A slot NOT idle at its
/// offline has a restart queued (Connect's `.endpoint(.start)` reached it mid-stop), so stop it
/// again and finish at the next offline (Contract 3: only an idle slot is dropped or restarted).
func finishMeshCoreSwap(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    guard let swap = state.meshCoreSwap else { return .none }
    // A drop during a removal: the interface holds any stop until the removal answers, and
    // `.channelRemoved` sends the stop.
    guard !swap.removingChannel else { return .none }
    if let slot = state.node.client.endpoint.meshCore, !slot.interface.isIdle {
        return meshCore(.stop)
    }
    state.meshCoreSwap = nil
    let effect: Effect<AppFeature.Action>
    if state.node.client.endpoint.meshCore != nil, let next = swap.next,
       next.radio == state.meshCoreSlotIdentity?.radio {
        // A key change, or turned back on during a removal: keep the slot. The wrapper reads the
        // new key at `driver.start`.
        keepMeshCoreSlot(&state, next)
        effect = swap.startNext ? meshCore(.start) : .none
    } else {
        effect = installMeshCoreSlot(&state, swap.next, start: swap.startNext)
    }
    // The old radio's drop may have emptied `connectedInterfaces`; a radio starting now is a dial in
    // progress, so show Connecting… Not after a Disconnect (`startNext` false).
    if swap.startNext, swap.next != nil, state.connectedInterfaces.isEmpty {
        state.connection = .connecting
    }
    return effect
}

/// Keeps the existing slot for `identity` (same radio). Resets the per-radio status as an install
/// does, keeping the counters: the slot is about to run again, so a turn-off's "removed" or "left on
/// the radio" no longer describes it (ruling F13). Both keep-slot paths restart for a new key (or a
/// turn-on), which may succeed where the old one failed, so a policy failure no longer holds
/// re-dials back (ruling F18).
private func keepMeshCoreSlot(_ state: inout AppFeature.State, _ identity: MeshCoreSlotIdentity) {
    state.meshCoreSlotIdentity = identity
    state.meshCorePolicyFailed = false
    let live = state.node.client.endpoint.meshCore.map { MeshCoreStatus.Counters($0.counters) }
        ?? MeshCoreStatus.Counters()
    state.meshCoreStatus = MeshCoreStatus(counters: state.meshCoreRetiredCounters + live)
}

/// Replaces the MeshCore slot (no slot, a different radio, or nil). Callers guarantee the current
/// slot is absent or idle. The old slot's counters are carried. The state's config never holds the
/// key: the driver wrapper fills it at `driver.start`.
func installMeshCoreSlot(_ state: inout AppFeature.State, _ identity: MeshCoreSlotIdentity?,
                         start: Bool) -> Effect<AppFeature.Action> {
    let relayEnabled = state.relayEnabled
    if let old = state.node.client.endpoint.meshCore {
        state.meshCoreRetiredCounters += MeshCoreStatus.Counters(old.counters)
    }
    state.node.client.endpoint.meshCore = identity.map {
        MeshCoreEndpoint.State(config: MeshCoreDriverConfig(radio: $0.radio, channelSecret: Data(),
                                                            canRoute: relayEnabled),
                               profile: .meshCore(params: nil))
    }
    state.meshCoreSlotIdentity = identity
    // A different radio (or key) may succeed where a policy failure stopped the old one.
    if identity != nil {
        state.meshCorePolicyFailed = false
    }
    // A turn-off's outcome stays visible while there's no slot; a new slot clears it.
    let keepRecord = identity == nil
    state.meshCoreStatus = MeshCoreStatus(
        channelLeftOnRadio: keepRecord && state.meshCoreStatus.channelLeftOnRadio,
        channelRemoved: keepRecord && state.meshCoreStatus.channelRemoved,
        counters: state.meshCoreRetiredCounters)
    guard identity != nil, start else { return .none }
    return meshCore(.start)
}

/// The MeshCore slot's app-side arms: turn-off acts at once, swap completion at `.radioOffline`,
/// the turn-off's channel removal, and recording a policy failure. Composed into `AppFeature.body`
/// after `MeshtasticRadioReducer`. Other delegates are Task 9's.
struct MeshCoreRadioReducer: Reducer {
    /// `\.meshCoreEnabled` as a read-only key path. A binding's key path compares equal to it, but
    /// forming it doesn't touch the `@Shared` property's deprecated setter, as the writable key path
    /// in `case .binding(\.meshCoreEnabled)` does.
    private static var meshCoreEnabledKeyPath: KeyPath<AppFeature.State, Bool> { \.meshCoreEnabled }

    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            switch action {
            case let .binding(binding) where binding.keyPath == Self.meshCoreEnabledKeyPath:
                // Turn-off acts at once (otherwise toggle-off, Disconnect, Connect would never sync
                // with the radio connected). Turning on waits for Connect, except while a swap is in
                // flight: that swap is already replacing the slot and would otherwise end with
                // `next` nil and the feature on.
                let enabled = state.meshCoreEnabled
                guard !enabled || state.meshCoreSwap != nil else { return .none }
                let effect = syncMeshCoreSlot(&state)
                if enabled, state.connection == .disconnected {
                    // After a Disconnect, turning on still doesn't start a radio without a Connect.
                    state.meshCoreSwap?.startNext = false
                }
                return effect

            case let .node(.client(.endpoint(.meshCore(.delegate(.channelRemoved(ok)))))):
                state.meshCoreStatus.channelLeftOnRadio = !ok
                state.meshCoreStatus.channelRemoved = ok
                guard state.meshCoreSwap?.removingChannel == true else { return .none }
                state.meshCoreSwap?.removingChannel = false
                return meshCore(.stop)

            case .node(.client(.endpoint(.meshCore(.delegate(.radioOffline))))):
                return finishMeshCoreSwap(&state)

            case let .node(.client(.endpoint(.meshCore(.delegate(.adapterUnavailable(.other(text?))))))):
                // No free slot, old firmware or a refused channel write: the live adapter has
                // released the radio, and only the user can fix it, so re-dials stop until Connect
                // or a new radio or key. Other causes ("radio not found", a missing text) may clear
                // on their own and keep being re-dialled.
                if MeshCoreLiveMessage.isPolicyFailure(text) {
                    state.meshCorePolicyFailed = true
                }
                return .none

            default:
                return .none
            }
        }
    }
}
