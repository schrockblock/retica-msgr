import Foundation
import Testing
import ReTiCaMsgrCore
@testable import ReTiCaMsgr

/// Repo root from this file's path (…/ReTiCaMsgrTests/TestHostScanTests.swift).
private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

private func swiftFiles(under folder: String) throws -> [(String, String)] {
    let dir = repoRoot.appendingPathComponent(folder)
    let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    return try items.filter { $0.pathExtension == "swift" }.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
}

@Test func testHostScanOnlyTheHelperSetsTheFlag() throws {
    var setters: [String] = []
    var readers: [String] = []
    for folder in ["ReTiCaMsgr", "ReTiCaMsgrTests", "ReTiCaMsgrUITests"] {
        for (name, source) in try swiftFiles(under: folder) {
            if source.contains("launchEnvironment") { setters.append("\(folder)/\(name)") }
            if source.contains("RETICAMSGR_TEST_HOST") { readers.append("\(folder)/\(name)") }
        }
    }
    // This file names both strings in its own source, so it appears in both lists.
    #expect(Set(setters) == ["ReTiCaMsgrUITests/TestApp.swift", "ReTiCaMsgrTests/TestHostScanTests.swift"])
    #expect(Set(readers) == ["ReTiCaMsgr/AppRuntime.swift", "ReTiCaMsgrUITests/TestApp.swift", "ReTiCaMsgrTests/TestHostScanTests.swift"])
}

@Test func testHostScanEntitlementsNameTheSharedGroup() throws {
    let url = repoRoot.appendingPathComponent("ReTiCaMsgr/ReTiCaMsgr.entitlements")
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
    let groups = plist?["keychain-access-groups"] as? [String]
    #expect(groups == ["$(AppIdentifierPrefix)co.lithobyte.reticulum.identity"])
    #expect(SharedIdentityLocation.accessGroup == "HK6WSAR793.co.lithobyte.reticulum.identity")
    #expect(SharedIdentityLocation.accessGroup.hasSuffix(String(groups![0].dropFirst("$(AppIdentifierPrefix)".count))))
    let tests = repoRoot.appendingPathComponent("ReTiCaMsgrTests/ReTiCaMsgrTests.entitlements")
    let testPlist = try PropertyListSerialization.propertyList(from: Data(contentsOf: tests), format: nil) as? [String: Any]
    #expect(testPlist?["keychain-access-groups"] as? [String] == groups)
}
