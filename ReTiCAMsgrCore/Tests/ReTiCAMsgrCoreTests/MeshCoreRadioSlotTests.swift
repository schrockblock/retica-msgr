import Testing
import Foundation
import Security
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
import ReTiCAKeychain
@testable import ReTiCAMsgrCore

// The MeshCore radio slot (lane D Task 7). Every store here runs the real reducers down to
// `MeshCoreInterface`, over `MeshCoreRadioHarness` with no key wrapper, so a start reports
// `secretBytes: 0`.
//
// Exact call lists are triggered with `.foregrounded` where the sync alone should act: Connect also
// sends `.endpoint(.start)` in the same burst, which reaches an old slot mid-stop and adds a second
// `.stop` (ruling F12). Tests that must use Connect pin that `[…, .stop, .stop, .start]` and check
// `mcNoOverlappingStarts`.

private func mcWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

/// Lets in-flight effects run before an absence check ("nothing more happened"), then brings the
/// store's state up to date with what they sent.
@MainActor
private func mcSettle(_ store: TestStoreOf<AppFeature>) async {
    for _ in 0..<5 { await Task.megaYield() }
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func slot(_ store: TestStoreOf<AppFeature>) -> MeshCoreEndpoint.State? {
    store.state.node.client.endpoint.meshCore
}

/// A real key change: a new key in the Keychain, then the result the Settings arm reduces.
@MainActor
private func changeKey(_ store: TestStoreOf<AppFeature>, _ keychain: InMemoryKeychain, to hex: String = mcHexB) async {
    #expect(MeshCoreKeyStore.live(ops: keychain.ops).paste(MeshCoreKeyText(hex)) == .changed)
    await store.send(.meshCoreKeyDidChange(.changed))
}

/// Connect, then bring radio A online.
@MainActor
private func connectedStore(radio: MeshCoreRadioHarness, keychain: InMemoryKeychain = mcKeyedKeychain(),
                            meshtastic: MeshRadioHarness = MeshRadioHarness(),
                            removeChannelSends: LockIsolated<Int>? = nil,
                            configure: ((inout AppFeature.State) -> Void)? = nil) async -> TestStoreOf<AppFeature> {
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, meshtastic: meshtastic, keychain: keychain,
                             removeChannelSends: removeChannelSends, configure: configure)
    await store.send(.connectTapped)
    await mcBringRadioOnline(store, radio, id: mcSlotIDA)
    return store
}

/// The packet IDs of the frames the harness sent from `index` on.
private func packetIDs(_ radio: MeshCoreRadioHarness, from index: Int = 0) -> [UInt16] {
    radio.sent.value.dropFirst(index).compactMap { ScotMeshRawCodec().parse($0.frame)?.packetID }
}

private let startA = McRadioCall.start(mcRadioIDA, canRoute: false, secretBytes: 0)
private let startB = McRadioCall.start(mcRadioIDB, canRoute: false, secretBytes: 0)

// MARK: - Connect

@MainActor @Test func mcSlotConnectStartsTheChosenRadio() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 })
    #expect(radio.calls.value.first == startA)
    #expect(slot(store)?.interface.config.radio == mcRadioIDA)
    #expect(mcConfigsHoldNoKey(radio))
}

@MainActor @Test func mcSlotConfigInStateHoldsNoKey() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 })
    #expect(slot(store)?.interface.config.channelSecret == Data())
    #expect(slot(store)?.interface.config.retiredChannelSecrets == [])
    #expect(radio.configs.value.count == 1)
    #expect(mcConfigsHoldNoKey(radio))
}

@MainActor @Test func mcSlotConnectWithMeshCoreOffBuildsNoSlot() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, enabled: false, radioHarness: radio)
    await store.send(.connectTapped)
    await mcSettle(store)
    #expect(slot(store) == nil)
    #expect(radio.calls.value.isEmpty)
}

@MainActor @Test func mcSlotConnectWithoutARadioBuildsNoSlotAndDialsNothing() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: nil, radioHarness: radio)
    await store.send(.connectTapped)
    await mcSettle(store)
    #expect(slot(store) == nil)
    #expect(radio.calls.value.isEmpty)
    #expect(store.state.connection == .disconnected, "nothing will dial: Connecting… would never resolve")
}

@MainActor @Test func mcSlotConnectWithoutAKeyBuildsNoSlot() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, keychain: InMemoryKeychain())
    await store.send(.connectTapped)
    await mcSettle(store)
    #expect(slot(store) == nil)
    #expect(radio.calls.value.isEmpty)
    #expect(store.state.connection == .disconnected)
}

@MainActor @Test func mcSlotAKeySetLaterStartsAtTheNextConnect() async {
    let radio = MeshCoreRadioHarness()
    let keychain = InMemoryKeychain()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, keychain: keychain)
    await store.send(.connectTapped)
    await mcSettle(store)
    #expect(slot(store) == nil)
    await changeKey(store, keychain, to: mcHexA)
    await mcSettle(store)
    #expect(radio.calls.value.isEmpty, "a key change alone dials nothing")
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 })
    #expect(radio.calls.value == [startA])
    #expect(mcConfigsHoldNoKey(radio))
}

/// Amendment A10 ("will something dial") gains the MeshCore radio.
@MainActor @Test func mcSlotConnectWithOnlyARadioShowsConnecting() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(store.state.connection == .connecting)
}

// MARK: - Turn-off and channel removal

@MainActor @Test func mcSlotTurningOffWhileOnlineRemovesTheChannelThenStops() async {
    let radio = MeshCoreRadioHarness()
    let removals = LockIsolated(0)
    let store = await connectedStore(radio: radio, removeChannelSends: removals)
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    #expect(await mcWait { radio.calls.value.count >= 3 })
    #expect(await mcEventually(store) { slot(store) == nil })
    #expect(radio.calls.value == [startA, .removeChannel, .stop])
    #expect(removals.value == 1, "the counter sees the removal the store reduced")
    #expect(store.state.meshCoreSwap == nil)
    #expect(store.state.node.client.endpoint.interfaces[mcSlotIDA] == nil)
}

@MainActor @Test func mcSlotARemovedChannelIsRecorded() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    #expect(await mcEventually(store) { slot(store) == nil })
    #expect(store.state.meshCoreStatus.channelRemoved)
    #expect(!store.state.meshCoreStatus.channelLeftOnRadio)
    #expect(!store.state.meshCoreTurnOffNoticeVisible)
}

@MainActor @Test func mcSlotARestartClearsTheRemovedRecord() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    #expect(await mcEventually(store) { slot(store) == nil })
    #expect(store.state.meshCoreStatus.channelRemoved)
    await store.send(.binding(.set(\.meshCoreEnabled, true)))
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(!store.state.meshCoreStatus.channelRemoved)
    #expect(store.state.meshCoreTurnOffNoticeVisible)
}

@MainActor @Test func mcSlotTurningOffWhileOnlineStopsOnlyAfterTheRemovalReturns() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdRemovals()
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    #expect(store.state.meshCoreSwap?.removingChannel == true)
    await mcSettle(store)
    #expect(radio.calls.value == [startA], "a .stop before the removal returned")
    #expect(slot(store) != nil)
    radio.releaseRemovals()
    #expect(await mcWait { radio.calls.value.count >= 3 })
    #expect(radio.calls.value == [startA, .removeChannel, .stop])
    #expect(await mcEventually(store) { slot(store) == nil })
}

@MainActor @Test func mcSlotFailedRemovalIsRecorded() async {
    let radio = MeshCoreRadioHarness()
    radio.removalResult.setValue(false)
    let store = await connectedStore(radio: radio)
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    #expect(await mcEventually(store) { slot(store) == nil })
    #expect(radio.calls.value == [startA, .removeChannel, .stop])
    #expect(store.state.meshCoreStatus.channelLeftOnRadio)
    #expect(!store.state.meshCoreStatus.channelRemoved)
}

/// The interface answers a `.removeChannel` to a radio that isn't online without calling the
/// driver, so the store's `.removeChannel` counter is what shows none was sent.
@MainActor @Test func mcSlotTurningOffWhileConnectingOnlyStops() async {
    let radio = MeshCoreRadioHarness()
    let removals = LockIsolated(0)
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, removeChannelSends: removals)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 })        // never connected: .connecting
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    #expect(await mcEventually(store) { slot(store) == nil })
    #expect(radio.calls.value == [startA, .stop])
    #expect(removals.value == 0, "a .removeChannel to a radio that isn't online")
    #expect(store.state.meshCoreStatus.channelLeftOnRadio)
}

/// No slot this session: we can't know whether our channel is on the radio, so nothing is claimed
/// and lane C's notice ("may") shows.
@MainActor @Test func mcSlotTurningOffWithNoSlotDoesNothing() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    await mcSettle(store)
    #expect(radio.calls.value == [])
    #expect(!store.state.meshCoreStatus.channelLeftOnRadio)
    #expect(store.state.meshCoreTurnOffNoticeVisible)
}

@MainActor @Test func mcSlotTurningOffAfterDisconnectIsRecorded() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.disconnectTapped)
    #expect(await mcEventually(store) { slot(store)?.interface.isIdle == true })
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    #expect(slot(store) == nil)
    #expect(store.state.meshCoreStatus.channelLeftOnRadio)
    await mcSettle(store)
    #expect(radio.calls.value == [startA, .stop])
}

@MainActor @Test func mcSlotTurningOnWithNoSwapWaitsForConnect() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, enabled: false, radioHarness: radio)
    await store.send(.binding(.set(\.meshCoreEnabled, true)))
    await mcSettle(store)
    #expect(radio.calls.value == [])
    #expect(slot(store) == nil)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 })
    #expect(radio.calls.value == [startA])
}

// MARK: - Turn-off races (Review Focus 4)

@MainActor @Test func mcSlotDisconnectDuringRemovalStillFinishes() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdRemovals()
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    await store.send(.disconnectTapped)
    await mcSettle(store)
    #expect(radio.calls.value == [startA], "a .stop before the removal returned")
    radio.releaseRemovals()
    #expect(await mcEventually(store) { slot(store) == nil })
    await mcSettle(store)
    #expect(radio.calls.value == [startA, .removeChannel, .stop])
    #expect(store.state.meshCoreSwap == nil)
}

@MainActor @Test func mcSlotBackOnDuringRemovalEndsRunning() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdRemovals()
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    await store.send(.binding(.set(\.meshCoreEnabled, true)))
    radio.releaseRemovals()
    #expect(await mcWait { radio.calls.value.count >= 4 })
    #expect(radio.calls.value == [startA, .removeChannel, .stop, startA])
    #expect(mcNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    #expect(await mcEventually(store) { store.state.meshCoreSwap == nil })
    #expect(slot(store)?.interface.config.radio == mcRadioIDA)
}

/// Ruling F13: the keep-slot branch resets the per-radio status, so a radio running again after a
/// removal doesn't show "removed".
@MainActor @Test func mcSlotBackOnDuringRemovalClearsTheRemovedRecord() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdRemovals()
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    await store.send(.binding(.set(\.meshCoreEnabled, true)))
    radio.releaseRemovals()
    #expect(await mcWait { radio.calls.value.count >= 4 })
    #expect(await mcEventually(store) { store.state.meshCoreSwap == nil })
    #expect(!store.state.meshCoreStatus.channelRemoved)
    #expect(!store.state.meshCoreStatus.channelLeftOnRadio)
}

@MainActor @Test func mcSlotBackOnAfterDisconnectDuringRemovalStaysStopped() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdRemovals()
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    await store.send(.disconnectTapped)
    await store.send(.binding(.set(\.meshCoreEnabled, true)))
    radio.releaseRemovals()
    #expect(await mcWait { radio.calls.value.count >= 3 })
    #expect(await mcEventually(store) { store.state.meshCoreSwap == nil })
    await mcSettle(store)
    #expect(radio.calls.value == [startA, .removeChannel, .stop], "turning on without a Connect started a radio")
    #expect(slot(store) != nil)
    #expect(store.state.connection == .disconnected)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value.last == startA)
    #expect(mcNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
}

@MainActor @Test func mcSlotConnectDuringRemovalNeverOverlaps() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdRemovals()
    await store.send(.binding(.set(\.meshCoreEnabled, false)))
    await store.send(.connectTapped)
    radio.releaseRemovals()
    #expect(await mcEventually(store) { slot(store) == nil })
    await mcSettle(store)
    #expect(radio.calls.value == [startA, .removeChannel, .stop])
    #expect(mcNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
}

/// Disconnect isn't turn-off: it stops the radio and keeps our channel slot.
@MainActor @Test func mcSlotDisconnectDoesNotRemoveTheChannel() async {
    let radio = MeshCoreRadioHarness()
    let removals = LockIsolated(0)
    let store = await connectedStore(radio: radio, removeChannelSends: removals)
    await store.send(.disconnectTapped)
    #expect(await mcWait { radio.calls.value.count >= 2 })
    await mcSettle(store)
    #expect(radio.calls.value == [startA, .stop])
    #expect(removals.value == 0)
    #expect(slot(store) != nil)
}

// MARK: - Radio and key changes

@MainActor @Test func mcSlotChangingTheRadioStopsWithoutRemoving() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, .stop, startB])
    #expect(await mcEventually(store) { slot(store)?.interface.config.radio == mcRadioIDB })
    #expect(mcConfigsHoldNoKey(radio))
}

@MainActor @Test func mcSlotChangingTheRadioWhileConnectingWaitsForItsStop() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 })        // never connected: .connecting
    radio.holdStops()
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.foregrounded)
    await mcSettle(store)
    #expect(radio.calls.value == [startA])
    #expect(slot(store)?.interface.config.radio == mcRadioIDA)
    radio.releaseStops()
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, .stop, startB])
}

@MainActor @Test func mcSlotAnIdleOldSlotIsReplacedAtOnce() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.disconnectTapped)
    #expect(await mcEventually(store) { slot(store)?.interface.isIdle == true })
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.connectTapped)
    #expect(slot(store)?.interface.config.radio == mcRadioIDB)
    #expect(store.state.meshCoreSwap == nil)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, .stop, startB])
}

/// A key change waits for Connect, then stops and restarts the same slot. Connect's
/// `.endpoint(.start)` reaches the stopping slot, so the app stops it twice (ruling F12).
@MainActor @Test func mcSlotAKeyChangeRestartsAtTheNextConnect() async {
    let radio = MeshCoreRadioHarness()
    let keychain = mcKeyedKeychain()
    let store = await connectedStore(radio: radio, keychain: keychain)
    await changeKey(store, keychain)
    await mcSettle(store)
    #expect(radio.calls.value == [startA], "a key change restarted the radio before Connect")
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, .stop, .stop, startA])
    #expect(mcNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    #expect(await mcEventually(store) { store.state.meshCoreSwap == nil })
    #expect(store.state.meshCoreSlotIdentity == MeshCoreSlotIdentity(radio: mcRadioIDA, keyGeneration: 1))
    #expect(mcConfigsHoldNoKey(radio))
}

@MainActor @Test func mcSlotAKeyChangeDoesNotRemoveTheChannel() async {
    let radio = MeshCoreRadioHarness()
    let keychain = mcKeyedKeychain()
    let removals = LockIsolated(0)
    let store = await connectedStore(radio: radio, keychain: keychain, removeChannelSends: removals)
    await changeKey(store, keychain)
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, .stop, startA])
    #expect(removals.value == 0)
}

/// A key change keeps the slot: the §5.5 limiter (stamped by the radio-up announce) and the packet
/// ID counter carry over. A fresh slot would reuse packet ID 0x1000 and forget the stamp.
@MainActor @Test func mcSlotAKeyChangeKeepsTheSlotState() async {
    let radio = MeshCoreRadioHarness()
    let keychain = mcKeyedKeychain()
    let store = await connectedStore(radio: radio, keychain: keychain)
    // The radio-up announce goes out on the radio and stamps the limiter.
    #expect(await mcWait { !radio.sent.value.isEmpty })
    #expect(await mcEventually(store) { slot(store)?.interface.limiter != MeshCoreAnnounceLimiter() })
    let limiterBefore = slot(store)?.interface.limiter
    let idsBefore = Set(packetIDs(radio))
    #expect(!idsBefore.isEmpty)
    await changeKey(store, keychain)
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(await mcEventually(store) { store.state.meshCoreSwap == nil })
    #expect(slot(store)?.interface.limiter == limiterBefore, "the limiter was reset")
    let sentBefore = radio.sent.value.count
    await mcBringRadioOnline(store, radio, id: mcSlotIDA, starts: 2)
    await store.send(.node(.client(.endpoint(.meshCore(.interface(.send(Data(repeating: 0xA5, count: 40))))))))
    #expect(await mcWait { radio.sent.value.count > sentBefore })
    await mcSettle(store)
    let idsAfter = packetIDs(radio, from: sentBefore)
    #expect(!idsAfter.isEmpty)
    #expect(Set(idsAfter).isDisjoint(with: idsBefore), "a packet ID was reused: \(idsAfter) vs \(idsBefore)")
}

@MainActor @Test func mcSlotAKeyChangeOnAnIdleSlotKeepsItsState() async {
    let radio = MeshCoreRadioHarness()
    let keychain = mcKeyedKeychain()
    let store = await connectedStore(radio: radio, keychain: keychain)
    #expect(await mcEventually(store) { slot(store)?.interface.limiter != MeshCoreAnnounceLimiter() })
    await store.send(.disconnectTapped)
    #expect(await mcEventually(store) { slot(store)?.interface.isIdle == true })
    let limiterBefore = slot(store)?.interface.limiter
    await changeKey(store, keychain)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(slot(store)?.interface.limiter == limiterBefore, "the limiter was reset")
    #expect(Array(radio.calls.value.suffix(2)) == [.stop, startA])
    #expect(store.state.meshCoreSlotIdentity == MeshCoreSlotIdentity(radio: mcRadioIDA, keyGeneration: 1))
}

/// Forgetting retired keys changes what a start carries, not the slot identity.
@MainActor @Test func mcSlotRetiredKeysAloneDoNotRestart() async {
    let radio = MeshCoreRadioHarness()
    let (keychain, keys) = mcKeychain()
    _ = keys.paste(MeshCoreKeyText(mcHexB))
    _ = keys.paste(MeshCoreKeyText(mcHexA))
    #expect(keys.secrets()?.retired.count == 1)
    let store = await connectedStore(radio: radio, keychain: keychain)
    keys.forgetRetired([Data(hexString: mcHexB)!])
    #expect(keys.secrets()?.retired == [])
    await store.send(.connectTapped)
    await mcSettle(store)
    #expect(radio.calls.value == [startA])
}

// MARK: - Relay

@MainActor @Test func mcSlotRelayOnSetsCanRoute() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio,
                             configure: { $0.$relayEnabled.withLock { $0 = true } })
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 })
    #expect(radio.calls.value.first == .start(mcRadioIDA, canRoute: true, secretBytes: 0))
}

@MainActor @Test func mcSlotRelayChangeUpdatesTheRunningSlot() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.setRelayMode(true))
    #expect(await mcEventually(store) { slot(store)?.interface.config.canRoute == true })
}

@MainActor @Test func mcSlotRelayChangeDoesNotRestartTheRadio() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    await store.send(.setRelayMode(true))
    await mcSettle(store)
    #expect(radio.calls.value == [startA])
    await store.send(.connectTapped)
    await mcSettle(store)
    #expect(radio.calls.value == [startA])
}

/// An action to the missing slot would trip `ifLet`, which fails the test.
@MainActor @Test func mcSlotRelayChangeWithNoSlotSendsNothing() async {
    let radio = MeshCoreRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio)
    await store.send(.setRelayMode(true))
    await mcSettle(store)
    await store.skipReceivedActions(strict: false)
    #expect(slot(store) == nil)
    #expect(radio.calls.value == [])
}

@MainActor @Test func mcSlotSwapInstallUsesTheCurrentRelaySetting() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdStops()
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.foregrounded)
    await store.send(.setRelayMode(true))
    radio.releaseStops()
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value.last == .start(mcRadioIDB, canRoute: true, secretBytes: 0))
}

// MARK: - Swaps under Connect (Review Focus 4)

/// A swap is replacing A with B, the radio is set back to A, then Connect: the in-flight swap is
/// retargeted (rule 1) rather than ignored, and the Connect's start reaching the stopping slot is
/// stopped again, so no two starts run without a stop between them.
@MainActor @Test func mcSlotConnectDuringASwapNeverStartsTwiceWithoutAStop() async {
    let radio = MeshCoreRadioHarness()
    let store = await connectedStore(radio: radio)
    radio.holdStops()
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.foregrounded)
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDA.uuidString)))
    await store.send(.connectTapped)
    radio.releaseStops()
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(await mcEventually(store) { store.state.meshCoreSwap == nil })
    await mcSettle(store)
    #expect(mcNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    #expect(radio.calls.value == [startA, .stop, .stop, startA])
    #expect(slot(store)?.interface.config.radio == mcRadioIDA)
}

// MARK: - Both radios (Review Focus 5)

private func bothRadios(_ state: inout AppFeature.State) {
    state.$meshtasticEnabled.withLock { $0 = true }
    state.$meshtasticRadioID.withLock { $0 = meshSlotRadioA.uuidString }
}

@MainActor @Test func mcSlotBothRadiosStartAtConnect() async {
    let radio = MeshCoreRadioHarness()
    let meshtastic = MeshRadioHarness()
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, meshtastic: meshtastic, configure: bothRadios)
    await store.send(.connectTapped)
    #expect(await mcWait { radio.startCount >= 1 && meshtastic.startCount >= 1 })
    #expect(radio.calls.value == [startA])
    #expect(meshtastic.calls.value == [.start(meshSlotRadioA)])
}

@MainActor @Test func mcSlotSwappingOneRadioLeavesTheOtherRunning() async {
    let radio = MeshCoreRadioHarness()
    let meshtastic = MeshRadioHarness()
    let store = await connectedStore(radio: radio, meshtastic: meshtastic, configure: bothRadios)
    await meshBringRadioOnline(store, meshtastic, id: meshSlotIDA)
    await store.send(.binding(.set(\.meshCoreRadioID, mcRadioIDB.uuidString)))
    await store.send(.foregrounded)
    #expect(await mcWait { radio.startCount >= 2 })
    #expect(radio.calls.value == [startA, .stop, startB])
    await mcSettle(store)
    #expect(meshtastic.calls.value == [.start(meshSlotRadioA)])
    #expect(store.state.node.client.endpoint.meshtastic?.interface.isOnline == true)
}

@MainActor @Test func mcSlotChangingMeshtasticLeavesMeshCoreRunning() async {
    let radio = MeshCoreRadioHarness()
    let meshtastic = MeshRadioHarness()
    let store = await connectedStore(radio: radio, meshtastic: meshtastic, configure: bothRadios)
    await meshBringRadioOnline(store, meshtastic, id: meshSlotIDA)
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.foregrounded)
    #expect(await mcWait { meshtastic.startCount >= 2 })
    #expect(meshtastic.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioB)])
    await mcSettle(store)
    #expect(radio.calls.value == [startA])
    #expect(slot(store)?.interface.isOnline == true)
}

// MARK: - Key presence

/// An unreadable key (device locked) is not a missing key: the next sync reads presence again.
@MainActor @Test func mcSlotKeyReadFailureIsNotANoKey() async {
    let radio = MeshCoreRadioHarness()
    let keychain = mcKeyedKeychain()
    keychain.failRead(at: MeshCoreKeyStore.keyLocation, status: errSecInteractionNotAllowed)
    let store = mcRadioStore(radio: mcRadioIDA, radioHarness: radio, keychain: keychain)
    await store.send(.connectTapped)
    await mcSettle(store)
    #expect(store.state.meshCoreKeyPresence == .unreadable)
    #expect(slot(store) == nil)
    #expect(radio.calls.value == [])
    keychain.clearFailures()
    await store.send(.foregrounded)
    #expect(store.state.meshCoreKeyPresence == .present)
    #expect(slot(store) != nil)
    #expect(await mcWait { radio.startCount >= 1 })
    #expect(radio.calls.value == [startA])
}
