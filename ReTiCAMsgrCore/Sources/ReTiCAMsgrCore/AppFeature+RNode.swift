import Foundation
import ComposableArchitecture

// RNode settings (spec 2026-11-08 §6). Lane D reads `rnodeWillDial` and `rnodeSettings` at connect time.

extension AppFeature.State {
    /// The chosen radio, or nil when none is chosen OR the stored string is not a UUID: a hand-edited
    /// or corrupted default must read as "no radio", never as a radio to dial.
    public var rnodeRadioUUID: UUID? {
        rnodeRadioID.flatMap(UUID.init(uuidString:))
    }

    /// The Settings radio row: the name the radio advertised when it was picked, else its UUID,
    /// else "None".
    public var rnodeRadioLabel: String {
        guard let id = rnodeRadioUUID else { return "None" }
        let name = rnodeRadioName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? id.uuidString : name
    }

    /// The stored radio parameters as one value.
    public var rnodeSettings: RNodeRadioSettings {
        RNodeRadioSettings(frequencyHz: rnodeFrequencyHz, bandwidthHz: rnodeBandwidthHz,
                           spreadingFactor: rnodeSpreadingFactor, codingRate: rnodeCodingRate,
                           txPowerDBm: rnodeTXPowerDBm)
    }

    /// Text problems first, then range problems. A field with unreadable text gets that one message:
    /// an unreadable frequency is stored as nil, so its `.frequencyMissing` is left out, and an
    /// unreadable bandwidth's `.bandwidthOutOfRange` is about a stored value the field doesn't show.
    public var rnodeSettingsProblems: [RNodeSettingsProblem] {
        var range = rnodeSettings.problems
        if rnodeTextProblems.contains(.frequencyUnreadable) {
            range.removeAll { $0 == .frequencyMissing }
        }
        if rnodeTextProblems.contains(.bandwidthUnreadable) {
            range.removeAll { $0 == .bandwidthOutOfRange }
        }
        return rnodeTextProblems + range
    }

    /// Every condition an RNode slot needs to start. Stale defaults (restored from a backup, or left
    /// over from a Debug build) fail the gate or a problem check, so nothing dials.
    var rnodeWillDial: Bool {
        rnodeAvailable && rnodeEnabled && rnodeRadioUUID != nil && rnodeSettingsProblems.isEmpty
    }

    /// "Enter a frequency to turn this on." shows only for a plainly empty frequency: with a text
    /// problem standing, that problem's own message already says what to fix.
    public var rnodeIncompleteNoticeVisible: Bool {
        rnodeFrequencyHz == nil && rnodeTextProblems.isEmpty
    }

    /// Settings' RNode toggle can't be turned on while a problem stands, but can always be turned off.
    public var rnodeToggleDisabled: Bool {
        !rnodeEnabled && !rnodeSettingsProblems.isEmpty
    }
}

/// The RNode settings arms of `AppFeature` (spec 2026-11-08 §6), composed into `AppFeature.body` after
/// `MeshCoreSettingsReducer`. The main reducer treats these actions as no-ops. Editing only writes
/// defaults: nothing reaches a running radio until the next Connect, so no arm returns an effect.
struct RNodeSettingsReducer: Reducer {
    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            switch action {
            case let .rnodeFrequencyTextChanged(text):
                if let hz = RNodeRadioSettings.parseMegahertz(text) {
                    state.$rnodeFrequencyHz.withLock { $0 = hz }
                    Self.setTextProblem(.frequencyUnreadable, false, in: &state)
                } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Blank is not unreadable: `.frequencyMissing` reports it.
                    state.$rnodeFrequencyHz.withLock { $0 = nil }
                    Self.setTextProblem(.frequencyUnreadable, false, in: &state)
                } else {
                    state.$rnodeFrequencyHz.withLock { $0 = nil }
                    Self.setTextProblem(.frequencyUnreadable, true, in: &state)
                }
                return .none

            case let .rnodeBandwidthTextChanged(text):
                // Bandwidth always has a value, so unreadable text (blank included) keeps the stored one.
                if let hz = RNodeRadioSettings.parseKilohertz(text) {
                    state.$rnodeBandwidthHz.withLock { $0 = hz }
                    Self.setTextProblem(.bandwidthUnreadable, false, in: &state)
                } else {
                    Self.setTextProblem(.bandwidthUnreadable, true, in: &state)
                }
                return .none

            // The view's steppers bound these; a stale stored value is caught by `problems`.
            case let .rnodeSpreadingFactorChanged(value):
                state.$rnodeSpreadingFactor.withLock { $0 = value }
                return .none

            case let .rnodeCodingRateChanged(value):
                state.$rnodeCodingRate.withLock { $0 = value }
                return .none

            case let .rnodeTXPowerChanged(value):
                state.$rnodeTXPowerDBm.withLock { $0 = value }
                return .none

            default:
                return .none
            }
        }
    }

    /// Adds or drops one text problem, keeping the list in field order.
    private static func setTextProblem(_ problem: RNodeSettingsProblem, _ present: Bool,
                                       in state: inout AppFeature.State) {
        let current = state.rnodeTextProblems
        state.rnodeTextProblems = RNodeSettingsProblem.allCases.filter {
            $0 == problem ? present : current.contains($0)
        }
    }
}
