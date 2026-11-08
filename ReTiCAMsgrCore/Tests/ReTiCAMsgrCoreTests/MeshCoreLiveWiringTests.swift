import Testing
import Foundation
import ComposableArchitecture
import MeshCoreKit
import MeshtasticKit
import ReTiCAInterfaces
import ReTiCAKeychain
@testable import ReTiCAMsgrCore

private let mcHexC = "0123456789abcdef0011223344556677"
private let wiringScanID = UUID(uuidString: "5CA40000-0000-4000-8000-0000000000C1")!
private let wiringMeshtasticScanID = UUID(uuidString: "5CA40000-0000-4000-8000-0000000000D1")!

private func key(_ hex: String) -> Data { Data(hexString: hex)! }

/// `meshWaitUntil` with room for a whole-package run: there, the forwarding tasks can wait seconds
/// for a thread. It returns as soon as `condition` holds, so only a failing check pays the timeout.
private func mcWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

/// A key store over a fresh in-memory Keychain, after pasting `hexes` in order: the last one is the
/// current key and the earlier ones are retired.
private func keyStore(pasting hexes: [String]) -> MeshCoreKeyStore {
    let (_, store) = mcKeychain()
    for hex in hexes { _ = store.paste(MeshCoreKeyText(hex)) }
    return store
}

private func config(_ radio: UUID = mcRadioIDA) -> MeshCoreDriverConfig {
    MeshCoreDriverConfig(radio: radio, channelSecret: Data(), canRoute: false)
}

/// Collects every event the stream yields, and whether it finished. Main-actor, like the rest of
/// the suite's consumers: in a whole-package run, a consumer task on the global executor can wait
/// longer than any timeout while TestStore tests hold it.
@MainActor
private final class EventLog {
    let events = LockIsolated<[MeshCoreDriverEvent]>([])
    let finished = LockIsolated(false)
    let task: Task<Void, Never>

    init(_ stream: AsyncStream<MeshCoreDriverEvent>) {
        let events = events, finished = finished
        task = Task {
            for await event in stream { events.withValue { $0.append(event) } }
            finished.setValue(true)
        }
    }
}

private let connectedEvent = MeshCoreDriverEvent.connected(selfPrefix: mcRadioPublicKey.prefix(4),
                                                           publicKey: mcRadioPublicKey, params: nil)

// MARK: - resolvingSecrets

@MainActor @Test func mcSecretsStartFillsTheKeyAndRetiredList() async {
    let harness = MeshCoreRadioHarness()
    let driver = MeshCoreDriver.resolvingSecrets(base: harness.driver, keyStore: keyStore(pasting: [mcHexB, mcHexA]))
    let log = EventLog(driver.start(config()))
    #expect(harness.configs.value.count == 1)
    #expect(harness.configs.value.first?.channelSecret == key(mcHexA))
    #expect(harness.configs.value.first?.retiredChannelSecrets == [key(mcHexB)])
    log.task.cancel()
}

@MainActor @Test func mcSecretsKeepsTheOtherConfigFields() async {
    let harness = MeshCoreRadioHarness()
    let driver = MeshCoreDriver.resolvingSecrets(base: harness.driver, keyStore: keyStore(pasting: [mcHexA]))
    let log = EventLog(driver.start(MeshCoreDriverConfig(radio: mcRadioIDB, channelSecret: Data(),
                                                         channelName: "Elsewhere", dataType: 0x1234,
                                                         canRoute: true)))
    let started = harness.configs.value.first
    #expect(started?.radio == mcRadioIDB)
    #expect(started?.canRoute == true)
    #expect(started?.channelName == "Elsewhere")
    #expect(started?.dataType == 0x1234)
    log.task.cancel()
}

@MainActor @Test func mcSecretsMissingKeyIsReportedNotStarted() async {
    let harness = MeshCoreRadioHarness()
    let driver = MeshCoreDriver.resolvingSecrets(base: harness.driver, keyStore: keyStore(pasting: []))
    let log = EventLog(driver.start(config()))
    #expect(await mcWait { log.finished.value })
    #expect(log.events.value == [.unavailable(.other("The channel key can't be read"))])
    #expect(harness.startCount == 0)
    #expect(harness.calls.value == [])
}

@MainActor @Test func mcSecretsForgetsWhenTheDriverReportsCleared() async {
    let harness = MeshCoreRadioHarness()
    let store = keyStore(pasting: [mcHexB, mcHexA])
    let driver = MeshCoreDriver.resolvingSecrets(base: harness.driver, keyStore: store)
    let log = EventLog(driver.start(config()))
    harness.yieldToLatest(.retiredChannelsCleared)
    #expect(await mcWait { log.events.value.count == 1 })
    #expect(store.secrets()?.retired == [])
    #expect(store.secrets()?.current == key(mcHexA))
    log.task.cancel()
}

@MainActor @Test func mcSecretsForgetOnlyWhatThatStartCarried() async {
    let harness = MeshCoreRadioHarness()
    // Current A, retired [B] at start.
    let store = keyStore(pasting: [mcHexB, mcHexA])
    let driver = MeshCoreDriver.resolvingSecrets(base: harness.driver, keyStore: store)
    let log = EventLog(driver.start(config()))
    // The user changes the key before the radio reports: A is retired too, [B, A].
    #expect(store.paste(MeshCoreKeyText(mcHexC)) == .changed)
    #expect(store.secrets()?.retired == [key(mcHexB), key(mcHexA)])
    harness.yieldToLatest(.retiredChannelsCleared)
    #expect(await mcWait { log.events.value.count == 1 })
    // Only B, which that start carried, is forgotten; A is still on the radio.
    #expect(store.secrets()?.retired == [key(mcHexA)])
    log.task.cancel()
}

@MainActor @Test func mcSecretsForwardsTheClearedEvent() async {
    let harness = MeshCoreRadioHarness()
    let driver = MeshCoreDriver.resolvingSecrets(base: harness.driver, keyStore: keyStore(pasting: [mcHexB, mcHexA]))
    let log = EventLog(driver.start(config()))
    harness.yieldToLatest(.retiredChannelsCleared)
    harness.yieldToLatest(connectedEvent)
    harness.finishLatest()
    #expect(await mcWait { log.finished.value })
    #expect(log.events.value == [.retiredChannelsCleared, connectedEvent])
}

@MainActor @Test func mcSecretsKeepsRetiredWithoutTheEvent() async {
    let harness = MeshCoreRadioHarness()
    let store = keyStore(pasting: [mcHexB, mcHexA])
    let driver = MeshCoreDriver.resolvingSecrets(base: harness.driver, keyStore: store)
    let log = EventLog(driver.start(config()))
    harness.yieldToLatest(connectedEvent)
    harness.finishLatest()
    #expect(await mcWait { log.finished.value })
    #expect(log.events.value == [connectedEvent])
    #expect(store.secrets()?.retired == [key(mcHexB)])
}

@MainActor @Test func mcSecretsForwardsSendRemoveAndStop() async {
    let harness = MeshCoreRadioHarness()
    let driver = MeshCoreDriver.resolvingSecrets(base: harness.driver, keyStore: keyStore(pasting: [mcHexA]))
    let log = EventLog(driver.start(config()))
    #expect(await driver.send(Data([0x52, 0x01])) == true)
    #expect(harness.sent.value == [MeshSentFrame(session: 0, frame: Data([0x52, 0x01]))])
    harness.removalResult.setValue(true)
    #expect(await driver.removeChannel() == true)
    await driver.stop()
    #expect(harness.calls.value == [.start(mcRadioIDA, canRoute: false, secretBytes: 16), .removeChannel, .stop])
    #expect(await mcWait { log.finished.value })
}

/// The forget must land before the event is forwarded: a consumer that acts on the event (or a
/// start that follows it) must already see the retired key gone. Inside `forgetRetired`, the test
/// waits (up to 3 s) for the consumer to report the event. The real wrapper hasn't forwarded it
/// yet, so the wait runs out and the check passes; a wrapper that forwarded first lets the
/// consumer see it during the wait. Correct code can't fail this; the 3 s only bounds how long a
/// forward-first wrapper has to show itself on a busy main actor.
@MainActor @Test func mcSecretsForgetsBeforeForwardingTheClearedEvent() async {
    let harness = MeshCoreRadioHarness()
    let live = keyStore(pasting: [mcHexB, mcHexA])
    let consumerSawEvent = LockIsolated(false)
    let forwardedBeforeForget = LockIsolated<Bool?>(nil)
    var store = live
    store.forgetRetired = { keys in
        let deadline = Date().addingTimeInterval(3)
        while !consumerSawEvent.value, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        forwardedBeforeForget.setValue(consumerSawEvent.value)
        live.forgetRetired(keys)
    }
    let driver = MeshCoreDriver.resolvingSecrets(base: harness.driver, keyStore: store)
    let stream = driver.start(config())
    let consumer = Task { @MainActor in
        for await event in stream where event == .retiredChannelsCleared {
            consumerSawEvent.setValue(true)
        }
    }
    harness.yieldToLatest(.retiredChannelsCleared)
    #expect(await mcWait { forwardedBeforeForget.value != nil && consumerSawEvent.value })
    #expect(forwardedBeforeForget.value == false, "the cleared event was forwarded before the forget")
    #expect(live.secrets()?.retired == [])
    consumer.cancel()
}

// MARK: - installDriver

/// The installed driver goes through `resolvingSecrets`: the base sees the 16-byte key at start,
/// though the reducer's config carries none.
@MainActor @Test func mcWiringInstalledDriverFillsTheKey() async {
    let harness = MeshCoreRadioHarness()
    var values = DependencyValues()
    MeshCoreLiveWiring.installDriver(into: &values, keyStore: keyStore(pasting: [mcHexB, mcHexA]),
                                     base: harness.driver)
    let log = EventLog(values.meshCoreDriver.start(config()))
    #expect(harness.configs.value.count == 1)
    #expect(harness.configs.value.first?.channelSecret.count == 16)
    #expect(harness.configs.value.first?.channelSecret == key(mcHexA))
    #expect(harness.configs.value.first?.retiredChannelSecrets == [key(mcHexB)])
    #expect(harness.calls.value == [.start(mcRadioIDA, canRoute: false, secretBytes: 16)])
    log.task.cancel()
}

// MARK: - Scanner

@MainActor @Test func mcLiveScanMapsEachRadio() async {
    let upstream = AsyncStream<DiscoveredMeshCoreRadio>.makeStream()
    let scan = RadioScanner.meshCoreResults { upstream.stream }
    let seen = LockIsolated<[RadioScanResult]>([])
    let consumer = Task { for await result in scan() { seen.withValue { $0.append(result) } } }
    upstream.continuation.yield(DiscoveredMeshCoreRadio(id: wiringScanID, name: "MeshCore-Alpha", rssi: -44))
    upstream.continuation.yield(DiscoveredMeshCoreRadio(id: mcRadioIDB, name: nil, rssi: -90))
    #expect(await mcWait { seen.value.count == 2 })
    #expect(seen.value == [RadioScanResult(id: wiringScanID, name: "MeshCore-Alpha", rssi: -44),
                           RadioScanResult(id: mcRadioIDB, name: nil, rssi: -90)])
    consumer.cancel()
}

@MainActor @Test func mcLiveScanFinishesWhenTheSourceFinishes() async {
    let upstream = AsyncStream<DiscoveredMeshCoreRadio>.makeStream()
    let scan = RadioScanner.meshCoreResults { upstream.stream }
    let finished = LockIsolated(false)
    let consumer = Task {
        for await _ in scan() {}
        finished.setValue(true)
    }
    upstream.continuation.finish()
    #expect(await mcWait { finished.value })
    consumer.cancel()
}

@MainActor @Test func mcLiveScanCancellingEndsTheSource() async {
    let ended = LockIsolated(false)
    let scan = RadioScanner.meshCoreResults {
        AsyncStream { continuation in continuation.onTermination = { _ in ended.setValue(true) } }
    }
    let stream = scan()
    let consumer = Task { for await _ in stream {} }
    consumer.cancel()
    #expect(await mcWait { ended.value })
}

/// Each `installScanner` sets only its own half of `radioScanner`, in either order. Both take a
/// source here, so no CoreBluetooth starts.
@MainActor @Test(arguments: [true, false])
func mcLiveScanInstallsDoNotOverwriteEachOther(meshtasticFirst: Bool) async {
    let meshtasticSource: @Sendable () -> AsyncStream<DiscoveredRadio> = {
        AsyncStream { $0.yield(DiscoveredRadio(id: wiringMeshtasticScanID, name: "Mesh", rssi: -50)) }
    }
    let meshCoreSource: @Sendable () -> AsyncStream<DiscoveredMeshCoreRadio> = {
        AsyncStream { $0.yield(DiscoveredMeshCoreRadio(id: wiringScanID, name: "Core", rssi: -60)) }
    }
    var values = DependencyValues()
    values.radioScanner = RadioScanner(scan: { AsyncStream { $0.finish() } },
                                       scanMeshCore: { AsyncStream { $0.finish() } })
    if meshtasticFirst {
        MeshtasticLiveWiring.installScanner(into: &values, source: meshtasticSource)
        MeshCoreLiveWiring.installScanner(into: &values, source: meshCoreSource)
    } else {
        MeshCoreLiveWiring.installScanner(into: &values, source: meshCoreSource)
        MeshtasticLiveWiring.installScanner(into: &values, source: meshtasticSource)
    }
    let scanner = values.radioScanner
    let seen = LockIsolated<[RadioScanResult]>([])
    let meshtasticConsumer = Task { for await result in scanner.stream(for: .meshtastic) { seen.withValue { $0.append(result) } } }
    let meshCoreConsumer = Task { for await result in scanner.stream(for: .meshCore) { seen.withValue { $0.append(result) } } }
    #expect(await mcWait { seen.value.count == 2 })
    #expect(Set(seen.value.map(\.id)) == [wiringMeshtasticScanID, wiringScanID])
    meshtasticConsumer.cancel()
    meshCoreConsumer.cancel()
}
