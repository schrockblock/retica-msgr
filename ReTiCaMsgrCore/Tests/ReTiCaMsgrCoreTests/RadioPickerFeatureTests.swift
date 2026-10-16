import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCaMsgrCore

// MARK: - Fixtures

private let alpha = UUID(uuidString: "A1A1A1A1-0000-4000-8000-000000000001")!
private let bravo = UUID(uuidString: "B2B2B2B2-0000-4000-8000-000000000002")!
private let alphaRadio = RadioScanResult(id: alpha, name: "Alpha", rssi: -70)
private let bravoRadio = RadioScanResult(id: bravo, name: "Bravo", rssi: -65)

/// Polls `condition` until it holds or `timeout` passes. Real time, not a TestClock: stream
/// termination runs on the cancelled effect's task, outside the store. Used by T3 too.
func waitUntil(timeout: Duration = .seconds(2), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A picker store with a scanner that never emits unless one is given, and a dismiss that only
/// records that it ran (the default `\.dismiss` reports an issue outside a presentation).
@MainActor
private func pickerStore(scanner: RadioScanner = RadioScanner(scan: { AsyncStream { _ in } }),
                         dismissed: LockIsolated<Bool> = LockIsolated(false)) -> TestStoreOf<RadioPickerFeature> {
    let store = TestStore(initialState: RadioPickerFeature.State()) {
        RadioPickerFeature()
    } withDependencies: {
        $0.radioScanner = scanner
        $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }
    store.exhaustivity = .off
    return store
}

// MARK: - Results

@MainActor @Test func radioPickerShowsRadiosTheScanReports() async {
    let (stream, continuation) = AsyncStream.makeStream(of: RadioScanResult.self)
    let store = pickerStore(scanner: RadioScanner(scan: { stream }))
    await store.send(.onAppear)
    continuation.yield(alphaRadio)
    await store.receive { if case .radioFound = $0 { return true }; return false }
    #expect(store.state.radios.map(\.id) == [alpha])
    continuation.finish()
}

/// A radio advertises over and over: one row, at its first-seen position, with the newest RSSI.
@MainActor @Test func radioPickerRepeatedRadioUpdatesItsRowInPlace() async {
    let store = pickerStore()
    await store.send(.radioFound(RadioScanResult(id: alpha, name: "Alpha", rssi: -80)))
    await store.send(.radioFound(RadioScanResult(id: bravo, name: "Bravo", rssi: -70)))
    await store.send(.radioFound(RadioScanResult(id: alpha, name: "Alpha", rssi: -60)))
    #expect(store.state.radios.map(\.id) == [alpha, bravo])
    #expect(store.state.radios[id: alpha]?.rssi == -60)
}

/// Not every advertisement carries the local name (a scan response may be missing): a repeat
/// without one must not blank the name already shown.
@MainActor @Test func radioPickerRepeatWithoutNameKeepsTheKnownName() async {
    let store = pickerStore()
    await store.send(.radioFound(RadioScanResult(id: alpha, name: "Alpha", rssi: -80)))
    await store.send(.radioFound(RadioScanResult(id: alpha, name: nil, rssi: -60)))
    #expect(store.state.radios[id: alpha]?.name == "Alpha")
}

/// Review Focus 3: the advertised name is unauthenticated free text.
@Test func radioPickerUnnamedRadioShowsAFallbackName() {
    #expect(RadioScanResult(id: alpha, name: nil, rssi: -50).displayName == "Unnamed radio")
    #expect(RadioScanResult(id: alpha, name: "  \n", rssi: -50).displayName == "Unnamed radio")
    #expect(RadioScanResult(id: alpha, name: " Base camp ", rssi: -50).displayName == "Base camp")
}

// MARK: - Scan lifecycle

@MainActor @Test func radioPickerScanEndingMarksTheScanEnded() async {
    let store = pickerStore(scanner: RadioScanner(scan: { AsyncStream { $0.finish() } }))
    await store.send(.onAppear)
    await store.receive { if case .scanFinished = $0 { return true }; return false }
    #expect(store.state.scanEnded)
}

/// Review Focus 5 and the loud-stub decision: until lane E installs the MeshtasticKit scanner,
/// the LIVE value must end the scan (so the sheet says why it found nothing) rather than spin.
/// Asserts only the action, so the `scanFinished` arm's own mutation cannot mask this one.
@MainActor @Test func radioPickerUninstalledLiveScannerEndsTheScan() async {
    let store = pickerStore(scanner: RadioScanner.liveValue)
    await store.send(.onAppear)
    await store.receive { if case .scanFinished = $0 { return true }; return false }
}

/// Review Focus 5: FCB has ONE scan per process and a new scan supersedes the old (spec §2). A
/// second appear (SwiftUI may fire onAppear again) must replace the first scan, not run beside it.
@MainActor @Test func radioPickerSecondAppearReplacesTheFirstScan() async {
    let started = LockIsolated(0)
    let ended = LockIsolated<Set<Int>>([])
    let scanner = RadioScanner(scan: {
        let n = started.withValue { count in
            count += 1
            return count
        }
        return AsyncStream { continuation in
            continuation.onTermination = { _ in ended.withValue { _ = $0.insert(n) } }
        }
    })
    let store = pickerStore(scanner: scanner)
    await store.send(.onAppear)
    #expect(await waitUntil { started.value == 1 })
    await store.send(.onAppear)
    #expect(await waitUntil { started.value == 2 })
    #expect(await waitUntil { ended.value.contains(1) })
    #expect(!ended.value.contains(2))
}

// MARK: - Pick and cancel

@MainActor @Test func radioPickerTapReportsTheTappedRadio() async {
    let store = pickerStore()
    await store.send(.radioFound(alphaRadio))
    await store.send(.radioFound(bravoRadio))
    await store.send(.radioTapped(bravo))
    await store.receive {
        if case let .delegate(.selected(radio)) = $0 { return radio.id == bravo }
        return false
    }
}

@MainActor @Test func radioPickerTapDismisses() async {
    let dismissed = LockIsolated(false)
    let store = pickerStore(dismissed: dismissed)
    await store.send(.radioFound(alphaRadio))
    await store.send(.radioTapped(alpha))
    await store.finish()
    #expect(dismissed.value)
}

@MainActor @Test func radioPickerCancelDismisses() async {
    let dismissed = LockIsolated(false)
    let store = pickerStore(dismissed: dismissed)
    await store.send(.radioFound(alphaRadio))
    await store.send(.cancelTapped)
    await store.finish()
    #expect(dismissed.value)
}

/// EXHAUSTIVE on purpose: the claim is that Cancel reports NOTHING, and `.off` cannot see a
/// stray action. Any `.delegate` received here fails the test at `finish()`.
@MainActor @Test func radioPickerCancelReportsNoRadio() async {
    let store = TestStore(initialState: RadioPickerFeature.State()) {
        RadioPickerFeature()
    } withDependencies: {
        $0.radioScanner = RadioScanner(scan: { AsyncStream { _ in } })
        $0.dismiss = DismissEffect { }
    }
    await store.send(.radioFound(alphaRadio)) { $0.radios = [alphaRadio] }
    await store.send(.cancelTapped)
    await store.finish()
}
