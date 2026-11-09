import Foundation
import ComposableArchitecture

// Meshtastic settings (spec 2026-10-16 §7 lane D). Lane E reads `meshtasticEnabled` and
// `meshtasticRadioUUID` at connect time to build the endpoint slot.

extension AppFeature.State {
    /// The chosen radio, or nil when none is chosen OR the stored string is not a UUID (Review
    /// Focus 4): a hand-edited or corrupted default must read as "no radio", never as a radio to dial.
    public var meshtasticRadioUUID: UUID? {
        meshtasticRadioID.flatMap(UUID.init(uuidString:))
    }

    /// The Settings radio row: the name the radio advertised when it was picked, else its UUID,
    /// else "None".
    public var meshtasticRadioLabel: String {
        guard let id = meshtasticRadioUUID else { return "None" }
        let name = meshtasticRadioName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? id.uuidString : name
    }
}

extension AppFeature.State {
    /// A BLE slot exists and its interface is up or coming up: `starting`, `online`, or waiting out
    /// an adapter retry (whose timer would restart scanning). `stopped` (Disconnect) and a terminal
    /// `unavailable` are not running: "pausing" them would make the picker's dismiss START them.
    /// Keyed on the live slot, not `bleEnabled`, which only takes effect at the next Connect.
    var bleIsRunning: Bool {
        guard let status = node.client.endpoint.ble?.ble.status else { return false }
        switch status {
        case .starting, .online, .waitingForAdapter: return true
        case .stopped, .unavailable:                 return false
        }
    }
}

/// Opens the radio picker for `kind` on `selected` and pauses a running BLE interface. Shared by
/// the Meshtastic and MeshCore "Choose radio…" arms: BLE pauses the same way for both.
func openRadioPicker(_ state: inout AppFeature.State, kind: RadioKind, selected: UUID?) -> Effect<AppFeature.Action> {
    guard state.radioPicker == nil else { return .none }
    state.radioPicker = RadioPickerFeature.State(kind: kind, selectedID: selected)
    // FCB runs ONE scan per process and a new scan silently supersedes the old (spec
    // §2), so a running BLE interface and the picker would steal each other's scan.
    // Pause BLE while the picker is up. A stopped or unavailable interface, or a
    // missing slot, is left alone (see `bleIsRunning`).
    guard state.bleIsRunning else { return .none }
    state.blePausedForRadioScan = true
    return .send(.node(.client(.endpoint(.ble(.stop)))))
}

/// The Meshtastic Settings arms of `AppFeature` (spec 2026-10-16 §7 lane D), composed into
/// `AppFeature.body` after `BlockingReducer`. The main reducer treats these actions as no-ops.
/// It owns the radio picker's presentation and the BLE pause around it.
struct MeshtasticSettingsReducer: Reducer {
    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            switch action {
            case .chooseRadioTapped:
                return openRadioPicker(&state, kind: .meshtastic, selected: state.meshtasticRadioUUID)

            case .chooseMeshCoreRadioTapped:
                guard state.meshCoreAvailable else { return .none }
                return openRadioPicker(&state, kind: .meshCore, selected: state.meshCoreRadioUUID)

            case let .radioPicker(.presented(.delegate(.selected(radio)))):
                // The child state is still present here: dismiss comes after the delegate action.
                switch state.radioPicker?.kind {
                case .meshCore:
                    state.$meshCoreRadioID.withLock { $0 = radio.id.uuidString }
                    state.$meshCoreRadioName.withLock { $0 = radio.name }
                case .meshtastic:
                    state.$meshtasticRadioID.withLock { $0 = radio.id.uuidString }
                    state.$meshtasticRadioName.withLock { $0 = radio.name }
                case .rnode: break  // stored by Task 3
                case nil:
                    // A swipe dismiss landed before this delegate: no picker, so no kind to store under.
                    break
                }
                return .none

            case .radioPicker(.dismiss):
                // Every way out arrives here: the sheet's swipe, Cancel and a pick (the child's
                // `dismiss()`). The presentation reducer cancels the scan right after this arm.
                // Start only BLE that was paused or whose start a wake deferred, and only if its slot
                // is still there.
                guard state.blePausedForRadioScan else { return .none }
                state.blePausedForRadioScan = false
                // Not a slot being removed (the setting went off): it is waiting to be dropped.
                guard state.node.client.endpoint.ble != nil, !state.bleSlotRemovalPending else { return .none }
                // The pause's stop took BLE peers down, and if they were the only interfaces up,
                // `connection` went to disconnected. BLE is about to dial again, so show
                // "Connecting…" as Connect does, not Disconnected with a Connect button.
                if state.connectedInterfaces.isEmpty {
                    state.connection = .connecting
                }
                return .send(.node(.client(.endpoint(.ble(.start)))))

            default:
                return .none
            }
        }
        .ifLet(\.$radioPicker, action: \.radioPicker) {
            RadioPickerFeature()
        }
    }
}
