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

let rnRadioIDA = UUID(uuidString: "E0E0E0E0-0000-4000-8000-0000000000A1")!
let rnRadioIDB = UUID(uuidString: "F0F0F0F0-0000-4000-8000-0000000000B2")!
let rnSlotIDA = rnodeInterfaceID(radio: rnRadioIDA)
let rnSlotIDB = rnodeInterfaceID(radio: rnRadioIDB)

/// Lane C's settings, complete: 868.1 MHz, 62.5 kHz, SF 8, CR 6, 0 dBm.
let rnCompleteSettings = RNodeRadioSettings(frequencyHz: 868_100_000, bandwidthHz: 62_500,
                                            spreadingFactor: 8, codingRate: 6, txPowerDBm: 0)

/// What the mock RNode driver was asked to do.
enum RnRadioCall: Equatable { case start(RNodeDriverConfig), stop }

/// A slot-level command the store reduced (`.node(.client(.endpoint(.rnode(…))))`), whether or not
/// the interface passed it on to the driver: an online interface ignores `.start`.
enum RnSlotCommand: Equatable, Sendable { case start, stop }

struct RNodeSentFrame: Equatable, Sendable {
    var session: Int
    var frame: Data
}

/// A mock RNode driver shaped like the live adapter: every `start` opens a FRESH session stream;
/// `stop` blocks while held and is recorded only when it RETURNS.
final class RNodeRadioHarness: Sendable {
    let calls = LockIsolated<[RnRadioCall]>([])
    let sessions = LockIsolated<[AsyncStream<RNodeDriverEvent>.Continuation]>([])
    let sent = LockIsolated<[RNodeSentFrame]>([])
    private let stopsHeld = LockIsolated(false)

    var driver: RNodeDriver {
        RNodeDriver(
            start: { [self] config in
                let session = AsyncStream<RNodeDriverEvent>.makeStream()
                calls.withValue { $0.append(.start(config)) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { [self] frame in
                let index = sessions.value.count - 1
                sent.withValue { $0.append(RNodeSentFrame(session: index, frame: frame)) }
                return true
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
    func yieldToLatest(_ event: RNodeDriverEvent) { sessions.value.last?.yield(event) }
    func finishLatest() { sessions.value.last?.finish() }

    func waitForCalls(_ count: Int) async {
        for _ in 0..<300 where calls.value.count < count { await Task.megaYield() }
    }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<300 where startCount < count { await Task.megaYield() }
    }
}

/// An AppFeature store with the RNode on (when `radio` is non-nil and `enabled`), `settings` stored
/// (nil leaves the app's defaults), `radioHarness` as the RNode driver, `meshtastic` and `meshCore`
/// as the other radios' drivers, and every other dependency hermetic. Built like `mcRadioStore`.
/// `slotCommands`, when given, logs every RNode slot command the store reduces.
@MainActor
func rnRadioStore(radio: UUID?, enabled: Bool = true, settings: RNodeRadioSettings? = rnCompleteSettings,
                  radioHarness: RNodeRadioHarness,
                  meshtastic: MeshRadioHarness = MeshRadioHarness(),
                  meshCore: MeshCoreRadioHarness = MeshCoreRadioHarness(),
                  tcp: MeshTCPHarness = MeshTCPHarness(),
                  slotCommands: LockIsolated<[RnSlotCommand]>? = nil,
                  configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    let keyStore = MeshCoreKeyStore.live(ops: mcKeyedKeychain().ops)
    let defaults = UserDefaults.inMemory
    var initial = withDependencies {
        $0.defaultAppStorage = defaults
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    initial.$rnodeEnabled.withLock { $0 = enabled }
    initial.$rnodeRadioID.withLock { $0 = radio?.uuidString }
    if let settings {
        initial.$rnodeFrequencyHz.withLock { $0 = settings.frequencyHz }
        initial.$rnodeBandwidthHz.withLock { $0 = settings.bandwidthHz }
        initial.$rnodeSpreadingFactor.withLock { $0 = settings.spreadingFactor }
        initial.$rnodeCodingRate.withLock { $0 = settings.codingRate }
        initial.$rnodeTXPowerDBm.withLock { $0 = settings.txPowerDBm }
    }
    initial.$listenEnabled.withLock { $0 = false }   // isolate the radio: no LAN listener
    configure?(&initial)
    let db = try! AppDatabase.makeInMemory()
    let testStore = TestStore(initialState: initial) {
        CombineReducers {
            AppFeature()
            // Every slot-level command the store reduces, in order: an absence check reads this
            // once a barrier action proves the effect that would have sent one has run.
            Reduce<AppFeature.State, AppFeature.Action> { _, action in
                switch action {
                case .node(.client(.endpoint(.rnode(.start)))): slotCommands?.withValue { $0.append(.start) }
                case .node(.client(.endpoint(.rnode(.stop)))): slotCommands?.withValue { $0.append(.stop) }
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
        $0.meshCoreKeyStore = keyStore
        $0.meshCoreDriver = meshCore.driver
        $0.meshCoreRadioDetails = { nil }
        $0.meshCoreClock = ImmediateClock()
        $0.meshCoreDate = DateGenerator { Date(timeIntervalSince1970: 1_700_000_000) }
        $0.rnodeDriver = radioHarness.driver
    }
    testStore.exhaustivity = .off
    return testStore
}

/// What a radio that echoes `rnCompleteSettings` reports.
let rnCompleteReport = RNodeRadioReport(
    name: "RNode 1A2B", firmwareMajor: 1, firmwareMinor: 78, platform: 0x80,
    params: RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 0,
                            spreadingFactor: 8, codingRate: 6))

/// Brings the newest RNode driver session online and waits for its interface to register.
/// Time-based waits with room for a whole-package run, where effects can wait seconds for a thread.
@MainActor
func rnBringRadioOnline(_ store: TestStoreOf<AppFeature>, _ radio: RNodeRadioHarness, id: InterfaceID,
                        starts: Int = 1, report: RNodeRadioReport = rnCompleteReport) async {
    _ = await meshWaitUntil(timeout: .seconds(20)) { radio.startCount >= starts }
    radio.yieldToLatest(.connected(report))
    await store.receive({ isInterfaceConnected($0, id) }, timeout: .seconds(20))
}

/// Polls `store`'s state until `condition` holds or `timeout` passes. A TestStore's `state` moves
/// only as received actions are consumed, so each round skips them first. Returns as soon as the
/// condition holds, so only a failing check pays the timeout.
@MainActor
func rnEventually(_ store: TestStoreOf<AppFeature>, timeout: Duration = .seconds(20),
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

func isRNodeRadioOffline(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.rnode(.delegate(.radioOffline))))) = action { return true }
    return false
}

/// True when no `.start` follows a `.start` without a `.stop` between them.
func rnNoOverlappingStarts(_ calls: [RnRadioCall]) -> Bool {
    var running = false
    for call in calls {
        switch call {
        case .start:
            if running { return false }
            running = true
        case .stop:
            running = false
        }
    }
    return true
}
