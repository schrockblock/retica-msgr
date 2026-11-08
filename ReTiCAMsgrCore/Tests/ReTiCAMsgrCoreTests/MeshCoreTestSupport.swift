import Testing
import Foundation
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
import ReTiCAKeychain
@testable import ReTiCAMsgrCore

// MARK: - Fixtures

let mcRadioA = RadioScanResult(id: UUID(uuidString: "C1C1C1C1-0000-4000-8000-0000000000C1")!,
                               name: "MeshCore-1a2b", rssi: -58)

/// Two acceptable channel keys, as 32 lowercase hex characters. Test-only values.
let mcHexA = "1f2e3d4c5b6a79881f2e3d4c5b6a7988"
let mcHexB = "a0b1c2d3e4f5061728394a5b6c7d8e9f"

/// An in-memory Keychain and a live key store over it.
func mcKeychain() -> (InMemoryKeychain, MeshCoreKeyStore) {
    let keychain = InMemoryKeychain()
    return (keychain, .live(ops: keychain.ops))
}

// MARK: - Store

/// An AppFeature store for the MeshCore tests, built like `meshStore` in `MeshtasticSettingsTests`:
/// its `@Shared(.appStorage)` keys live in `defaults`, its node list is in an in-memory file store,
/// and the TCP, listener, BLE and push dependencies are hermetic. The State is built INSIDE
/// `withDependencies`: an `@Shared` key binds its store when the property is initialised.
@MainActor
func mcStore(defaults: UserDefaults = .inMemory,
             scanner: RadioScanner = RadioScanner(scan: { AsyncStream { _ in } }),
             keyStore: MeshCoreKeyStore = .inert,
             configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = withDependencies {
        $0.defaultAppStorage = defaults
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    configure?(&initial)
    let db = try! AppDatabase.makeInMemory()
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.badge = .ignored
        $0.defaultAppStorage = defaults
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in },
                                     close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in },
                                 openChannel: { _ in }, send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
        $0.radioScanner = scanner
        $0.meshCoreKeyStore = keyStore
    }
    store.exhaustivity = .off
    return store
}
