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

let mcRadioIDA = UUID(uuidString: "C0C0C0C0-0000-4000-8000-0000000000A1")!
let mcRadioIDB = UUID(uuidString: "D0D0D0D0-0000-4000-8000-0000000000B2")!
let mcSlotIDA = meshCoreInterfaceID(radio: mcRadioIDA)
let mcSlotIDB = meshCoreInterfaceID(radio: mcRadioIDB)
/// The radio's 32-byte public key; `.connected` carries its first 4 bytes as `selfPrefix`.
let mcRadioPublicKey = Data((0..<32).map { UInt8($0 + 1) })

/// What the mock MeshCore driver was asked to do. `secretBytes` is the length of the start's
/// `channelSecret`, never its value: 0 when the driver sits under the reducer with no wrapper.
enum McRadioCall: Equatable { case start(UUID, canRoute: Bool, secretBytes: Int), stop, removeChannel }

/// A slot-level command the store reduced (`.node(.client(.endpoint(.meshCore(…))))`), whether or not
/// the interface passed it on to the driver: an online interface ignores `.start`.
enum McSlotCommand: Equatable, Sendable { case start, stop, removeChannel }

/// A mock MeshCore driver shaped like the live adapter: every `start` opens a FRESH session
/// stream; `stop` and `removeChannel` block while held and are recorded only when they RETURN.
final class MeshCoreRadioHarness: Sendable {
    let calls = LockIsolated<[McRadioCall]>([])
    /// Every config `start` received, in order. Test-only: this is how the wrapper tests see the
    /// key the wrapper filled in.
    let configs = LockIsolated<[MeshCoreDriverConfig]>([])
    let sessions = LockIsolated<[AsyncStream<MeshCoreDriverEvent>.Continuation]>([])
    let sent = LockIsolated<[MeshSentFrame]>([])
    /// What `removeChannel` returns.
    let removalResult = LockIsolated(true)
    private let stopsHeld = LockIsolated(false)
    private let removalsHeld = LockIsolated(false)

    var driver: MeshCoreDriver {
        MeshCoreDriver(
            start: { [self] config in
                let session = AsyncStream<MeshCoreDriverEvent>.makeStream()
                calls.withValue {
                    $0.append(.start(config.radio, canRoute: config.canRoute, secretBytes: config.channelSecret.count))
                }
                configs.withValue { $0.append(config) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { [self] frame in
                let index = sessions.value.count - 1
                sent.withValue { $0.append(MeshSentFrame(session: index, frame: frame)) }
                return true
            },
            removeChannel: { [self] in
                while removalsHeld.value { await Task.yield() }
                calls.withValue { $0.append(.removeChannel) }
                return removalResult.value
            },
            stop: { [self] in
                while stopsHeld.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
    }

    var startCount: Int { calls.value.filter { if case .start = $0 { return true }; return false }.count }

    func holdStops() { stopsHeld.setValue(true) }
    func releaseStops() { stopsHeld.setValue(false) }
    func holdRemovals() { removalsHeld.setValue(true) }
    func releaseRemovals() { removalsHeld.setValue(false) }
    func yieldToLatest(_ event: MeshCoreDriverEvent) { sessions.value.last?.yield(event) }
    func finishLatest() { sessions.value.last?.finish() }

    func waitForCalls(_ count: Int) async {
        for _ in 0..<300 where calls.value.count < count { await Task.megaYield() }
    }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<300 where startCount < count { await Task.megaYield() }
    }
}

/// An in-memory Keychain holding `mcHexA` as the channel key.
func mcKeyedKeychain() -> InMemoryKeychain {
    let (keychain, store) = mcKeychain()
    _ = store.paste(MeshCoreKeyText(mcHexA))
    return keychain
}

/// An AppFeature store with MeshCore on (when `radio` is non-nil and `enabled`), a key store over
/// `keychain` (by default holding a key), `radioHarness` as the MeshCore driver and `meshtastic` as the Meshtastic
/// driver, and every other dependency hermetic. Built like `meshRadioStore`.
@MainActor
func mcRadioStore(radio: UUID?, enabled: Bool = true, radioHarness: MeshCoreRadioHarness,
                  meshtastic: MeshRadioHarness = MeshRadioHarness(),
                  tcp: MeshTCPHarness = MeshTCPHarness(),
                  keychain: InMemoryKeychain = mcKeyedKeychain(),
                  removeChannelSends: LockIsolated<Int>? = nil,
                  slotCommands: LockIsolated<[McSlotCommand]>? = nil,
                  configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    let store = MeshCoreKeyStore.live(ops: keychain.ops)
    let defaults = UserDefaults.inMemory
    var initial = withDependencies {
        $0.defaultAppStorage = defaults
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    initial.$meshCoreEnabled.withLock { $0 = enabled }
    initial.$meshCoreRadioID.withLock { $0 = radio?.uuidString }
    initial.meshCoreKeyPresence = store.presence()
    configure?(&initial)
    let db = try! AppDatabase.makeInMemory()
    let testStore = TestStore(initialState: initial) {
        CombineReducers {
            AppFeature()
            // Counts the `.removeChannel`s the store reduces, when the test asks: lane B's
            // interface answers one sent to a radio that isn't online without calling the driver,
            // so the harness never sees it.
            Reduce<AppFeature.State, AppFeature.Action> { _, action in
                if case .node(.client(.endpoint(.meshCore(.removeChannel)))) = action {
                    removeChannelSends?.withValue { $0 += 1 }
                }
                // Every slot-level command the store reduces, in order: an absence check reads this
                // once a barrier action proves the effect that would have sent one has run.
                switch action {
                case .node(.client(.endpoint(.meshCore(.start)))): slotCommands?.withValue { $0.append(.start) }
                case .node(.client(.endpoint(.meshCore(.stop)))): slotCommands?.withValue { $0.append(.stop) }
                case .node(.client(.endpoint(.meshCore(.removeChannel)))):
                    slotCommands?.withValue { $0.append(.removeChannel) }
                default: break
                }
                return .none
            }
        }
    } withDependencies: {
        $0.badge = .ignored
        $0.defaultAppStorage = defaults
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = tcp.connection
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in },
                                     close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in },
                                 openChannel: { _ in }, send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
        $0.radioScanner = RadioScanner(scan: { AsyncStream { _ in } })
        $0.meshtasticDriver = meshtastic.driver
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 1_700_000_000) }
        $0.meshCoreKeyStore = store
        $0.meshCoreDriver = radioHarness.driver
        $0.meshCoreClock = ImmediateClock()
        $0.meshCoreDate = DateGenerator { Date(timeIntervalSince1970: 1_700_000_000) }
    }
    testStore.exhaustivity = .off
    return testStore
}

/// Brings the newest MeshCore driver session online and waits for its interface to register.
/// Time-based waits with room for a whole-package run, where effects can wait seconds for a thread.
@MainActor
func mcBringRadioOnline(_ store: TestStoreOf<AppFeature>, _ radio: MeshCoreRadioHarness, id: InterfaceID,
                        starts: Int = 1,
                        params: MeshCoreLinkParams? = MeshCoreLinkParams(spreadingFactor: 10, bandwidthHz: 250_000,
                                                                         codingRate: 5)) async {
    _ = await meshWaitUntil(timeout: .seconds(20)) { radio.startCount >= starts }
    radio.yieldToLatest(.connected(selfPrefix: mcRadioPublicKey.prefix(4), publicKey: mcRadioPublicKey,
                                   params: params))
    await store.receive({ isInterfaceConnected($0, id) }, timeout: .seconds(20))
}

/// Polls `store`'s state until `condition` holds or `timeout` passes. A TestStore's `state` moves
/// only as received actions are consumed, so each round skips them first. Returns as soon as the
/// condition holds, so only a failing check pays the timeout.
@MainActor
func mcEventually(_ store: TestStoreOf<AppFeature>, timeout: Duration = .seconds(20),
                  _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        await store.skipReceivedActions(strict: false)
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    await store.skipReceivedActions(strict: false)
    return condition()
}

/// True when every config the reducer handed the driver kept the key out of state: an empty channel
/// secret and an empty retired list (the wrapper fills both only at `driver.start`).
func mcConfigsHoldNoKey(_ radio: MeshCoreRadioHarness) -> Bool {
    radio.configs.value.allSatisfy { $0.channelSecret.isEmpty && $0.retiredChannelSecrets.isEmpty }
}

func isMeshCoreRadioOffline(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.meshCore(.delegate(.radioOffline))))) = action { return true }
    return false
}

/// True when no `.start` follows a `.start` without a `.stop` between them.
func mcNoOverlappingStarts(_ calls: [McRadioCall]) -> Bool {
    var running = false
    for call in calls {
        switch call {
        case .start:
            if running { return false }
            running = true
        case .stop:
            running = false
        case .removeChannel:
            break
        }
    }
    return true
}
