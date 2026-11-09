import Foundation
import ReTiCAInterfaces

/// A radio section's own Connect button in Settings (`AppFeature.Action.radioConnectTapped`).
public enum RadioConnectButton: Equatable, Sendable {
    /// The radio won't dial (off, no radio chosen, Release gate closed, no MeshCore key, an RNode
    /// setting problem), or it is online with what Settings wants.
    case hidden
    /// Tappable: the radio is set up but stopped, unavailable or waiting on the user.
    case connect
    /// Shown disabled: the radio is dialling, or a swap is replacing its slot and will start it.
    case connecting
    /// Tappable: the slot is online or dialling, but Settings now wants something else (another
    /// radio, RNode parameters, a new MeshCore key). The tap's slot sync replaces it.
    case applyChanges
}

/// Where a radio slot is, reduced to what the button needs.
private enum SlotPhase { case none, idleOrFailed, connecting, online }

extension AppFeature.State {
    /// What a radio section's Connect button shows. Read from the slot itself: the status structs
    /// lag a swap, and only the interface knows it is still connecting. "Settings changed" is the
    /// exact comparison that radio's slot sync makes, so the button never offers a change the sync
    /// would ignore.
    public func radioConnectButton(_ kind: RadioKind) -> RadioConnectButton {
        let endpoint = node.client.endpoint
        switch kind {
        case .meshtastic:
            guard meshtasticWillDial else { return .hidden }
            if let swap = meshtasticSwap { return Self.swapButton(startNext: swap.startNext, hasNext: swap.next != nil) }
            let phase: SlotPhase
            switch endpoint.meshtastic?.interface.status {
            case .online: phase = .online
            case .connecting: phase = .connecting
            case .stopped, .unavailable: phase = .idleOrFailed
            case nil: phase = .none
            }
            return Self.slotButton(phase, changed: endpoint.meshtastic?.interface.config != meshtasticWantedConfig)
        case .meshCore:
            guard meshCoreWillDial else { return .hidden }
            if let swap = meshCoreSwap { return Self.swapButton(startNext: swap.startNext, hasNext: swap.next != nil) }
            let phase: SlotPhase
            switch endpoint.meshCore?.interface.status {
            case .online: phase = .online
            case .connecting: phase = .connecting
            case .stopped, .unavailable: phase = .idleOrFailed
            case nil: phase = .none
            }
            return Self.slotButton(phase, changed: meshCoreSlotIdentity != meshCoreWantedIdentity)
        case .rnode:
            guard rnodeWillDial else { return .hidden }
            if let swap = rnodeSwap { return Self.swapButton(startNext: swap.startNext, hasNext: swap.next != nil) }
            let phase: SlotPhase
            switch endpoint.rnode?.interface.status {
            case .online: phase = .online
            case .connecting: phase = .connecting
            case .stopped, .unavailable: phase = .idleOrFailed
            case nil: phase = .none
            }
            return Self.slotButton(phase, changed: endpoint.rnode?.interface.config != rnodeWantedConfig)
        }
    }

    /// A swap in flight: it will start the new slot (Connecting…), or a Disconnect left it stopped.
    private static func swapButton(startNext: Bool, hasNext: Bool) -> RadioConnectButton {
        startNext && hasNext ? .connecting : .connect
    }

    private static func slotButton(_ phase: SlotPhase, changed: Bool) -> RadioConnectButton {
        switch phase {
        case .none, .idleOrFailed: return .connect
        case .connecting: return changed ? .applyChanges : .connecting
        case .online: return changed ? .applyChanges : .hidden
        }
    }
}
