import Testing
import Foundation
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
@testable import ReTiCaMsgrCore

// MARK: - Helpers

private let radioA = RadioScanResult(id: UUID(uuidString: "A1A1A1A1-0000-4000-8000-0000000000A1")!,
                                     name: "Alpha", rssi: -61)

/// An AppFeature store whose `@Shared(.appStorage)` keys live in `defaults` and whose node list is
/// in an in-memory file store, so no test shares either with another. The State is built INSIDE
/// `withDependencies`: an `@Shared` key binds its store when the property is initialised.
/// Hermetic TCP, listener, BLE and push dependencies mirror `AppFeatureTests.makeStore`.
@MainActor
private func meshStore(defaults: UserDefaults = .inMemory,
                       scanner: RadioScanner = RadioScanner(scan: { AsyncStream { _ in } }),
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

// MARK: - Settings keys (T2)

@MainActor @Test func meshSettingsDefaultsAreOffWithNoRadio() async {
    let store = meshStore()
    #expect(store.state.meshtasticEnabled == false)
    #expect(store.state.meshtasticRadioID == nil)
    #expect(store.state.meshtasticRadioLabel == "None")
}

/// The toggle goes through the same path as Settings' `$store.meshtasticEnabled` binding, and the
/// value must land under the spec's key.
@MainActor @Test func meshSettingsToggleWritesTheMeshtasticEnabledKey() async {
    let defaults = UserDefaults.inMemory
    let store = meshStore(defaults: defaults)
    await store.send(.binding(.set(\.meshtasticEnabled, true)))
    #expect(defaults.bool(forKey: "meshtasticEnabled") == true)
}

/// A radio chosen in an earlier launch is read back from the spec's key.
@MainActor @Test func meshSettingsReadsAPersistedRadioID() async {
    let defaults = UserDefaults.inMemory
    defaults.set(radioA.id.uuidString, forKey: "meshtasticRadioID")
    let store = meshStore(defaults: defaults)
    #expect(store.state.meshtasticRadioUUID == radioA.id)
}

@MainActor @Test func meshSettingsRadioLabelShowsTheName() async {
    let store = meshStore { state in
        state.$meshtasticRadioID.withLock { $0 = radioA.id.uuidString }
        state.$meshtasticRadioName.withLock { $0 = "Base camp" }
    }
    #expect(store.state.meshtasticRadioLabel == "Base camp")
}

/// Review Focus 3: a blank advertised name is no name.
@MainActor @Test func meshSettingsRadioLabelFallsBackToTheIDForABlankName() async {
    let store = meshStore { state in
        state.$meshtasticRadioID.withLock { $0 = radioA.id.uuidString }
        state.$meshtasticRadioName.withLock { $0 = "  " }
    }
    #expect(store.state.meshtasticRadioLabel == radioA.id.uuidString)
}

/// Review Focus 4: a stored ID that is not a UUID reads as no radio, name or not.
@MainActor @Test func meshSettingsNonUUIDRadioIDCountsAsNoRadio() async {
    let store = meshStore { state in
        state.$meshtasticRadioID.withLock { $0 = "not-a-uuid" }
        state.$meshtasticRadioName.withLock { $0 = "Ghost" }
    }
    #expect(store.state.meshtasticRadioUUID == nil)
    #expect(store.state.meshtasticRadioLabel == "None")
}
