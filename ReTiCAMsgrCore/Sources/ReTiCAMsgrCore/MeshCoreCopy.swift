#if DEBUG
import Foundation

/// The MeshCore Settings section's user-facing text (spec 2026-11-07 §6). Debug-only, like the
/// section itself: lane E removes the gate. Says "this app", never the app's name, which is pending.
public enum MeshCoreCopy {
    public static let header = "MeshCore"
    public static let toggle = "Connect through a MeshCore radio"
    public static let radioRow = "Radio"
    public static let chooseRadio = "Choose radio…"

    public static let keyRow = "Channel key"
    public static let keySet = "Set"
    public static let keyNotSet = "Not set"
    public static let keyUnreadable = "Can't be read"
    public static let generateKey = "Generate key"
    public static let pasteKey = "Paste key…"
    public static let copyKey = "Copy key"
    public static let shareKey = "Share key…"

    public static let replaceTitle = "Replace the channel key?"
    public static let replaceMessage =
        "Everyone on the tunnel needs the new key. The old channel is removed from the radio at the next connection."
    public static let replaceButton = "Replace"
    public static let cancelButton = "Cancel"

    public static let requiredWarning =
        "Text messages waiting on the radio are removed when this app connects and won't reach the MeshCore app."

    public static let footer =
        "Sends and receives messages through a MeshCore radio paired with this device over Bluetooth. "
        + "This adds traffic to a shared radio network, so leave it off unless you need it. "
        + "Everyone on the tunnel needs the same channel key, so set one before turning this on. "
        + requiredWarning
        + " The radio must not be connected to another app, such as the MeshCore app, at the same time. "
        + "Choosing a radio pauses Bluetooth connections to nearby devices until the list closes. "
        + "Off by default. Turning this on, or changing the radio or key, takes effect on the next Connect."

    public static let turnOffNotice =
        "Turning this off removes this app's channel from the radio if it's connected. "
        + "If it isn't connected, the channel may stay on the radio, and you can remove it in the MeshCore app."

    public static let radioChangeNotice =
        "Choosing a different radio leaves this app's channel on the old radio. "
        + "You can remove it there with the MeshCore app."

    public static let noKeyNotice = "Set a channel key to turn this on."

    public static let channelLeftNotice =
        "This app couldn't remove its channel from the radio. You can remove it in the MeshCore app."

    public static let pasteTitle = "Paste Channel Key"
    public static let pastePrompt = "32 hex characters"
    public static let saveButton = "Save"

    public static let shareTitle = "Channel Key"
    public static let shareBody =
        "Anyone with this key can read and send on this tunnel. Share it only with people on the tunnel."

    /// Every string above, for the test that no copy names the app.
    public static let all: [String] = [
        header, toggle, radioRow, chooseRadio,
        keyRow, keySet, keyNotSet, keyUnreadable, generateKey, pasteKey, copyKey, shareKey,
        replaceTitle, replaceMessage, replaceButton, cancelButton,
        requiredWarning, footer, turnOffNotice, radioChangeNotice, noKeyNotice, channelLeftNotice,
        pasteTitle, pastePrompt, saveButton, shareTitle, shareBody,
    ]

    /// The channel key row's value for a presence.
    public static func keyValue(_ presence: MeshCoreKeyPresence) -> String {
        switch presence {
        case .present: return keySet
        case .absent: return keyNotSet
        case .unreadable: return keyUnreadable
        }
    }
}
#endif
