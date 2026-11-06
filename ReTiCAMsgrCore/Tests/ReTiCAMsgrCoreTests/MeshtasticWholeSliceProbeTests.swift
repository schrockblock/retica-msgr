import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCAMsgrCore

/// Contract 4 through production wiring: TCP comes up first (registration announce on TCP), then
/// the radio comes up — its announce must go out on the radio ONLY.
@MainActor @Test func meshSliceARadioComingUpAnnouncesOnTheRadioOnly() async {
    let radio = MeshRadioHarness()
    let tcp = MeshTCPHarness()
    let node = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio, tcp: tcp) { state in
        state.$nodes.withLock { $0 = [node] }
    }
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, node.interfaceID) }, timeout: .seconds(2))
    await store.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    #expect(await meshWaitUntil { !tcp.sends.value.isEmpty }, "precondition: the registration announce went out on TCP")
    try? await Task.sleep(for: .milliseconds(100))
    let tcpWritesBeforeRadio = tcp.sends.value.count
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    await store.receive { $0 == .node(.client(.announceDeliveryOnInterface(meshSlotIDA))) }
    #expect(await meshWaitUntil { !radio.reassembled(session: 0).isEmpty })
    let announce = radio.reassembled(session: 0).compactMap { Packet(raw: $0) }.first { $0.packetType == .announce }
    #expect(announce?.destinationHash == store.state.node.client.deliveryDestinationHash)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(tcp.sends.value.count == tcpWritesBeforeRadio, "the radio coming up re-announced on TCP")
}

/// Review Focus 5 end to end: radio A online, the radio changed, Connect tapped while A's stop is
/// in flight. Ends on radio B — registered, announced on B — with no driver overlap, A
/// deregistered, and the counters cumulative.
@MainActor @Test func meshSliceARadioChangeDuringConnectEndsOnTheNewRadioWithNoDriverOverlap() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    for frame in LandandairCodec().split(Data(repeating: 0x42, count: 300), index: 7) {
        radio.yieldToLatest(.fragment(from: meshSlotPeerNode, frame))
    }
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.interface(.delegate(.packetReceived)))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.connectTapped)
    radio.releaseStops()
    #expect(await meshWaitUntil(timeout: .seconds(3)) { radio.calls.value.last == .start(meshSlotRadioB) },
            "calls: \(radio.calls.value)")
    #expect(meshNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    let sessionB = radio.sessions.value.count - 1
    radio.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: 6))
    await store.receive({ isInterfaceConnected($0, meshSlotIDB) }, timeout: .seconds(2))
    await store.receive { $0 == .node(.client(.announceDeliveryOnInterface(meshSlotIDB))) }
    #expect(await meshWaitUntil { !radio.reassembled(session: sessionB).isEmpty }, "no announce on radio B")
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.interfaces[meshSlotIDA] == nil)
    #expect(store.state.node.client.endpoint.interfaces[meshSlotIDB] != nil)
    #expect(store.state.meshtasticStatus.online)
    #expect(store.state.meshtasticStatus.counters.completed == 1)
}
