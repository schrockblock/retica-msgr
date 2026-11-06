# Diagnostics Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only "Diagnostics" screen in ReTiCAMsgr Settings that answers "which layer is broken?" at a glance, and can export its state as shareable text.

**Architecture:** A pure `DiagnosticsSnapshot` value type in `ReTiCAMsgrCore`, built by `init(from: AppFeature.State, at: Date)`, holding six `Layer`s each with a `Health` and rows. A dumb `DiagnosticsView` in the app target renders it and re-renders live via ordinary TCA observation. One accessor is added to ReTiCA's `TransportEndpoint.State`.

**Tech Stack:** Swift 6, SwiftUI, The Composable Architecture, Swift Testing (`@Test` / `#expect`), two repos — the ReTiCA library at `/Users/ell/development/ios/pods/ReTiCA` and the app at `/Users/ell/development/ios/apps/ReTiCAMsgr`.

**Spec:** `docs/superpowers/specs/2026-08-21-diagnostics-page-design.md` (in the app repo). Read it before starting.

## Global Constraints

- **Commit directly to `main` in both repos.** No feature branch — standing project convention.
- **Commit trailers MUST start at column 0** or git cannot parse them:
  ```
  Co-Authored-By: Claude <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
  ```
  Verify with `git log -1 --format='%(trailers:key=Claude-Session)'` — empty output means it did not parse.
- **Baselines that must not regress:** ReTiCA `swift test --no-parallel` = **1001 tests, 1 known issue** (`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`, pre-existing). App core `swift test --package-path ReTiCAMsgrCore --no-parallel` = **46 tests**.
- **Mutation-verify every test you write**, per the project's standard process: (a) run, confirm pass; (b) break the production code in a batch so the new tests should fail, run once, confirm they all fail; (c) revert, confirm green. If a test still passes under mutation, it is not testing what you think.
- **No secrets in the snapshot.** `LinkSession.State` carries `sessionKey: Data` and `ephemeral: Identity`. Build every layer from a hand-written list of fields. Never `Mirror`, never a generic dump.
- **Cite symbols, not line numbers**, in comments and commit messages. Line citations in these repos have drifted repeatedly.
- **The app working tree has unrelated uncommitted work** (AnnounceListView, QRCodeImage, AddressView, and edits to AppFeature/SettingsView). `git add` only the specific files each task names. Never `git commit -a` in the app repo.

## File Structure

| File | Repo | Responsibility |
|---|---|---|
| `Sources/ReTiCANode/TransportEndpoint.swift` | ReTiCA | Add an `interfaces` accessor beside the existing `learned` / `links` / `registrations` |
| `Tests/ReTiCANodeTests/TransportEndpointTests.swift` | ReTiCA | Pin the new accessor for both transports |
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/DiagnosticsSnapshot.swift` | app | The whole pure type: `Health`, `Row`, `Layer`, the six builders, and `text` |
| `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DiagnosticsSnapshotTests.swift` | app | Health rules, cross-checks, export, and the no-secrets test |
| `ReTiCAMsgr/DiagnosticsView.swift` | app | Rendering only — no logic |
| `ReTiCAMsgr/SettingsView.swift` | app | One `NavigationLink` in a new final Section |

`DiagnosticsSnapshot.swift` grows across Tasks 2–5. That is deliberate: the layers share the `Layer`/`Row`/`Health` vocabulary and the same input, so splitting them across files would scatter one cohesive responsibility. It should land around 300 lines; if it passes ~450, split the layer builders into `DiagnosticsSnapshot+Layers.swift` and say so in the commit.

---

### Task 1: ReTiCA accessibility — `interfaces` accessor and a public `PendingDelivery` init

**Repo:** ReTiCA (`/Users/ell/development/ios/pods/ReTiCA`)

**Files:**
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift` (the `State` enum's computed-property block, alongside `learned`, `links`, `registrations`)
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (the `PendingDelivery` struct)
- Test: `Tests/ReTiCANodeTests/TransportEndpointTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `TransportEndpoint.State.interfaces: [InterfaceID: InterfaceProfile]` (Task 2's Socket layer, Task 3's Paths layer) and `LXMFRouter.PendingDelivery(resend:attempts:)` as a **public** initialiser (Task 4's Delivery test).

**Context:** two separate accessibility gaps, batched because they are both one-liners in the same library and neither is worth its own review gate.

1. `TransportEndpoint.State` is an enum (`.tcp(TCPEndpoint.State)` / `.ble(BLEEndpoint.State)`) already exposing `learned`, `links` and `registrations` by switching on itself. `interfaces` lives at `s.transport.interfaces` on both.

2. `LXMFRouter.PendingDelivery` is declared as
   `public struct PendingDelivery: Equatable { public var resend: ResendInfo; public var attempts: Int }`
   — a public struct with **no explicit initialiser**, so Swift's synthesised memberwise init is
   **internal**. It therefore cannot be constructed from the app's test target at all. Adding an
   explicit `public init` is the minimum fix; do not work around it by making the test
   `@testable import ReTiCANode`, which would hide the same gap from every other consumer.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ReTiCANodeTests/TransportEndpointTests.swift`:

```swift
// The unified surface exposes `learned`, `links` and `registrations`; `interfaces` was the
// one table missing, which forced consumers to switch on .tcp/.ble to answer "is this
// interface still up?" — the question `reachableLearned` is built on.
@Test @MainActor func interfacesAreExposedOnTheUnifiedSurfaceForBothTransports() {
    var tcp = TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false)
    tcp.transport.interfaces[InterfaceID("tcp")] = .tcp
    #expect(TransportEndpoint.State.tcp(tcp).interfaces == [InterfaceID("tcp"): .tcp])

    var ble = BLEEndpoint.State()
    ble.transport.interfaces[InterfaceID("ble-1")] = .ble
    #expect(TransportEndpoint.State.ble(ble).interfaces == [InterfaceID("ble-1"): .ble])
}

// `PendingDelivery` is a public struct with no explicit init, so its memberwise init is
// INTERNAL and no other module can build one. Constructing it here from the test target is
// the assertion.
@Test func pendingDeliveryIsConstructibleFromAnotherModule() {
    let pending = LXMFRouter.PendingDelivery(
        resend: .opportunistic(destinationHash: Data(repeating: 0x01, count: 16), payload: Data()),
        attempts: 3)
    #expect(pending.attempts == 3)
}
```

`BLEEndpoint.State()` compiles with no arguments — every parameter of its `init` is defaulted
(`maxPeers`, `pairingMode`, `profile`). Keep both transports in the test; covering only TCP is
what let the gap exist.

- [ ] **Step 2: Run the test and verify it fails**

```bash
swift test --package-path /Users/ell/development/ios/pods/ReTiCA --no-parallel --filter interfacesAreExposedOnTheUnifiedSurface
```
Expected: two compile errors — `value of type 'TransportEndpoint.State' has no member 'interfaces'`, and `'PendingDelivery' initializer is inaccessible due to 'internal' protection level`.

- [ ] **Step 3a: Add the public `PendingDelivery` init**

In `Sources/ReTiCANode/LXMFRouter.swift`, replace the one-line `PendingDelivery` declaration with:

```swift
    public struct PendingDelivery: Equatable {
        public var resend: ResendInfo
        public var attempts: Int
        /// Explicit because the synthesised memberwise init on a `public struct` is INTERNAL,
        /// which made this type public in name only — no other module could construct one.
        public init(resend: ResendInfo, attempts: Int) {
            self.resend = resend
            self.attempts = attempts
        }
    }
```

- [ ] **Step 3b: Add the accessor**

In `Sources/ReTiCANode/TransportEndpoint.swift`, immediately after the `learned` computed property:

```swift
        /// Connected interfaces of the active transport. Paired with `learned`: an entry in
        /// `learned` names an `interfaceID`, and only an id present HERE is still reachable —
        /// which is the test `Transport.reachableLearned` performs and `openLink` gates on.
        public var interfaces: [InterfaceID: InterfaceProfile] {
            switch self {
            case let .tcp(s): return s.transport.interfaces
            case let .ble(s): return s.transport.interfaces
            }
        }
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
swift test --package-path /Users/ell/development/ios/pods/ReTiCA --no-parallel --filter interfacesAreExposedOnTheUnifiedSurface
```
Expected: PASS.

- [ ] **Step 5: Run the full ReTiCA suite**

```bash
swift test --package-path /Users/ell/development/ios/pods/ReTiCA --no-parallel
```
Expected: **1003 tests, 1 known issue**, no failures.

- [ ] **Step 6: Commit**

```bash
git -C /Users/ell/development/ios/pods/ReTiCA add Sources/ReTiCANode/TransportEndpoint.swift Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/TransportEndpointTests.swift
```

Then commit. The body should say that `interfaces` completes the unified surface — it is what lets a consumer answer "is this learned path's interface still up?" without switching on the transport — and that `PendingDelivery` was public in name only, since a public struct's synthesised memberwise init is internal. Include the two trailers at column 0.

---

### Task 2: `DiagnosticsSnapshot` skeleton + Socket and Identity layers

**Repo:** app (`/Users/ell/development/ios/apps/ReTiCAMsgr`)

**Files:**
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/DiagnosticsSnapshot.swift`
- Create: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DiagnosticsSnapshotTests.swift`

**Interfaces:**
- Consumes: `TransportEndpoint.State.interfaces` (Task 1).
- Produces: `DiagnosticsSnapshot.Health` (`.ok`/`.warn`/`.problem`), `DiagnosticsSnapshot.Row(label:value:)`, `DiagnosticsSnapshot.Layer(title:health:reason:rows:)`, `DiagnosticsSnapshot(from:at:)`, `.layers: [Layer]`, `.generatedAt: Date`. Tasks 3–5 append layer builders; Task 6 renders these.

**Context — state access paths** (deep nesting; do not rediscover):

| Needed | Path from `AppFeature.State` |
|---|---|
| app connection | `.connection` (`.disconnected`/`.connecting`/`.connected`) |
| interface status/host/port | `.node.client.endpoint` → `case .tcp(let s)` → `s.interface.status` / `.host` / `.port` |
| interfaces | `.node.client.endpoint.interfaces` |
| learned paths | `.node.client.endpoint.learned` |
| links | `.node.client.endpoint.links` |
| peers | `.node.client.learnedPeers` |
| delivery destination | `.node.client.deliveryDestinationHash` |
| router | `.node.client.router` |

`TCPClientInterface.State.status` is `.disconnected`/`.connecting`/`.online`. `InterfaceProfile` is a struct with `.name`. `InterfaceID` has `.rawValue`. `Data.hexString` exists and is accessible inside `ReTiCAMsgrCore`.

- [ ] **Step 1: Write the failing tests**

Create `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DiagnosticsSnapshotTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCAMsgrCore

// MARK: - Fixtures

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

/// A state whose SOCKET layer is healthy: app connected, interface online, interface registered.
/// Fixtures here are built COHERENTLY on purpose — seeding `learned` without `interfaces`
/// produces a state the runtime cannot reach, and that incoherence is itself one of the
/// conditions under test (see the paths cross-check in a later task).
@MainActor
private func healthyState() -> AppFeature.State {
    var state = AppFeature.State(identity: Identity())
    state.connection = .connected
    guard case var .tcp(tcp) = state.node.client.endpoint else {
        fatalError("fixture assumes a TCP endpoint")
    }
    tcp.interface.status = .online
    tcp.transport.interfaces[tcp.interfaceID] = .tcp
    state.node.client.endpoint = .tcp(tcp)
    state.node.client.deliveryDestinationHash = Data(repeating: 0xAA, count: 16)
    return state
}

/// Mutate the TCP endpoint of a state in place.
@MainActor
private func withTCP(_ state: inout AppFeature.State, _ body: (inout TCPEndpoint.State) -> Void) {
    guard case var .tcp(tcp) = state.node.client.endpoint else {
        fatalError("fixture assumes a TCP endpoint")
    }
    body(&tcp)
    state.node.client.endpoint = .tcp(tcp)
}

private func layer(_ snapshot: DiagnosticsSnapshot, _ title: String) -> DiagnosticsSnapshot.Layer {
    guard let found = snapshot.layers.first(where: { $0.title == title }) else {
        fatalError("no layer titled \(title)")
    }
    return found
}

// MARK: - Socket

@MainActor @Test func socketIsOkWhenAppAndInterfaceAgreeAndInterfaceIsRegistered() {
    let snapshot = DiagnosticsSnapshot(from: healthyState(), at: fixedDate)
    let socket = layer(snapshot, "Socket")
    #expect(socket.health == .ok)
    #expect(socket.reason == nil)
}

// The two rows that disagreed for the whole duration of the stale-callback reconnect bug.
// Reported as a DISAGREEMENT, not masked by the milder "connecting" rule beneath it.
@MainActor @Test func socketIsAProblemWhenAppSaysConnectedButInterfaceIsNot() {
    var state = healthyState()
    withTCP(&state) { $0.interface.status = .connecting }
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.health == .problem)
    #expect(socket.reason == "app reports connected, interface reports connecting")
}

@MainActor @Test func socketIsAProblemWhenInterfaceIsOnlineButTransportHasNoInterfaces() {
    var state = healthyState()
    withTCP(&state) { $0.transport.interfaces = [:] }
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.health == .problem)
    #expect(socket.reason == "socket is up but Transport has no registered interface")
}

@MainActor @Test func socketWarnsWhileBothAgreeConnecting() {
    var state = healthyState()
    state.connection = .connecting
    withTCP(&state) { $0.interface.status = .connecting }
    let socket = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Socket")
    #expect(socket.health == .warn)
    #expect(socket.reason == "connecting")
}

// MARK: - Identity

@MainActor @Test func identityIsAProblemWhenNoDeliveryDestinationIsRegistered() {
    var state = healthyState()
    state.node.client.deliveryDestinationHash = nil
    let identity = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Identity")
    #expect(identity.health == .problem)
    #expect(identity.reason == "no delivery destination registered — nothing can reach us")
}

@MainActor @Test func identityIsOkWhenDeliveryDestinationIsRegistered() {
    let identity = layer(DiagnosticsSnapshot(from: healthyState(), at: fixedDate), "Identity")
    #expect(identity.health == .ok)
    #expect(identity.reason == nil)
}
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --no-parallel --filter DiagnosticsSnapshot
```
Expected: compile error — `cannot find 'DiagnosticsSnapshot' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/DiagnosticsSnapshot.swift`:

```swift
import Foundation
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport

/// A read-only, point-in-time view of the app's networking state, arranged as layers so the
/// question "which layer is broken?" has a single visible answer.
///
/// **Pure by construction.** Everything is derived from `AppFeature.State` plus an injected
/// date; nothing here reads a clock, touches the network, or mutates. That is what makes the
/// health rules and the shareable `text` unit-testable.
///
/// **Fields are listed by hand, never reflected.** `LinkSession.State` carries `sessionKey` and
/// an `ephemeral` keypair, and `text` is designed to be pasted into bug reports. A `Mirror`-based
/// or "render every property" implementation would leak session keys the first time someone
/// added a field. A test pins this.
public struct DiagnosticsSnapshot: Equatable {
    public enum Health: Equatable { case ok, warn, problem }

    public struct Row: Equatable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Layer: Equatable {
        public let title: String
        public let health: Health
        /// Why the layer is not `.ok`. Always nil when `.ok`, always non-nil otherwise —
        /// a status without a stated reason is the thing this screen exists to avoid.
        public let reason: String?
        public let rows: [Row]
    }

    public let generatedAt: Date
    public let layers: [Layer]

    public init(from state: AppFeature.State, at date: Date) {
        self.generatedAt = date
        self.layers = [
            Self.socketLayer(state),
            Self.identityLayer(state),
        ]
    }
}

// MARK: - Socket

extension DiagnosticsSnapshot {
    static func socketLayer(_ state: AppFeature.State) -> Layer {
        let endpoint = state.node.client.endpoint
        let interfaces = endpoint.interfaces

        var status = "n/a"
        var dialing = "n/a"
        if case let .tcp(tcp) = endpoint {
            status = describe(tcp.interface.status)
            dialing = "\(tcp.interface.host):\(tcp.interface.port)"
        }
        let app = describe(state.connection)

        let rows = [
            Row("app connection", app),
            Row("interface status", status),
            Row("dialing", dialing),
            Row("interfaces", interfaces.isEmpty
                 ? "(none)"
                 : interfaces
                    .map { "\($0.key.rawValue) (\($0.value.name))" }
                    .sorted()
                    .joined(separator: ", ")),
        ]

        // Order matters: a disagreement must be reported AS a disagreement rather than being
        // masked by the milder "connecting" rule below it.
        let interfaceOnline = status == "online"
        if (app == "connected") != interfaceOnline {
            return Layer(title: "Socket", health: .problem,
                         reason: "app reports \(app), interface reports \(status)", rows: rows)
        }
        if interfaceOnline && interfaces.isEmpty {
            return Layer(title: "Socket", health: .problem,
                         reason: "socket is up but Transport has no registered interface", rows: rows)
        }
        if app == "connecting" {
            return Layer(title: "Socket", health: .warn, reason: "connecting", rows: rows)
        }
        if app == "disconnected" {
            return Layer(title: "Socket", health: .warn, reason: "disconnected", rows: rows)
        }
        return Layer(title: "Socket", health: .ok, reason: nil, rows: rows)
    }

    static func describe(_ status: TCPClientInterface.Status) -> String {
        switch status {
        case .disconnected: return "disconnected"
        case .connecting:   return "connecting"
        case .online:       return "online"
        }
    }

    static func describe(_ connection: AppFeature.Connection) -> String {
        switch connection {
        case .disconnected: return "disconnected"
        case .connecting:   return "connecting"
        case .connected:    return "connected"
        }
    }
}

// MARK: - Identity

extension DiagnosticsSnapshot {
    static func identityLayer(_ state: AppFeature.State) -> Layer {
        let registered = state.node.client.deliveryDestinationHash != nil
        let rows = [
            Row("address", state.myAddressHex),
            Row("display name", state.displayName.isEmpty ? "(unset)" : state.displayName),
            Row("delivery registered", registered ? "yes" : "no"),
            Row("node mode", state.nodeModeEnabled ? "on" : "off"),
        ]
        guard registered else {
            return Layer(title: "Identity", health: .problem,
                         reason: "no delivery destination registered — nothing can reach us",
                         rows: rows)
        }
        return Layer(title: "Identity", health: .ok, reason: nil, rows: rows)
    }
}
```

If `AppFeature.Connection` or `deliveryDestinationHash` is not settable/visible from the test target, do NOT weaken the type — check the declaration and adjust the fixture instead.

- [ ] **Step 4: Run the tests and verify they pass**

```bash
swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --no-parallel --filter DiagnosticsSnapshot
```
Expected: 6 tests PASS.

- [ ] **Step 5: Mutation-verify**

Make these three changes at once, run the filter above once, and confirm the matching tests fail:
1. In `socketLayer`, change the disagreement check to `if false {` → the disagreement test must fail.
2. In `socketLayer`, delete the `interfaces.isEmpty` problem branch → that test must fail.
3. In `identityLayer`, change `guard registered` to `guard true` → the no-delivery-destination test must fail.

Then revert all three and re-run: 6 PASS. If any test survived its mutation, fix the test before continuing.

- [ ] **Step 6: Run the full app-core suite and commit**

```bash
swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --no-parallel
```
Expected: **52 tests** (46 + 6), no failures.

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/DiagnosticsSnapshot.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DiagnosticsSnapshotTests.swift
```

Commit. Explain in the body why the socket rules are ORDERED, and that app-connection and interface-status are separate rows because they disagreed throughout the stale-callback reconnect bug. Trailers at column 0.

---

### Task 3: Paths and Peers layers — the two cross-checks

**Repo:** app

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/DiagnosticsSnapshot.swift` (add two builders; append both to the `layers` array in `init`)
- Modify: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DiagnosticsSnapshotTests.swift` (append)

**Interfaces:**
- Consumes: `Layer`, `Row`, `Health`, the fixtures from Task 2.
- Produces: layers titled `"Paths"` and `"Peers"`.

**Context — this is the point of the whole feature.** Two cross-checks, each of which would have collapsed a real multi-hour diagnosis into a glance:

- **Paths / reachable** (F8): `learned` is deliberately non-destructive, so a path outlives the interface it was heard on. An entry whose `interfaceID` is absent from `interfaces` is unusable.
- **Peers / has path** (F20): `learnedPeers` is persisted by the app but `LearnedDestination` — which holds the identity and route — is not. After a cold launch the Announce tab lists peers the app cannot message.

Types: `LearnedDestination` has `identity`, `appData`, `ratchet`, `interfaceID`, `hops: UInt8`, `nextHop: Data?`, `announceEmitted`, `learnedAt: Date`. `LXMFNode.LearnedPeer` has `displayName: String?`, `stampCost: Int?`, `supportsCompression: Bool`, `learnedAt: Date`. Its initialiser is `LearnedPeer(displayName:stampCost:supportsCompression:learnedAt:)`.

- [ ] **Step 1: Write the failing tests**

Append to `DiagnosticsSnapshotTests.swift`:

```swift
// MARK: - Paths (F8 cross-check)

private let peerHash = Data(repeating: 0xBB, count: 16)

@MainActor @Test func pathsWarnWhenALearnedPathNamesAnInterfaceThatIsGone() {
    var state = healthyState()
    withTCP(&state) { tcp in
        // A path heard on an interface that no longer exists. `learned` is non-destructive,
        // so this is the ORDINARY state after a socket drop — not a contrived one.
        tcp.transport.learned[peerHash] = LearnedDestination(
            identity: Identity(), appData: nil, ratchet: nil,
            interfaceID: InterfaceID("gone"), hops: 1, nextHop: nil, announceEmitted: 0)
    }
    let paths = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Paths")
    #expect(paths.health == .warn)
    #expect(paths.reason == "1 path names an interface that is gone")
    #expect(paths.rows.contains { $0.value.contains("reachable=NO") })
}

@MainActor @Test func pathsAreOkWhenEveryPathNamesALiveInterface() {
    var state = healthyState()
    withTCP(&state) { tcp in
        tcp.transport.learned[peerHash] = LearnedDestination(
            identity: Identity(), appData: nil, ratchet: nil,
            interfaceID: tcp.interfaceID, hops: 0, nextHop: nil, announceEmitted: 0)
    }
    let paths = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Paths")
    #expect(paths.health == .ok)
    #expect(paths.reason == nil)
    #expect(paths.rows.contains { $0.value.contains("reachable=yes") })
}

// MARK: - Peers (F20 cross-check)

@MainActor @Test func peersWarnWhenAKnownPeerHasNoPath() {
    var state = healthyState()
    // Exactly what a cold launch produces: learnedPeers is rehydrated from disk, the path
    // table is not, so the peer is listed but cannot be messaged.
    state.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: "Sideband", stampCost: 8, supportsCompression: true, learnedAt: fixedDate)
    let peers = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Peers")
    #expect(peers.health == .warn)
    #expect(peers.reason == "1 peer has no path — known but not reachable")
    #expect(peers.rows.contains { $0.value.contains("path=NO") })
}

@MainActor @Test func peersAreOkWhenEveryPeerHasAPath() {
    var state = healthyState()
    state.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: "Sideband", stampCost: 8, supportsCompression: true, learnedAt: fixedDate)
    withTCP(&state) { tcp in
        tcp.transport.learned[peerHash] = LearnedDestination(
            identity: Identity(), appData: nil, ratchet: nil,
            interfaceID: tcp.interfaceID, hops: 0, nextHop: nil, announceEmitted: 0)
    }
    let peers = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Peers")
    #expect(peers.health == .ok)
    #expect(peers.reason == nil)
    #expect(peers.rows.contains { $0.value.contains("path=yes") })
}
```

- [ ] **Step 2: Run and verify they fail**

```bash
swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --no-parallel --filter DiagnosticsSnapshot
```
Expected: the four new tests fail — `fatalError("no layer titled Paths")`.

- [ ] **Step 3: Implement both layers**

Add to `DiagnosticsSnapshot.swift`, and extend `init`'s array to
`[socketLayer, identityLayer, pathsLayer, peersLayer]`:

```swift
// MARK: - Paths

extension DiagnosticsSnapshot {
    /// F8 cross-check. `Transport.State.learned` is deliberately NON-destructive: losing an
    /// interface does not purge the paths heard on it, so an entry routinely outlives the
    /// interface it names. `Transport.reachableLearned` is the runtime's version of this test,
    /// and `openLink` gates on it — a path whose interface is gone cannot carry a link.
    static func pathsLayer(_ state: AppFeature.State) -> Layer {
        let endpoint = state.node.client.endpoint
        let interfaces = endpoint.interfaces
        let learned = endpoint.learned

        let entries = learned
            .map { hash, entry -> (hash: Data, reachable: Bool, row: Row) in
                let reachable = interfaces[entry.interfaceID] != nil
                let next = entry.nextHop.map { $0.hexString } ?? "direct"
                return (hash, reachable, Row(
                    hash.hexString,
                    "hops=\(entry.hops) next=\(next) if=\(entry.interfaceID.rawValue) "
                    + "reachable=\(reachable ? "yes" : "NO")"))
            }
            .sorted { $0.hash.hexString < $1.hash.hexString }

        let rows = entries.isEmpty ? [Row("(none)", "no paths learned this session")]
                                   : entries.map(\.row)
        let unreachable = entries.filter { !$0.reachable }.count
        guard unreachable == 0 else {
            return Layer(title: "Paths", health: .warn,
                         reason: "\(unreachable) path\(unreachable == 1 ? "" : "s") "
                                 + "name\(unreachable == 1 ? "s" : "") an interface that is gone",
                         rows: rows)
        }
        return Layer(title: "Paths", health: .ok, reason: nil, rows: rows)
    }
}

// MARK: - Peers

extension DiagnosticsSnapshot {
    /// F20 cross-check. `learnedPeers` is persisted by the app; the path table that holds the
    /// peer's IDENTITY and route is not. After a cold launch the Announce tab can list peers
    /// the app cannot message — opportunistic send needs the identity, `openLink` needs the
    /// path. This row names that state instead of leaving it to be inferred from a greyed-out
    /// Send button.
    static func peersLayer(_ state: AppFeature.State) -> Layer {
        let learned = state.node.client.endpoint.learned
        let peers = state.node.client.learnedPeers

        let entries = peers
            .map { hash, peer -> (hash: Data, hasPath: Bool, row: Row) in
                let hasPath = learned[hash] != nil
                let cost = peer.stampCost.map(String.init) ?? "-"
                return (hash, hasPath, Row(
                    peer.displayName ?? "(unnamed)",
                    "\(hash.hexString) cost=\(cost) path=\(hasPath ? "yes" : "NO")"))
            }
            .sorted { $0.hash.hexString < $1.hash.hexString }

        let rows = entries.isEmpty ? [Row("(none)", "no peers detected")] : entries.map(\.row)
        let pathless = entries.filter { !$0.hasPath }.count
        guard pathless == 0 else {
            return Layer(title: "Peers", health: .warn,
                         reason: "\(pathless) peer\(pathless == 1 ? "" : "s") has no path "
                                 + "— known but not reachable",
                         rows: rows)
        }
        return Layer(title: "Peers", health: .ok, reason: nil, rows: rows)
    }
}
```

Note the reason strings must match the tests exactly, including the singular/plural forms. If the plural forms read awkwardly for counts > 1, fix the STRING and the test together — do not leave them disagreeing.

- [ ] **Step 4: Run and verify they pass**

Expected: 10 `DiagnosticsSnapshot` tests PASS.

- [ ] **Step 5: Mutation-verify**

Two changes at once:
1. In `pathsLayer`, force `let reachable = true` → the F8 test must fail.
2. In `peersLayer`, force `let hasPath = true` → the F20 test must fail.

Revert both, confirm 10 PASS.

- [ ] **Step 6: Full suite and commit**

Expected: **56 tests**. Stage the same two files as Task 2 and commit. The body should say what F8 and F20 are and why these two cross-checks are the reason the page exists.

---

### Task 4: Links and Delivery layers

**Repo:** app

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/DiagnosticsSnapshot.swift`
- Modify: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DiagnosticsSnapshotTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–3.
- Produces: layers titled `"Links"` and `"Delivery"`. After this task `layers.count == 6`.

**Context:** `LinkSession.State` has `role` (`.initiator`/`.responder`), `status` (`.pending`/`.handshake`/`.active`/`.closed`), `linkID: Data`, `destinationHash: Data`, `rtt: Double?`, `transfers: IdentifiedArrayOf<ResourceTransfer.State>`, `activatedAt`/`lastInbound`/`lastData` as `Double?`. **It also has `sessionKey: Data` and `ephemeral: Identity` — neither may be rendered.**

`LXMFRouter.State` has `directLinks: [Data: LinkStatus]` where `LinkStatus` is `.awaitingPath` / `.establishing` / `.active(linkID: Data)`; `knownPaths: Set<Data>`; `pendingDeliveries: [Data: PendingDelivery]` where `PendingDelivery` has `resend` and `attempts: Int`; `outboundPropagationNode: Data?`.

Constructing a `LinkSession.State` in a test needs its initialiser — open `Sources/ReTiCATransport/LinkSession.swift` and read it rather than guessing. Build the link via `LinkPlane`/`TCPEndpoint` state directly if the initialiser is awkward.

- [ ] **Step 1: Write the failing tests**

Append:

```swift
// MARK: - Delivery

@MainActor @Test func deliveryWarnsWhenMessagesArePendingWithNoActiveLink() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[Data(repeating: 0x01, count: 32)] =
        LXMFRouter.PendingDelivery(
            resend: .opportunistic(destinationHash: peerHash, payload: Data()), attempts: 2)
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .warn)
    #expect(delivery.reason == "1 message pending with no active link")
}

@MainActor @Test func deliveryIsOkWhenPendingMessagesHaveAnActiveLink() {
    var state = healthyState()
    state.node.client.router.pendingDeliveries[Data(repeating: 0x01, count: 32)] =
        LXMFRouter.PendingDelivery(
            resend: .opportunistic(destinationHash: peerHash, payload: Data()), attempts: 1)
    state.node.client.router.directLinks[peerHash] = .active(linkID: Data(repeating: 0x0C, count: 16))
    let delivery = layer(DiagnosticsSnapshot(from: state, at: fixedDate), "Delivery")
    #expect(delivery.health == .ok)
    #expect(delivery.reason == nil)
}

@MainActor @Test func deliveryIsOkWithNothingPending() {
    let delivery = layer(DiagnosticsSnapshot(from: healthyState(), at: fixedDate), "Delivery")
    #expect(delivery.health == .ok)
}

// MARK: - Links

@MainActor @Test func linksLayerReportsNoLinksOnAQuietState() {
    let links = layer(DiagnosticsSnapshot(from: healthyState(), at: fixedDate), "Links")
    #expect(links.health == .ok)
    #expect(links.rows.contains { $0.label == "(none)" })
}

@MainActor @Test func snapshotHasAllSixLayersInOrder() {
    let snapshot = DiagnosticsSnapshot(from: healthyState(), at: fixedDate)
    #expect(snapshot.layers.map(\.title)
            == ["Socket", "Identity", "Paths", "Peers", "Links", "Delivery"])
}
```

- [ ] **Step 2: Run and verify they fail**

Expected: `fatalError("no layer titled Delivery")` / `"Links"`.

- [ ] **Step 3: Implement both layers**

Extend `init`'s array to all six in the order `socket, identity, paths, peers, links, delivery`.
Note `linksLayer` takes the injected date (it renders ages), so the call is
`Self.linksLayer(state, at: date)` while the other five take only `state`:

```swift
        self.layers = [
            Self.socketLayer(state),
            Self.identityLayer(state),
            Self.pathsLayer(state),
            Self.peersLayer(state),
            Self.linksLayer(state, at: date),
            Self.deliveryLayer(state),
        ]
```

Then add:

```swift
// MARK: - Links

extension DiagnosticsSnapshot {
    /// Renders a hand-picked set of fields. `LinkSession.State` also carries `sessionKey` and
    /// an `ephemeral` keypair; those are secrets and must never appear here or in `text`.
    static func linksLayer(_ state: AppFeature.State, at date: Date) -> Layer {
        let links = state.node.client.endpoint.links
        let now = date.timeIntervalSince1970

        let rows = links.map { link -> Row in
            let role = link.role == .initiator ? "initiator" : "responder"
            let rtt = link.rtt.map { String(format: "%.0fms", $0 * 1000) } ?? "-"
            // `lastInbound` advances on ANY link-addressed packet; `lastData` only on traffic
            // that actually decrypted. Both are shown because the difference distinguishes "a
            // peer is talking to us" from "an AUTHENTICATED peer is talking to us" — and
            // `LinkPlane` evicts responder links in order of `lastData`, not `lastInbound`.
            return Row(link.linkID.hexString,
                       "\(role) \(describe(link.status)) dest=\(link.destinationHash.hexString) "
                       + "rtt=\(rtt) transfers=\(link.transfers.count) "
                       + "up=\(age(link.activatedAt, now)) "
                       + "in=\(age(link.lastInbound, now)) data=\(age(link.lastData, now))")
        }

        // An initiator link sitting in `.handshake` is establishment in flight — or stalled.
        // `LinkSession.establishmentTimeout` bounds it at 15s.
        let stalled = links.filter { $0.role == .initiator && $0.status == .handshake }.count
        guard stalled == 0 else {
            return Layer(title: "Links", health: .warn,
                         reason: "\(stalled) outbound link\(stalled == 1 ? "" : "s") "
                                 + "still in handshake",
                         rows: rows)
        }
        return Layer(title: "Links", health: .ok, reason: nil,
                     rows: rows.isEmpty ? [Row("(none)", "no live links")] : rows)
    }

    static func describe(_ status: LinkSession.Status) -> String {
        switch status {
        case .pending:   return "pending"
        case .handshake: return "handshake"
        case .active:    return "active"
        case .closed:    return "closed"
        }
    }

    /// Seconds since a unix-timestamp field, rendered compactly. Uses the INJECTED date, never
    /// a live clock — that is what keeps `text` deterministic under test.
    static func age(_ timestamp: Double?, _ now: Double) -> String {
        guard let timestamp else { return "-" }
        let seconds = max(0, now - timestamp)
        if seconds < 90 { return "\(Int(seconds))s" }
        if seconds < 5400 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h"
    }
}

// MARK: - Delivery

extension DiagnosticsSnapshot {
    static func deliveryLayer(_ state: AppFeature.State) -> Layer {
        let router = state.node.client.router

        let linkRows = router.directLinks
            .map { dest, status -> (String, Row) in
                let text: String
                switch status {
                case .awaitingPath:      text = "awaitingPath"
                case .establishing:      text = "establishing"
                case let .active(linkID): text = "active (\(linkID.hexString))"
                }
                return (dest.hexString, Row(dest.hexString, text))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        let pendingRows = router.pendingDeliveries
            .map { hash, pending in (hash.hexString, Row(hash.hexString, "attempts=\(pending.attempts)")) }
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        var rows = [Row("known paths", String(router.knownPaths.count))]
        rows.append(Row("propagation node",
                        router.outboundPropagationNode?.hexString ?? "(none)"))
        rows.append(contentsOf: linkRows)
        rows.append(contentsOf: pendingRows)

        let hasActive = router.directLinks.values.contains {
            if case .active = $0 { return true }
            return false
        }
        let pending = router.pendingDeliveries.count
        if pending > 0 && !hasActive {
            return Layer(title: "Delivery", health: .warn,
                         reason: "\(pending) message\(pending == 1 ? "" : "s") pending "
                                 + "with no active link",
                         rows: rows)
        }
        return Layer(title: "Delivery", health: .ok, reason: nil, rows: rows)
    }
}
```

- [ ] **Step 4: Run and verify they pass**

Expected: 15 `DiagnosticsSnapshot` tests PASS.

- [ ] **Step 5: Mutation-verify**

Two changes at once:
1. In `deliveryLayer`, force `let hasActive = true` → the pending-with-no-link test must fail.
2. In `init`, reverse the `layers` array → the ordering test must fail.

Revert, confirm 15 PASS.

- [ ] **Step 6: Full suite and commit**

Expected: **61 tests**. Stage the same two files and commit.

---

### Task 5: `text` export and the no-secrets guarantee

**Repo:** app

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/DiagnosticsSnapshot.swift`
- Modify: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DiagnosticsSnapshotTests.swift`

**Interfaces:**
- Consumes: `layers`, `generatedAt`.
- Produces: `DiagnosticsSnapshot.text: String` — consumed by Task 6's `ShareLink`.

**Context:** identifiers are already full-length in `Row.value` (Tasks 3–4 used `hexString`, not a truncation), so `text` renders rows verbatim. **Truncation is the VIEW's job in Task 6, not this type's.** The timestamp uses ISO 8601.

- [ ] **Step 1: Write the failing tests**

Append:

```swift
// MARK: - Export

@MainActor @Test func textIncludesTheTimestampLayerTitlesAndHealthMarkers() {
    var state = healthyState()
    withTCP(&state) { $0.interface.status = .connecting }
    let text = DiagnosticsSnapshot(from: state, at: fixedDate).text

    #expect(text.contains("ReTiCAMsgr diagnostics"))
    #expect(text.contains("2023-11-14"))              // fixedDate in ISO 8601
    #expect(text.contains("SOCKET  [problem]"))
    #expect(text.contains("app reports connected, interface reports connecting"))
    #expect(text.contains("IDENTITY  [ok]"))
    #expect(text.contains("app connection"))
}

@MainActor @Test func textCarriesFullIdentifiersNotTruncatedOnes() {
    var state = healthyState()
    withTCP(&state) { tcp in
        tcp.transport.learned[peerHash] = LearnedDestination(
            identity: Identity(), appData: nil, ratchet: nil,
            interfaceID: tcp.interfaceID, hops: 0, nextHop: nil, announceEmitted: 0)
    }
    let text = DiagnosticsSnapshot(from: state, at: fixedDate).text
    // Full 32-char hex, because this gets correlated against rnsd logs and the other client.
    #expect(text.contains(peerHash.hexString))
    #expect(peerHash.hexString.count == 32)
}

// NOT a correctness test — a safety one. `LinkSession.State` carries `sessionKey` and an
// `ephemeral` keypair, and this text is designed to be pasted into bug reports. This is what
// stops a later "just render all the fields" change from leaking key material.
//
// The link is built with a REAL LinkSession.State and asserted to be present before the
// no-leak check. A safety test that silently exercises an empty collection passes for the
// wrong reason and is worse than no test at all.
@MainActor @Test func textNeverContainsALinkSessionKey() {
    var state = healthyState()
    let secret = Data(repeating: 0x5E, count: 32)
    withTCP(&state) { tcp in
        var link = LinkSession.State(
            responderFor: Identity(),
            destinationHash: peerHash,
            interfaceID: tcp.interfaceID)
        link.sessionKey = secret
        link.status = .active
        link.linkID = Data(repeating: 0x0C, count: 16)
        tcp.links.append(link)
    }

    let snapshot = DiagnosticsSnapshot(from: state, at: fixedDate)
    // Precondition: the fixture really does contain a link carrying the secret.
    #expect(state.node.client.endpoint.links.count == 1)
    #expect(snapshot.layers.first { $0.title == "Links" }?.rows.first?.label
            == Data(repeating: 0x0C, count: 16).hexString)

    let text = snapshot.text
    #expect(!text.contains(secret.hexString))
    #expect(!text.lowercased().contains("sessionkey"))
}
```

`LinkSession.State`'s responder initialiser is
`init(id:responderFor:destinationHash:interfaceID:ephemeral:establishmentTimeout:keepaliveInterval:)`
with everything except `responderFor`, `destinationHash` and `interfaceID` defaulted, and
`sessionKey` / `status` / `linkID` are `public var`s. `TCPEndpoint.State.links` has both a getter
and a setter (it forwards to `linkPlane.links`), so `tcp.links.append(link)` works.

The two `#expect`s before the leak check are the anti-vacuity guard: they fail loudly if the
fixture ever stops containing a link, rather than letting the no-leak assertions pass over an
empty collection.

- [ ] **Step 2: Run and verify they fail**

Expected: `value of type 'DiagnosticsSnapshot' has no member 'text'`.

- [ ] **Step 3: Implement `text`**

```swift
// MARK: - Text export

extension DiagnosticsSnapshot {
    /// Plain-text rendering for the share sheet. Identifiers are FULL here — the on-screen view
    /// truncates for legibility, but a pasted dump gets correlated against rnsd logs and the
    /// other end's client, so it needs the whole hash.
    public var text: String {
        var out = "ReTiCAMsgr diagnostics — \(Self.timestamp.string(from: generatedAt))\n"
        for layer in layers {
            let marker: String
            switch layer.health {
            case .ok:      marker = "ok"
            case .warn:    marker = "warn"
            case .problem: marker = "problem"
            }
            out += "\n\(layer.title.uppercased())  [\(marker)]"
            if let reason = layer.reason { out += " \(reason)" }
            out += "\n"
            for row in layer.rows {
                out += "  \(row.label.padding(toLength: max(row.label.count, 20),
                                              withPad: " ", startingAt: 0)) \(row.value)\n"
            }
        }
        return out
    }

    static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
```

- [ ] **Step 4: Run and verify they pass**

Expected: 18 `DiagnosticsSnapshot` tests PASS.

- [ ] **Step 5: Mutation-verify, including the safety test**

Three changes at once:
1. Drop the `reason` from `text` → the timestamp/markers test must fail.
2. Truncate identifiers in `text` (e.g. `String(row.value.prefix(8))`) → the full-identifier test must fail.
3. Add `Row("sessionKey", link.sessionKey.hexString)` to `linksLayer` → the secrets test must fail. **If it does not fail, the fixture has no link in it and the test is vacuous — fix the fixture before continuing.**

Revert all three, confirm 18 PASS.

- [ ] **Step 6: Full suite and commit**

Expected: **64 tests**. Stage and commit; the body should record that the secrets test was verified to fail under a deliberate leak, since that is the only thing distinguishing it from a test that passes trivially.

---

### Task 6: `DiagnosticsView` and the Settings link

**Repo:** app

**Files:**
- Create: `ReTiCAMsgr/DiagnosticsView.swift`
- Modify: `ReTiCAMsgr/SettingsView.swift` (add a final Section inside the existing `Form`, after "Propagation Node")

**Interfaces:**
- Consumes: `DiagnosticsSnapshot(from:at:)`, `.layers`, `.text`, `Layer.title/health/reason/rows`, `Row.label/value`.
- Produces: nothing consumed elsewhere.

**Context:** `SettingsView` is `struct SettingsView: View` with `@Bindable var store: StoreOf<AppFeature>` and a `NavigationStack { Form { ... } }`. Add the new Section as the last child of that `Form`. The new file must be added to the Xcode project target — if `xcodebuild` reports it missing, add it to `ReTiCAMsgr.xcodeproj` in the `ReTiCAMsgr` target's Sources build phase.

There are no unit tests here — the view holds no logic, which is the whole point of Tasks 2–5. The gate is that the app builds and the screen renders.

- [ ] **Step 1: Create the view**

```swift
import SwiftUI
import ComposableArchitecture
import ReTiCAMsgrCore

/// Read-only triage. All derivation lives in `DiagnosticsSnapshot`; this file renders and
/// nothing else. Rebuilding the snapshot inside `body` is what makes the screen live — TCA
/// re-runs `body` when the observed state changes, so no timer or stored copy is needed.
struct DiagnosticsView: View {
    let store: StoreOf<AppFeature>

    private var snapshot: DiagnosticsSnapshot {
        DiagnosticsSnapshot(from: store.state, at: Date())
    }

    var body: some View {
        let snapshot = self.snapshot
        List {
            Section {
                ShareLink(item: snapshot.text) {
                    Label("Share diagnostics", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = snapshot.text
                } label: {
                    Label("Copy to clipboard", systemImage: "doc.on.doc")
                }
            } footer: {
                Text("The shared text carries full identifiers; the rows below are shortened "
                     + "for readability.")
            }

            ForEach(snapshot.layers, id: \.title) { layer in
                Section {
                    ForEach(Array(layer.rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top) {
                            // `shorten` is applied to BOTH label and value: the Paths layer uses
                            // the full destination hash as its label, and non-hex labels (a peer's
                            // display name, "app connection") pass through untouched.
                            Text(shorten(row.label))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(shorten(row.value))
                                .font(.system(.caption, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Circle().fill(color(layer.health)).frame(width: 8, height: 8)
                        Text(layer.title)
                        if let reason = layer.reason {
                            Text("— \(reason)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func color(_ health: DiagnosticsSnapshot.Health) -> Color {
        switch health {
        case .ok:      return .green
        case .warn:    return .yellow
        case .problem: return .red
        }
    }

    /// Truncation is the VIEW's job — `DiagnosticsSnapshot.text` deliberately keeps identifiers
    /// full so a pasted dump can be correlated against other logs.
    private func shorten(_ value: String) -> String {
        value.split(separator: " ").map { token -> String in
            let parts = token.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[1].count > 16, isHex(String(parts[1])) {
                return "\(parts[0])=\(parts[1].prefix(8))…"
            }
            if token.count > 16, isHex(String(token)) { return "\(token.prefix(8))…" }
            return String(token)
        }.joined(separator: " ")
    }

    private func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isHexDigit }
    }
}
```

- [ ] **Step 2: Add the Settings link**

In `ReTiCAMsgr/SettingsView.swift`, after the `Section("Propagation Node") { ... }` block and still inside the `Form`:

```swift
                Section {
                    NavigationLink { DiagnosticsView(store: store) } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("Connection, paths, peers, links and delivery state — and a shareable "
                         + "snapshot for bug reports.")
                }
```

- [ ] **Step 3: Build the app**

```bash
xcodebuild build -project /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination 'generic/platform=iOS Simulator' 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"
```
Expected: `** BUILD SUCCEEDED **`. Pre-existing deprecation warnings about `$store.host` / `$store.port` in SettingsView are not yours — leave them.

- [ ] **Step 4: Re-run the app-core suite**

```bash
swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --no-parallel
```
Expected: **64 tests**, unchanged — this task adds no logic.

- [ ] **Step 5: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr add ReTiCAMsgr/DiagnosticsView.swift ReTiCAMsgr/SettingsView.swift
```

If the Xcode project file changed to include the new source file, add `ReTiCAMsgr.xcodeproj/project.pbxproj` too. **Do not stage anything else** — the working tree has unrelated in-progress work.

Commit noting that the view holds no logic by design, and that truncation lives here while the export keeps full identifiers.

---

## Verification

After Task 6:

- ReTiCA: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --no-parallel` → **1003 tests, 1 known issue**.
- App core: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --no-parallel` → **64 tests**.
- App builds for the simulator.
- Both repos: `git log -1 --format='%(trailers:key=Claude-Session)'` returns the URL, not empty.
- `git -C /Users/ell/development/ios/apps/ReTiCAMsgr status --short` still shows the pre-existing uncommitted work (AnnounceListView, QRCodeImage, AddressView, AppFeature, ContentView, AppFeatureTests) — those must NOT have been swept into a commit.
