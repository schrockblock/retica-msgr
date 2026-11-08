import Testing
import Foundation
import Security
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
import ReTiCAKeychain
@testable import ReTiCAMsgrCore

// Task 4 (lane C): the MeshCore key actions, copy and the result messages. "Paste" here is what the
// paste sheet does: call the store, then send `.meshCoreKeyDidChange(result)`.

private let invalidMessage =
    "Enter a key of 32 hex characters. A key other people already use for something else can't be used here."
private let storageFailedMessage = "The key couldn't be saved. Try again."

/// The key the dump tests' generator returns, so every key in that flow is known. Test-only value.
private let mcHexG = "5d4c3b2a19087f6e5d4c3b2a19087f6e"

private func isDidChange(_ result: MeshCoreKeyChangeResult) -> (AppFeature.Action) -> Bool {
    { action in
        if case let .meshCoreKeyDidChange(got) = action { return got == result }
        return false
    }
}

/// A key store over a fresh in-memory Keychain that already holds `hex` as its key.
private func mcKeychain(holding hex: String) -> (InMemoryKeychain, MeshCoreKeyStore) {
    let (keychain, keyStore) = mcKeychain()
    let seeded = keyStore.paste(MeshCoreKeyText(hex))
    precondition(seeded == .changed)
    return (keychain, keyStore)
}

/// Records what the pasteboard was given.
private func recordingPasteboard() -> (LockIsolated<MeshCoreKeyText?>, MeshCoreKeyPasteboard) {
    let copied = LockIsolated<MeshCoreKeyText?>(nil)
    return (copied, MeshCoreKeyPasteboard { text in copied.setValue(text) })
}

// MARK: - Presence and generation

@MainActor @Test func mcKeyFlowLaunchLoadsPresence() async {
    let (_, keyStore) = mcKeychain(holding: mcHexA)
    let store = mcStore(keyStore: keyStore)
    #expect(store.state.meshCoreKeyPresence == .absent)
    await store.send(.onLaunch)
    #expect(store.state.meshCoreKeyPresence == .present)
}

@MainActor @Test func mcKeyFlowGenerateMakesTheKeyPresent() async {
    let (_, keyStore) = mcKeychain()
    let store = mcStore(keyStore: keyStore)
    await store.send(.meshCoreGenerateKeyTapped)
    await store.receive(isDidChange(.changed))
    #expect(store.state.meshCoreKeyPresence == .present)
}

@MainActor @Test func mcKeyFlowChangeBumpsTheGeneration() async {
    let (_, keyStore) = mcKeychain()
    let store = mcStore(keyStore: keyStore)
    #expect(store.state.meshCoreKeyGeneration == 0)
    await store.send(.meshCoreKeyDidChange(keyStore.paste(MeshCoreKeyText(mcHexA))))
    #expect(store.state.meshCoreKeyGeneration == 1)
}

@MainActor @Test func mcKeyFlowUnchangedDoesNotBumpTheGeneration() async {
    let (_, keyStore) = mcKeychain(holding: mcHexA)
    let store = mcStore(keyStore: keyStore)
    let result = keyStore.paste(MeshCoreKeyText(mcHexA))
    #expect(result == .unchanged)
    await store.send(.meshCoreKeyDidChange(result))
    #expect(store.state.meshCoreKeyGeneration == 0)
    #expect(store.state.meshCoreKeyMessage == nil)
}

// MARK: - Messages

@MainActor @Test func mcKeyFlowInvalidPasteShowsAMessage() async {
    let (_, keyStore) = mcKeychain()
    let store = mcStore(keyStore: keyStore)
    let result = keyStore.paste(MeshCoreKeyText("not a key"))
    #expect(result == .invalid)
    await store.send(.meshCoreKeyDidChange(result))
    #expect(store.state.meshCoreKeyMessage == invalidMessage)
    #expect(store.state.meshCoreKeyGeneration == 0)
    #expect(store.state.meshCoreKeyPresence == .absent)
}

@MainActor @Test func mcKeyFlowStorageFailureShowsAMessage() async {
    let (keychain, keyStore) = mcKeychain()
    keychain.failAdd(at: MeshCoreKeyStore.keyLocation, status: errSecNotAvailable)
    let store = mcStore(keyStore: keyStore)
    await store.send(.meshCoreGenerateKeyTapped)
    await store.receive(isDidChange(.storageFailed))
    #expect(store.state.meshCoreKeyMessage == storageFailedMessage)
    #expect(store.state.meshCoreKeyGeneration == 0)
}

@MainActor @Test func mcKeyFlowASuccessfulChangeClearsAnOldMessage() async {
    let (_, keyStore) = mcKeychain()
    let store = mcStore(keyStore: keyStore)
    await store.send(.meshCoreKeyDidChange(keyStore.paste(MeshCoreKeyText("not a key"))))
    #expect(store.state.meshCoreKeyMessage == invalidMessage)
    await store.send(.meshCoreKeyDidChange(keyStore.paste(MeshCoreKeyText(mcHexA))))
    #expect(store.state.meshCoreKeyMessage == nil)
}

// MARK: - Copy

@MainActor @Test func mcKeyFlowCopyGivesThePasteboardTheKey() async {
    let (_, keyStore) = mcKeychain(holding: mcHexA)
    let (copied, pasteboard) = recordingPasteboard()
    let store = mcStore(keyStore: keyStore)
    store.dependencies.meshCoreKeyPasteboard = pasteboard
    await store.send(.meshCoreCopyKeyTapped)
    await store.finish()
    // Comparing, never printing: a failure shows only `<redacted>`.
    #expect(copied.value?.reveal() == mcHexA)
}

@MainActor @Test func mcKeyFlowCopyWithoutAKeyCopiesNothing() async {
    let (_, keyStore) = mcKeychain()
    let (copied, pasteboard) = recordingPasteboard()
    let store = mcStore(keyStore: keyStore)
    store.dependencies.meshCoreKeyPasteboard = pasteboard
    await store.send(.meshCoreCopyKeyTapped)
    await store.finish()
    #expect(copied.value == nil)
}

// MARK: - Retiring

@MainActor @Test func mcKeyFlowPasteOverAKeyRetiresTheOldKey() async throws {
    let (_, keyStore) = mcKeychain(holding: mcHexA)
    let store = mcStore(keyStore: keyStore)
    await store.send(.meshCoreKeyDidChange(keyStore.paste(MeshCoreKeyText(mcHexB))))
    let keyA = try #require(Data(hexString: mcHexA))
    #expect(keyStore.secrets()?.retired == [keyA])
    #expect(store.state.meshCoreKeyGeneration == 1)
}

@MainActor @Test func mcKeyFlowGenerateOverAKeyRetiresTheOldKey() async throws {
    let (_, keyStore) = mcKeychain(holding: mcHexA)
    let store = mcStore(keyStore: keyStore)
    await store.send(.meshCoreGenerateKeyTapped)
    await store.receive(isDidChange(.changed))
    let keyA = try #require(Data(hexString: mcHexA))
    #expect(keyStore.secrets()?.retired == [keyA])
    #expect(store.state.meshCoreKeyGeneration == 1)
}

// MARK: - Nothing carries a key

/// Runs `base`, then records `String(customDumping:)` of the action and of the state after it.
private struct RecordingReducer<Base: Reducer>: Reducer
where Base.State == AppFeature.State, Base.Action == AppFeature.Action {
    let base: Base
    let actions: LockIsolated<[String]>
    let states: LockIsolated<[String]>

    func reduce(into state: inout AppFeature.State, action: AppFeature.Action) -> Effect<AppFeature.Action> {
        let effect = base.reduce(into: &state, action: action)
        let actionDump = String(customDumping: action)
        let stateDump = String(customDumping: state)
        actions.withValue { $0.append(actionDump) }
        states.withValue { $0.append(stateDump) }
        return effect
    }
}

/// What the dump tests found. Holds only counts and flags, so a failing `#expect` never prints a key.
private struct DumpFlowOutcome {
    var actionRecords = 0
    var stateRecords = 0
    var actionLeaks = 0
    var stateLeaks = 0
    var exportIsB = false
    var aIsRetired = false
}

/// Every way a key could be spelled in a dump: hex either case, base64, and its decimal bytes.
private func spellings(of hex: String) -> [String] {
    guard let key = Data(hexString: hex) else { return [] }
    let bytes = [UInt8](key)
    return [hex.lowercased(), hex.uppercased(), key.base64EncodedString(),
            bytes.description, String(customDumping: bytes)]
}

/// An AppFeature store wrapped in `RecordingReducer`, with `mcStore`'s hermetic dependencies. Drives
/// generate, paste A, paste B, copy and `.onLaunch`, then scans every record for every key involved.
@MainActor
private func runDumpFlow() async -> DumpFlowOutcome {
    let keychain = InMemoryKeychain()
    let keyG = Data(hexString: mcHexG)!
    let keyStore = MeshCoreKeyStore.live(ops: keychain.ops, randomKey: { keyG })
    let actions = LockIsolated<[String]>([])
    let states = LockIsolated<[String]>([])
    let defaults = UserDefaults.inMemory
    let initial = withDependencies {
        $0.defaultAppStorage = defaults
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    let db = try! AppDatabase.makeInMemory()
    let store = TestStore(initialState: initial) {
        RecordingReducer(base: AppFeature(), actions: actions, states: states)
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
        $0.radioScanner = RadioScanner(scan: { AsyncStream { _ in } })
        $0.meshCoreKeyStore = keyStore
        $0.meshCoreKeyPasteboard = MeshCoreKeyPasteboard { _ in }
    }
    store.exhaustivity = .off

    await store.send(.meshCoreGenerateKeyTapped)
    await store.receive(isDidChange(.changed))
    await store.send(.meshCoreKeyDidChange(keyStore.paste(MeshCoreKeyText(mcHexA))))
    await store.send(.meshCoreKeyDidChange(keyStore.paste(MeshCoreKeyText(mcHexB))))
    await store.send(.meshCoreCopyKeyTapped)
    await store.send(.onLaunch)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)

    let keys = [mcHexG, mcHexA, mcHexB].flatMap(spellings(of:))
    let actionRecords = actions.value
    let stateRecords = states.value
    var outcome = DumpFlowOutcome()
    outcome.actionRecords = actionRecords.count
    outcome.stateRecords = stateRecords.count
    outcome.actionLeaks = actionRecords.filter { record in keys.contains { record.contains($0) } }.count
    outcome.stateLeaks = stateRecords.filter { record in keys.contains { record.contains($0) } }.count
    outcome.exportIsB = keyStore.exportText()?.reveal() == mcHexB
    let keyA = Data(hexString: mcHexA)!
    outcome.aIsRetired = keyStore.secrets()?.retired.contains(keyA) == true
    return outcome
}

@MainActor @Test func mcKeyFlowStateDumpCarriesNoKey() async {
    let outcome = await runDumpFlow()
    #expect(outcome.stateRecords > 0)
    #expect(outcome.exportIsB)
    #expect(outcome.aIsRetired)
    #expect(outcome.stateLeaks == 0)
}

@MainActor @Test func mcKeyFlowActionDumpCarriesNoKey() async {
    let outcome = await runDumpFlow()
    #expect(outcome.actionRecords > 0)
    #expect(outcome.exportIsB)
    #expect(outcome.aIsRetired)
    #expect(outcome.actionLeaks == 0)
}
