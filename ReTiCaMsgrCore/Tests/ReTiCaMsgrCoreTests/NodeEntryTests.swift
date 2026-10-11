import Testing
import Foundation
import ReTiCATransport
@testable import ReTiCaMsgrCore

private let hexA = String(repeating: "a1", count: 16)
private let hexB = String(repeating: "b2", count: 16)
private let defaultHex = "ef92bcaeb90947a9fc2228affabdce13"

private func nodeID(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
}

private func withoutHex(_ entry: NodeEntry) -> NodeEntry {
    var entry = entry
    entry.pushHubHex = nil
    return entry
}

/// A deterministic id source for the migration: 100, 101, …
private final class IDs {
    var next = 100
    func make() -> UUID { defer { next += 1 }; return nodeID(next) }
}

private func migrate(_ host: String, _ port: Int, _ hex: String) -> [NodeEntry] {
    let ids = IDs()
    return NodeMigration.migrate(legacyHost: host, legacyPort: port, legacyPushHex: hex, makeID: ids.make)
}

// MARK: - NodeEntry

@Test func nodeEntryJSONRoundTripAndInterfaceID() throws {
    let withHex = NodeEntry(id: nodeID(1), name: "Pi", host: "pi.local", port: 4243, enabled: true,
                            isBuiltIn: false, pushHubHex: hexA)
    let withoutHex = NodeEntry(id: nodeID(2), name: "Other", host: "o.example", port: 1, enabled: false)
    let encoded = try JSONEncoder().encode([withHex, withoutHex])
    let decoded = try JSONDecoder().decode([NodeEntry].self, from: encoded)
    #expect(decoded == [withHex, withoutHex])
    #expect(withHex.interfaceID == InterfaceID("tcp:pi.local:4243"))
    #expect(withHex.hostPort == "pi.local:4243")
}

@Test func nodeEntryDefaultHasTheFixedIdHostPortAndHex() {
    let entry = DefaultNode.entry
    #expect(entry.id == UUID(uuidString: "6E0DE000-0000-4000-8000-000000000001"))
    #expect(entry.name == "Gaefu")
    #expect(entry.host == "gaefu.ddns.net")
    #expect(entry.port == 4242)
    #expect(entry.pushHubHex == defaultHex)
    #expect(entry.isBuiltIn == true)
    #expect(entry.enabled == true)
    #expect(entry.interfaceID == InterfaceID("tcp:gaefu.ddns.net:4242"))
    #expect(DefaultNode.propagationHex == nil)
}

// MARK: - NodeRules

@Test func nodeRulesValidationRejectsEmptyHostBadPortsAndShortHex() {
    #expect(NodeRules.validationError(host: "   ", port: 4242, pushHubHex: nil) == .emptyHost)
    #expect(NodeRules.validationError(host: "h", port: 0, pushHubHex: nil) == .portOutOfRange)
    #expect(NodeRules.validationError(host: "h", port: 70000, pushHubHex: nil) == .portOutOfRange)
    #expect(NodeRules.validationError(host: "h", port: 4242, pushHubHex: String(hexA.dropLast())) == .invalidPushHex)
    #expect(NodeRules.validationError(host: "h", port: 4242, pushHubHex: "zz" + String(hexA.dropFirst(2))) == .invalidPushHex)
    #expect(NodeRules.validationError(host: "h", port: 4242, pushHubHex: nil) == nil)
    #expect(NodeRules.validationError(host: " h ", port: 65535, pushHubHex: "  ") == nil, "blank hex means none")
    #expect(NodeRules.validationError(host: "h", port: 1, pushHubHex: hexA.uppercased()) == nil)
    let normalized = NodeRules.normalized(host: " h ", pushHubHex: " \(hexA.uppercased()) ")
    #expect(normalized.host == "h")
    #expect(normalized.pushHubHex == hexA)
    #expect(NodeRules.normalized(host: "h", pushHubHex: "").pushHubHex == nil)
}

@Test func nodeRulesOnePushNodeClearsEveryOtherHex() {
    let builtIn = DefaultNode.entry
    let user = NodeEntry(id: nodeID(1), name: "Pi", host: "pi.local", port: 4243, pushHubHex: hexA)
    let kept = NodeRules.enforceOnePushNode([builtIn, user], keeping: user.id)
    #expect(kept[0].pushHubHex == nil)
    #expect(kept[1].pushHubHex == hexA)
    // Keeping an entry WITHOUT a hex changes nothing.
    let plain = NodeEntry(id: nodeID(2), name: "P", host: "p", port: 1)
    #expect(NodeRules.enforceOnePushNode([builtIn, plain], keeping: plain.id) == [builtIn, plain])
}

/// Amendment A13 (F2): with no entry carrying a push hex, the built-in entry regains the shipped
/// default — but only then. A disabled entry that still carries a hex counts as carrying one.
@Test func nodeFinalRestoringDefaultHexOnlyWhenNoneCarriesOne() {
    let builtIn = withoutHex(DefaultNode.entry)

    let userNoHex = NodeEntry(id: nodeID(1), name: "U", host: "u.example", port: 1, pushHubHex: nil)
    let restored = NodeRules.restoringDefaultPushHex([builtIn, userNoHex])
    #expect(restored[0].pushHubHex == defaultHex)
    #expect(restored[1].pushHubHex == nil)

    let userWithHex = NodeEntry(id: nodeID(2), name: "U", host: "u.example", port: 1, pushHubHex: hexA)
    #expect(NodeRules.restoringDefaultPushHex([builtIn, userWithHex]) == [builtIn, userWithHex])

    let disabledUserWithHex = NodeEntry(id: nodeID(3), name: "U", host: "u.example", port: 1,
                                        enabled: false, pushHubHex: hexA)
    #expect(NodeRules.restoringDefaultPushHex([builtIn, disabledUserWithHex]) == [builtIn, disabledUserWithHex])
}

@Test func nodeRulesPushNodeIsTheEnabledEntryWithAHex() {
    let disabledWithHex = NodeEntry(id: nodeID(1), name: "A", host: "a", port: 1, enabled: false, pushHubHex: hexA)
    let enabledWithout = NodeEntry(id: nodeID(2), name: "B", host: "b", port: 1, enabled: true)
    #expect(NodeRules.pushNode(in: [disabledWithHex, enabledWithout]) == nil)
    let enabledWith = NodeEntry(id: nodeID(3), name: "C", host: "c", port: 1, enabled: true, pushHubHex: hexB)
    #expect(NodeRules.pushNode(in: [disabledWithHex, enabledWithout, enabledWith]) == enabledWith)
}

// MARK: - NodeMigration

@Test func nodeMigrateCustomHostBecomesAUserEntryAndTakesTheCustomHex() {
    let entries = migrate("node.example", 4243, hexA)
    #expect(entries.count == 2)
    #expect(entries[0] == NodeEntry(id: DefaultNode.id, name: "Gaefu", host: "gaefu.ddns.net", port: 4242,
                                    enabled: true, isBuiltIn: true, pushHubHex: nil))
    #expect(entries[1] == NodeEntry(id: nodeID(100), name: "node.example", host: "node.example", port: 4243,
                                    enabled: true, isBuiltIn: false, pushHubHex: hexA))
}

@Test func nodeMigrateSkipsTheLegacyLoopbackAndKeepsTheDefaultHex() {
    #expect(migrate("127.0.0.1", 4242, "") == [DefaultNode.entry])
}

@Test func nodeMigrateCustomHexWithTheDefaultHostAttachesToTheBuiltInEntry() {
    var expected = DefaultNode.entry
    expected.pushHubHex = hexA
    #expect(migrate("gaefu.ddns.net", 4242, hexA) == [expected])
}

@Test func nodeMigrateCustomHexWithLoopbackCreatesAnOwnEntry() {
    let entries = migrate("127.0.0.1", 4242, hexA)
    #expect(entries.count == 2)
    #expect(entries[0].pushHubHex == nil)
    #expect(entries[1] == NodeEntry(id: nodeID(100), name: "127.0.0.1:4242", host: "127.0.0.1", port: 4242,
                                    enabled: true, isBuiltIn: false, pushHubHex: hexA))
}

@Test func nodeMigrateDefaultHexIsNotTreatedAsCustom() {
    let entries = migrate("node.example", 4243, defaultHex)
    #expect(entries.count == 2)
    #expect(entries[0].pushHubHex == defaultHex, "the built-in entry keeps its hex")
    #expect(entries[1].pushHubHex == nil)
}

@Test func nodeMigrateInvalidHexIsDropped() {
    let entries = migrate("node.example", 4243, String(hexA.dropLast()))
    #expect(entries.count == 2)
    #expect(entries[0].pushHubHex == defaultHex)
    #expect(entries[1].pushHubHex == nil)
}
