import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode

/// One step of a BLE slot removal (`bleSlotRemovalPending`, set by `syncEndpointNodes` when
/// `bleEnabled` is off). An idle slot (`BLEInterface.State.isIdle`: stopped, its `driver.stop()`
/// returned) is dropped now; any other slot is sent `.stop` and dropped at a later step. Never
/// drop a slot that is not idle: one dropped before it was stopped leaves the adapter scanning and
/// its peers registered, and one dropped mid-stop (`.stopped` but still `stopping`) gets its
/// `.driverStopped` with no state, while a new slot's start could race that stop.
func advanceBLESlotRemoval(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    guard state.bleSlotRemovalPending, let slot = state.node.client.endpoint.ble else {
        state.bleSlotRemovalPending = false
        return .none
    }
    if slot.ble.isIdle {
        state.node.client.endpoint.ble = nil
        state.bleSlotRemovalPending = false
        return .none
    }
    // The interface's `.stop` is idempotent: while a stop is in flight it only cancels a start
    // deferred behind it, and it reports `.driverStopped` once per `driver.stop()`.
    return .send(.node(.client(.endpoint(.ble(.stop)))))
}

/// Drives a pending BLE slot removal from the interface's own actions. Composed into
/// `AppFeature.body` after the `LXMFServiceNode` scope, so the interface has already reduced each
/// action seen here and `isIdle` is current.
/// - `.driverStopped`: the stop returned, so the slot is idle and is dropped now.
/// - `.start` (Connect's `.endpoint(.start)` and the foreground re-dial reach every slot present):
///   the interface defers it behind the stop in flight; stopping again at once cancels that
///   deferred start. Without this the deferred start runs at `.driverStopped`, and stopping the
///   restarted slot then races its start effect: the mock driver saw `driver.start()` called AFTER
///   the second `driver.stop()` returned, which on the live adapter is a session nothing stops.
struct BLESlotReducer: Reducer {
    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            guard state.bleSlotRemovalPending else { return .none }
            switch action {
            case .node(.client(.endpoint(.ble(.ble(.driverStopped))))),
                 .node(.client(.endpoint(.ble(.ble(.start))))):
                return advanceBLESlotRemoval(&state)
            default:
                return .none
            }
        }
    }
}
