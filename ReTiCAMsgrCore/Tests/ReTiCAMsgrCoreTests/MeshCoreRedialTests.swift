import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
import ReTiCAKeychain
import ReTiCAMeshCoreLive
@testable import ReTiCAMsgrCore

// The MeshCore slot's re-dial, Disconnect and picker guards (lane D Task 8). Every store runs the
// real reducers down to `MeshCoreInterface`, over `MeshCoreRadioHarness` with no key wrapper, so a
// start reports `secretBytes: 0`.
//
// Absence checks ("no `.start` went out") read the store's slot-command log after `redial`, which
// waits for the re-dial's push re-point: `redialDownNodes` concatenates the radio sync and restarts
// BEFORE it, so by then any `.meshCore(.start)` or `.stop` it sent has been reduced.

private func mcWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

/// Lets in-flight effects run before an absence check on the harness, then brings the store's state
/// up to date with what they sent.
@MainActor
private func mcSettle(_ store: TestStoreOf<AppFeature>) async {
    for _ in 0..<5 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func slot(_ store: TestStoreOf<AppFeature>) -> MeshCoreEndpoint.State? {
    store.state.node.client.endpoint.meshCore
}

private func isMeshCoreAdapterUnavailable(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.meshCore(.delegate(.adapterUnavailable))))) = action { return true }
    return false
}

private func isMeshtasticAdapterUnavailable(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.meshtastic(.delegate(.adapterUnavailable))))) = action { return true }
    return false
}

/// Sends `action` (`.foregrounded` or `.pushWake`) and waits until `redialDownNodes` has run past its
/// restarts: its push re-point's `.push(.hubChanged)` comes after them. Needs no TCP client slot,
/// so the re-dial takes its full path. Actions already received are skipped first, so an earlier
/// re-point (Connect's) can't stand in for this one.
@MainActor
private func redial(_ store: TestStoreOf<AppFeature>, _ action: AppFeature.Action) async {
    await store.skipReceivedActions(strict: false)
    await store.send(action)
    await store.receive({ if case .push(.hubChanged) = $0 { return true }; return false }, timeout: .seconds(20))
    await store.skipReceivedActions(strict: false)
}

/// The newest session ends the way the live adapter ends one: `.unavailable(.other(text))`, then
/// the stream finishes. Waits until the app has reduced the endpoint's delegate.
@MainActor
private func failRadio(_ store: TestStoreOf<AppFeature>, _ radio: MeshCoreRadioHarness, _ text: String) async {
    radio.yieldToLatest(.unavailable(.other(text)))
    radio.finishLatest()
    await store.receive(isMeshCoreAdapterUnavailable, timeout: .seconds(20))
}

/// Connect, then wait for radio A's first start (the radio is still connecting, where policy
/// failures happen).
@MainActor
private func connectingStore(radio: MeshCoreRadioHarness, keychain: InMemoryKeychain = mcKeyedKeychain(),
                             slotCommands: LockIsolated<[McSlotCommand]>? = nil) async -> TestStoreOf<AppFeature> {
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, keychain: keychain, slotCommands: slotCommands)
    await store.send(.connectTapped)
    _ = await mcWait { radio.startCount >= 1 }
    return store
}

/// Connect, then bring radio A online.
@MainActor
private func connectedStore(radio: MeshCoreRadioHarness, meshtastic: MeshRadioHarness = MeshRadioHarness(),
                            slotCommands: LockIsolated<[McSlotCommand]>? = nil,
                            configure: ((inout AppFeature.State) -> Void)? = nil) async -> TestStoreOf<AppFeature> {
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, meshtastic: meshtastic,
                             slotCommands: slotCommands, configure: configure)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    return store
}

/// Disconnect, and wait until the MeshCore slot is fully down and nothing is connected.
@MainActor
private func disconnect(_ store: TestStoreOf<AppFeature>) async {
    await store.send(.disconnectTapped)
    #expect(await mcEventually(store) {
        slot(store)?.interface.isIdle == true && store.state.connectedInterfaces.isEmpty
    })
}

private func bothRadios(_ state: inout AppFeature.State) {
    state.$meshtasticEnabled.withLock { $0 = true }
    state.$meshtasticRadioID.withLock { $0 = meshSlotRadioA.uuidString }
}

/// `meshBringRadioOnline` with a time-based wait sized for a whole-package run.
@MainActor
private func bringMeshtasticOnline(_ store: TestStoreOf<AppFeature>, _ meshtastic: MeshRadioHarness,
                                   starts: Int = 1) async {
    _ = await mcWait { meshtastic.startCount >= starts }
    meshtastic.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: 8))
    await store.receive({ isInterfaceConnected($0, meshSlotIDA) }, timeout: .seconds(20))
}

/// A real key change: a new key in the Keychain, then the result the Settings arm reduces.
@MainActor
private func changeKey(_ store: TestStoreOf<AppFeature>, _ keychain: InMemoryKeychain) async {
    #expect(MeshCoreKeyStore.live(ops: keychain.ops).paste(MeshCoreKeyText(mcHexB)) == .changed)
    await store.send(.meshCoreKeyDidChange(.changed))
}

private let startA = McRadioCall.start(mcRadioIDA, canRoute: false, secretBytes: 0)
private let startB = McRadioCall.start(mcRadioIDB, canRoute: false, secretBytes: 0)
/// Not a policy failure: the radio wasn't found this time, and a later attempt may find it.
private let radioNotFound = "radio not found"

/// Spec Contract 2's three policy failures (ruling F16).
private let policyFailures = [MeshCoreLiveMessage.noFreeSlot, MeshCoreLiveMessage.firmwareTooOld,
                              MeshCoreLiveMessage.channelSetupFailed]

// MARK: - Foreground and push wake

@MainActor @Test func mcRedialForegroundRestartsAStoppedRadio() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    await disconnect(store)
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, .stop, startA])
}

/// `.start` reaches an online interface, which ignores it; nothing stops the radio first.
@MainActor @Test func mcRedialForegroundLeavesAnOnlineRadioAlone() async {
    let radio = MeshCoreRadioHarness()
    let commands = LockIsolated<[McSlotCommand]>([])
    let store = await connectedStore(radio: radio, slotCommands: commands)
    commands.setValue([])
    await redial(store, .foregrounded)
    #expect(!commands.value.contains(.stop), "commands: \(commands.value)")
    await mcSettle(store)
    #expect(radio.calls.value == [startA])
    #expect(slot(store)?.interface.isOnline == true)
    #expect(store.state.node.client.endpoint.interfaces[mcSlotIDA] != nil)
}

/// `redialDownNodes` returns early when every TCP node is up; the radio restart must still go out.
/// "radio not found" is not a policy failure.
@MainActor @Test func mcRedialRestartsAnUnavailableRadio() async {
    let radio = MeshCoreRadioHarness()
    let tcp = MeshTCPHarness()
    let node = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, tcp: tcp) { state in
        state.$nodes.withLock { $0 = [node] }
    }
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, node.interfaceID) }, timeout: .seconds(20))
    #expect(await mcWait { radio.startCount >= 1 })
    await failRadio(store, radio, radioNotFound)
    #expect(!store.state.meshCorePolicyFailed)
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, startA])
}

@MainActor @Test func mcRedialPushWakeRestartsAStoppedRadio() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    await disconnect(store)
    await store.send(.pushWake)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, .stop, startA])
}

// MARK: - Policy failures (Review Focus 1)

@MainActor @Test(arguments: policyFailures)
func mcRedialPolicyFailureIsNotRestartedByForegrounding(_ text: String) async {
    let radio = MeshCoreRadioHarness()
    let commands = LockIsolated<[McSlotCommand]>([])
    let store = await connectingStore(radio: radio, slotCommands: commands)
    await failRadio(store, radio, text)
    #expect(store.state.meshCorePolicyFailed)
    commands.setValue([])
    await redial(store, .foregrounded)
    #expect(commands.value == [], "a foreground re-dialled a radio that failed on policy")
    await mcSettle(store)
    #expect(radio.calls.value == [startA])
}

@MainActor @Test(arguments: policyFailures)
func mcRedialPolicyFailureIsNotRestartedByAPushWake(_ text: String) async {
    let radio = MeshCoreRadioHarness()
    let commands = LockIsolated<[McSlotCommand]>([])
    let store = await connectingStore(radio: radio, slotCommands: commands)
    await failRadio(store, radio, text)
    #expect(store.state.meshCorePolicyFailed)
    commands.setValue([])
    await redial(store, .pushWake)
    #expect(commands.value == [], "a push wake re-dialled a radio that failed on policy")
    await mcSettle(store)
    #expect(radio.calls.value == [startA])
}

/// The user frees a slot in the MeshCore app and taps Connect: that retries. Once the flag is
/// clear, an ordinary drop is re-dialled again.
@MainActor @Test(arguments: policyFailures)
func mcRedialConnectRetriesAPolicyFailure(_ text: String) async {
    let radio = MeshCoreRadioHarness()
    let commands = LockIsolated<[McSlotCommand]>([])
    let store = await connectingStore(radio: radio, slotCommands: commands)
    await failRadio(store, radio, text)
    commands.setValue([])
    await redial(store, .foregrounded)
    #expect(commands.value == [])
    await store.send(.connectTapped)
    #expect(!store.state.meshCorePolicyFailed)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, startA])
    await failRadio(store, radio, radioNotFound)
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 3 }, "calls: \(radio.calls.value)")
}

/// Installing a different radio clears the flag: B may have a free slot.
@MainActor @Test func mcRedialANewRadioIsNotHeldByTheOldFailure() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectingStore(radio: radio)
    await failRadio(store, radio, MeshCoreLiveMessage.noFreeSlot)
    #expect(store.state.meshCorePolicyFailed)
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, .stop, startB])
    #expect(await mcEventually(store) { store.state.meshCoreSwap == nil })
    #expect(!store.state.meshCorePolicyFailed)
    await failRadio(store, radio, radioNotFound)
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 3 }, "calls: \(radio.calls.value)")
    #expect(radio.calls.value.last == startB)
}

/// Ruling F18: a key change on the same radio keeps the slot (it never reaches the install), and
/// clears the flag too: the new key may succeed.
@MainActor @Test func mcRedialANewKeyIsNotHeldByTheOldFailure() async {
    let radio = MeshCoreRadioHarness()
    let keychain = mcKeyedKeychain()
    let store = await connectingStore(radio: radio, keychain: keychain)
    await failRadio(store, radio, MeshCoreLiveMessage.noFreeSlot)
    #expect(store.state.meshCorePolicyFailed)
    await changeKey(store, keychain)
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, .stop, startA])
    #expect(await mcEventually(store) { store.state.meshCoreSwap == nil })
    #expect(store.state.meshCoreSlotIdentity == MeshCoreSlotIdentity(radio: mcRadioIDA, keyGeneration: 1))
    #expect(!store.state.meshCorePolicyFailed)
    await failRadio(store, radio, radioNotFound)
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 3 }, "calls: \(radio.calls.value)")
}

// MARK: - Swaps

/// Review Focus 5: a foreground during a swap must not `.start` the slot being replaced.
@MainActor @Test func mcRedialNeverRestartsTheSlotASwapIsReplacing() async {
    let radio = MeshCoreRadioHarness()
    let commands = LockIsolated<[McSlotCommand]>([])
    let store = await connectedStore(radio: radio, slotCommands: commands)
    radio.holdStops()
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    commands.setValue([])
    await redial(store, .foregrounded)
    await redial(store, .foregrounded)
    #expect(commands.value == [.stop], "commands: \(commands.value)")
    #expect(radio.calls.value == [startA])
    radio.releaseStops()
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(await mcEventually(store) { store.state.meshCoreSwap == nil })
    await mcSettle(store)
    #expect(radio.calls.value == [startA, .stop, startB])
}

// MARK: - Both radios (Review Focus 5)

@MainActor @Test func mcRedialRestartsEachRadioIndependently() async {
    let radio = MeshCoreRadioHarness()
    let meshtastic = MeshRadioHarness()
    let store = await connectedStore(radio: radio, meshtastic: meshtastic, configure: bothRadios)
    await bringMeshtasticOnline(store, meshtastic)
    // MeshCore goes down, Meshtastic stays online.
    radio.yieldToLatest(.unavailable(.poweredOff))
    await store.receive(isMeshCoreAdapterUnavailable, timeout: .seconds(20))
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 2 })
    await mcSettle(store)
    #expect(meshtastic.calls.value == [.start(meshSlotRadioA)])
    // The reverse.
    await mcBringRadioOnline(store, radio, id: mcSlotIDA, starts: 2)
    meshtastic.yieldToLatest(.unavailable(.poweredOff))
    await store.receive(isMeshtasticAdapterUnavailable, timeout: .seconds(20))
    await store.send(.foregrounded)
    #expect(await mcWait { meshtastic.startCount >= 2 })
    await mcSettle(store)
    #expect(radio.calls.value == [startA, startA])
}

// MARK: - The picker

/// A MeshCore session connects by retrieval and never scans, so its restart isn't held behind the
/// picker. BLE's is: it would take FCB's one scan.
@MainActor @Test func mcRedialIsNotDeferredByThePicker() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio) { state in
        state.$bleEnabled.withLock { $0 = true }
        var ble = BLEEndpoint.State(localIdentity: state.identity.hash)
        ble.ble.status = .stopped
        state.node.client.endpoint.ble = ble
    }
    await disconnect(store)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
    await store.send(.chooseMeshCoreRadioTapped)
    #expect(store.state.radioPicker?.kind == .meshCore)
    await redial(store, .foregrounded)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, .stop, startA])
    await mcSettle(store)
    #expect(store.state.blePausedForRadioScan)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
}

/// The Connect button sits behind the sheet: a tap under the MeshCore picker is dropped.
@MainActor @Test func mcRedialConnectUnderAMeshCorePickerIsDropped() async {
    let radio = MeshCoreRadioHarness()
    let commands = LockIsolated<[McSlotCommand]>([])
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, slotCommands: commands)
    await store.send(.chooseMeshCoreRadioTapped)
    #expect(store.state.radioPicker?.kind == .meshCore)
    await store.send(.connectTapped)
    #expect(slot(store) == nil)
    #expect(store.state.connection == .disconnected)
    await mcSettle(store)
    #expect(commands.value == [])
    #expect(radio.calls.value == [])
}

// MARK: - Disconnect

/// A swap finishing after Disconnect installs the new radio stopped, and `connection` stays
/// Disconnected rather than showing Connecting… for a radio that isn't dialing.
@MainActor @Test func mcRedialDisconnectDuringASwapLeavesTheNewRadioStopped() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdStops()
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.foregrounded)
    await store.send(.disconnectTapped)
    #expect(store.state.meshCoreSwap?.startNext == false)
    radio.releaseStops()
    await store.receive(isMeshCoreRadioOffline, timeout: .seconds(20))
    #expect(await mcEventually(store) { store.state.meshCoreSwap == nil })
    await mcSettle(store)
    #expect(slot(store)?.interface.config.radio == mcRadioIDB)
    #expect(slot(store)?.interface.isIdle == true)
    #expect(radio.calls.value == [startA, .stop])
    #expect(store.state.connection == .disconnected, "a swap finishing after Disconnect must not show Connecting…")
}

/// T7 review carry: turned back on during a removal, THEN Disconnect (the opposite order of
/// `mcSlotBackOnAfterDisconnectDuringRemovalStaysStopped`). The swap the turn-on retargeted must
/// not start the radio once the removal and stop finish.
@MainActor @Test func mcRedialBackOnDuringRemovalThenDisconnectStaysStopped() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdRemovals()
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    await store.send(.binding(.set(\.meshCoreEnabled, true)))
    #expect(store.state.meshCoreSwap?.startNext == true)
    await store.send(.disconnectTapped)
    radio.releaseRemovals()
    #expect(await mcWait { radio.calls.value.count >= 3 })
    #expect(await mcEventually(store) { store.state.meshCoreSwap == nil })
    await mcSettle(store)
    #expect(radio.calls.value == [startA, .removeChannel, .stop], "a radio started after Disconnect")
    #expect(slot(store)?.interface.isIdle == true)
    #expect(store.state.connection == .disconnected)
}

@MainActor @Test func mcRedialDisconnectStopsBothRadios() async {
    let radio = MeshCoreRadioHarness()
    let meshtastic = MeshRadioHarness()
    let store = await connectedStore(radio: radio, meshtastic: meshtastic, configure: bothRadios)
    await bringMeshtasticOnline(store, meshtastic)
    await store.send(.disconnectTapped)
    #expect(await mcWait { radio.calls.value.count >= 2 && meshtastic.calls.value.count >= 2 })
    #expect(radio.calls.value == [startA, .stop])
    #expect(meshtastic.calls.value == [.start(meshSlotRadioA), .stop])
    #expect(store.state.connection == .disconnected)
}

/// Amendment A10 on the re-dial path: with only the MeshCore radio set up, a foreground that
/// restarts it shows Connecting….
@MainActor @Test func mcRedialShowsConnectingWhenOnlyMeshCoreWillDial() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    await disconnect(store)
    #expect(store.state.connection == .disconnected)
    await store.send(.foregrounded)
    #expect(store.state.connection == .connecting)
}
