import Foundation

/// Builds the first node list from the pre-nodes settings (spec §2 "Upgrade migration"). Pure:
/// the reducer supplies the legacy values, the default entry and the id source, and persists the
/// result. Runs once, when the persisted list is empty (amendment A5).
public enum NodeMigration {
    /// What the old `host`/`port` keys defaulted to: a local rnsd nobody has on a phone.
    public static let legacyDefaultHost = "127.0.0.1"
    public static let legacyDefaultPort = 4242

    public static func migrate(legacyHost: String, legacyPort: Int, legacyPushHex: String,
                               defaultEntry: NodeEntry = DefaultNode.entry,
                               makeID: () -> UUID) -> [NodeEntry] {
        var entries = [defaultEntry]
        let (host, hex) = NodeRules.normalized(host: legacyHost, pushHubHex: legacyPushHex)
        let targetIsUsable = !host.isEmpty && NodeRules.portRange.contains(legacyPort)
        let targetIsDefault = host == defaultEntry.host && legacyPort == defaultEntry.port
        let targetIsLoopback = host == legacyDefaultHost && legacyPort == legacyDefaultPort

        // Step 2: a custom host becomes a user entry named after the host.
        let hasCustomHost = targetIsUsable && !targetIsDefault && !targetIsLoopback
        if hasCustomHost {
            entries.append(NodeEntry(id: makeID(), name: host, host: host, port: legacyPort, enabled: true))
        }

        // Step 3: a custom, valid hex is attached to exactly one entry.
        guard let hex, NodeRules.isValidPushHex(hex),
              hex != defaultEntry.pushHubHex?.lowercased()
        else { return entries }
        if hasCustomHost {
            entries[1].pushHubHex = hex
            return NodeRules.enforceOnePushNode(entries, keeping: entries[1].id)
        }
        if targetIsDefault {
            // The user's hub is the default node itself: their hex replaces the shipped one.
            entries[0].pushHubHex = hex
            return entries
        }
        guard targetIsUsable else { return entries }
        // The legacy loopback target with a custom hub: a node of the user's own.
        let own = NodeEntry(id: makeID(), name: "\(host):\(legacyPort)", host: host, port: legacyPort,
                            enabled: true, pushHubHex: hex)
        entries.append(own)
        return NodeRules.enforceOnePushNode(entries, keeping: own.id)
    }
}
