import Foundation
import ComposableArchitecture

/// The developer's hub, shipped as the built-in node (spec 2026-10-10 §2 "DefaultNode").
public enum DefaultNode {
    public static let id = UUID(uuidString: "6E0DE000-0000-4000-8000-000000000001")!
    public static let name = "Gaefu"
    public static let host = "gaefu.ddns.net"
    public static let port = 4242
    /// Gaefu's push registration destination (post 2026-10-03), confirmed 2026-10-10.
    public static let pushHubHex = "ef92bcaeb90947a9fc2228affabdce13"
    /// Gaefu's propagation node's LXMF address, once its `lxmd` announces. nil until then; while
    /// nil the "use the default's propagation node" toggle has no effect and is not shown.
    public static let propagationHex: String? = nil

    public static var entry: NodeEntry {
        NodeEntry(id: id, name: name, host: host, port: port, enabled: true, isBuiltIn: true,
                  pushHubHex: pushHubHex)
    }
}

/// `DefaultNode.propagationHex` as a dependency (spec amendment A9), so the reducer's toggle rule
/// can be tested with and without a default. Live: the constant. Test: nil.
public enum DefaultPropagationHexKey: DependencyKey {
    public static let liveValue: String? = DefaultNode.propagationHex
    public static let testValue: String? = nil
}

extension DependencyValues {
    public var defaultPropagationHex: String? {
        get { self[DefaultPropagationHexKey.self] }
        set { self[DefaultPropagationHexKey.self] = newValue }
    }
}
