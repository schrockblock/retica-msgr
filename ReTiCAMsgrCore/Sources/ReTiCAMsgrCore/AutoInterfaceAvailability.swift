import Foundation

/// Where AutoInterface (zero-config LAN peering, spec 2026-11-10-autointerface) may run.
///
/// Logic reads these values through `AppFeature.State.autoInterfaceAvailable` and
/// `autoInterfaceStopsInBackground` instead of using `#if os(iOS)` itself, so tests (which run on
/// the Mac) can exercise the iOS behaviour. The same shape as `MeshCoreReleaseGate`.
public enum AutoInterfaceAvailability {
    /// iOS needs `com.apple.developer.networking.multicast` to send or receive multicast over BSD
    /// sockets (spec §8.1), and Apple grants it only on request. Without it AutoInterface can
    /// discover no one. Flip to true once Apple grants com.apple.developer.networking.multicast
    /// and the entitlement is added to `ReTiCAMsgr.entitlements` (spec §9 R1). Until then the iOS
    /// toggle is hidden and the slot is never created. macOS needs no entitlement.
    public static let isEntitledOniOS = false

    /// AutoInterface can run in this build on this platform: always on the Mac, on iOS only once
    /// entitled.
    public static var isAvailable: Bool {
        #if os(iOS)
        isEntitledOniOS
        #else
        true
        #endif
    }

    /// iOS has no background mode for UDP and may reclaim the sockets while suspended (spec §8.5),
    /// so the slot stops on `.backgrounded` and starts afresh on `.foregrounded`. The Mac app keeps
    /// running in the background and never stops it.
    public static var stopsInBackground: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}

/// What the AutoInterface slot has told the app (spec §6), for Settings and Diagnostics.
/// Session-only. Cleared when the app (re)starts the slot, since each start is a fresh session
/// whose interface reports again.
public struct AutoInterfaceNotices: Equatable, Sendable {
    /// NICs whose data port another program holds (on a Mac usually rnsd or NomadNet, spec §4.10).
    /// Read it through `AppFeature.State.autoInterfaceDataPortInUse`, which drops a NIC once its
    /// data socket has bound after all (the interface retries every peer-job tick, D3).
    public var dataPortInUse: Set<String> = []
    /// NICs on which no multicast echo ever arrived, or whose multicast join failed.
    public var multicastUnavailable: Set<String> = []
    /// NICs whose echoes stopped (`carrierLost`) and have not come back (`carrierRecovered`).
    public var carrierLost: Set<String> = []
    /// Denied-class send errors and no echo (spec §8.4): the local-network permission is off (or,
    /// on iOS, the multicast entitlement is missing). A slot in this state is excluded from
    /// `somethingWillDial`. Cleared by a peer appearing or a restart.
    public var localNetworkDenied = false

    public init() {}
}

/// The alert that points the user at the Local Network privacy setting.
public enum LocalNetworkAlert: Equatable, Sendable {
    /// The interface reported `.localNetworkDenied`.
    case denied
    /// No adopted NIC has heard its own multicast echo: on a Mac this is what a denied Local
    /// Network permission looks like when no send fails outright.
    case multicastUnavailable
}

/// The user-facing AutoInterface text, shared by Settings, the alert and Diagnostics.
public enum AutoInterfaceText {
    static var thisDevice: String {
        #if os(macOS)
        "this Mac"
        #else
        "this device"
        #endif
    }

    /// Where the Local Network permission lives on this platform.
    public static var localNetworkSettingsPath: String {
        #if os(macOS)
        "System Settings › Privacy & Security › Local Network"
        #else
        "Settings › Privacy & Security › Local Network"
        #endif
    }

    public static let toggleTitle = "Find devices on this network"

    /// The Settings caption, in the listener's style.
    public static let caption = "Finds other Reticulum devices on your local Wi-Fi or Ethernet "
        + "automatically and connects to them directly, with no server. Anyone on the same network "
        + "can reach this device. On by default."

    /// `.dataPortInUse` (spec §6, §9 R2): on a Mac, nearly always rnsd or NomadNet already running.
    /// A default rnsd or NomadNet config has no TCP server interface, so "add it as a node" alone
    /// would point at nothing: the copy gives the config that makes it true.
    public static var dataPortInUse: String {
        "Another Reticulum program on \(thisDevice) (for example rnsd or NomadNet) is already using "
            + "local discovery, so this app can’t. To use local discovery here, quit that program. "
            + "To keep it running and connect through it instead, give it a TCP server interface: add "
            + "[[TCP Server]] with type = TCPServerInterface, listen_ip = 127.0.0.1 and "
            + "listen_port = 4242 to its Reticulum config, restart it, then add 127.0.0.1:4242 as a node."
    }

    public static let noUsableInterfaces = "No Wi-Fi or Ethernet connection to search on."

    /// Spec §9 R5.
    public static let noPeersYet = "No devices found yet. If other Reticulum devices are on this "
        + "network, it may block device-to-device traffic, as guest and work Wi-Fi often do."

    public static var localNetworkDenied: String {
        "Local network access is off for ReTiCAMsgr, so it can’t find devices nearby. Turn it on "
            + "in \(localNetworkSettingsPath)."
    }

    public static let alertTitle = "Allow Local Network Access"

    public static func alertMessage(_ alert: LocalNetworkAlert) -> String {
        switch alert {
        case .denied:
            return "ReTiCAMsgr can’t reach devices on your local network. To find Reticulum devices "
                + "nearby, turn on local network access in \(localNetworkSettingsPath)."
        case .multicastUnavailable:
            return "ReTiCAMsgr can’t search your local network for Reticulum devices. If local "
                + "network access is off for it, turn it on in \(localNetworkSettingsPath)."
        }
    }
}
