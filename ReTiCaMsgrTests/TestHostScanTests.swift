import Foundation
import Testing
import ReTiCaMsgrCore
@testable import ReTiCaMsgr

/// Repo root from this file's path (…/ReTiCaMsgrTests/TestHostScanTests.swift).
private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// Recursive, so a future subfolder in a target is not skipped silently. The returned name is the
/// path relative to `folder` (e.g. "Views/Foo.swift"; a top-level file is just its own name).
private func swiftFiles(under folder: String) throws -> [(String, String)] {
    let dir = repoRoot.appendingPathComponent(folder)
    let base = dir.path
    guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    var results: [(String, String)] = []
    for case let url as URL in enumerator {
        guard url.pathExtension == "swift" else { continue }
        var relative = url.path
        if relative.hasPrefix(base + "/") {
            relative = String(relative.dropFirst(base.count + 1))
        }
        results.append((relative, try String(contentsOf: url, encoding: .utf8)))
    }
    return results
}

@Test func testHostScanOnlyTheHelperSetsTheFlag() throws {
    var setters: [String] = []
    var readers: [String] = []
    var launchers: [String] = []
    for folder in ["ReTiCaMsgr", "ReTiCaMsgrTests", "ReTiCaMsgrUITests"] {
        for (name, source) in try swiftFiles(under: folder) {
            if source.contains("launchEnvironment") { setters.append("\(folder)/\(name)") }
            if source.contains("RETICAMSGR_TEST_HOST") { readers.append("\(folder)/\(name)") }
            if source.contains("XCUIApplication(") { launchers.append("\(folder)/\(name)") }
        }
    }
    // This file names all three strings in its own source, so it appears in every list.
    #expect(Set(setters) == ["ReTiCaMsgrUITests/TestApp.swift", "ReTiCaMsgrTests/TestHostScanTests.swift"])
    #expect(Set(readers) == ["ReTiCaMsgr/AppRuntime.swift", "ReTiCaMsgrUITests/TestApp.swift", "ReTiCaMsgrTests/TestHostScanTests.swift"])
    // M4: a UI test that launches `XCUIApplication()` directly bypasses `TestApp.make()` and its
    // flag, so the app would run against the real Keychain. Pin who is allowed to launch it.
    #expect(Set(launchers) == ["ReTiCaMsgrUITests/TestApp.swift", "ReTiCaMsgrTests/TestHostScanTests.swift"])
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
