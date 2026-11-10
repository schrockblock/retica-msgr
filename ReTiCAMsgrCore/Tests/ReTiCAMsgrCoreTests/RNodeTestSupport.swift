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

let rnRadioA = RadioScanResult(id: UUID(uuidString: "D1D1D1D1-0000-4000-8000-0000000000D1")!,
                               name: "RNode 1A2B", rssi: -61)

// MARK: - Store

/// An AppFeature store for the RNode tests, built like `mcStore`: its `@Shared(.appStorage)` keys
/// live in `defaults`, its node list is in an in-memory file store, and the TCP, listener, BLE and
/// push dependencies are hermetic. The State is built INSIDE `withDependencies`.
@MainActor
func rnStore(defaults: UserDefaults = .inMemory,
             scanner: RadioScanner = RadioScanner(scan: { AsyncStream { _ in } }),
             configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = withDependencies {
        $0.defaultAppStorage = defaults
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    initial.autoInterfaceAvailable = false   // hermetic: no AutoInterface slot
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
    }
    store.exhaustivity = .off
    return store
}
