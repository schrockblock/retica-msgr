import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
import ReTiCAKeychain
import ReTiCAMeshCoreLive
import ReTiCARNodeLive
import RNodeKit
@testable import ReTiCAMsgrCore

// A radio section's own Connect button in Settings (`radioConnectTapped`) and the state it shows
// (`radioConnectButton`). Every store runs the real reducers down to the radio interfaces, over the
// mock drivers in the radio test support files.

private func rcWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

/// Lets in-flight effects run before an absence check on a harness, then brings the store's state up
/// to date with what they sent.
@MainActor
private func rcSettle(_ store: TestStoreOf<AppFeature>) async {
    for _ in 0..<5 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
}

private func isRNodeUnavailable(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.rnode(.delegate(.adapterUnavailable))))) = action { return true }
    return false
}

private func isMeshtasticUnavailable(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.meshtastic(.delegate(.adapterUnavailable))))) = action { return true }
    return false
}

private func isMeshCoreUnavailable(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.meshCore(.delegate(.adapterUnavailable))))) = action { return true }
    return false
}

/// The newest RNode session ends the way the live adapter ends one, and the app has reduced it.
@MainActor
private func failRNode(_ store: TestStoreOf<AppFeature>, _ radio: RNodeRadioHarness, _ text: String?) async {
    radio.yieldToLatest(.unavailable(.other(text)))
    radio.finishLatest()
    await store.receive(isRNodeUnavailable, timeout: .seconds(20))
}

private func meshtasticAndMeshCoreOn(_ state: inout AppFeature.State) {
    state.$meshtasticEnabled.withLock { $0 = true }
    state.$meshtasticRadioID.withLock { $0 = meshSlotRadioA.uuidString }
    state.$meshCoreEnabled.withLock { $0 = true }
    state.$meshCoreRadioID.withLock { $0 = mcRadioIDA.uuidString }
}

private let rcParamsF1 = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                         spreadingFactor: 8, codingRate: 6)
private let rcStartA1 = RnRadioCall.start(RNodeDriverConfig(radio: rnRadioIDA, params: rcParamsF1))

private func rcParamsTX(_ dBm: UInt8) -> RNodeLoRaParams {
    RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: dBm, spreadingFactor: 8, codingRate: 6)
}

// MARK: - The action

/// The trap from hardware testing: the hub is up (so the main Connect button isn't shown) and the
/// RNode failed on pairing. Its own Connect retries it, and the hub stays connected.
@MainActor @Test func rcRNodeConnectRetriesAUserActionFailureWhileTheHubIsUp() async {
    let radio = RNodeRadioHarness()
    let tcp = MeshTCPHarness()
    let node = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, tcp: tcp) { state in
        state.$nodes.withLock { $0 = [node] }
    }
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, node.interfaceID) }, timeout: .seconds(20))
    #expect(await rcWait { radio.startCount >= 1 })
    await failRNode(store, radio, RNodeLiveMessage.pairingRequired)
    #expect(store.state.rnodeNeedsUserAction)
    #expect(store.state.connection == .connected)

    await store.send(.radioConnectTapped(.rnode))
    #expect(!store.state.rnodeNeedsUserAction)
    #expect(await rcWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
    await rcSettle(store)
    #expect(radio.calls.value == [rcStartA1, rcStartA1])
    #expect(store.state.connection == .connected)
    #expect(store.state.connectedInterfaces.contains(node.interfaceID))
}

/// Nothing but the RNode is synced or started: no TCP slot, listener, BLE slot or other radio appears,
/// though every one of them is turned on. From Disconnected, the radio dialling shows Connecting….
@MainActor @Test func rcRNodeConnectTouchesOnlyTheRNode() async {
    let radio = RNodeRadioHarness()
    let meshtastic = MeshRadioHarness()
    let meshCore = MeshCoreRadioHarness()
    let node = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, meshtastic: meshtastic,
                             meshCore: meshCore) { state in
        state.$nodes.withLock { $0 = [node] }
        state.$listenEnabled.withLock { $0 = true }
        state.$bleEnabled.withLock { $0 = true }
        meshtasticAndMeshCoreOn(&state)
    }
    #expect(store.state.connection == .disconnected)
    await store.send(.radioConnectTapped(.rnode))
    #expect(store.state.connection == .connecting)
    #expect(await rcWait { radio.startCount >= 1 })
    await rcSettle(store)
    let endpoint = store.state.node.client.endpoint
    #expect(endpoint.rnode?.interface.config == RNodeDriverConfig(radio: rnRadioIDA, params: rcParamsF1))
    #expect(endpoint.tcpClients.isEmpty)
    #expect(endpoint.tcpServer == nil)
    #expect(endpoint.ble == nil)
    #expect(endpoint.meshtastic == nil)
    #expect(endpoint.meshCore == nil)
    #expect(meshtastic.calls.value == [])
    #expect(meshCore.calls.value == [])
    #expect(radio.calls.value == [rcStartA1])
}

/// A radio that won't dial (here: none chosen) leaves Disconnected alone (amendment A10).
@MainActor @Test func rcConnectForARadioThatWontDialStaysDisconnected() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: nil, radioHarness: radio)
    await store.send(.radioConnectTapped(.rnode))
    #expect(store.state.connection == .disconnected)
    #expect(store.state.node.client.endpoint.rnode == nil)
}

/// The button sits behind the picker's sheet: a tap under it is dropped, as Connect's is.
@MainActor @Test func rcConnectUnderThePickerIsDropped() async {
    let radio = RNodeRadioHarness()
    let commands = LockIsolated<[RnSlotCommand]>([])
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, slotCommands: commands)
    await store.send(.chooseRNodeRadioTapped)
    #expect(store.state.radioPicker?.kind == .rnode)
    await store.send(.radioConnectTapped(.rnode))
    #expect(store.state.node.client.endpoint.rnode == nil)
    #expect(store.state.connection == .disconnected)
    await rcSettle(store)
    #expect(commands.value == [])
    #expect(radio.calls.value == [])
}

/// The current Settings values apply: the radio clamped 30 dBm to 22, the user lowers TX power and
/// taps the RNode's Connect, and the slot is replaced with the new parameters.
@MainActor @Test func rcRNodeConnectAppliesChangedSettings() async {
    let radio = RNodeRadioHarness()
    var tx30 = rnCompleteSettings
    tx30.txPowerDBm = 30
    let store = rnRadioStore(radio: rnRadioIDA, settings: tx30, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(await rcWait { radio.startCount >= 1 })
    await failRNode(store, radio, RNodeLiveMessage.configurationRejected(
        [RNodeParameterMismatch(field: .txPower, requested: 30, reported: 22)]))
    #expect(store.state.rnodeNeedsUserAction)
    await store.send(.rnodeTXPowerChanged(22))
    await store.send(.radioConnectTapped(.rnode))
    #expect(!store.state.rnodeNeedsUserAction)
    #expect(await rcWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rcSettle(store)
    #expect(radio.calls.value.first == .start(RNodeDriverConfig(radio: rnRadioIDA, params: rcParamsTX(30))))
    #expect(radio.calls.value.last == .start(RNodeDriverConfig(radio: rnRadioIDA, params: rcParamsTX(22))))
    #expect(rnNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
}

/// Meshtastic's own Connect restarts only Meshtastic: the RNode and MeshCore radios stay online and
/// their drivers see nothing new, though both have a pending change (new RNode parameters, a new
/// MeshCore key) that a sync of every slot would apply.
@MainActor @Test func rcMeshtasticConnectRestartsOnlyMeshtastic() async {
    let radio = RNodeRadioHarness()
    let meshtastic = MeshRadioHarness()
    let meshCore = MeshCoreRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio, meshtastic: meshtastic, meshCore: meshCore,
                             configure: meshtasticAndMeshCoreOn)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    await meshBringRadioOnline(store, meshtastic, id: meshSlotIDA)
    await mcBringRadioOnline(store, meshCore, id: mcSlotIDA)
    meshtastic.yieldToLatest(.unavailable(.poweredOff))
    await store.receive(isMeshtasticUnavailable, timeout: .seconds(20))
    #expect(store.state.radioConnectButton(.meshtastic) == .connect)
    #expect(store.state.radioConnectButton(.rnode) == .hidden)
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.meshCoreKeyDidChange(.changed))

    await store.send(.radioConnectTapped(.meshtastic))
    #expect(store.state.rnodeSwap == nil)
    #expect(store.state.meshCoreSwap == nil)
    #expect(await rcWait { meshtastic.startCount >= 2 }, "calls: \(meshtastic.calls.value)")
    await rcSettle(store)
    #expect(meshtastic.calls.value == [.start(meshSlotRadioA), .start(meshSlotRadioA)])
    #expect(radio.calls.value == [rcStartA1])
    #expect(meshCore.calls.value.count == 1, "calls: \(meshCore.calls.value)")
    #expect(store.state.node.client.endpoint.rnode?.interface.config.params == rcParamsF1)
    #expect(store.state.node.client.endpoint.rnode?.interface.isOnline == true)
    #expect(store.state.node.client.endpoint.meshCore?.interface.isOnline == true)
}

// MARK: - Apply changes

/// The RNode is online and the hub may be up, so neither Connect is on screen: a parameter change
/// shows Apply changes, and the tap swaps the slot to the new parameters.
@MainActor @Test func rcRNodeApplyChangesSwapsAnOnlineRadio() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    #expect(store.state.radioConnectButton(.rnode) == .hidden)
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    #expect(store.state.radioConnectButton(.rnode) == .applyChanges)
    await store.send(.radioConnectTapped(.rnode))
    #expect(await rcWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
    await rcSettle(store)
    let paramsF2 = RNodeLoRaParams(frequencyHz: 869_525_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                   spreadingFactor: 8, codingRate: 6)
    #expect(radio.calls.value == [rcStartA1, .stop, .start(RNodeDriverConfig(radio: rnRadioIDA, params: paramsF2))])
    #expect(store.state.node.client.endpoint.rnode?.interface.config.params == paramsF2)
}

/// A different Meshtastic radio chosen while one is online: Apply changes, and the tap swaps to it.
@MainActor @Test func rcMeshtasticApplyChangesSwapsAnOnlineRadio() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    #expect(store.state.radioConnectButton(.meshtastic) == .hidden)
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    #expect(store.state.radioConnectButton(.meshtastic) == .applyChanges)
    await store.send(.radioConnectTapped(.meshtastic))
    #expect(await rcWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
    #expect(await rnEventually(store) { store.state.meshtasticSwap == nil })
    await rcSettle(store)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioB)])
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioB)
}

/// A new MeshCore key while the radio is online: Apply changes, and the tap stops the slot and
/// restarts it for the new key generation.
@MainActor @Test func rcMeshCoreApplyChangesRestartsAnOnlineRadioForANewKey() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    #expect(store.state.radioConnectButton(.meshCore) == .hidden)
    await store.send(.meshCoreKeyDidChange(.changed))
    #expect(store.state.radioConnectButton(.meshCore) == .applyChanges)
    await store.send(.radioConnectTapped(.meshCore))
    #expect(await rcWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
    #expect(await rnEventually(store) { store.state.meshCoreSwap == nil })
    #expect(store.state.meshCoreSlotIdentity == MeshCoreSlotIdentity(radio: mcRadioIDA, keyGeneration: 1))
    #expect(radio.calls.value.contains(.stop), "calls: \(radio.calls.value)")
}

/// The Meshtastic button's labels (no Meshtastic copy file existed; these live in Core so they're pinned).
@Test func rcMeshtasticCopyLabels() {
    #expect(MeshtasticCopy.connectButton == "Connect Meshtastic radio")
    #expect(MeshtasticCopy.connecting == "Connecting…")
    #expect(MeshtasticCopy.applyChanges == "Apply changes")
}

/// MeshCore's own Connect clears a policy failure and retries; with nothing else up it shows
/// Connecting… again.
@MainActor @Test func rcMeshCoreConnectRetriesAPolicyFailure() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(await rcWait { radio.startCount >= 1 })
    radio.yieldToLatest(.unavailable(.other(MeshCoreLiveMessage.noFreeSlot)))
    radio.finishLatest()
    await store.receive(isMeshCoreUnavailable, timeout: .seconds(20))
    #expect(store.state.meshCorePolicyFailed)
    #expect(store.state.meshCoreChannelKnownAbsent)
    #expect(store.state.connection == .disconnected)
    #expect(store.state.radioConnectButton(.meshCore) == .connect)

    await store.send(.radioConnectTapped(.meshCore))
    #expect(!store.state.meshCorePolicyFailed)
    #expect(!store.state.meshCoreChannelKnownAbsent)
    #expect(store.state.connection == .connecting)
    #expect(await rcWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
}

// MARK: - The button

/// Hidden until the radio will dial, Connect while it is stopped, Connecting… while it dials, hidden
/// once online, Connect again once unavailable.
@MainActor @Test func rcButtonFollowsTheRNodeSlot() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, enabled: false, radioHarness: radio)
    #expect(store.state.radioConnectButton(.rnode) == .hidden)
    await store.send(.binding(.set(\.rnodeEnabled, true)))
    #expect(store.state.radioConnectButton(.rnode) == .connect)
    await store.send(.radioConnectTapped(.rnode))
    #expect(await rnEventually(store) { store.state.radioConnectButton(.rnode) == .connecting })
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    #expect(store.state.radioConnectButton(.rnode) == .hidden)
    radio.yieldToLatest(.unavailable(.poweredOff))
    await store.receive(isRNodeUnavailable, timeout: .seconds(20))
    #expect(store.state.radioConnectButton(.rnode) == .connect)
}

/// A swap replacing an online slot will start the new one: Connecting…. After a Disconnect the swap
/// leaves it stopped: Connect.
@MainActor @Test func rcButtonDuringASwap() async {
    let radio = RNodeRadioHarness()
    let store = rnRadioStore(radio: rnRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    await rnBringRadioOnline(store, radio, id: rnSlotIDA)
    radio.holdStops()
    await store.send(.rnodeFrequencyTextChanged("869.525"))
    await store.send(.radioConnectTapped(.rnode))
    #expect(store.state.rnodeSwap?.startNext == true)
    #expect(store.state.radioConnectButton(.rnode) == .connecting)
    await store.send(.disconnectTapped)
    #expect(store.state.rnodeSwap?.startNext == false)
    #expect(store.state.radioConnectButton(.rnode) == .connect)
    radio.releaseStops()
    #expect(await rnEventually(store) { store.state.rnodeSwap == nil })
}

/// Hidden behind each will-dial condition: the Release gate, a missing MeshCore key, an RNode
/// setting problem, no Meshtastic radio.
@MainActor @Test func rcButtonIsHiddenWhenTheRadioWontDial() async {
    let mc = mcRadioStore(radio: mcRadioIDA, radioHarness: MeshCoreRadioHarness())
    #expect(mc.state.radioConnectButton(.meshCore) == .connect)
    let mcNoKey = mcRadioStore(radio: mcRadioIDA, radioHarness: MeshCoreRadioHarness(), keychain: InMemoryKeychain())
    #expect(mcNoKey.state.radioConnectButton(.meshCore) == .hidden)
    let mcGated = mcRadioStore(radio: mcRadioIDA, radioHarness: MeshCoreRadioHarness()) { $0.meshCoreAvailable = false }
    #expect(mcGated.state.radioConnectButton(.meshCore) == .hidden)

    let rnGated = rnRadioStore(radio: rnRadioIDA, radioHarness: RNodeRadioHarness()) { $0.rnodeAvailable = false }
    #expect(rnGated.state.radioConnectButton(.rnode) == .hidden)
    let rnNoFrequency = rnRadioStore(radio: rnRadioIDA, settings: nil, radioHarness: RNodeRadioHarness())
    #expect(rnNoFrequency.state.radioConnectButton(.rnode) == .hidden)

    let mesh = meshRadioStore(radio: meshSlotRadioA, harness: MeshRadioHarness())
    #expect(mesh.state.radioConnectButton(.meshtastic) == .connect)
    let meshNoRadio = meshRadioStore(radio: nil, harness: MeshRadioHarness())
    #expect(meshNoRadio.state.radioConnectButton(.meshtastic) == .hidden)
}
