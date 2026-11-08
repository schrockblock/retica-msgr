import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAMeshCoreLive
@testable import ReTiCAMsgrCore

// The MeshCore slot's delegates into `meshCoreStatus`, its counters, the announces on its
// interface's up and down, and the slow-radio photo rule (lane D Task 9). Every store runs the real
// reducers down to `MeshCoreInterface`, over `MeshCoreRadioHarness`.

private func mcWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

private func isMeshCoreAdapterUnavailable(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.meshCore(.delegate(.adapterUnavailable))))) = action { return true }
    return false
}

private func isMeshCorePacketReceived(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.meshCore(.interface(.delegate(.packetReceived)))))) = action { return true }
    return false
}

private func isRegisterDelivery(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.registerDelivery)) = action { return true }
    return false
}

/// Another MeshCore node's 4-byte prefix.
private let mcPeerPrefix = Data([0x09, 0x08, 0x07, 0x06])

/// One 300-byte packet in three broadcast fragments from `mcPeerPrefix`, through the radio's
/// newest session; waits until the interface has reassembled it.
@MainActor
private func mcCompleteOnePacket(_ store: TestStoreOf<AppFeature>, _ radio: MeshCoreRadioHarness,
                                 fill: UInt8, packetID: UInt16) async {
    let frames = ScotMeshRawCodec().split(Data(repeating: fill, count: 300), type: .rnsFragment,
                                          src: mcPeerPrefix, dst: ScotMeshRawCodec.broadcast,
                                          packetID: packetID, canRoute: false)
    #expect(frames.count == 3)
    for frame in frames { radio.yieldToLatest(.datagram(frame)) }
    await store.receive(isMeshCorePacketReceived, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
}

private func bothRadios(_ state: inout AppFeature.State) {
    state.$meshtasticEnabled.withLock { $0 = true }
    state.$meshtasticRadioID.withLock { $0 = meshSlotRadioA.uuidString }
}

/// A store with MeshCore radio A and one enabled TCP node over `tcp`.
@MainActor
private func mcStoreWithTCP(radio: MeshCoreRadioHarness, tcp: MeshTCPHarness, node: NodeEntry,
                            meshtastic: MeshRadioHarness = MeshRadioHarness()) -> TestStoreOf<AppFeature> {
    mcRadioStore(radio: mcRadioIDA, radioHarness: radio, meshtastic: meshtastic, tcp: tcp) { state in
        state.$nodes.withLock { $0 = [node] }
    }
}

private let hubNode = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)

// MARK: - Status

@MainActor @Test func mcStatusRadioOnlineFillsTheStatus() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA,
                             params: MeshCoreLinkParams(spreadingFactor: 11, bandwidthHz: 62_500, codingRate: 8))
    #expect(await mcEventually(store) { store.state.meshCoreStatus.online })
    #expect(store.state.meshCoreStatus.params
            == MeshCoreStatus.LoRaParams(spreadingFactor: 11, bandwidthHz: 62_500, codingRate: 8))
}

/// Diagnostics shows the radio's name, firmware code and our channel slot (never the key), read
/// from the live driver's details sink at `.radioOnline`.
@MainActor @Test func mcStatusRadioOnlineReadsTheDetails() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio,
                             details: MeshCoreRadioDetails(name: "Base", firmwareCode: 11, channelSlot: 3))
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    #expect(await mcEventually(store) { store.state.meshCoreStatus.radioName == "Base" })
    #expect(store.state.meshCoreStatus.firmwareCode == 11)
    #expect(store.state.meshCoreStatus.channelSlot == 3)
}

@MainActor @Test func mcStatusRadioOfflineRecordsTheReason() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    radio.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive(isMeshCoreRadioOffline, timeout: .seconds(20))
    #expect(!store.state.meshCoreStatus.online)
    #expect(store.state.meshCoreStatus.offlineReason == "link lost")
}

@MainActor @Test func mcStatusAdapterUnavailableIsShown() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 })
    radio.yieldToLatest(.unavailable(.other(MeshCoreLiveMessage.noFreeSlot)))
    await store.receive(isMeshCoreAdapterUnavailable, timeout: .seconds(20))
    #expect(store.state.meshCoreStatus.userMessage == "No free channel slot on this radio")
    #expect(!store.state.meshCoreStatus.online)
}

@MainActor @Test func mcStatusRadioOnlineClearsAnAdapterFault() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 })
    radio.yieldToLatest(.unavailable(.poweredOff))
    await store.receive(isMeshCoreAdapterUnavailable, timeout: .seconds(20))
    #expect(store.state.meshCoreStatus.adapterUnavailable == .poweredOff)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    #expect(await mcEventually(store) { store.state.meshCoreStatus.online })
    #expect(store.state.meshCoreStatus.adapterUnavailable == nil)
}

/// Every Contract 3 counter lands in its own field, and the shown counters follow the live slot as
/// its datagrams arrive.
@MainActor @Test func mcStatusCountersFollowTheLiveSlot() async {
    let mapped = MeshCoreStatus.Counters(MeshCoreCounters(
        malformed: 1, notAddressed: 2, evicted: 3, timedOut: 4, oversize: 5, completed: 6,
        queueFull: 7, sendFailed: 8, announcesLimited: 9, pathRequestsLimited: 10))
    #expect(mapped == MeshCoreStatus.Counters(
        malformed: 1, notAddressed: 2, evicted: 3, timedOut: 4, oversize: 5, completed: 6,
        queueFull: 7, sendFailed: 8, announcesLimited: 9, pathRequestsLimited: 10))

    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await mcCompleteOnePacket(store, radio, fill: 0x42, packetID: 7)
    #expect(store.state.meshCoreStatus.counters.completed == 1)
}

/// `MeshCoreStatus.Counters` are cumulative since launch; the endpoint's reset with each slot.
/// Radio B completes a packet of its own after the change, so the shown total (2) needs radio A's
/// carried counters and B's live ones summed on B's actions.
@MainActor @Test func mcStatusCountersSurviveARadioChange() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await mcCompleteOnePacket(store, radio, fill: 0x42, packetID: 7)
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.foregrounded)
    await store.receive(isMeshCoreRadioOffline, timeout: .seconds(20))
    await mcBringRadioOnline(store, radio, id: mcSlotIDB, starts: 2)
    #expect(store.state.node.client.endpoint.meshCore?.interface.config.radio == mcRadioIDB)
    await mcCompleteOnePacket(store, radio, fill: 0x43, packetID: 8)
    #expect(store.state.meshCoreStatus.counters.completed == 2)
}

/// Each radio's delegates move only its own status: MeshCore online leaves Meshtastic offline, and
/// MeshCore dropping leaves Meshtastic online.
@MainActor @Test func mcStatusBothRadiosKeepSeparateStatus() async {
    let radio = MeshCoreRadioHarness()
    let meshtastic = MeshRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, meshtastic: meshtastic,
                             configure: bothRadios)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    #expect(await mcEventually(store) { store.state.meshCoreStatus.online })
    #expect(!store.state.meshtasticStatus.online)

    _ = await mcWait { meshtastic.startCount >= 1 }
    meshtastic.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: 8))
    await store.receive({ isInterfaceConnected($0, meshSlotIDA) }, timeout: .seconds(20))
    #expect(await mcEventually(store) { store.state.meshtasticStatus.online })
    radio.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive(isMeshCoreRadioOffline, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
    #expect(!store.state.meshCoreStatus.online)
    #expect(store.state.meshtasticStatus.online)
    #expect(store.state.meshtasticStatus.offlineReason == nil)
}

/// T8 carry: after Connect with only a MeshCore radio set up, a policy failure leaves nothing
/// dialing (the radio waits for the next Connect), so the app shows Disconnected and its Connect
/// button, not a Connecting… that never resolves.
@MainActor @Test func mcStatusPolicyFailureWithNothingElseDialingShowsDisconnected() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(store.state.connection == .connecting)
    #expect(await mcWait { radio.startCount >= 1 })
    radio.yieldToLatest(.unavailable(.other(MeshCoreLiveMessage.noFreeSlot)))
    radio.finishLatest()
    await store.receive(isMeshCoreAdapterUnavailable, timeout: .seconds(20))
    #expect(store.state.connection == .disconnected)
}

/// The other half: a TCP node still dialing keeps Connecting… through the radio's policy failure.
@MainActor @Test func mcStatusPolicyFailureWhileATCPNodeDialsStaysConnecting() async {
    let radio = MeshCoreRadioHarness()
    let tcp = MeshTCPHarness()
    let store = mcStoreWithTCP(radio: radio, tcp: tcp, node: hubNode)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 })
    radio.yieldToLatest(.unavailable(.other(MeshCoreLiveMessage.noFreeSlot)))
    radio.finishLatest()
    await store.receive(isMeshCoreAdapterUnavailable, timeout: .seconds(20))
    #expect(store.state.connection == .connecting)
}

/// Review Focus 5 (T9 review carry): a MeshCore policy failure never marks the app Disconnected
/// while another radio is up. Meshtastic is turned off in Settings after it came up (that waits for
/// Connect, so the radio stays up) so nothing else will dial: only the interface that is up keeps
/// `.connected`.
@MainActor @Test func mcStatusPolicyFailureWithMeshtasticUpStaysConnected() async {
    let radio = MeshCoreRadioHarness()
    let meshtastic = MeshRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, meshtastic: meshtastic,
                             configure: bothRadios)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 && meshtastic.startCount >= 1 })
    meshtastic.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: 8))
    await store.receive({ isInterfaceConnected($0, meshSlotIDA) }, timeout: .seconds(20))
    #expect(store.state.connection == .connected)
    await store.send(.binding(.set(\.meshtasticEnabled, false)))
    #expect(store.state.node.client.endpoint.meshtastic?.interface.isOnline == true,
            "precondition: turning Meshtastic off waits for Connect")
    radio.yieldToLatest(.unavailable(.other(MeshCoreLiveMessage.noFreeSlot)))
    radio.finishLatest()
    await store.receive(isMeshCoreAdapterUnavailable, timeout: .seconds(20))
    #expect(store.state.meshCorePolicyFailed)
    #expect(!store.state.somethingWillDial, "precondition: nothing else will dial")
    #expect(store.state.connection == .connected)
}

// MARK: - Announces

/// Contract 4: only the first interface-up registers; the MeshCore radio coming up after TCP
/// announces on its own interface only.
@MainActor @Test func mcAnnounceAFurtherInterfaceUpAnnouncesOnThatInterface() async {
    let radio = MeshCoreRadioHarness()
    let tcp = MeshTCPHarness()
    let store = mcStoreWithTCP(radio: radio, tcp: tcp, node: hubNode)
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, hubNode.interfaceID) }, timeout: .seconds(20))
    await store.receive(isRegisterDelivery, timeout: .seconds(20))
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(mcSlotIDA))) }, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func mcAnnounceFirstInterfaceRegistersDelivery() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await store.receive(isRegisterDelivery, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
}

/// A persisted Relay setting is re-applied when the MeshCore radio comes up.
@MainActor @Test func mcAnnounceRelayIsReappliedOnMeshCoreUp() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio) { state in
        state.$relayEnabled.withLock { $0 = true }
    }
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await store.receive({ if case .node(.client(.endpoint(.enableRelay))) = $0 { return true }; return false },
                        timeout: .seconds(20))
    await store.receive({ $0 == .node(.client(.endpoint(.transport(.setRecursivePathRequests(true))))) },
                        timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
}

private let downMeshCore = meshCoreInterfaceID(radio: mcRadioIDA)
private let downHub = InterfaceID("tcp:hub:4242")
private let downAccepted = InterfaceID("tcpserver:7")
private let downBLE = InterfaceID("ble:aa")
private let downMeshtastic = InterfaceID("meshtastic:radio")
private let downNow = Date(timeIntervalSince1970: 1_700_000_000)

@Test func mcAnnounceRadioDownTargetsEveryTCPInterfaceAndNothingElse() {
    #expect(downMeshCore.rawValue.hasPrefix("meshcore:"))
    let targets = AppFeature.radioDownAnnounceTargets(
        departing: downMeshCore, connected: [downHub, downAccepted, downBLE, downMeshtastic],
        lastAnnounceAt: nil, now: downNow)
    #expect(targets == [downHub, downAccepted])
}

@Test func mcAnnounceRadioDownIsThrottled() {
    let interval = AppFeature.radioDownAnnounceInterval
    #expect(AppFeature.radioDownAnnounceTargets(departing: downMeshCore, connected: [downHub],
                                                lastAnnounceAt: nil, now: downNow) == [downHub])
    #expect(AppFeature.radioDownAnnounceTargets(departing: downMeshCore, connected: [downHub],
                                                lastAnnounceAt: downNow.addingTimeInterval(-interval + 1),
                                                now: downNow).isEmpty)
    #expect(AppFeature.radioDownAnnounceTargets(departing: downMeshCore, connected: [downHub],
                                                lastAnnounceAt: downNow.addingTimeInterval(-interval),
                                                now: downNow) == [downHub])
}

/// The MeshCore radio dropping re-announces over the TCP interface still up, through the reducer.
@MainActor @Test func mcAnnounceARadioGoingDownAnnouncesOverTCP() async {
    let radio = MeshCoreRadioHarness()
    let tcp = MeshTCPHarness()
    let store = mcStoreWithTCP(radio: radio, tcp: tcp, node: hubNode)
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, hubNode.interfaceID) }, timeout: .seconds(20))
    await store.receive(isRegisterDelivery, timeout: .seconds(20))
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(mcSlotIDA))) }, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
    radio.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(hubNode.interfaceID))) },
                        timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.lastRadioDownAnnounceAt == downNow)
}

// MARK: - Profile photo

@MainActor @Test func mcPhotoDoesNotRideOnlyAMeshCoreRadio() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connectedInterfaces == [mcSlotIDA])
    #expect(!store.state.profilePhotoMayRide)
}

@MainActor @Test func mcPhotoDoesNotRideTwoRadios() async {
    let radio = MeshCoreRadioHarness()
    let meshtastic = MeshRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, meshtastic: meshtastic,
                             configure: bothRadios)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    _ = await mcWait { meshtastic.startCount >= 1 }
    meshtastic.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: 8))
    await store.receive({ isInterfaceConnected($0, meshSlotIDA) }, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connectedInterfaces == [mcSlotIDA, meshSlotIDA])
    #expect(!store.state.profilePhotoMayRide)
}

@MainActor @Test func mcPhotoRidesWithTCPUp() async {
    let radio = MeshCoreRadioHarness()
    let tcp = MeshTCPHarness()
    let store = mcStoreWithTCP(radio: radio, tcp: tcp, node: hubNode)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, hubNode.interfaceID) }, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connectedInterfaces == [mcSlotIDA, hubNode.interfaceID])
    #expect(store.state.profilePhotoMayRide)
}
