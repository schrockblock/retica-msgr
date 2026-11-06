import Foundation
import Testing
import Security
import GRDB
import SQLiteData
import ReTiCA
import ReTiCAKeychain
import ReTiCAPushCore
import ReTiCAMsgrCore
@testable import ReTiCAMsgr

private let shared = SharedIdentityLocation.shared

@MainActor
private func makeRuntime(planted: Data?, lock: Bool = false) throws -> AppRuntime {
    let keychain = InMemoryKeychain()
    if let planted { keychain.set(planted, at: shared) }
    if lock { keychain.failRead(at: shared, status: errSecInteractionNotAllowed) }
    let suite = "pushRuntimeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return AppRuntime(environment: .init(
        database: try AppDatabase.makeInMemory(),
        identityStore: .live(ops: keychain.ops),
        anchor: IdentityAnchor(defaults: defaults),
        pushStorage: .temporary(),
        wakeHold: .zero))
}

@MainActor
@Test func pushRuntimeWakeBuildsTheStoreWithoutAScene() async throws {
    let runtime = try makeRuntime(planted: Identity().privateKey!)
    #expect(runtime.store == nil)
    let woke = await runtime.pushWake()
    #expect(woke)
    #expect(runtime.store != nil)
}

@MainActor
@Test func pushRuntimeWakeWithLockedKeychainReturnsFalse() async throws {
    let runtime = try makeRuntime(planted: Identity().privateKey!, lock: true)
    let woke = await runtime.pushWake()
    #expect(!woke)
    #expect(runtime.store == nil)
    #expect(runtime.state == .unavailable(.locked))
}
