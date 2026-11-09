import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAMsgrCore

// MARK: - Radio picker, RNode kind (T1)

/// A picker store whose dismiss only records that it ran.
@MainActor
private func rnPickerStore(kind: RadioKind, scanner: RadioScanner) -> TestStoreOf<RadioPickerFeature> {
    let store = TestStore(initialState: RadioPickerFeature.State(kind: kind)) {
        RadioPickerFeature()
    } withDependencies: {
        $0.radioScanner = scanner
        $0.dismiss = DismissEffect { }
    }
    store.exhaustivity = .off
    return store
}

/// A scanner whose three closures count their calls and stay open.
private func rnCountingScanner(meshtastic: LockIsolated<Int>, meshCore: LockIsolated<Int>,
                               rnode: LockIsolated<Int>) -> RadioScanner {
    RadioScanner(
        scan: {
            meshtastic.withValue { $0 += 1 }
            return AsyncStream { _ in }
        },
        scanMeshCore: {
            meshCore.withValue { $0 += 1 }
            return AsyncStream { _ in }
        },
        scanRNode: {
            rnode.withValue { $0 += 1 }
            return AsyncStream { _ in }
        })
}

@MainActor @Test func rnPickerRNodeScanUsesScanRNode() async {
    let meshtasticScans = LockIsolated(0)
    let meshCoreScans = LockIsolated(0)
    let rnodeScans = LockIsolated(0)
    let store = rnPickerStore(
        kind: .rnode,
        scanner: rnCountingScanner(meshtastic: meshtasticScans, meshCore: meshCoreScans, rnode: rnodeScans))
    await store.send(.onAppear)
    #expect(await waitUntil { rnodeScans.value == 1 })
    #expect(rnodeScans.value == 1)
    #expect(meshCoreScans.value == 0)
    #expect(meshtasticScans.value == 0)
    await store.send(.cancelTapped)
}

/// Asserts only the action, like `mcPickerUninstalledMeshCoreScannerEndsTheScan`.
@MainActor @Test func rnPickerUninstalledRNodeScannerEndsTheScan() async {
    let store = rnPickerStore(kind: .rnode, scanner: RadioScanner.liveValue)
    await store.send(.onAppear)
    await store.receive { if case .scanFinished = $0 { return true }; return false }
}

@Test func rnPickerRNodeMessagesNameRNodes() {
    #expect(RadioPickerFeature.State(kind: .rnode).scanningMessage
            == "Scanning for RNodes… Only RNodes with Bluetooth LE appear. Make sure the radio is on, its "
            + "Bluetooth is on, and it isn't connected to another app.")
    #expect(RadioPickerFeature.State(kind: .rnode).scanEndedEmptyMessage
            == "Scanning stopped before any radio was found. RNode support may not be installed in this "
            + "build, or Bluetooth may be off or not allowed.")
}

// MARK: - Persisted radio settings, validation, the gate value (T2)

/// A complete, in-range value: each boundary test changes one field.
private let rnGoodSettings = RNodeRadioSettings(frequencyHz: 868_100_000, bandwidthHz: 62_500,
                                                spreadingFactor: 8, codingRate: 6, txPowerDBm: 0)

/// Defaults that dial: enabled, a radio and a frequency. Callers add the one thing under test.
private func rnDialReadyDefaults() -> UserDefaults {
    let defaults = UserDefaults.inMemory
    defaults.set(true, forKey: "rnodeEnabled")
    defaults.set(rnRadioA.id.uuidString, forKey: "rnodeRadioID")
    defaults.set(868_100_000, forKey: "rnodeFrequencyHz")
    return defaults
}

@MainActor @Test func rnSettingsDefaultsAreSidebandsDefaults() {
    let state = rnStore().state
    #expect(state.rnodeFrequencyHz == nil)
    #expect(state.rnodeBandwidthHz == 62_500)
    #expect(state.rnodeSpreadingFactor == 8)
    #expect(state.rnodeCodingRate == 6)
    #expect(state.rnodeTXPowerDBm == 0)
    #expect(!state.rnodeEnabled)
    #expect(state.rnodeRadioID == nil)
    #expect(state.rnodeRadioName == nil)
}

@MainActor @Test func rnSettingsEachValuePersists() async {
    let defaults = UserDefaults.inMemory
    let store = rnStore(defaults: defaults)
    await store.send(.rnodeFrequencyTextChanged("868.1"))
    await store.send(.rnodeBandwidthTextChanged("125"))
    await store.send(.rnodeSpreadingFactorChanged(10))
    await store.send(.rnodeCodingRateChanged(5))
    await store.send(.rnodeTXPowerChanged(17))
    // The spec's key names.
    #expect(defaults.integer(forKey: "rnodeFrequencyHz") == 868_100_000)
    #expect(defaults.integer(forKey: "rnodeBandwidthHz") == 125_000)
    #expect(defaults.integer(forKey: "rnodeSpreadingFactor") == 10)
    #expect(defaults.integer(forKey: "rnodeCodingRate") == 5)
    #expect(defaults.integer(forKey: "rnodeTXPowerDBm") == 17)
    let fresh = rnStore(defaults: defaults).state
    #expect(fresh.rnodeFrequencyHz == 868_100_000)
    #expect(fresh.rnodeBandwidthHz == 125_000)
    #expect(fresh.rnodeSpreadingFactor == 10)
    #expect(fresh.rnodeCodingRate == 5)
    #expect(fresh.rnodeTXPowerDBm == 17)
}

@MainActor @Test func rnSettingsDefaultsAreMissingOnlyTheFrequency() {
    let state = rnStore().state
    #expect(state.rnodeSettings.problems == [.frequencyMissing])
    #expect(state.rnodeSettingsProblems == [.frequencyMissing])
}

@Test(arguments: [(136_999_999, true), (137_000_000, false), (3_000_000_000, false), (3_000_000_001, true)])
func rnSettingsFrequencyBoundaries(_ hz: Int, _ flagged: Bool) {
    var settings = rnGoodSettings
    settings.frequencyHz = hz
    #expect(settings.problems.contains(.frequencyOutOfRange) == flagged)
}

@Test(arguments: [(7_799, true), (7_800, false), (1_625_000, false), (1_625_001, true)])
func rnSettingsBandwidthBoundaries(_ hz: Int, _ flagged: Bool) {
    var settings = rnGoodSettings
    settings.bandwidthHz = hz
    #expect(settings.problems.contains(.bandwidthOutOfRange) == flagged)
}

@Test(arguments: [(4, true), (5, false), (12, false), (13, true)])
func rnSettingsSpreadingFactorBoundaries(_ value: Int, _ flagged: Bool) {
    var settings = rnGoodSettings
    settings.spreadingFactor = value
    #expect(settings.problems.contains(.spreadingFactorOutOfRange) == flagged)
}

@Test(arguments: [(4, true), (5, false), (8, false), (9, true)])
func rnSettingsCodingRateBoundaries(_ value: Int, _ flagged: Bool) {
    var settings = rnGoodSettings
    settings.codingRate = value
    #expect(settings.problems.contains(.codingRateOutOfRange) == flagged)
}

@Test(arguments: [(-1, true), (0, false), (37, false), (38, true)])
func rnSettingsTXPowerBoundaries(_ value: Int, _ flagged: Bool) {
    var settings = rnGoodSettings
    settings.txPowerDBm = value
    #expect(settings.problems.contains(.txPowerOutOfRange) == flagged)
}

@Test func rnSettingsProblemsAreInFieldOrder() {
    let settings = RNodeRadioSettings(frequencyHz: 1, bandwidthHz: 1, spreadingFactor: 1, codingRate: 1,
                                      txPowerDBm: -5)
    #expect(settings.problems == [.frequencyOutOfRange, .bandwidthOutOfRange, .spreadingFactorOutOfRange,
                                  .codingRateOutOfRange, .txPowerOutOfRange])
}

@Test func rnSettingsFrequencyTextParses() {
    #expect(RNodeRadioSettings.parseMegahertz("868.1") == 868_100_000)
    #expect(RNodeRadioSettings.parseMegahertz("433.775") == 433_775_000)
    #expect(RNodeRadioSettings.parseMegahertz("915") == 915_000_000)
    #expect(RNodeRadioSettings.parseMegahertz("868.000001") == 868_000_001)
    // A value `Int(Double(text)! * 1_000_000)` truncates to 256_000_996.
    #expect(RNodeRadioSettings.parseMegahertz("256.000997") == 256_000_997)
}

@Test func rnSettingsFrequencyTextAcceptsSurroundingWhitespace() {
    #expect(RNodeRadioSettings.parseMegahertz(" 868.1\n") == 868_100_000)
}

@Test(arguments: ["868,1", "868.1 MHz", "868.1000001", "1e9", "-868", "", ".", "868.", "99999999999999999999"])
func rnSettingsFrequencyTextRejects(_ text: String) {
    #expect(RNodeRadioSettings.parseMegahertz(text) == nil)
}

@Test func rnSettingsBandwidthTextParses() {
    #expect(RNodeRadioSettings.parseKilohertz("62.5") == 62_500)
    #expect(RNodeRadioSettings.parseKilohertz("7.8") == 7_800)
    #expect(RNodeRadioSettings.parseKilohertz("125") == 125_000)
    #expect(RNodeRadioSettings.parseKilohertz("31.25") == 31_250)
    // A value `Int(Double(text)! * 1_000)` truncates to 8_013.
    #expect(RNodeRadioSettings.parseKilohertz("8.014") == 8_014)
}

@Test(arguments: ["62.5 kHz", "62,5", "7.8001", "", "-1", "99999999999999999999"])
func rnSettingsBandwidthTextRejects(_ text: String) {
    #expect(RNodeRadioSettings.parseKilohertz(text) == nil)
}

@Test func rnSettingsTextFormatsRoundTrip() {
    #expect(RNodeRadioSettings.megahertzText(868_100_000) == "868.1")
    #expect(RNodeRadioSettings.megahertzText(915_000_000) == "915")
    #expect(RNodeRadioSettings.kilohertzText(62_500) == "62.5")
    #expect(RNodeRadioSettings.kilohertzText(125_000) == "125")
    #expect(RNodeRadioSettings.parseMegahertz(RNodeRadioSettings.megahertzText(433_775_000)) == 433_775_000)
    #expect(RNodeRadioSettings.parseKilohertz(RNodeRadioSettings.kilohertzText(31_250)) == 31_250)
}

/// A stored frequency is planted first, so the test proves unreadable text clears it.
@MainActor @Test func rnSettingsUnreadableFrequencyIsReported() async {
    let defaults = UserDefaults.inMemory
    defaults.set(868_100_000, forKey: "rnodeFrequencyHz")
    let store = rnStore(defaults: defaults)
    await store.send(.rnodeFrequencyTextChanged("abc"))
    #expect(store.state.rnodeFrequencyHz == nil)
    // One message for the field: the stored nil's `.frequencyMissing` is left out.
    #expect(store.state.rnodeSettingsProblems == [.frequencyUnreadable])
}

@MainActor @Test func rnSettingsBlankFrequencyIsMissingNotUnreadable() async {
    let defaults = UserDefaults.inMemory
    defaults.set(868_100_000, forKey: "rnodeFrequencyHz")
    let store = rnStore(defaults: defaults)
    await store.send(.rnodeFrequencyTextChanged(""))
    #expect(store.state.rnodeFrequencyHz == nil)
    #expect(store.state.rnodeSettingsProblems == [.frequencyMissing])
}

@MainActor @Test func rnSettingsUnreadableBandwidthKeepsTheStoredValue() async {
    let store = rnStore()
    await store.send(.rnodeBandwidthTextChanged("x"))
    #expect(store.state.rnodeBandwidthHz == 62_500)
    #expect(store.state.rnodeSettingsProblems == [.bandwidthUnreadable, .frequencyMissing])
}

@MainActor @Test func rnSettingsAGoodEntryClearsTheTextProblem() async {
    let store = rnStore()
    await store.send(.rnodeFrequencyTextChanged("abc"))
    #expect(store.state.rnodeSettingsProblems == [.frequencyUnreadable])
    await store.send(.rnodeFrequencyTextChanged("868.1"))
    #expect(store.state.rnodeSettingsProblems == [])
}

/// Settings re-seeds its fields from the stored values on appear (F7): a problem about text that is
/// no longer in the field goes away.
@MainActor @Test func rnSettingsReseedingClearsAStaleTextProblem() async {
    let store = rnStore()
    await store.send(.rnodeBandwidthTextChanged("x"))
    await store.send(.rnodeFrequencyTextChanged("abc"))
    #expect(store.state.rnodeSettingsProblems == [.frequencyUnreadable, .bandwidthUnreadable])
    let state = store.state
    await store.send(.rnodeFrequencyTextChanged(state.rnodeFrequencyHz.map(RNodeRadioSettings.megahertzText) ?? ""))
    await store.send(.rnodeBandwidthTextChanged(RNodeRadioSettings.kilohertzText(state.rnodeBandwidthHz)))
    #expect(store.state.rnodeSettingsProblems == [.frequencyMissing])
}

private struct RNDialCase: Sendable, CustomTestStringConvertible {
    var name: String
    var available = true
    var enabled = true
    var radio = true
    var frequency = true
    var spreadingFactor = 8
    var expected: Bool
    var testDescription: String { name }
}

@MainActor @Test(arguments: [
    RNDialCase(name: "all set", expected: true),
    RNDialCase(name: "gate off", available: false, expected: false),
    RNDialCase(name: "disabled", enabled: false, expected: false),
    RNDialCase(name: "no radio", radio: false, expected: false),
    RNDialCase(name: "no frequency", frequency: false, expected: false),
    RNDialCase(name: "SF 13", spreadingFactor: 13, expected: false),
])
private func rnSettingsWillDialNeedsEveryCondition(_ c: RNDialCase) {
    let defaults = UserDefaults.inMemory
    defaults.set(c.enabled, forKey: "rnodeEnabled")
    if c.radio { defaults.set(rnRadioA.id.uuidString, forKey: "rnodeRadioID") }
    if c.frequency { defaults.set(868_100_000, forKey: "rnodeFrequencyHz") }
    defaults.set(c.spreadingFactor, forKey: "rnodeSpreadingFactor")
    let store = rnStore(defaults: defaults) { $0.rnodeAvailable = c.available }
    #expect(store.state.rnodeWillDial == c.expected)
}

@MainActor @Test func rnSettingsStaleDefaultsWithoutAFrequencyWillNotDial() {
    let defaults = UserDefaults.inMemory
    defaults.set(true, forKey: "rnodeEnabled")
    defaults.set(rnRadioA.id.uuidString, forKey: "rnodeRadioID")
    let state = rnStore(defaults: defaults).state
    #expect(state.rnodeEnabled)
    #expect(state.rnodeRadioUUID == rnRadioA.id)
    #expect(!state.rnodeWillDial)
}

/// Dial-ready apart from the spreading factor, so only the SF range check can stop the dial.
@MainActor @Test func rnSettingsOutOfRangeStoredValueWillNotDial() {
    let defaults = rnDialReadyDefaults()
    defaults.set(13, forKey: "rnodeSpreadingFactor")
    let state = rnStore(defaults: defaults).state
    #expect(state.rnodeFrequencyHz == 868_100_000)
    #expect(state.rnodeSpreadingFactor == 13)
    #expect(!state.rnodeWillDial)
}

/// The string is planted under the real key, so the test goes through `rnodeRadioUUID`.
@MainActor @Test func rnSettingsBadRadioIDReadsAsNoRadio() {
    let defaults = UserDefaults.inMemory
    defaults.set("not-a-uuid", forKey: "rnodeRadioID")
    let state = rnStore(defaults: defaults).state
    #expect(state.rnodeRadioID == "not-a-uuid")
    #expect(state.rnodeRadioUUID == nil)
    #expect(state.rnodeRadioLabel == "None")
}

/// Exhaustive: each edit changes state only. No effect runs and no action is received, so nothing
/// reaches a running radio until the next Connect.
@MainActor @Test func rnSettingsEditingSendsNoEndpointAction() async {
    let store = rnStore()
    store.exhaustivity = .on
    await store.send(.binding(.set(\.rnodeEnabled, true))) {
        $0.$rnodeEnabled.withLock { $0 = true }
    }
    await store.send(.rnodeFrequencyTextChanged("868.1")) {
        $0.$rnodeFrequencyHz.withLock { $0 = 868_100_000 }
    }
    await store.send(.rnodeBandwidthTextChanged("x")) {
        $0.rnodeTextProblems = [.bandwidthUnreadable]
    }
    await store.send(.rnodeBandwidthTextChanged("125")) {
        $0.$rnodeBandwidthHz.withLock { $0 = 125_000 }
        $0.rnodeTextProblems = []
    }
    await store.send(.rnodeSpreadingFactorChanged(10)) {
        $0.$rnodeSpreadingFactor.withLock { $0 = 10 }
    }
    await store.send(.rnodeCodingRateChanged(5)) {
        $0.$rnodeCodingRate.withLock { $0 = 5 }
    }
    await store.send(.rnodeTXPowerChanged(17)) {
        $0.$rnodeTXPowerDBm.withLock { $0 = 17 }
    }
}

@Test func rnSettingsGateIsOnInDebug() {
    #if DEBUG
    #expect(RNodeReleaseGate.isCompiledIn)
    #else
    #expect(!RNodeReleaseGate.isCompiledIn)
    #endif
}

@MainActor @Test func rnSettingsAvailableDefaultsToTheGate() {
    #expect(rnStore().state.rnodeAvailable == RNodeReleaseGate.isCompiledIn)
}

/// Review Focus 2: stale defaults with a problem can still be turned off.
@MainActor @Test func rnSettingsToggleStaysEnabledWhileOn() {
    let defaults = UserDefaults.inMemory
    defaults.set(true, forKey: "rnodeEnabled")
    let state = rnStore(defaults: defaults).state
    #expect(!state.rnodeSettingsProblems.isEmpty)
    #expect(!state.rnodeToggleDisabled)
}

@MainActor @Test func rnSettingsToggleIsDisabledWhileOffWithProblems() {
    let off = rnStore().state
    #expect(!off.rnodeSettingsProblems.isEmpty)
    #expect(off.rnodeToggleDisabled)
    let defaults = UserDefaults.inMemory
    defaults.set(868_100_000, forKey: "rnodeFrequencyHz")
    let complete = rnStore(defaults: defaults).state
    #expect(complete.rnodeSettingsProblems.isEmpty)
    #expect(!complete.rnodeToggleDisabled)
}
