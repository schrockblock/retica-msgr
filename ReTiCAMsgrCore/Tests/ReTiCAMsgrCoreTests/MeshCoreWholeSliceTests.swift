import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAMeshCoreLive
@testable import ReTiCAMsgrCore

// The MeshCore slot end to end (lane D Task 10): the real `LXMFServiceNode` → `LXMFNode` →
// `TransportEndpoint` → `MeshCoreInterface`, over `MeshCoreRadioHarness` (and `MeshRadioHarness` /
// `MeshTCPHarness` beside it). On-air bytes are read back with lane B's `ScotMeshRawCodec`. The
// `mcGate…` tests are the Release gate: stale MeshCore defaults in a build without the feature
// (`meshCoreAvailable` false) must start nothing.

private func mcWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

/// Lets in-flight effects run before an absence check, then brings the store's state up to date.
@MainActor
private func mcSettle(_ store: TestStoreOf<AppFeature>) async {
    for _ in 0..<5 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
}

private func isRegisterDelivery(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.registerDelivery)) = action { return true }
    return false
}

private func isInterfaceDisconnected(_ action: AppFeature.Action, _ id: InterfaceID) -> Bool {
    if case let .node(.client(.endpoint(.transport(.interfaceDisconnected(gone))))) = action { return gone == id }
    return false
}

private func bothRadios(_ state: inout AppFeature.State) {
    state.$meshtasticEnabled.withLock { $0 = true }
    state.$meshtasticRadioID.withLock { $0 = meshSlotRadioA.uuidString }
}

private let hubNode = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)

/// Brings the newest Meshtastic session online, with time-based waits (`meshBringRadioOnline`'s
/// fixed yields and 2 s timeout are too short in a whole-package run).
@MainActor
private func meshUp(_ store: TestStoreOf<AppFeature>, _ meshtastic: MeshRadioHarness, starts: Int = 1) async {
    _ = await mcWait { meshtastic.startCount >= starts }
    meshtastic.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: 8))
    await store.receive({ isInterfaceConnected($0, meshSlotIDA) }, timeout: .seconds(20))
}

/// The whole RNS packets the MeshCore harness put on the air in `session`, reassembled from their
/// `.rnsFragment` datagrams with `ScotMeshRawCodec` (BIND frames are skipped).
private func mcOnAir(_ radio: MeshCoreRadioHarness, session: Int) -> [Data] {
    var parts: [UInt16: [UInt8: Data]] = [:]
    var totals: [UInt16: UInt8] = [:]
    var order: [UInt16] = []
    for item in radio.sent.value where item.session == session {
        guard let datagram = ScotMeshRawCodec().parse(item.frame), datagram.type == .rnsFragment else { continue }
        if parts[datagram.packetID] == nil { order.append(datagram.packetID) }
        parts[datagram.packetID, default: [:]][datagram.fragmentIndex] = datagram.body
        totals[datagram.packetID] = datagram.fragmentTotal
    }
    return order.compactMap { id in
        guard let total = totals[id], let got = parts[id], (0..<total).allSatisfy({ got[$0] != nil }) else { return nil }
        return (0..<total).reduce(into: Data()) { $0.append(got[$1]!) }
    }
}

/// Our delivery announces among `packets`.
@MainActor
private func ourAnnounces(_ packets: [Data], _ store: TestStoreOf<AppFeature>) -> Int {
    let ours = store.state.node.client.deliveryDestinationHash
    return packets.compactMap { Packet(raw: $0) }
        .filter { $0.packetType == .announce && $0.destinationHash == ours }.count
}

/// A peer's announce, packed, and its destination hash.
private func peerAnnounce() -> (raw: Data, destinationHash: Data) {
    let identity = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: ["svc"])
    let destHash = Destination.hash(identityHash: identity.hash, appName: "app", aspects: ["svc"])
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

private let mcPeerPrefix = Data([0x09, 0x08, 0x07, 0x06])

// MARK: - Whole slice

/// Contract 4 through the production wiring: TCP comes up first (the registration announce goes out
/// on TCP), then the MeshCore radio comes up. Its announce goes out on the radio ONLY; TCP gets
/// nothing more.
@MainActor @Test func mcSliceARadioComingUpAnnouncesOnTheRadioOnly() async {
    let radio = MeshCoreRadioHarness()
    let tcp = MeshTCPHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, tcp: tcp) { state in
        state.$nodes.withLock { $0 = [hubNode] }
    }
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, hubNode.interfaceID) }, timeout: .seconds(20))
    await store.receive(isRegisterDelivery, timeout: .seconds(20))
    #expect(await mcWait { !tcp.sends.value.isEmpty }, "precondition: the registration announce went out on TCP")
    await mcSettle(store)
    let tcpWritesBeforeRadio = tcp.sends.value.count

    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(mcSlotIDA))) }, timeout: .seconds(20))
    #expect(await mcWait { !mcOnAir(radio, session: 0).isEmpty }, "nothing went out on the radio")
    #expect(ourAnnounces(mcOnAir(radio, session: 0), store) == 1)
    await mcSettle(store)
    #expect(tcp.sends.value.count == tcpWritesBeforeRadio, "the radio coming up re-announced on TCP")
}

/// TCP up, then the Meshtastic radio, then the MeshCore radio: each radio's announce goes out on that
/// radio only, and neither radio coming up puts anything on TCP or on the other radio.
@MainActor @Test func mcSliceEachRadioAnnouncesOnlyOnItself() async {
    let radio = MeshCoreRadioHarness()
    let meshtastic = MeshRadioHarness()
    let tcp = MeshTCPHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, meshtastic: meshtastic, tcp: tcp) { state in
        bothRadios(&state)
        state.$nodes.withLock { $0 = [hubNode] }
    }
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, hubNode.interfaceID) }, timeout: .seconds(20))
    await store.receive(isRegisterDelivery, timeout: .seconds(20))
    #expect(await mcWait { !tcp.sends.value.isEmpty }, "precondition: the registration announce went out on TCP")
    await mcSettle(store)
    let tcpWrites = tcp.sends.value.count

    await meshUp(store, meshtastic)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(meshSlotIDA))) }, timeout: .seconds(20))
    #expect(await mcWait { !meshtastic.reassembled(session: 0).isEmpty }, "nothing went out on the Meshtastic radio")
    await mcSettle(store)
    let meshtasticPackets = meshtastic.reassembled(session: 0).count
    #expect(tcp.sends.value.count == tcpWrites, "the Meshtastic radio coming up re-announced on TCP")
    #expect(radio.sent.value.isEmpty, "the MeshCore radio sent before it came up")

    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(mcSlotIDA))) }, timeout: .seconds(20))
    #expect(await mcWait { !mcOnAir(radio, session: 0).isEmpty }, "nothing went out on the MeshCore radio")
    #expect(ourAnnounces(mcOnAir(radio, session: 0), store) == 1)
    await mcSettle(store)
    #expect(tcp.sends.value.count == tcpWrites, "the MeshCore radio coming up re-announced on TCP")
    #expect(meshtastic.reassembled(session: 0).count == meshtasticPackets,
            "the MeshCore radio coming up re-announced on the Meshtastic radio")
}

/// A peer's announce arriving as MeshCore fragments is learned with the MeshCore interface as its
/// path. The radio it arrives on is one a swap installed (radio A, changed to B, foreground), so the
/// slot is started by `installMeshCoreSlot` itself: at Connect or foreground the endpoint-wide start
/// would start a freshly installed slot anyway.
@MainActor @Test func mcSliceAPacketFromTheRadioRegistersItsPath() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.foregrounded)
    await store.receive(isMeshCoreRadioOffline, timeout: .seconds(20))
    await mcBringRadioOnline(store, radio, id: mcSlotIDB, starts: 2)
    let (raw, destinationHash) = peerAnnounce()
    let frames = ScotMeshRawCodec().split(raw, type: .rnsFragment, src: mcPeerPrefix,
                                          dst: ScotMeshRawCodec.broadcast, packetID: 0x0101, canRoute: false)
    #expect(frames.count >= 2, "precondition: the announce spans several datagrams")
    for frame in frames { radio.yieldToLatest(.datagram(frame)) }
    #expect(await mcEventually(store) {
        store.state.node.client.endpoint.learned[destinationHash]?.interfaceID == mcSlotIDB
    }, "learned: \(String(describing: store.state.node.client.endpoint.learned[destinationHash]?.interfaceID))")
}

/// Review Focus 5: with both radios up, the MeshCore radio dropping leaves the app `.connected`;
/// once the Meshtastic radio drops too, it is `.disconnected`.
@MainActor @Test func mcSliceConnectionStaysUpWhileEitherRadioIs() async {
    let radio = MeshCoreRadioHarness()
    let meshtastic = MeshRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, meshtastic: meshtastic, configure: bothRadios)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await meshUp(store, meshtastic)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connectedInterfaces == [mcSlotIDA, meshSlotIDA])

    radio.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive({ isInterfaceDisconnected($0, mcSlotIDA) }, timeout: .seconds(20))
    #expect(store.state.connection == .connected, "the Meshtastic radio is still up")
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connection == .connected)

    meshtastic.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive({ isInterfaceDisconnected($0, meshSlotIDA) }, timeout: .seconds(20))
    #expect(store.state.connection == .disconnected)
    #expect(store.state.connectedInterfaces.isEmpty)
}

/// Radio A online, the radio changed, Connect tapped while A's stop is in flight: ends on radio B,
/// registered and announced on B, with no two driver starts without a stop between them, A
/// deregistered, and B's status online.
@MainActor @Test func mcSliceARadioChangeDuringConnectEndsOnTheNewRadio() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    radio.holdStops()
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.connectTapped)
    radio.releaseStops()
    #expect(await mcWait { radio.calls.value.last == .start(mcRadioIDB, canRoute: false, secretBytes: 0) },
            "calls: \(radio.calls.value)")
    #expect(mcNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    await mcBringRadioOnline(store, radio, id: mcSlotIDB, starts: 2)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(mcSlotIDB))) }, timeout: .seconds(20))
    let sessionB = radio.sessions.value.count - 1
    #expect(await mcWait { !mcOnAir(radio, session: sessionB).isEmpty }, "no announce on radio B")
    #expect(await mcEventually(store) { store.state.meshCoreStatus.online })
    #expect(store.state.node.client.endpoint.interfaces[mcSlotIDA] == nil)
    #expect(store.state.node.client.endpoint.interfaces[mcSlotIDB] != nil)
    #expect(store.state.node.client.endpoint.meshCore?.interface.config.radio == mcRadioIDB)
    #expect(mcNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
}

/// Turning MeshCore off with the radio online removes our channel, stops the radio and drops the
/// slot: no MeshCore interface is left registered, connected or installed.
@MainActor @Test func mcSliceTurnOffEndToEndLeavesNoInterface() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    #expect(await mcEventually(store) { store.state.node.client.endpoint.meshCore == nil },
            "the slot was never dropped")
    #expect(store.state.node.client.endpoint.interfaces[mcSlotIDA] == nil)
    #expect(!store.state.connectedInterfaces.contains(mcSlotIDA))
    #expect(store.state.meshCoreSlotIdentity == nil)
    #expect(store.state.meshCoreSwap == nil)
    #expect(radio.calls.value == [.start(mcRadioIDA, canRoute: false, secretBytes: 0), .removeChannel, .stop])
}

// MARK: - Release gate

/// Stale defaults in a build without MeshCore: the setting on, a radio chosen and a key in the
/// Keychain.
private func staleDefaults(_ state: inout AppFeature.State) {
    state.meshCoreAvailable = false
    // A disabled node stops `.onLaunch`'s migration adding the default node, so nothing else dials.
    state.$nodes.withLock { $0 = [NodeEntry(id: UUID(), name: "off", host: "off.example", port: 4242, enabled: false)] }
}

@MainActor @Test func mcGateStaleDefaultsStartNoSlot() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, configure: staleDefaults)
    #expect(store.state.meshCoreEnabled && store.state.meshCoreRadioUUID == mcRadioIDA)
    await store.send(.onLaunch)
    #expect(store.state.meshCoreKeyPresence == .present, "precondition: the key is in the Keychain")
    #expect(store.state.node.client.endpoint.meshCore == nil, "onLaunch built a slot")
    await store.send(.connectTapped)
    #expect(store.state.node.client.endpoint.meshCore == nil, "Connect built a slot")
    await store.send(.foregrounded)
    #expect(store.state.node.client.endpoint.meshCore == nil, "foreground built a slot")
    await mcSettle(store)
    #expect(store.state.node.client.endpoint.meshCore == nil)
    #expect(radio.calls.value == [])
}

@MainActor @Test func mcGateStaleDefaultsDoNotShowConnecting() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, configure: staleDefaults)
    await store.send(.onLaunch)
    #expect(store.state.connection == .disconnected, "onLaunch")
    await store.send(.connectTapped)
    #expect(store.state.connection == .disconnected, "Connect")
    await store.send(.foregrounded)
    #expect(store.state.connection == .disconnected, "foreground")
}

/// `\.meshCoreDriver` left at its unimplemented test value: any call to it reports an issue.
@MainActor @Test func mcGateStaleDefaultsNeverTouchTheDriver() async {
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: MeshCoreRadioHarness(), configure: staleDefaults)
    store.dependencies.meshCoreDriver = .testValue
    await store.send(.onLaunch)
    await store.send(.connectTapped)
    await store.send(.foregrounded)
    await mcSettle(store)
    #expect(store.state.node.client.endpoint.meshCore == nil)
}
