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

// MARK: - Picker presentation and BLE pause (T3)

/// A BLE slot as a Connect with `bleEnabled` on builds it, with its interface in `status`.
private func withBLE(_ state: inout AppFeature.State, _ status: BLEInterfaceStatus) {
    state.$bleEnabled.withLock { $0 = true }
    var ble = BLEEndpoint.State(localIdentity: state.identity.hash)
    ble.ble.status = status
    state.node.client.endpoint.ble = ble
}

/// Matches the INTERFACE-level stop. `BLEEndpoint` forwards its own `.stop` to `.ble(.stop)` through
/// a further effect, and only that inner action changes `status`, so receiving it is what makes the
/// status below observable. It exists only because the endpoint-level stop was sent.
private func isBLEStop(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.ble(.ble(.stop))))) = action { return true }
    return false
}

/// The interface-level start, for the same reason as `isBLEStop`.
private func isBLEStart(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.ble(.ble(.start))))) = action { return true }
    return false
}

private func isPickerDismiss(_ action: AppFeature.Action) -> Bool {
    if case .radioPicker(.dismiss) = action { return true }
    return false
}

private func isPickerSelection(_ action: AppFeature.Action) -> Bool {
    if case .radioPicker(.presented(.delegate(.selected))) = action { return true }
    return false
}

enum PickerExit: String, CaseIterable, Sendable { case swipe, cancel, pick }

@MainActor @Test func meshPickerFlowChooseRadioOpensThePickerOnTheStoredRadio() async {
    let store = meshStore { $0.$meshtasticRadioID.withLock { $0 = radioA.id.uuidString } }
    await store.send(.chooseRadioTapped)
    #expect(store.state.radioPicker?.selectedID == radioA.id)
}

/// FCB has one scan per process (spec §2): a running BLE interface is stopped while the picker
/// scans.
@MainActor @Test func meshPickerFlowPausesRunningBLE() async {
    let store = meshStore { withBLE(&$0, .online) }
    await store.send(.chooseRadioTapped)
    await store.receive(isBLEStop)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
    #expect(store.state.blePausedForRadioScan)
}

/// Swipe (what the sheet binding sends), Cancel and a pick all restart the BLE the picker paused.
@MainActor @Test(arguments: PickerExit.allCases)
func meshPickerFlowEveryExitResumesPausedBLE(_ exit: PickerExit) async {
    let store = meshStore { withBLE(&$0, .online) }
    await store.send(.chooseRadioTapped)
    await store.receive(isBLEStop)
    switch exit {
    case .swipe:
        await store.send(.radioPicker(.dismiss))
    case .cancel:
        await store.send(.radioPicker(.presented(.cancelTapped)))
        await store.receive(isPickerDismiss)
    case .pick:
        await store.send(.radioPicker(.presented(.radioFound(radioA))))
        await store.send(.radioPicker(.presented(.radioTapped(radioA.id))))
        await store.receive(isPickerDismiss)
    }
    await store.receive(isBLEStart)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .starting)
    #expect(!store.state.blePausedForRadioScan)
}

/// Review Focus 2: BLE the user stopped (Disconnect) is not "paused" by the picker, so closing it
/// must not start BLE.
@MainActor @Test func meshPickerFlowLeavesStoppedBLEStopped() async {
    let store = meshStore { withBLE(&$0, .stopped) }
    await store.send(.chooseRadioTapped)
    #expect(!store.state.blePausedForRadioScan)
    await store.send(.radioPicker(.dismiss))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
}

/// Review Focus 2: BLE toggled on but never connected has no slot. A `.ble` action to the missing
/// slot would trip TransportEndpoint's ifLet (a reported issue fails this test).
@MainActor @Test func meshPickerFlowWithoutBLESlotSendsNoBLEAction() async {
    let store = meshStore { $0.$bleEnabled.withLock { $0 = true } }
    await store.send(.chooseRadioTapped)
    await store.skipReceivedActions(strict: false)
    #expect(!store.state.blePausedForRadioScan)
    await store.send(.radioPicker(.dismiss))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble == nil)
}

@MainActor @Test func meshPickerFlowSelectingStoresTheRadioID() async {
    let defaults = UserDefaults.inMemory
    let store = meshStore(defaults: defaults)
    await store.send(.chooseRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(radioA))))
    await store.send(.radioPicker(.presented(.radioTapped(radioA.id))))
    await store.receive(isPickerSelection)
    #expect(defaults.string(forKey: "meshtasticRadioID") == radioA.id.uuidString)
}

@MainActor @Test func meshPickerFlowSelectingStoresTheRadioName() async {
    let defaults = UserDefaults.inMemory
    let store = meshStore(defaults: defaults)
    await store.send(.chooseRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(radioA))))
    await store.send(.radioPicker(.presented(.radioTapped(radioA.id))))
    await store.receive(isPickerSelection)
    #expect(defaults.string(forKey: "meshtasticRadioName") == "Alpha")
}

@MainActor @Test func meshPickerFlowSelectingClosesThePicker() async {
    let store = meshStore()
    await store.send(.chooseRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(radioA))))
    await store.send(.radioPicker(.presented(.radioTapped(radioA.id))))
    await store.receive(isPickerDismiss)
    #expect(store.state.radioPicker == nil)
}

/// The scan must not outlive the sheet: closing it ends the scanner's stream.
@MainActor @Test func meshPickerFlowDismissStopsTheScan() async {
    let started = LockIsolated(false)
    let terminated = LockIsolated(false)
    let scanner = RadioScanner(scan: {
        started.setValue(true)
        return AsyncStream { continuation in
            continuation.onTermination = { _ in terminated.setValue(true) }
        }
    })
    let store = meshStore(scanner: scanner)
    await store.send(.chooseRadioTapped)
    await store.send(.radioPicker(.presented(.onAppear)))
    // Precondition: the scan really started, so termination below is the dismiss's doing.
    #expect(await waitUntil { started.value })
    #expect(!terminated.value)
    await store.send(.radioPicker(.dismiss))
    #expect(await waitUntil { terminated.value })
}

/// Review Focus 1. SEEDED, not driven, on purpose: the pause itself is proven by
/// `meshPickerFlowPausesRunningBLE`, and seeding keeps this test's only failure mode the
/// `redialDownNodes` guard (the one-batch mutation rule in Step 6). An empty node list means no
/// TCP slots, which is the case where `redialDownNodes` always reaches the BLE restart.
@MainActor @Test func meshPickerFlowForegroundWhileOpenKeepsBLEPaused() async {
    let store = meshStore { state in
        withBLE(&state, .stopped)
        state.radioPicker = RadioPickerFeature.State()
        state.blePausedForRadioScan = true
    }
    await store.send(.foregrounded)
    // `redialDownNodes` concatenates removals, then the dials (BLE start among them), then the push
    // re-point, whose first action is `.push(.hubChanged)`. Receiving it proves the redial ran past
    // the dials. But `BLEEndpoint` forwards an endpoint-level start to the interface's `.ble(.start)`
    // through a further effect, queued AFTER `hubChanged`, and only that one changes `status`. So
    // drain the rest before reading the status, or a BLE start would go unseen.
    await store.receive { if case .push(.hubChanged) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
}
