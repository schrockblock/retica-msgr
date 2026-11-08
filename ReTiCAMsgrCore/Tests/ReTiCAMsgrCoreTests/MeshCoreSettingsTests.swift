import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAMsgrCore

// MARK: - Radio picker kind (T1)

/// A picker store whose dismiss only records that it ran.
@MainActor
private func mcPickerStore(kind: RadioKind, scanner: RadioScanner) -> TestStoreOf<RadioPickerFeature> {
    let store = TestStore(initialState: RadioPickerFeature.State(kind: kind)) {
        RadioPickerFeature()
    } withDependencies: {
        $0.radioScanner = scanner
        $0.dismiss = DismissEffect { }
    }
    store.exhaustivity = .off
    return store
}

/// A scanner whose two closures count their calls and stay open.
private func mcCountingScanner(meshtastic: LockIsolated<Int>, meshCore: LockIsolated<Int>) -> RadioScanner {
    RadioScanner(
        scan: {
            meshtastic.withValue { $0 += 1 }
            return AsyncStream { _ in }
        },
        scanMeshCore: {
            meshCore.withValue { $0 += 1 }
            return AsyncStream { _ in }
        })
}

@Test func mcPickerDefaultsToMeshtastic() {
    #expect(RadioPickerFeature.State().kind == .meshtastic)
}

@MainActor @Test func mcPickerMeshCoreScanUsesScanMeshCore() async {
    let meshtasticScans = LockIsolated(0)
    let meshCoreScans = LockIsolated(0)
    let store = mcPickerStore(
        kind: .meshCore, scanner: mcCountingScanner(meshtastic: meshtasticScans, meshCore: meshCoreScans))
    await store.send(.onAppear)
    #expect(await waitUntil { meshCoreScans.value == 1 })
    #expect(meshCoreScans.value == 1)
    #expect(meshtasticScans.value == 0)
    await store.send(.cancelTapped)
}

@MainActor @Test func mcPickerMeshtasticScanUsesScan() async {
    let meshtasticScans = LockIsolated(0)
    let meshCoreScans = LockIsolated(0)
    let store = mcPickerStore(
        kind: .meshtastic, scanner: mcCountingScanner(meshtastic: meshtasticScans, meshCore: meshCoreScans))
    await store.send(.onAppear)
    #expect(await waitUntil { meshtasticScans.value == 1 })
    #expect(meshtasticScans.value == 1)
    #expect(meshCoreScans.value == 0)
    await store.send(.cancelTapped)
}

/// Asserts only the action, like `radioPickerUninstalledLiveScannerEndsTheScan`.
@MainActor @Test func mcPickerUninstalledMeshCoreScannerEndsTheScan() async {
    let store = mcPickerStore(kind: .meshCore, scanner: RadioScanner.liveValue)
    await store.send(.onAppear)
    await store.receive { if case .scanFinished = $0 { return true }; return false }
}

@Test func mcPickerMeshCoreMessagesNameMeshCore() {
    #expect(RadioPickerFeature.State(kind: .meshCore).scanningMessage
            == "Scanning for MeshCore radios… Make sure the radio is on and not connected to another app.")
    #expect(RadioPickerFeature.State(kind: .meshCore).scanEndedEmptyMessage
            == "Scanning stopped before any radio was found. MeshCore support may not be installed in this "
            + "build, or Bluetooth may be off or not allowed.")
}

@Test func mcPickerMeshtasticMessagesAreUnchanged() {
    #expect(RadioPickerFeature.State().scanningMessage
            == "Scanning for Meshtastic radios… Make sure the radio is on and not connected to another app.")
    #expect(RadioPickerFeature.State().scanEndedEmptyMessage == RadioPickerFeature.scanEndedEmptyMessage)
}

// MARK: - Persisted settings and the Release gate value (T2)

@MainActor @Test func mcSettingsDefaultsAreOffWithNoRadio() {
    let state = mcStore().state
    #expect(!state.meshCoreEnabled)
    #expect(state.meshCoreRadioID == nil)
    #expect(state.meshCoreRadioLabel == "None")
}

/// The toggle goes through the same path as Settings' `$store.meshCoreEnabled` binding.
@MainActor @Test func mcSettingsToggleWritesTheMeshCoreEnabledKey() async {
    let defaults = UserDefaults.inMemory
    let store = mcStore(defaults: defaults)
    await store.send(.binding(.set(\.meshCoreEnabled, true)))
    #expect(defaults.bool(forKey: "meshCoreEnabled"))
}

@MainActor @Test func mcSettingsReadsAPersistedRadioID() {
    let defaults = UserDefaults.inMemory
    defaults.set(mcRadioA.id.uuidString, forKey: "meshCoreRadioID")
    let store = mcStore(defaults: defaults)
    #expect(store.state.meshCoreRadioUUID == mcRadioA.id)
}

@MainActor @Test func mcSettingsRadioNameKeyIsMeshCoreRadioName() {
    let defaults = UserDefaults.inMemory
    defaults.set(mcRadioA.id.uuidString, forKey: "meshCoreRadioID")
    defaults.set("Base camp", forKey: "meshCoreRadioName")
    let store = mcStore(defaults: defaults)
    #expect(store.state.meshCoreRadioLabel == "Base camp")
}

@MainActor @Test func mcSettingsRadioLabelFallsBackToTheIDForABlankName() {
    let defaults = UserDefaults.inMemory
    defaults.set(mcRadioA.id.uuidString, forKey: "meshCoreRadioID")
    defaults.set("   ", forKey: "meshCoreRadioName")
    let store = mcStore(defaults: defaults)
    #expect(store.state.meshCoreRadioLabel == mcRadioA.id.uuidString)
}

/// The string is planted under the real key, so the test goes through `meshCoreRadioUUID`.
@MainActor @Test func mcSettingsNonUUIDRadioIDCountsAsNoRadio() {
    let defaults = UserDefaults.inMemory
    defaults.set("not-a-uuid", forKey: "meshCoreRadioID")
    let store = mcStore(defaults: defaults)
    #expect(store.state.meshCoreRadioID == "not-a-uuid")
    #expect(store.state.meshCoreRadioUUID == nil)
    #expect(store.state.meshCoreRadioLabel == "None")
}

@MainActor @Test func mcSettingsMeshtasticSettingsDoNotLeakIn() {
    let defaults = UserDefaults.inMemory
    defaults.set(true, forKey: "meshtasticEnabled")
    defaults.set(mcRadioA.id.uuidString, forKey: "meshtasticRadioID")
    let store = mcStore(defaults: defaults)
    #expect(!store.state.meshCoreEnabled)
    #expect(store.state.meshCoreRadioUUID == nil)
}

private struct MCDialCase: Sendable, CustomTestStringConvertible {
    var enabled: Bool
    var radio: Bool
    var presence: MeshCoreKeyPresence
    var available: Bool
    var expected: Bool
    var testDescription: String {
        "enabled \(enabled), radio \(radio), key \(presence), available \(available) -> \(expected)"
    }
}

@MainActor @Test(arguments: [
    MCDialCase(enabled: true, radio: true, presence: .present, available: true, expected: true),
    MCDialCase(enabled: false, radio: true, presence: .present, available: true, expected: false),
    MCDialCase(enabled: true, radio: false, presence: .present, available: true, expected: false),
    MCDialCase(enabled: true, radio: true, presence: .present, available: false, expected: false),
    MCDialCase(enabled: true, radio: true, presence: .absent, available: true, expected: false),
    MCDialCase(enabled: true, radio: true, presence: .unreadable, available: true, expected: false),
])
private func mcSettingsWillDialNeedsEveryCondition(_ c: MCDialCase) {
    let defaults = UserDefaults.inMemory
    defaults.set(c.enabled, forKey: "meshCoreEnabled")
    if c.radio { defaults.set(mcRadioA.id.uuidString, forKey: "meshCoreRadioID") }
    let store = mcStore(defaults: defaults) { state in
        state.meshCoreKeyPresence = c.presence
        state.meshCoreAvailable = c.available
    }
    #expect(store.state.meshCoreWillDial == c.expected)
}

/// Defaults restored from a backup, with no Keychain item behind them.
@MainActor @Test func mcSettingsRestoredDefaultsWithoutAKeyWillNotDial() {
    let defaults = UserDefaults.inMemory
    defaults.set(true, forKey: "meshCoreEnabled")
    defaults.set(mcRadioA.id.uuidString, forKey: "meshCoreRadioID")
    let state = mcStore(defaults: defaults) { $0.meshCoreKeyPresence = .absent }.state
    #expect(state.meshCoreEnabled)
    #expect(state.meshCoreRadioUUID == mcRadioA.id)
    #expect(!state.meshCoreWillDial)
}

/// A Release build with Debug-era defaults and a key: the gate alone stops the dial.
@MainActor @Test func mcSettingsStaleDefaultsWithTheGateOffWillNotDial() {
    let defaults = UserDefaults.inMemory
    defaults.set(true, forKey: "meshCoreEnabled")
    defaults.set(mcRadioA.id.uuidString, forKey: "meshCoreRadioID")
    let state = mcStore(defaults: defaults) {
        $0.meshCoreKeyPresence = .present
        $0.meshCoreAvailable = false
    }.state
    #expect(state.meshCoreEnabled)
    #expect(state.meshCoreRadioUUID == mcRadioA.id)
    #expect(!state.meshCoreWillDial)
}

@Test func mcSettingsGateIsOnInThisBuild() {
    #expect(MeshCoreReleaseGate.isCompiledIn)
}

// MARK: - Settings copy, notices and Generate (T7)

@Test func mcCopyWarningSaysMessagesAreRemoved() {
    #expect(MeshCoreCopy.requiredWarning
            == "Text messages waiting on the radio are removed when this app connects and won't reach the MeshCore app.")
}

@Test func mcCopyFooterCarriesTheWarning() {
    #expect(MeshCoreCopy.footer.contains(MeshCoreCopy.requiredWarning))
}

@Test func mcCopyFooterSaysThisAddsSharedTraffic() {
    #expect(MeshCoreCopy.footer.contains("adds traffic to a shared radio network"))
}

@Test func mcCopyFooterSaysEveryoneNeedsTheKey() {
    #expect(MeshCoreCopy.footer.contains("Everyone on the tunnel needs the same channel key"))
}

@Test func mcCopyTurnOffSaysWhatHappensWhenNotConnected() {
    #expect(MeshCoreCopy.turnOffNotice.contains("may stay on the radio"))
    #expect(MeshCoreCopy.turnOffNotice.contains("MeshCore app"))
}

@Test func mcCopyRadioChangeSaysTheOldChannelStays() {
    #expect(MeshCoreCopy.radioChangeNotice.contains("different radio"))
    #expect(MeshCoreCopy.radioChangeNotice.contains("old radio"))
    #expect(MeshCoreCopy.radioChangeNotice.contains("MeshCore app"))
}

@Test func mcCopyNeverNamesTheApp() {
    for text in MeshCoreCopy.all {
        #expect(!text.lowercased().contains("reticamsgr"), "\(text)")
    }
}

/// Guards `all` itself: a string left out of it would escape `mcCopyNeverNamesTheApp`.
@Test func mcCopyAllListsTheNotices() {
    for text in [MeshCoreCopy.footer, MeshCoreCopy.requiredWarning, MeshCoreCopy.turnOffNotice,
                 MeshCoreCopy.radioChangeNotice, MeshCoreCopy.noKeyNotice, MeshCoreCopy.channelLeftNotice,
                 MeshCoreCopy.shareBody, MeshCoreCopy.replaceMessage] {
        #expect(MeshCoreCopy.all.contains(text), "\(text)")
    }
}

@Test func mcCopyUserMessageFallsBackForOtherWithoutText() {
    #expect(MeshCoreStatus(adapterUnavailable: .other(nil)).userMessage
            == "The Bluetooth path to the radio is unavailable.")
}

@Test func mcCopyUserMessageForUnauthorized() {
    #expect(MeshCoreStatus(adapterUnavailable: .unauthorized).userMessage
            == "Bluetooth permission is off for this app. Allow it in Settings.")
}

@Test func mcCopyUserMessageForUnsupported() {
    #expect(MeshCoreStatus(adapterUnavailable: .unsupported).userMessage
            == "This device has no Bluetooth LE radio.")
}

@Test func mcCopyUserMessageForPoweredOff() {
    #expect(MeshCoreStatus(adapterUnavailable: .poweredOff).userMessage
            == "Bluetooth is off. Turn it on to reach the radio.")
}

@Test func mcCopyUserMessageIsNilWhileTheAdapterIsAvailable() {
    #expect(MeshCoreStatus().userMessage == nil)
}

@MainActor @Test(arguments: [false, true])
func mcCopyTurnOffNoticeShowsWithARadioChosen(enabled: Bool) {
    let defaults = UserDefaults.inMemory
    defaults.set(enabled, forKey: "meshCoreEnabled")
    defaults.set(mcRadioA.id.uuidString, forKey: "meshCoreRadioID")
    let state = mcStore(defaults: defaults).state
    #expect(state.meshCoreEnabled == enabled)
    #expect(state.meshCoreTurnOffNoticeVisible)
}

@MainActor @Test func mcCopyTurnOffNoticeHidesWithNoRadio() {
    let defaults = UserDefaults.inMemory
    defaults.set(true, forKey: "meshCoreEnabled")
    let state = mcStore(defaults: defaults).state
    #expect(!state.meshCoreTurnOffNoticeVisible)
}

@MainActor @Test func mcCopyTurnOffNoticeHidesAfterARemoval() {
    let defaults = UserDefaults.inMemory
    defaults.set(mcRadioA.id.uuidString, forKey: "meshCoreRadioID")
    let state = mcStore(defaults: defaults) { $0.meshCoreStatus.channelRemoved = true }.state
    #expect(!state.meshCoreTurnOffNoticeVisible)
}

@MainActor @Test func mcCopyTurnOffNoticeGivesWayToTheLeftNotice() {
    let defaults = UserDefaults.inMemory
    defaults.set(mcRadioA.id.uuidString, forKey: "meshCoreRadioID")
    let state = mcStore(defaults: defaults) { $0.meshCoreStatus.channelLeftOnRadio = true }.state
    #expect(!state.meshCoreTurnOffNoticeVisible)
}

/// A key store whose `generate` counts its calls.
private func mcCountingKeyStore(calls: LockIsolated<Int>) -> MeshCoreKeyStore {
    var keyStore = MeshCoreKeyStore.inert
    keyStore.generate = {
        calls.withValue { $0 += 1 }
        return .changed
    }
    keyStore.presence = { .present }
    return keyStore
}

@MainActor @Test func mcCopyGenerateMarksItselfRunning() async {
    let store = mcStore(keyStore: mcCountingKeyStore(calls: LockIsolated(0)))
    await store.send(.meshCoreGenerateKeyTapped)
    #expect(store.state.meshCoreKeyGenerating)
    await store.receive { if case .meshCoreKeyDidChange = $0 { return true }; return false }
}

/// A second tap while the first generate runs would make two real key changes and two reconnects.
/// The running state is planted, so the test doesn't race the first generate's effect.
@MainActor @Test func mcCopyGenerateWhileOneIsRunningIsIgnored() async {
    let calls = LockIsolated(0)
    let store = mcStore(keyStore: mcCountingKeyStore(calls: calls)) { $0.meshCoreKeyGenerating = true }
    await store.send(.meshCoreGenerateKeyTapped)
    await store.finish()
    #expect(calls.value == 0)
}

@MainActor @Test func mcCopyGenerateIsAllowedAgainAfterTheResult() async {
    let calls = LockIsolated(0)
    let store = mcStore(keyStore: mcCountingKeyStore(calls: calls))
    await store.send(.meshCoreGenerateKeyTapped)
    await store.receive { if case .meshCoreKeyDidChange = $0 { return true }; return false }
    #expect(!store.state.meshCoreKeyGenerating)
    await store.send(.meshCoreGenerateKeyTapped)
    await store.receive { if case .meshCoreKeyDidChange = $0 { return true }; return false }
    #expect(calls.value == 2)
}
