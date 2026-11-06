import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCAMsgrCore

@MainActor @Test func meshStatusRadioOnlineFillsTheStatus() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA, preset: 6)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.meshtasticStatus.online)
    #expect(store.state.meshtasticStatus.modemPreset == 6)
    #expect(store.state.meshtasticStatus.myNodeNum == meshSlotOwnNode)
}

@MainActor @Test func meshStatusRadioOfflineRecordsTheReason() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    #expect(!store.state.meshtasticStatus.online)
    #expect(store.state.meshtasticStatus.offlineReason == "link lost")
}

@MainActor @Test func meshStatusAdapterUnavailableIsShown() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await radio.waitForStarts(1)
    radio.yieldToLatest(.unavailable(.other("radio not found")))
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.delegate(.adapterUnavailable))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    #expect(store.state.meshtasticStatus.adapterUnavailable == .other("radio not found"))
}

@MainActor @Test func meshStatusRadioOnlineClearsAnAdapterFault() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await radio.waitForStarts(1)
    radio.yieldToLatest(.unavailable(.poweredOff))
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.delegate(.adapterUnavailable))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    radio.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: 8))
    await store.receive({ isInterfaceConnected($0, meshSlotIDA) }, timeout: .seconds(2))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.meshtasticStatus.adapterUnavailable == nil)
    #expect(store.state.meshtasticStatus.online)
}

@MainActor @Test func meshStatusCountersFollowTheLiveSlot() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    for frame in LandandairCodec().split(Data(repeating: 0x42, count: 300), index: 7) {
        radio.yieldToLatest(.fragment(from: meshSlotPeerNode, frame))
    }
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.interface(.delegate(.packetReceived)))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.meshtasticStatus.counters.completed == 1)
}

/// `MeshtasticStatus.Counters` are cumulative since launch; the endpoint's reset with each slot.
/// Radio B completes a packet of its own after the change, so the shown total (2) needs both the
/// carried counters of A and B's live ones summed on B's actions.
@MainActor @Test func meshStatusCountersSurviveARadioChange() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    for frame in LandandairCodec().split(Data(repeating: 0x42, count: 300), index: 7) {
        radio.yieldToLatest(.fragment(from: meshSlotPeerNode, frame))
    }
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.interface(.delegate(.packetReceived)))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.foregrounded)
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await meshBringRadioOnline(store, radio, id: meshSlotIDB, starts: 2)
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioB)
    for frame in LandandairCodec().split(Data(repeating: 0x43, count: 300), index: 8) {
        radio.yieldToLatest(.fragment(from: meshSlotPeerNode, frame))
    }
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.interface(.delegate(.packetReceived)))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.meshtasticStatus.counters.completed == 2)
}

/// Contract 4: only the FIRST interface-up registers (and announces everywhere); later ones
/// announce on THAT interface only.
@MainActor @Test func meshAnnounceAFurtherInterfaceUpAnnouncesOnThatInterface() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: nil, harness: radio)
    let first = InterfaceID("tcp:first:4242")
    let second = InterfaceID("tcp:second:4242")
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(first, .tcp))))))
    await store.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(second, .tcp))))))
    await store.receive { $0 == .node(.client(.announceDeliveryOnInterface(second))) }
    await store.skipReceivedActions(strict: false)
}

private let downRadio = InterfaceID("meshtastic:radio")
private let downHub = InterfaceID("tcp:hub:4242")
private let downAccepted = InterfaceID("tcpserver:7")
private let downBLE = InterfaceID("ble:aa")
private let downNow = Date(timeIntervalSince1970: 1_700_000_000)

@Test func meshAnnounceRadioDownTargetsEveryTCPInterfaceAndNothingElse() {
    let targets = AppFeature.radioDownAnnounceTargets(departing: downRadio,
                                                      connected: [downHub, downAccepted, downBLE],
                                                      lastAnnounceAt: nil, now: downNow)
    #expect(targets == [downHub, downAccepted])
}

@Test func meshAnnounceOnlyARadioGoingDownReannounces() {
    for departing in [downHub, downAccepted, downBLE] {
        #expect(AppFeature.radioDownAnnounceTargets(departing: departing, connected: [downHub, downAccepted],
                                                    lastAnnounceAt: nil, now: downNow).isEmpty)
    }
}

@Test func meshAnnounceRadioDownIsThrottled() {
    let interval = AppFeature.radioDownAnnounceInterval
    #expect(AppFeature.radioDownAnnounceTargets(departing: downRadio, connected: [downHub],
                                                lastAnnounceAt: downNow.addingTimeInterval(-interval + 1),
                                                now: downNow).isEmpty)
    #expect(AppFeature.radioDownAnnounceTargets(departing: downRadio, connected: [downHub],
                                                lastAnnounceAt: downNow.addingTimeInterval(-interval),
                                                now: downNow) == [downHub])
}

/// A radio going down re-announces over the TCP interface still up, through the reducer.
@MainActor @Test func meshAnnounceARadioGoingDownAnnouncesOverTCP() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: nil, harness: radio)
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(downHub, .tcp))))))
    await store.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(downRadio, .tcp))))))
    await store.receive { $0 == .node(.client(.announceDeliveryOnInterface(downRadio))) }
    await store.skipReceivedActions(strict: false)
    await store.send(.node(.client(.endpoint(.transport(.interfaceDisconnected(downRadio))))))
    await store.receive { $0 == .node(.client(.announceDeliveryOnInterface(downHub))) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.lastRadioDownAnnounceAt == downNow)
}
