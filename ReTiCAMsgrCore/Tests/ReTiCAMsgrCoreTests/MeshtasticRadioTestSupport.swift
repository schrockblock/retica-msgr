import Testing
import Foundation
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
@testable import ReTiCAMsgrCore

let meshSlotRadioA = UUID(uuidString: "A0A0A0A0-0000-4000-8000-0000000000A1")!
let meshSlotRadioB = UUID(uuidString: "B0B0B0B0-0000-4000-8000-0000000000B2")!
let meshSlotIDA = meshtasticInterfaceID(radio: meshSlotRadioA)
let meshSlotIDB = meshtasticInterfaceID(radio: meshSlotRadioB)
let meshSlotOwnNode: UInt32 = 0x0A0A_0A0A
let meshSlotPeerNode: UInt32 = 0x0B0B_0B0B

enum MeshRadioCall: Equatable { case start(UUID), stop }

struct MeshSentFrame: Equatable, Sendable {
    var session: Int
    var frame: Data
}

/// A mock Meshtastic driver shaped like the live adapter: every `start` opens a FRESH session
/// stream; `stop` blocks while stops are held and records `.stop` only when it RETURNS.
final class MeshRadioHarness: Sendable {
    let calls = LockIsolated<[MeshRadioCall]>([])
    let sessions = LockIsolated<[AsyncStream<MeshtasticDriverEvent>.Continuation]>([])
    let sent = LockIsolated<[MeshSentFrame]>([])
    private let held = LockIsolated(false)

    var driver: MeshtasticDriver {
        MeshtasticDriver(
            start: { [self] config in
                let session = AsyncStream<MeshtasticDriverEvent>.makeStream()
                calls.withValue { $0.append(.start(config.radio)) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { [self] frame in
                let index = sessions.value.count - 1
                sent.withValue { $0.append(MeshSentFrame(session: index, frame: frame)) }
                return true
            },
            stop: { [self] in
                while held.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
    }

    var startCount: Int { calls.value.filter { if case .start = $0 { return true }; return false }.count }

    func holdStops() { held.setValue(true) }
    func releaseStops() { held.setValue(false) }
    func yieldToLatest(_ event: MeshtasticDriverEvent) { sessions.value.last?.yield(event) }

    func waitForCalls(_ count: Int) async {
        for _ in 0..<300 where calls.value.count < count { await Task.megaYield() }
    }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<300 where startCount < count { await Task.megaYield() }
    }

    /// Complete packets put on the air in `session`, reassembled from their landandair frames.
    func reassembled(session: Int) -> [Data] {
        var bodies: [UInt8: [Int: Data]] = [:]
        var counts: [UInt8: Int] = [:]
        for item in sent.value where item.session == session {
            guard case let .data(index, pos, body)? = LandandairCodec().parse(item.frame) else { continue }
            let slot = Int(pos.magnitude)
            bodies[index, default: [:]][slot] = body
            if pos < 0 { counts[index] = slot }
        }
        return counts.keys.sorted().compactMap { index in
            guard let n = counts[index], let parts = bodies[index], (1...n).allSatisfy({ parts[$0] != nil })
            else { return nil }
            return (1...n).reduce(into: Data()) { $0.append(parts[$1]!) }
        }
    }
}

/// A hermetic TCP socket the test drives: `events` feeds the client, `sends` records writes.
final class MeshTCPHarness: Sendable {
    let stream = AsyncStream<TCPEvent>.makeStream()
    let sends = LockIsolated<[Data]>([])

    var connection: TCPConnection {
        TCPConnection(open: { [self] _, _ in stream.stream },
                      send: { [self] data in sends.withValue { $0.append(data) } },
                      close: { })
    }
}

/// An AppFeature store with Meshtastic on (when `radio` is non-nil and `enabled`), the radio
/// harness as the driver, and every other dependency hermetic (mirrors `meshStore` in
/// MeshtasticSettingsTests). Real child reducers: `LXMFServiceNode` → `LXMFNode` → `TransportEndpoint`.
@MainActor
func meshRadioStore(radio: UUID?, enabled: Bool = true, harness: MeshRadioHarness,
                    tcp: MeshTCPHarness = MeshTCPHarness(),
                    configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    let defaults = UserDefaults.inMemory
    var initial = withDependencies {
        $0.defaultAppStorage = defaults
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    initial.$meshtasticEnabled.withLock { $0 = enabled }
    initial.$meshtasticRadioID.withLock { $0 = radio?.uuidString }
    configure?(&initial)
    let db = try! AppDatabase.makeInMemory()
    let store = TestStore(initialState: initial) {
        AppFeature()
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
        $0.meshtasticDriver = harness.driver
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 1_700_000_000) }
    }
    store.exhaustivity = .off
    return store
}

func isInterfaceConnected(_ action: AppFeature.Action, _ id: InterfaceID) -> Bool {
    if case let .node(.client(.endpoint(.transport(.interfaceConnected(connected, _))))) = action { return connected == id }
    return false
}

func isRadioOffline(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.meshtastic(.delegate(.radioOffline))))) = action { return true }
    return false
}

/// Brings the newest driver session online and waits for its interface to register.
@MainActor
func meshBringRadioOnline(_ store: TestStoreOf<AppFeature>, _ radio: MeshRadioHarness, id: InterfaceID,
                          starts: Int = 1, preset: Int? = 8) async {
    await radio.waitForStarts(starts)
    radio.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: preset))
    await store.receive({ isInterfaceConnected($0, id) }, timeout: .seconds(2))
}

func meshWaitUntil(timeout: Duration = .seconds(2), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// True when no `.start` follows a `.start` without a `.stop` between them.
func meshNoOverlappingStarts(_ calls: [MeshRadioCall]) -> Bool {
    zip(calls, calls.dropFirst()).allSatisfy { pair in
        if case .start = pair.0, case .start = pair.1 { return false }
        return true
    }
}
