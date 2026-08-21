import Foundation
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport

/// A read-only, point-in-time view of the app's networking state, arranged as layers so the
/// question "which layer is broken?" has a single visible answer.
///
/// **Pure by construction.** Everything is derived from `AppFeature.State` plus an injected
/// date; nothing here reads a clock, touches the network, or mutates. That is what makes the
/// health rules and the shareable `text` unit-testable.
///
/// **Fields are listed by hand, never reflected.** `LinkSession.State` carries `sessionKey` and
/// an `ephemeral` keypair, and `text` is designed to be pasted into bug reports. A `Mirror`-based
/// or "render every property" implementation would leak session keys the first time someone
/// added a field. A test pins this.
public struct DiagnosticsSnapshot: Equatable {
    public enum Health: Equatable { case ok, warn, problem }

    public struct Row: Equatable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Layer: Equatable {
        public let title: String
        public let health: Health
        /// Why the layer is not `.ok`. Always nil when `.ok`, always non-nil otherwise —
        /// a status without a stated reason is the thing this screen exists to avoid.
        public let reason: String?
        public let rows: [Row]
    }

    public let generatedAt: Date
    public let layers: [Layer]

    public init(from state: AppFeature.State, at date: Date) {
        self.generatedAt = date
        self.layers = [
            Self.socketLayer(state),
            Self.identityLayer(state),
        ]
    }
}

// MARK: - Socket

extension DiagnosticsSnapshot {
    static func socketLayer(_ state: AppFeature.State) -> Layer {
        let endpoint = state.node.client.endpoint
        let interfaces = endpoint.interfaces

        var status = "n/a"
        var dialing = "n/a"
        if case let .tcp(tcp) = endpoint {
            status = describe(tcp.interface.status)
            dialing = "\(tcp.interface.host):\(tcp.interface.port)"
        }
        let app = describe(state.connection)

        let rows = [
            Row("app connection", app),
            Row("interface status", status),
            Row("dialing", dialing),
            Row("interfaces", interfaces.isEmpty
                 ? "(none)"
                 : interfaces
                    .map { "\($0.key.rawValue) (\($0.value.name))" }
                    .sorted()
                    .joined(separator: ", ")),
        ]

        // Order matters: a disagreement must be reported AS a disagreement rather than being
        // masked by the milder "connecting" rule below it.
        let interfaceOnline = status == "online"
        if (app == "connected") != interfaceOnline {
            return Layer(title: "Socket", health: .problem,
                         reason: "app reports \(app), interface reports \(status)", rows: rows)
        }
        if interfaceOnline && interfaces.isEmpty {
            return Layer(title: "Socket", health: .problem,
                         reason: "socket is up but Transport has no registered interface", rows: rows)
        }
        if app == "connecting" {
            return Layer(title: "Socket", health: .warn, reason: "connecting", rows: rows)
        }
        if app == "disconnected" {
            return Layer(title: "Socket", health: .warn, reason: "disconnected", rows: rows)
        }
        return Layer(title: "Socket", health: .ok, reason: nil, rows: rows)
    }

    static func describe(_ status: TCPClientInterface.Status) -> String {
        switch status {
        case .disconnected: return "disconnected"
        case .connecting:   return "connecting"
        case .online:       return "online"
        }
    }

    static func describe(_ connection: AppFeature.Connection) -> String {
        switch connection {
        case .disconnected: return "disconnected"
        case .connecting:   return "connecting"
        case .connected:    return "connected"
        }
    }
}

// MARK: - Identity

extension DiagnosticsSnapshot {
    static func identityLayer(_ state: AppFeature.State) -> Layer {
        let registered = state.node.client.deliveryDestinationHash != nil
        let rows = [
            Row("address", state.myAddressHex),
            Row("display name", state.displayName.isEmpty ? "(unset)" : state.displayName),
            Row("delivery registered", registered ? "yes" : "no"),
            Row("node mode", state.nodeModeEnabled ? "on" : "off"),
        ]
        guard registered else {
            return Layer(title: "Identity", health: .problem,
                         reason: "no delivery destination registered — nothing can reach us",
                         rows: rows)
        }
        return Layer(title: "Identity", health: .ok, reason: nil, rows: rows)
    }
}
