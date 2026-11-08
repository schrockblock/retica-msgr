import Foundation
import ComposableArchitecture

// MeshCore settings (spec 2026-11-07 §6). Lane D reads `meshCoreWillDial` at connect time.

extension AppFeature.State {
    /// The chosen radio, or nil when none is chosen OR the stored string is not a UUID: a hand-edited
    /// or corrupted default must read as "no radio", never as a radio to dial.
    public var meshCoreRadioUUID: UUID? {
        meshCoreRadioID.flatMap(UUID.init(uuidString:))
    }

    /// The Settings radio row: the name the radio advertised when it was picked, else its UUID,
    /// else "None".
    public var meshCoreRadioLabel: String {
        guard let id = meshCoreRadioUUID else { return "None" }
        let name = meshCoreRadioName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? id.uuidString : name
    }

    /// Every condition a MeshCore slot needs to start. Stale defaults (restored from a backup without
    /// the Keychain item, or left over from a Debug build) fail the key or gate check, so nothing dials.
    var meshCoreWillDial: Bool {
        meshCoreAvailable && meshCoreEnabled && meshCoreRadioUUID != nil && meshCoreKeyPresence == .present
    }
}

/// The MeshCore key arms of `AppFeature` (spec 2026-11-07 §6), composed into `AppFeature.body` after
/// `MeshtasticSettingsReducer`. The main reducer treats these actions as no-ops.
///
/// The key never passes through here: Generate and Copy are effects that call the store, and the
/// paste sheet calls the store itself and sends only the result. State gets presence, a generation
/// counter and a message, nothing derived from the key.
struct MeshCoreSettingsReducer: Reducer {
    @Dependency(\.meshCoreKeyStore) var keyStore
    @Dependency(\.meshCoreKeyPasteboard) var pasteboard

    static let invalidKeyMessage =
        "Enter a key of 32 hex characters. A key other people already use for something else can't be used here."
    static let storageFailedMessage = "The key couldn't be saved. Try again."

    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            switch action {
            case .meshCoreGenerateKeyTapped:
                return .run { [keyStore] send in
                    await send(.meshCoreKeyDidChange(keyStore.generate()))
                }

            case .meshCoreCopyKeyTapped:
                return .run { [keyStore, pasteboard] _ in
                    if let text = keyStore.exportText() {
                        pasteboard.copy(text)
                    }
                }

            case let .meshCoreKeyDidChange(result):
                state.meshCoreKeyPresence = keyStore.presence()
                // Lane D's slot identity reads the generation: only a real change may move it.
                if result == .changed {
                    state.meshCoreKeyGeneration += 1
                }
                switch result {
                case .invalid:
                    state.meshCoreKeyMessage = Self.invalidKeyMessage
                case .storageFailed:
                    state.meshCoreKeyMessage = Self.storageFailedMessage
                case .changed, .unchanged:
                    state.meshCoreKeyMessage = nil
                }
                return .none

            default:
                return .none
            }
        }
    }
}
