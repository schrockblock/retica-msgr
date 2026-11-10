import Foundation
import ReTiCAInterfaces

/// The status light on a radio section's Radio row in Settings: whether that radio is connected,
/// at a glance.
public enum RadioLight: Equatable, Sendable {
    /// The radio is off, has no radio chosen, or is stopped (not yet connected, or Disconnect).
    case off
    /// Dialling, or a swap is replacing its slot and will start the new one.
    case connecting
    /// The radio finished its handshake.
    case connected
    /// The radio reported itself unavailable: Bluetooth off or denied, not paired, rejected
    /// settings, and so on. The section's red note says which.
    case problem

    /// Read aloud for the light, which has no text of its own.
    public var accessibilityText: String {
        switch self {
        case .off: return "Not connected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .problem: return "Can’t connect"
        }
    }
}

private enum SlotLight {
    /// A swap in flight: it will start the new slot, or a Disconnect left it stopped.
    static func swap(startNext: Bool, hasNext: Bool) -> RadioLight { startNext && hasNext ? .connecting : .off }
}

extension AppFeature.State {
    /// The radio's status light. Read from the slot itself, like `radioConnectButton`: the status
    /// structs lag a swap.
    public func radioLight(_ kind: RadioKind) -> RadioLight {
        let endpoint = node.client.endpoint
        switch kind {
        case .meshtastic:
            guard meshtasticWillDial else { return .off }
            if let swap = meshtasticSwap { return SlotLight.swap(startNext: swap.startNext, hasNext: swap.next != nil) }
            guard let status = endpoint.meshtastic?.interface.status else { return .off }
            switch status {
            case .online: return .connected
            case .connecting: return .connecting
            case .unavailable: return .problem
            case .stopped: return .off
            }
        case .meshCore:
            guard meshCoreWillDial else { return .off }
            if let swap = meshCoreSwap { return SlotLight.swap(startNext: swap.startNext, hasNext: swap.next != nil) }
            guard let status = endpoint.meshCore?.interface.status else { return .off }
            switch status {
            case .online: return .connected
            case .connecting: return .connecting
            case .unavailable: return .problem
            case .stopped: return .off
            }
        case .rnode:
            guard rnodeWillDial else { return .off }
            if let swap = rnodeSwap { return SlotLight.swap(startNext: swap.startNext, hasNext: swap.next != nil) }
            guard let status = endpoint.rnode?.interface.status else { return .off }
            switch status {
            case .online: return .connected
            case .connecting: return .connecting
            case .unavailable: return .problem
            case .stopped: return .off
            }
        }
    }
}
