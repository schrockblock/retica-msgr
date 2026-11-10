import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
@testable import ReTiCAMsgrCore

// The Meshtastic hop limit setting: stored under its own key, 1 by default, clamped to 1...7, and
// handed to the driver at start. A change while the radio is online shows Apply changes.

private func hlWait(_ condition: @Sendable () -> Bool) async -> Bool {
    await meshWaitUntil(timeout: .seconds(20), condition)
}

@MainActor @Test func hopLimitDefaultsToOne() async {
    let store = meshRadioStore(radio: meshSlotRadioA, harness: MeshRadioHarness())
    #expect(store.state.meshtasticHopLimit == 1)
    #expect(store.state.meshtasticWantedConfig?.hopLimit == 1)
}

/// The stepper goes through the same binding as Settings, and lands under its own key.
@MainActor @Test func hopLimitWritesItsKey() async {
    let defaults = UserDefaults.inMemory
    let initial = withDependencies {
        $0.defaultAppStorage = defaults
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
        $0.defaultAppStorage = defaults
    }
    store.exhaustivity = .off
    await store.send(.binding(.set(\.meshtasticHopLimit, 4)))
    #expect(defaults.integer(forKey: "meshtasticHopLimit") == 4)
}

/// A value stored out of range (an older build, a hand-edited default) is clamped, never sent as is.
@MainActor @Test func hopLimitClampsAStoredValue() async {
    let low = meshRadioStore(radio: meshSlotRadioA, harness: MeshRadioHarness()) { state in
        state.$meshtasticHopLimit.withLock { $0 = 0 }
    }
    let high = meshRadioStore(radio: meshSlotRadioA, harness: MeshRadioHarness()) { state in
        state.$meshtasticHopLimit.withLock { $0 = 99 }
    }
    #expect(low.state.meshtasticHopLimitValue == 1)
    #expect(low.state.meshtasticWantedConfig?.hopLimit == 1)
    #expect(high.state.meshtasticHopLimitValue == 7)
    #expect(high.state.meshtasticWantedConfig?.hopLimit == 7)
}

/// Connect starts the driver with the stored hop limit.
@MainActor @Test func hopLimitReachesTheDriverAtConnect() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio) { state in
        state.$meshtasticHopLimit.withLock { $0 = 4 }
    }
    await store.send(.connectTapped)
    await radio.waitForStarts(1)
    #expect(radio.startConfigs.value.map(\.hopLimit) == [4])
}

/// A new hop limit while the radio is online: Apply changes, and the tap restarts the same radio
/// with it.
@MainActor @Test func hopLimitChangeWhileOnlineAppliesOnTap() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    #expect(store.state.radioConnectButton(.meshtastic) == .hidden)
    await store.send(.binding(.set(\.meshtasticHopLimit, 3)))
    #expect(store.state.radioConnectButton(.meshtastic) == .applyChanges)
    await store.send(.radioConnectTapped(.meshtastic))
    #expect(await hlWait { radio.startCount >= 2 }, "calls: \(radio.calls.value)")
    #expect(radio.startConfigs.value.map(\.hopLimit) == [1, 3])
    #expect(radio.startConfigs.value.map(\.radio) == [meshSlotRadioA, meshSlotRadioA])
}

@Test func hopLimitCopy() {
    #expect(MeshtasticHopLimit.defaultValue == 1)
    #expect(MeshtasticHopLimit.range == 1...7)
    #expect(MeshtasticCopy.hopLimitRow(3) == "Hop limit: 3")
    #expect(MeshtasticCopy.hopLimitNotice.contains("Please be kind to your mesh"))
}
