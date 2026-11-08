import Foundation
import ComposableArchitecture

/// The "Choose radio" sheet (spec 2026-10-16 §7 lane D). It scans while it is on screen, lists
/// what it hears (one row per radio, first-seen order, newest RSSI), and either reports a pick
/// and dismisses, or dismisses on Cancel. Presented from `AppFeature.State.radioPicker`. The
/// presentation reducer cancels the scan on dismiss, and `AppFeature` pauses and resumes BLE
/// around it (`MeshtasticSettingsReducer`).
@Reducer
public struct RadioPickerFeature {
    /// Shown when the scan ended without finding anything. With the lane D stub scanner this is
    /// the "not installed" case, and later it can mean Bluetooth is off or not allowed.
    public static let scanEndedEmptyMessage =
        "Scanning stopped before any radio was found. Meshtastic support may not be installed in "
        + "this build, or Bluetooth may be off or not allowed."

    @ObservableState
    public struct State: Equatable {
        public var radios: IdentifiedArrayOf<RadioScanResult> = []
        /// The scanner's stream finished. A live scanner only finishes when scanning stopped for
        /// good, so the sheet stops showing a spinner and says why.
        public var scanEnded = false
        /// The radio Settings currently holds (a checkmark), then the one just tapped.
        public var selectedID: UUID?

        /// Which family of radio this picker scans for.
        public var kind: RadioKind

        public init(kind: RadioKind = .meshtastic, selectedID: UUID? = nil) {
            self.kind = kind
            self.selectedID = selectedID
        }

        /// The footer while a scan runs.
        public var scanningMessage: String {
            let name = kind == .meshCore ? "MeshCore" : "Meshtastic"
            return "Scanning for \(name) radios… Make sure the radio is on and not connected to another app."
        }

        /// The footer when the scan ended without finding anything.
        public var scanEndedEmptyMessage: String {
            switch kind {
            case .meshtastic:
                RadioPickerFeature.scanEndedEmptyMessage
            case .meshCore:
                "Scanning stopped before any radio was found. MeshCore support may not be installed in "
                    + "this build, or Bluetooth may be off or not allowed."
            }
        }
    }

    public enum Action: Equatable {
        /// The sheet appeared: start (or restart) the scan.
        case onAppear
        case radioFound(RadioScanResult)
        case scanFinished
        case radioTapped(UUID)
        case cancelTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// The user picked this radio. The parent stores it. The picker then dismisses itself.
            case selected(RadioScanResult)
        }
    }

    private enum CancelID: Hashable { case scan }

    @Dependency(\.radioScanner) var radioScanner
    @Dependency(\.dismiss) var dismiss

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.scanEnded = false
                // `cancelInFlight`: SwiftUI can fire onAppear twice, and FCB's one process-wide scan
                // means a second concurrent scan would supersede the first (Review Focus 5).
                return .run { [radioScanner, kind = state.kind] send in
                    for await radio in radioScanner.stream(for: kind) {
                        await send(.radioFound(radio))
                    }
                    // A cancelled scan (dismiss, a second appear) ended on purpose: not "stopped".
                    guard !Task.isCancelled else { return }
                    await send(.scanFinished)
                }
                .cancellable(id: CancelID.scan, cancelInFlight: true)

            case let .radioFound(radio):
                // A repeat without a name keeps the one already heard. The id subscript replaces
                // the row in place (first-seen order) or appends a new one.
                var merged = radio
                if merged.name == nil { merged.name = state.radios[id: radio.id]?.name }
                state.radios[id: radio.id] = merged
                return .none

            case .scanFinished:
                state.scanEnded = true
                return .none

            case let .radioTapped(id):
                guard let radio = state.radios[id: id] else { return .none }
                state.selectedID = id
                return .concatenate(
                    .send(.delegate(.selected(radio))),
                    .run { [dismiss] _ in await dismiss() }
                )

            case .cancelTapped:
                return .run { [dismiss] _ in await dismiss() }

            case .delegate:
                return .none
            }
        }
    }
}
