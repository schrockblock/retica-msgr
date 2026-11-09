#if DEBUG
import Foundation

/// The RNode Settings section's user-facing text (spec 2026-11-08 §6). Debug-only, like the section
/// itself: lane E removes the gate. Says "this app", never the app's name, which is pending.
public enum RNodeCopy {
    public static let header = "RNode"
    public static let toggle = "Connect through an RNode"
    public static let radioRow = "Radio"
    public static let chooseRadio = "Choose radio…"
    /// The section's own Connect button (`radioConnectTapped(.rnode)`), and its label while dialling.
    public static let connectButton = "Connect RNode"
    public static let connecting = "Connecting…"

    /// The footer's last sentence: what applies a change.
    public static let changesApply =
        "Changes take effect when you tap Connect RNode or Connect, and again whenever this app "
        + "reconnects by itself, like when you come back to it or a notification wakes it."

    public static let frequencyRow = "Frequency (MHz)"
    public static let frequencyPrompt = "Required, e.g. 868.1"
    public static let bandwidthRow = "Bandwidth (kHz)"
    public static let spreadingFactorRow = "Spreading factor"
    public static let codingRateRow = "Coding rate"
    public static let txPowerRow = "TX power (dBm)"

    public static let incompleteNotice = "Enter a frequency to turn this on."

    public static let frequencyMissing = "Enter a frequency."
    public static let frequencyUnreadable = "Enter the frequency in MHz, like 868.1."
    public static let frequencyOutOfRange = "Enter a frequency between 137 and 3000 MHz."
    public static let bandwidthUnreadable = "Enter the bandwidth in kHz, like 62.5."
    public static let bandwidthOutOfRange = "Enter a bandwidth between 7.8 and 1625 kHz."
    public static let spreadingFactorOutOfRange = "Use a spreading factor from 5 to 12."
    public static let codingRateOutOfRange = "Use a coding rate from 5 to 8."
    public static let txPowerOutOfRange = "Use a TX power from 0 to 37 dBm. Your radio may allow less."

    public static let boardsNotice =
        "Works with RNodes that have Bluetooth LE: Heltec V3 and V4, LilyGO T3S3, T-Deck and T-Beam Supreme, "
        + "Seeed XIAO S3, RAK4631, LilyGO T-Echo and Heltec T114. RNodes with only Classic Bluetooth, such as "
        + "the original T-Beam, LoRa32, Heltec V2 and RNode NG, can't connect to this device."

    public static let pairingNotice =
        "To pair, hold the RNode's button for 5 to 10 seconds until it shows a PIN, then tap Connect RNode and "
        + "enter that PIN when asked. The RNode drops the connection once after pairing, and this app "
        + "reconnects by itself. An RNode without a screen can't show its PIN here."

    public static let footer =
        "Sends and receives messages over LoRa through an RNode paired with this device over Bluetooth. "
        + "This app sets the radio's frequency, bandwidth, spreading factor, coding rate and TX power every "
        + "time it connects. Everyone you want to reach must use the same frequency, bandwidth, spreading "
        + "factor and coding rate. You're responsible for using settings that are legal where you are. "
        + "The radio must not be connected to another app, such as Sideband, at the same time. "
        + "Choosing a radio pauses Bluetooth connections to nearby devices until the list closes. "
        + "Off by default. " + changesApply

    /// The message under the fields for a problem. Exhaustive: a new case fails to compile until it has copy.
    public static func problemMessage(_ problem: RNodeSettingsProblem) -> String {
        switch problem {
        case .frequencyMissing: return frequencyMissing
        case .frequencyUnreadable: return frequencyUnreadable
        case .frequencyOutOfRange: return frequencyOutOfRange
        case .bandwidthUnreadable: return bandwidthUnreadable
        case .bandwidthOutOfRange: return bandwidthOutOfRange
        case .spreadingFactorOutOfRange: return spreadingFactorOutOfRange
        case .codingRateOutOfRange: return codingRateOutOfRange
        case .txPowerOutOfRange: return txPowerOutOfRange
        }
    }

    /// Every string above, for the test that no copy names the app.
    public static let all: [String] = [
        header, toggle, radioRow, chooseRadio, connectButton, connecting, changesApply,
        frequencyRow, frequencyPrompt, bandwidthRow, spreadingFactorRow, codingRateRow, txPowerRow,
        incompleteNotice,
        frequencyMissing, frequencyUnreadable, frequencyOutOfRange, bandwidthUnreadable,
        bandwidthOutOfRange, spreadingFactorOutOfRange, codingRateOutOfRange, txPowerOutOfRange,
        boardsNotice, pairingNotice, footer,
    ]
}
#endif
