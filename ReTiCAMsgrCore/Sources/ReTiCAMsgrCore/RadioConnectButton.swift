import Foundation
import ReTiCAInterfaces

/// A radio section's own Connect button in Settings (`AppFeature.Action.radioConnectTapped`).
public enum RadioConnectButton: Equatable, Sendable {
    /// The radio won't dial (off, no radio chosen, Release gate closed, no MeshCore key, an RNode
    /// setting problem), or it is online.
    case hidden
    /// Tappable: the radio is set up but stopped, unavailable or waiting on the user.
    case connect
    /// Shown disabled: the radio is dialling, or a swap is replacing its slot and will start it.
    case connecting
}

extension AppFeature.State {
    /// What a radio section's Connect button shows. Read from the slot itself: the status structs
    /// lag a swap, and only the interface knows it is still connecting.
    public func radioConnectButton(_ kind: RadioKind) -> RadioConnectButton {
        let endpoint = node.client.endpoint
        switch kind {
        case .meshtastic:
            guard meshtasticWillDial else { return .hidden }
            if let swap = meshtasticSwap { return swap.startNext && swap.next != nil ? .connecting : .connect }
            switch endpoint.meshtastic?.interface.status {
            case .online: return .hidden
            case .connecting: return .connecting
            case .stopped, .unavailable, nil: return .connect
            }
        case .meshCore:
            guard meshCoreWillDial else { return .hidden }
            if let swap = meshCoreSwap { return swap.startNext && swap.next != nil ? .connecting : .connect }
            switch endpoint.meshCore?.interface.status {
            case .online: return .hidden
            case .connecting: return .connecting
            case .stopped, .unavailable, nil: return .connect
            }
        case .rnode:
            guard rnodeWillDial else { return .hidden }
            if let swap = rnodeSwap { return swap.startNext && swap.next != nil ? .connecting : .connect }
            switch endpoint.rnode?.interface.status {
            case .online: return .hidden
            case .connecting: return .connecting
            case .stopped, .unavailable, nil: return .connect
            }
        }
    }
}
