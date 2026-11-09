import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCARNodeLive
import RNodeKit
@testable import ReTiCAMsgrCore

// The RNode slot's delegates into `rnodeStatus`, its counters and telemetry, the announces on its
// interface's up and down, and the slow-radio photo rule (RNode lane D Task 9). Every store runs
// the real reducers down to `RNodeInterface`, over `RNodeRadioHarness`.

private func rnWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

private func isRNodeAdapterUnavailable(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.rnode(.delegate(.adapterUnavailable))))) = action { return true }
    return false
}

private func isRNodePacketReceived(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.rnode(.interface(.delegate(.packetReceived)))))) = action { return true }
    return false
}

private func isRegisterDelivery(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.registerDelivery)) = action { return true }
    return false
}

private func allThreeRadios(_ state: inout AppFeature.State) {
    state.$meshtasticEnabled.withLock { $0 = true }
    state.$meshtasticRadioID.withLock { $0 = meshSlotRadioA.uuidString }
    state.$meshCoreEnabled.withLock { $0 = true }
    state.$meshCoreRadioID.withLock { $0 = mcRadioIDA.uuidString }
}

private let hubNode = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)

/// A store with RNode radio A and one enabled TCP node over `tcp`.
@MainActor
private func rnStoreWithTCP(radio: RNodeRadioHarness, tcp: MeshTCPHarness) -> TestStoreOf<AppFeature> {
    rnRadioStore(radio: rnRadioIDA, radioHarness: radio, tcp: tcp) { state in
        state.$nodes.withLock { $0 = [hubNode] }
    }
}

/// One packet from the air, through the radio's newest session; waits until the interface has
/// delivered it.
@MainActor
private func rnReceiveOnePacket(_ store: TestStoreOf<AppFeature>, _ radio: RNodeRadioHarness,
                                rssi: Int? = nil, snr: Double? = nil) async {
    radio.yieldToLatest(.packet(Data(repeating: 0x42, count: 40), rssi: rssi, snr: snr))
    await store.receive(isRNodePacketReceived, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
}

/// What the radio echoes in the status tests: every field distinct, TX power nonzero, so a swapped
/// or dropped field shows. SF 8 / 62.5 kHz / CR 6 is 1302 bps.
private let echoedParams = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 17,
                                           spreadingFactor: 8, codingRate: 6)

private func report(major: UInt8 = 1, minor: UInt8 = 86) -> RNodeRadioReport {
    RNodeRadioReport(name: "RNode 1A2B", firmwareMajor: major, firmwareMinor: minor, platform: 0x80,
                     params: echoedParams)
}

/// The TX power clamp, as the live adapter words it.
private let txPowerRejected = RNodeLiveMessage.configurationRejected(
    [RNodeParameterMismatch(field: .txPower, requested: 30, reported: 22)])

// MARK: - Status

@MainActor @Test func rnStatusRadioOnlineFillsTheStatus() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA, report: report())
    #expect(await rnEventually(store) { store.state.rnodeStatus.online })
    let status = store.state.rnodeStatus
    #expect(status.radioName == "RNode 1A2B")
    #expect(status.firmware == "1.86")
    #expect(status.platform == 0x80)
    #expect(status.reported == RNodeStatus.Params(frequencyHz: 868_100_000, bandwidthHz: 62_500,
                                                  spreadingFactor: 8, codingRate: 6, txPowerDBm: 17))
    #expect(status.bitrate == 1302)
}

@MainActor @Test func rnStatusFirmwareMinorIsTwoDigits() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA, report: report(major: 1, minor: 5))
    #expect(await rnEventually(store) { store.state.rnodeStatus.online })
    #expect(store.state.rnodeStatus.firmware == "1.05")
}

@MainActor @Test func rnStatusRadioOfflineRecordsTheReason() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    radio.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive(isRNodeRadioOffline, timeout: .seconds(20))
    #expect(!store.state.rnodeStatus.online)
    #expect(store.state.rnodeStatus.offlineReason == "link lost")
}

/// The rejection reaches Settings word for word, and T8's gate still holds the radio (flag set, and
/// with nothing else dialing the app shows Disconnected).
@MainActor @Test func rnStatusAdapterUnavailableIsShown() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(await rnWait { radio.startCount >= 1 })
    radio.yieldToLatest(.unavailable(.other(txPowerRejected)))
    radio.finishLatest()
    await store.receive(isRNodeAdapterUnavailable, timeout: .seconds(20))
    #expect(store.state.rnodeStatus.userMessage == txPowerRejected)
    #expect(store.state.rnodeStatus.adapterUnavailable == .other(txPowerRejected))
    #expect(!store.state.rnodeStatus.online)
    #expect(store.state.rnodeNeedsUserAction)
    #expect(store.state.connection == .disconnected)
}

/// Coming online clears both an earlier drop's reason and an adapter fault.
@MainActor @Test func rnStatusRadioOnlineClearsAnAdapterFault() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    radio.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive(isRNodeRadioOffline, timeout: .seconds(20))
    radio.yieldToLatest(.unavailable(.poweredOff))
    await store.receive(isRNodeAdapterUnavailable, timeout: .seconds(20))
    #expect(store.state.rnodeStatus.adapterUnavailable == .poweredOff)
    #expect(store.state.rnodeStatus.offlineReason == "link lost")
    radio.yieldToLatest(.connected(rnCompleteReport))
    await store.receive({ isInterfaceConnected($0, rnSlotIDA) }, timeout: .seconds(20))
    #expect(await rnEventually(store) { store.state.rnodeStatus.online })
    #expect(store.state.rnodeStatus.adapterUnavailable == nil)
    #expect(store.state.rnodeStatus.offlineReason == nil)
}

/// Every Contract 3 counter lands in its own field (distinct values, one check per field), and the
/// shown counters follow the live slot as it receives, sends, drops and reports errors.
@MainActor @Test func rnStatusCountersFollowTheLiveSlot() async {
    let mapped = RNodeStatus.Counters(RNodeCounters(received: 1, sent: 2, oversize: 3, queueFull: 4,
                                                    sendFailed: 5, hardwareErrors: 6))
    #expect(mapped.received == 1)
    #expect(mapped.sent == 2)
    #expect(mapped.oversize == 3)
    #expect(mapped.queueFull == 4)
    #expect(mapped.sendFailed == 5)
    #expect(mapped.hardwareErrors == 6)

    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await rnReceiveOnePacket(store, radio)
    #expect(store.state.rnodeStatus.counters.received == 1)
    await store.send(.node(.client(.endpoint(.rnode(.interface(.send(Data(repeating: 0xA5, count: 600))))))))
    #expect(store.state.rnodeStatus.counters.oversize == 1)
    // The delivery announce at interface-up goes out on the radio too, so count what the driver
    // took: every frame it accepted is one `sent`.
    let ours = Data(repeating: 0x5A, count: 40)
    await store.send(.node(.client(.endpoint(.rnode(.interface(.send(ours)))))))
    #expect(await rnEventually(store) {
        radio.sent.value.contains { $0.frame == ours }
            && store.state.rnodeStatus.counters.sent == radio.sent.value.count
    })
    radio.yieldToLatest(.hardwareError(0x03))
    #expect(await rnEventually(store) { store.state.rnodeStatus.counters.hardwareErrors == 1 })
    #expect(store.state.rnodeStatus.counters
            == RNodeStatus.Counters(received: 1, sent: radio.sent.value.count, oversize: 1, hardwareErrors: 1))
}

/// Signal, channel load (0...100 percent, as Diagnostics renders it), noise floor and the last
/// hardware error follow the live slot. RNodeKit already reports the loads in percent (raw / 100,
/// RNodeSession.swift:601), so 2.15 stays 2.15 and renders "2.15%".
@MainActor @Test func rnStatusTelemetryFollowsTheLiveSlot() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await rnReceiveOnePacket(store, radio, rssi: -97, snr: 6.25)
    radio.yieldToLatest(.channelLoad(RNodeChannelLoad(airtimeShort: 2.15, airtimeLong: 1.5, channelLoadShort: 12.5,
                                                      channelLoadLong: 7.25, noiseFloor: -112)))
    radio.yieldToLatest(.hardwareError(0x02))
    #expect(await rnEventually(store) { store.state.rnodeStatus.lastHardwareError == 0x02 })
    let status = store.state.rnodeStatus
    #expect(status.lastRSSI == -97)
    #expect(status.lastSNR == 6.25)
    #expect(status.airtimeShort == 2.15)
    #expect(status.airtimeLong == 1.5)
    #expect(status.channelLoadShort == 12.5)
    #expect(status.channelLoadLong == 7.25)
    #expect(status.noiseFloor == -112)
    #expect(DiagnosticsSnapshot.rnodePercentPair(status.airtimeShort, status.airtimeLong) == "2.15% / 1.50%")
}

/// `RNodeStatus.Counters` are cumulative since launch; the endpoint's reset with each slot. The new
/// slot receives a packet of its own after the change, so the shown total (2) needs the old slot's
/// carried counters and the new one's live ones summed on the new slot's actions.
@MainActor @Test func rnStatusCountersSurviveAParameterChange() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await rnReceiveOnePacket(store, radio)
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.connectTapped)
    await store.receive(isRNodeRadioOffline, timeout: .seconds(20))
    await rnBringRadioOnline(store, radio, id: rnSlotIDA, starts: 2)
    #expect(store.state.node.client.endpoint.rnode?.interface.config.params.frequencyHz == 869_525_000)
    await rnReceiveOnePacket(store, radio)
    #expect(store.state.rnodeStatus.counters.received == 2)
}

/// Each radio's delegates move only its own status: the RNode online leaves Meshtastic and MeshCore
/// offline, and the RNode dropping leaves Meshtastic online.
@MainActor @Test func rnStatusRadiosKeepSeparateStatus() async {
    let radio = RNodeRadioHarness()
    let meshtastic = MeshRadioHarness()
    let meshCore = MeshCoreRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, meshtastic: meshtastic, meshCore: meshCore,
                             configure: allThreeRadios)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    #expect(await rnEventually(store) { store.state.rnodeStatus.online })
    #expect(!store.state.meshtasticStatus.online)
    #expect(!store.state.meshCoreStatus.online)

    await meshBringRadioOnline(store, meshtastic, id: meshSlotIDA)
    #expect(await rnEventually(store) { store.state.meshtasticStatus.online })
    radio.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive(isRNodeRadioOffline, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
    #expect(!store.state.rnodeStatus.online)
    #expect(store.state.meshtasticStatus.online)
    #expect(store.state.meshtasticStatus.offlineReason == nil)
    #expect(!store.state.meshCoreStatus.online)
}

// MARK: - Announces

/// Contract 4: only the first interface-up registers; the RNode coming up after TCP announces on
/// its own interface only.
@MainActor @Test func rnAnnounceAFurtherInterfaceUpAnnouncesOnThatInterface() async {
    let radio = RNodeRadioHarness()
    let tcp = MeshTCPHarness()
    let store = rnStoreWithTCP(radio: radio, tcp: tcp)
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, hubNode.interfaceID) }, timeout: .seconds(20))
    await store.receive(isRegisterDelivery, timeout: .seconds(20))
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(rnSlotIDA))) }, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
}

/// A persisted Relay setting is re-applied when the RNode comes up.
@MainActor @Test func rnAnnounceRelayIsReappliedOnRNodeUp() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio) { state in
        state.$relayEnabled.withLock { $0 = true }
    }
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await store.receive({ if case .node(.client(.endpoint(.enableRelay))) = $0 { return true }; return false },
                        timeout: .seconds(20))
    await store.receive({ $0 == .node(.client(.endpoint(.transport(.setRecursivePathRequests(true))))) },
                        timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
}

private let downHub = InterfaceID("tcp:hub:4242")
private let downAccepted = InterfaceID("tcpserver:7")
private let downBLE = InterfaceID("ble:aa")
private let downMeshtastic = InterfaceID("meshtastic:radio")
private let downMeshCore = InterfaceID("meshcore:radio")
private let downNow = Date(timeIntervalSince1970: 1_700_000_000)

@Test func rnAnnounceRadioDownTargetsEveryTCPInterfaceAndNothingElse() {
    #expect(rnSlotIDA.rawValue.hasPrefix("rnode:"))
    let targets = AppFeature.radioDownAnnounceTargets(
        departing: rnSlotIDA, connected: [downHub, downAccepted, downBLE, downMeshtastic, downMeshCore],
        lastAnnounceAt: nil, now: downNow)
    #expect(targets == [downHub, downAccepted])
}

/// The RNode dropping re-announces over the TCP interface still up, through the reducer.
@MainActor @Test func rnAnnounceARadioGoingDownAnnouncesOverTCP() async {
    let radio = RNodeRadioHarness()
    let tcp = MeshTCPHarness()
    let store = rnStoreWithTCP(radio: radio, tcp: tcp)
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, hubNode.interfaceID) }, timeout: .seconds(20))
    await store.receive(isRegisterDelivery, timeout: .seconds(20))
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(rnSlotIDA))) }, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
    radio.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(hubNode.interfaceID))) },
                        timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.lastRadioDownAnnounceAt == downNow)
}

// MARK: - Profile photo

@MainActor @Test func rnPhotoDoesNotRideOnlyAnRNode() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connectedInterfaces == [rnSlotIDA])
    #expect(!store.state.profilePhotoMayRide)
}

@MainActor @Test func rnPhotoDoesNotRideThreeRadios() async {
    let radio = RNodeRadioHarness()
    let meshtastic = MeshRadioHarness()
    let meshCore = MeshCoreRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, meshtastic: meshtastic, meshCore: meshCore,
                             configure: allThreeRadios)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await meshBringRadioOnline(store, meshtastic, id: meshSlotIDA)
    await mcBringRadioOnline(store, meshCore, id: mcSlotIDA)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connectedInterfaces == [rnSlotIDA, meshSlotIDA, mcSlotIDA])
    #expect(!store.state.profilePhotoMayRide)
}

@MainActor @Test func rnPhotoRidesWithTCPUp() async {
    let radio = RNodeRadioHarness()
    let tcp = MeshTCPHarness()
    let store = rnStoreWithTCP(radio: radio, tcp: tcp)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, hubNode.interfaceID) }, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connectedInterfaces == [rnSlotIDA, hubNode.interfaceID])
    #expect(store.state.profilePhotoMayRide)
}
