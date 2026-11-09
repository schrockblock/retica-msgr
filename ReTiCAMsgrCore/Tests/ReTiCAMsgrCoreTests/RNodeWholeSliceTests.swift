import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCAMsgrCore

// The RNode slot end to end (lane D Task 10): the real `LXMFServiceNode` → `LXMFNode` →
// `TransportEndpoint` → `RNodeInterface`, over `RNodeRadioHarness` (and `MeshRadioHarness` /
// `MeshCoreRadioHarness` / `MeshTCPHarness` beside it). The RNode carries whole packets, so the
// harness's sent frames ARE the on-air packets. The `rnGate…` tests are the Release gate: stale RNode
// defaults in a build without the feature (`rnodeAvailable` false) must start nothing.

private func rnWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

/// Lets in-flight effects run before an absence check, then brings the store's state up to date.
@MainActor
private func rnSettle(_ store: TestStoreOf<AppFeature>) async {
    for _ in 0..<5 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
}

private func isRegisterDeliveryAction(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.registerDelivery)) = action { return true }
    return false
}

private func isInterfaceGone(_ action: AppFeature.Action, _ id: InterfaceID) -> Bool {
    if case let .node(.client(.endpoint(.transport(.interfaceDisconnected(gone))))) = action { return gone == id }
    return false
}

private func allThree(_ state: inout AppFeature.State) {
    state.$meshtasticEnabled.withLock { $0 = true }
    state.$meshtasticRadioID.withLock { $0 = meshSlotRadioA.uuidString }
    state.$meshCoreEnabled.withLock { $0 = true }
    state.$meshCoreRadioID.withLock { $0 = mcRadioIDA.uuidString }
}

private let sliceHub = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)

/// The whole packets the RNode harness put on the air in `session`.
private func rnOnAir(_ radio: RNodeRadioHarness, session: Int) -> [Data] {
    radio.sent.value.filter { $0.session == session }.map(\.frame)
}

/// Our delivery announces among `packets`.
private func rnOurAnnounces(_ packets: [Data], _ ours: Data?) -> Int {
    packets.compactMap { Packet(raw: $0) }
        .filter { $0.packetType == .announce && $0.destinationHash == ours }.count
}

/// A peer's announce, packed, and its destination hash.
private func rnPeerAnnounce() -> (raw: Data, destinationHash: Data) {
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

/// TCP up first (its registration announce), returning its write count once settled.
@MainActor
private func tcpUpFirst(_ store: TestStoreOf<AppFeature>, _ tcp: MeshTCPHarness) async -> Int {
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, sliceHub.interfaceID) }, timeout: .seconds(20))
    await store.receive(isRegisterDeliveryAction, timeout: .seconds(20))
    #expect(await rnWait { !tcp.sends.value.isEmpty }, "precondition: the registration announce went out on TCP")
    await rnSettle(store)
    return tcp.sends.value.count
}

// MARK: - Whole slice

/// Contract 4 through the production wiring: TCP comes up first (the registration announce goes out
/// on TCP), then the RNode comes up. Its announce goes out on the radio ONLY; TCP gets nothing more.
@MainActor @Test func rnSliceARadioComingUpAnnouncesOnTheRadioOnly() async {
    let radio = RNodeRadioHarness()
    let tcp = MeshTCPHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, tcp: tcp) { state in
        state.$nodes.withLock { $0 = [sliceHub] }
    }
    let tcpWritesBeforeRadio = await tcpUpFirst(store, tcp)

    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(rnSlotIDA))) }, timeout: .seconds(20))
    let ours = store.state.node.client.deliveryDestinationHash
    #expect(await rnWait { rnOurAnnounces(rnOnAir(radio, session: 0), ours) == 1 }, "no announce on the radio")
    await rnSettle(store)
    #expect(rnOurAnnounces(rnOnAir(radio, session: 0), ours) == 1)
    #expect(tcp.sends.value.count == tcpWritesBeforeRadio, "the radio coming up re-announced on TCP")
}

/// TCP up, then Meshtastic, then MeshCore, then the RNode: each radio's announce goes out on that
/// radio only, and none coming up puts anything on TCP or on another radio.
@MainActor @Test func rnSliceEachRadioAnnouncesOnlyOnItself() async {
    let radio = RNodeRadioHarness()
    let meshtastic = MeshRadioHarness()
    let meshCore = MeshCoreRadioHarness()
    let tcp = MeshTCPHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, meshtastic: meshtastic,
                             meshCore: meshCore, tcp: tcp) { state in
        allThree(&state)
        state.$nodes.withLock { $0 = [sliceHub] }
    }
    let tcpWrites = await tcpUpFirst(store, tcp)

    _ = await rnWait { meshtastic.startCount >= 1 }
    meshtastic.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: 8))
    await store.receive({ isInterfaceConnected($0, meshSlotIDA) }, timeout: .seconds(20))
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(meshSlotIDA))) }, timeout: .seconds(20))
    #expect(await rnWait { !meshtastic.reassembled(session: 0).isEmpty }, "nothing went out on Meshtastic")
    await rnSettle(store)
    let meshtasticPackets = meshtastic.reassembled(session: 0).count

    await mcBringRadioOnline(store, meshCore, id: mcSlotIDA)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(mcSlotIDA))) }, timeout: .seconds(20))
    #expect(await rnWait { !meshCore.sent.value.isEmpty }, "nothing went out on MeshCore")
    await rnSettle(store)
    let meshCoreFrames = meshCore.sent.value.count
    #expect(radio.sent.value.isEmpty, "the RNode sent before it came up")

    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(rnSlotIDA))) }, timeout: .seconds(20))
    let ours = store.state.node.client.deliveryDestinationHash
    #expect(await rnWait { rnOurAnnounces(rnOnAir(radio, session: 0), ours) == 1 }, "no announce on the RNode")
    await rnSettle(store)
    #expect(rnOurAnnounces(rnOnAir(radio, session: 0), ours) == 1)
    #expect(tcp.sends.value.count == tcpWrites, "the RNode coming up re-announced on TCP")
    #expect(meshtastic.reassembled(session: 0).count == meshtasticPackets,
            "the RNode coming up re-announced on Meshtastic")
    #expect(meshCore.sent.value.count == meshCoreFrames, "the RNode coming up re-announced on MeshCore")
}

/// A peer's announce arriving from the radio is learned with the RNode interface as its path. The
/// radio is one a swap installed (A, changed to B, foreground), so the slot is started by
/// `installRNodeSlot` itself: at Connect or foreground the endpoint-wide start would start a freshly
/// installed slot anyway.
@MainActor @Test func rnSliceAPacketFromTheRadioRegistersItsPath() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await store.send(.binding(.set(\.rnodeRadioID, rnRadioIDB.uuidString)))
    await store.send(.foregrounded)
    await store.receive(isRNodeRadioOffline, timeout: .seconds(20))
    await rnBringRadioOnline(store, radio, id: rnSlotIDB, starts: 2)
    let (raw, destinationHash) = rnPeerAnnounce()
    radio.yieldToLatest(.packet(raw, rssi: -90, snr: 5))
    #expect(await rnEventually(store) {
        store.state.node.client.endpoint.learned[destinationHash]?.interfaceID == rnSlotIDB
    }, "learned: \(String(describing: store.state.node.client.endpoint.learned[destinationHash]?.interfaceID))")
}

/// With all radios up, the RNode dropping leaves the app `.connected`; once the others drop too, it
/// is `.disconnected`.
@MainActor @Test func rnSliceConnectionStaysUpWhileAnyRadioIs() async {
    let radio = RNodeRadioHarness()
    let meshtastic = MeshRadioHarness()
    let meshCore = MeshCoreRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, meshtastic: meshtastic,
                             meshCore: meshCore, configure: allThree)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await mcBringRadioOnline(store, meshCore, id: mcSlotIDA)
    _ = await rnWait { meshtastic.startCount >= 1 }
    meshtastic.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: 8))
    await store.receive({ isInterfaceConnected($0, meshSlotIDA) }, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connectedInterfaces == [rnSlotIDA, mcSlotIDA, meshSlotIDA])

    radio.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive({ isInterfaceGone($0, rnSlotIDA) }, timeout: .seconds(20))
    #expect(store.state.connection == .connected, "the other radios are still up")
    await store.skipReceivedActions(strict: false)
    #expect(store.state.connection == .connected)

    meshCore.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive({ isInterfaceGone($0, mcSlotIDA) }, timeout: .seconds(20))
    #expect(store.state.connection == .connected, "Meshtastic is still up")
    meshtastic.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive({ isInterfaceGone($0, meshSlotIDA) }, timeout: .seconds(20))
    #expect(store.state.connection == .disconnected)
    #expect(store.state.connectedInterfaces.isEmpty)
}

/// Radio A online, a parameter changed, Connect tapped while A's stop is in flight: ends on the new
/// config, registered and announced, with no two driver starts without a stop between them.
@MainActor @Test func rnSliceAParameterChangeDuringConnectEndsOnTheNewConfig() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    radio.holdStops()
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.connectTapped)
    radio.releaseStops()
    #expect(await rnWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
    #expect(rnNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    let newReport = RNodeRadioReport(
        name: "RNode 1A2B", firmwareMajor: 1, firmwareMinor: 78, platform: 0x80,
        params: RNodeLoRaParams(frequencyHz: 869_525_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                spreadingFactor: 8, codingRate: 6))
    await rnBringRadioOnline(store, radio, id: rnSlotIDA, starts: 2, report: newReport)
    await store.receive({ $0 == .node(.client(.announceDeliveryOnInterface(rnSlotIDA))) }, timeout: .seconds(20))
    let sessionB = radio.sessions.value.count - 1
    let ours = store.state.node.client.deliveryDestinationHash
    #expect(await rnWait { rnOurAnnounces(rnOnAir(radio, session: sessionB), ours) == 1 },
            "no announce on the new session")
    #expect(await rnEventually(store) { store.state.rnodeStatus.online })
    #expect(store.state.node.client.endpoint.rnode?.interface.config.params.frequencyHz == 869_525_000)
    guard case let .start(config)? = radio.calls.value.last(where: { if case .start = $0 { return true }; return false })
    else { Issue.record("no start"); return }
    #expect(config.params.frequencyHz == 869_525_000, "the last start used the old config")
    #expect(rnNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
}

/// Turning the RNode off with the radio online, then Connect: the slot is stopped and dropped, and no
/// RNode interface is left registered, connected or installed.
@MainActor @Test func rnSliceTurnOffEndToEndLeavesNoInterface() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await store.send(.binding(.set(\.rnodeEnabled, false)))
    await store.send(.connectTapped)
    #expect(await rnEventually(store) { store.state.node.client.endpoint.rnode == nil },
            "the slot was never dropped")
    #expect(store.state.node.client.endpoint.interfaces[rnSlotIDA] == nil)
    #expect(!store.state.connectedInterfaces.contains(rnSlotIDA))
    #expect(store.state.rnodeSwap == nil)
    #expect(radio.calls.value.last == .stop, "calls: \(radio.calls.value)")
    #expect(rnNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
}

// MARK: - Release gate

/// Stale defaults in a build without the RNode: the setting on, a radio chosen and complete settings
/// stored, but `rnodeAvailable` false (set explicitly: under DEBUG the gate defaults true).
private func rnStaleDefaults(_ state: inout AppFeature.State) {
    state.rnodeAvailable = false
    // A disabled node stops `.onLaunch`'s migration adding the default node, so nothing else dials.
    state.$nodes.withLock { $0 = [NodeEntry(id: UUID(), name: "off", host: "off.example", port: 4242, enabled: false)] }
}

@MainActor @Test func rnGateStaleDefaultsStartNoSlot() async {
    let radio = RNodeRadioHarness()
    let commands = LockIsolated<[RnSlotCommand]>([])
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, slotCommands: commands,
                             configure: rnStaleDefaults)
    #expect(store.state.rnodeEnabled && store.state.rnodeRadioUUID == rnRadioIDA
            && store.state.rnodeSettingsProblems.isEmpty && !store.state.rnodeAvailable)
    await store.send(.onLaunch)
    #expect(store.state.node.client.endpoint.rnode == nil, "onLaunch built a slot")
    await store.send(.connectTapped)
    #expect(store.state.node.client.endpoint.rnode == nil, "Connect built a slot")
    await store.send(.foregrounded)
    #expect(store.state.node.client.endpoint.rnode == nil, "foreground built a slot")
    await rnSettle(store)
    #expect(store.state.node.client.endpoint.rnode == nil)
    #expect(radio.calls.value == [])
    #expect(commands.value == [])
}

@MainActor @Test func rnGateStaleDefaultsDoNotShowConnecting() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, configure: rnStaleDefaults)
    await store.send(.onLaunch)
    #expect(store.state.connection == .disconnected, "onLaunch")
    await store.send(.connectTapped)
    #expect(store.state.connection == .disconnected, "Connect")
    await store.send(.foregrounded)
    #expect(store.state.connection == .disconnected, "foreground")
}

/// `\.rnodeDriver` left at its unimplemented test value: any call to it reports an issue.
@MainActor @Test func rnGateStaleDefaultsNeverTouchTheDriver() async {
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: RNodeRadioHarness(), configure: rnStaleDefaults)
    store.dependencies.rnodeDriver = .testValue
    await store.send(.onLaunch)
    await store.send(.connectTapped)
    await store.send(.foregrounded)
    await rnSettle(store)
    #expect(store.state.node.client.endpoint.rnode == nil)
}
