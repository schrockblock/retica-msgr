import Foundation
import ReTiCATransport

/// One TCP node the app dials (spec 2026-10-10 §2). The built-in entry is `DefaultNode.entry`;
/// it can be disabled but never edited or deleted. Persisted as a JSON array (`nodes.json`).
public struct NodeEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var enabled: Bool
    public var isBuiltIn: Bool
    /// The node's push-hub registration destination (32 hex) when this node is a push hub. At
    /// most one entry carries one (`NodeRules.enforceOnePushNode`).
    public var pushHubHex: String?

    public init(id: UUID, name: String, host: String, port: Int, enabled: Bool = true,
                isBuiltIn: Bool = false, pushHubHex: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.enabled = enabled
        self.isBuiltIn = isBuiltIn
        self.pushHubHex = pushHubHex
    }

    /// The endpoint slot id for this node: "is this node up" is `transport.interfaces[interfaceID]`.
    public var interfaceID: InterfaceID { InterfaceID("tcp:\(host):\(port)") }

    public var hostPort: String { "\(host):\(port)" }
}

public enum NodeValidationError: Equatable, Sendable {
    case emptyHost
    case portOutOfRange
    case invalidPushHex
}

/// The node-list rules of spec §2 "Rules", as pure functions so the reducer and the form agree.
public enum NodeRules {
    public static let portRange = 1...65535
    public static let pushHexLength = 32

    /// Trimmed host; trimmed, lowercased hex, nil when blank.
    public static func normalized(host: String, pushHubHex: String?) -> (host: String, pushHubHex: String?) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = pushHubHex?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return (host, hex.isEmpty ? nil : hex)
    }

    public static func isValidPushHex(_ hex: String) -> Bool {
        hex.count == pushHexLength && hex.allSatisfy(\.isHexDigit)
    }

    /// The first failing rule, or nil when the (normalized) node is valid.
    public static func validationError(host: String, port: Int, pushHubHex: String?) -> NodeValidationError? {
        let (host, hex) = normalized(host: host, pushHubHex: pushHubHex)
        if host.isEmpty { return .emptyHost }
        if !portRange.contains(port) { return .portOutOfRange }
        if let hex, !isValidPushHex(hex) { return .invalidPushHex }
        return nil
    }

    /// One push node: when the entry `id` carries a hex, every other entry's hex is cleared.
    public static func enforceOnePushNode(_ entries: [NodeEntry], keeping id: UUID) -> [NodeEntry] {
        guard entries.first(where: { $0.id == id })?.pushHubHex != nil else { return entries }
        return entries.map { entry in
            var entry = entry
            if entry.id != id { entry.pushHubHex = nil }
            return entry
        }
    }

    /// The push node: the enabled entry that carries a push hex.
    public static func pushNode(in entries: [NodeEntry]) -> NodeEntry? {
        entries.first { $0.enabled && $0.pushHubHex != nil }
    }

    /// Amendment A13: with no push hex anywhere, the built-in entry gets the shipped default back.
    public static func restoringDefaultPushHex(_ entries: [NodeEntry], defaultHex: String = DefaultNode.pushHubHex) -> [NodeEntry] {
        guard !entries.contains(where: { $0.pushHubHex != nil }) else { return entries }
        return entries.map { entry in
            var entry = entry
            if entry.isBuiltIn { entry.pushHubHex = defaultHex }
            return entry
        }
    }
}
