# ReTiCaMsgr Slice 3 — Propagation / Offline Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user reliably message an offline peer by also sending each message to a configured LXMF propagation node (store-and-forward) and syncing held messages on connect.

**Architecture:** One small ReTiCA addition — `LXMFNode.sendMessage(message:alsoViaPropagation:)` routes a single prebuilt `LXMessage` via opportunistic and (optionally) propagation so both copies share a hash and the recipient dedups. Then app-layer wiring in `AppFeature` (routing, PN config, sync-on-connect, manual sync, `propagationAccepted` status) plus small UI in Settings and the conversation list. No new propagation plumbing — `LXMFNode` already implements `setPropagationNode`/`sendViaPropagation`/`syncFromPropagationNode` and the sync protocol, all integration-tested.

**Tech Stack:** Swift 6, TCA, SQLiteData/GRDB, ReTiCA/ReTiCANode (LXMF), SwiftUI. Two git repos.

## Global Constraints

- **Two repos.**
  - ReTiCA package (Task 1): `/Users/ell/development/ios/pods/ReTiCA` — commit via `git -C /Users/ell/development/ios/pods/ReTiCA`.
  - App (Tasks 2–3): `/Users/ell/development/ios/apps/ReTiCaMsgr` — commit via `git -C /Users/ell/development/ios/apps/ReTiCaMsgr`.
  - The app depends on ReTiCA by local path, so Task 1's `sendMessage` is picked up automatically once committed — no version bump.
- **Commit directly to `main`** in both repos.
- **Commit message trailers, verbatim, at COLUMN 0 (no leading whitespace):**
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
  Commit with `git commit -F <file>` (NEVER `-m` — trailers contain `;`). Write the message to a file under `/tmp/ReTiCaMsgr/` with an editor. After each commit verify the trailer parses in that repo: `git -C <repo> log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'` must print the URL; if empty, `git commit --amend -F <file>`.
- **No compound shell commands:** one command per invocation; no `&&`/`||`/`;`/pipes/`xargs`/inline interpreter scripts. A single `>` redirect IS allowed. Edit files with editor tools, never `echo`/heredoc.
- **Three-step mutation verification for every new/changed test.** Where a test set asserts *opposite* branches (present vs absent), a single mutation cannot fail all of them — use two mutation passes as the task specifies, reverting between. Confirm each test fails under the pass that targets it, then revert and confirm all pass.
- **Test/build commands:**
  - ReTiCA package test: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter <name>` (large package; first build is slow).
  - App package test: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`.
  - App build (Task 3): `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination 'generic/platform=iOS Simulator' build`.
- **SQLiteData / TCA gotchas (from slices 1–2, verified):** StructuredQueries `==` is `@unavailable` → use `.eq()`. GRDB reads/writes are `try await database.read/write { }`. `TestStore.state` is **get-only** — arrange initial state via a `configure` closure passed to a `makeStore` helper, not `store.state.x = y`. Under `.off` exhaustivity, asserting an action did NOT fire is done by asserting resulting state (e.g. `store.state.node.router.outboundPropagationNode == nil`), not by scanning actions. `InterfaceID("tcp")` has no default init. The app test target already depends on `ReTiCAInterfaces` + `ReTiCATransport`.
- **Verified APIs:**
  - `LXMFNode.Action.setPropagationNode(destinationHash: Data)`, `.syncFromPropagationNode`, `.registerDelivery`, `.send(destinationHash:title:content:method:)`, delegate `.propagationAccepted(messageHash: Data)`.
  - `LXMFRouter.Action.send(message: LXMessage, desiredMethod:)`, `.sendViaPropagation(message: LXMessage, propagationPacked: Data)`; `DeliveryMethod.opportunistic`.
  - `LXMFPropagation.pack(message: LXMessage, recipientIdentity: Identity, timestamp: Double) -> (propagationPacked: Data, transientId: Data)`.
  - `Transport.State.learned: [Data: LearnedDestination]`; `LearnedDestination(identity:appData:ratchet:interfaceID:hops:nextHop:announceEmitted:learnedAt:)` (last arg defaults).
  - `LXMFRouter.State` (all `@testable`-visible): `public var outboundPropagationNode: Data?`, `public var knownIdentities: [Data: Identity]`, `public var knownPaths: Set<Data>`, `public var pendingDeliveries: [Data: PendingDelivery]`; `PendingDelivery.resend: ResendInfo` with cases `.opportunistic(...)`, `.direct(...)`, `.propagated(...)`.
  - `isValidPeerAddress(_ hex: String) -> Bool` (public in ReTiCaMsgrCore) == decodes to 16 bytes.

---

## Task 1: ReTiCA — `LXMFNode.sendMessage(message:alsoViaPropagation:)`

**Repo:** `/Users/ell/development/ios/pods/ReTiCA`
**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Create: `Tests/ReTiCANodeTests/LXMFNodeSendMessageTests.swift`

**Interfaces:**
- Consumes: `LXMessage`, `LXMFPropagation.pack`, `Transport.State.learned`, `LXMFRouter.Action.send`/`.sendViaPropagation`.
- Produces: `LXMFNode.Action.sendMessage(message: LXMessage, alsoViaPropagation: Bool)` — always dispatches `router.send(message, .opportunistic)`; if `alsoViaPropagation` and `transport.learned[message.destinationHash]?.identity` exists, also `router.sendViaPropagation(message, pack(...))`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFNodeSendMessageTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

@MainActor
private func makeNode(identity: Identity, seedLearned: Identity?, dest: Data,
                      pn: Data?) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var ep = Endpoint.State(host: "h", port: 4242, reconnectOnDrop: false)
    if let r = seedLearned {
        ep.transport.learned[dest] = LearnedDestination(
            identity: r, appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
            hops: 1, nextHop: nil, announceEmitted: 0)
    }
    var node = LXMFNode.State(identity: identity, endpoint: ep)
    // Seed the router so the opportunistic send can arm, and (when set) propagation can arm.
    node.router.knownIdentities[dest] = seedLearned ?? Identity()
    node.router.knownPaths.insert(dest)
    if let pn { node.router.outboundPropagationNode = pn }
    let store = TestStore(initialState: node) { LXMFNode() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } },
                                         send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

private func isPropagated(_ resend: LXMFRouter.ResendInfo?) -> Bool {
    if case .propagated = resend { return true }; return false
}
private func isOpportunistic(_ resend: LXMFRouter.ResendInfo?) -> Bool {
    if case .opportunistic = resend { return true }; return false
}

@MainActor @Test func sendMessageFlagFalseSendsOpportunisticOnly() async {
    let me = Identity(); let recipient = Identity()
    let dest = Data(repeating: 0xA1, count: 16)
    let store = makeNode(identity: me, seedLearned: recipient, dest: dest, pn: Data(repeating: 0xC0, count: 16))
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, alsoViaPropagation: false))
    await store.receive { if case let .router(.send(m, method)) = $0 { return m == msg && method == .opportunistic }; return false }
    #expect(isOpportunistic(store.state.router.pendingDeliveries[msg.hash]?.resend))
}

@MainActor @Test func sendMessageFlagTrueKnownIdentitySendsBoth() async {
    let me = Identity(); let recipient = Identity()
    let dest = Data(repeating: 0xA2, count: 16)
    let store = makeNode(identity: me, seedLearned: recipient, dest: dest, pn: Data(repeating: 0xC0, count: 16))
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, alsoViaPropagation: true))
    await store.receive { if case let .router(.send(m, method)) = $0 { return m == msg && method == .opportunistic }; return false }
    await store.receive { if case let .router(.sendViaPropagation(m, _)) = $0 { return m == msg }; return false }
    #expect(isPropagated(store.state.router.pendingDeliveries[msg.hash]?.resend))
}

@MainActor @Test func sendMessageFlagTrueUnknownIdentitySkipsPropagation() async {
    let me = Identity()
    let dest = Data(repeating: 0xA3, count: 16)
    // NOTE: seedLearned nil → transport.learned has no identity for dest → propagation must be skipped.
    let store = makeNode(identity: me, seedLearned: nil, dest: dest, pn: Data(repeating: 0xC0, count: 16))
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, alsoViaPropagation: true))
    await store.receive { if case let .router(.send(m, method)) = $0 { return m == msg && method == .opportunistic }; return false }
    #expect(isOpportunistic(store.state.router.pendingDeliveries[msg.hash]?.resend))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter LXMFNodeSendMessageTests`
Expected: FAIL to build — `LXMFNode.Action.sendMessage` is undefined.

- [ ] **Step 3: Add the action + handler**

In `Sources/ReTiCANode/LXMFNode.swift`, add the case to `enum Action` (next to `.send`):

```swift
case sendMessage(message: LXMessage, alsoViaPropagation: Bool)
```

And add the handler in the `Reduce` switch (next to the existing `case let .send(...)`):

```swift
case let .sendMessage(message, alsoViaPropagation):
    var effects: [Effect<Action>] = [
        .send(.router(.send(message: message, desiredMethod: .opportunistic)))
    ]
    if alsoViaPropagation,
       let recipient = state.endpoint.transport.learned[message.destinationHash]?.identity {
        let (packed, _) = LXMFPropagation.pack(
            message: message, recipientIdentity: recipient,
            timestamp: date.now.timeIntervalSince1970)
        effects.append(.send(.router(.sendViaPropagation(message: message, propagationPacked: packed))))
    }
    return .merge(effects)
```

(The reducer already binds `[date]`; `date.now` is in scope. `LXMFPropagation` is from `ReTiCA`, already imported.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter LXMFNodeSendMessageTests`
Expected: PASS (all three).

- [ ] **Step 5: Mutation-verify (two passes — the tests assert opposite branches)**

Pass A — **neuter propagation**: change `if alsoViaPropagation,` to `if false,`. Run the three tests. Expected: `sendMessageFlagTrueKnownIdentitySendsBoth` FAILS (resend is `.opportunistic`, not `.propagated`); the other two still pass. Revert.

Pass B — **force propagation unconditionally**: change the whole condition to `if true, let recipient = Optional(state.identity) {` (propagate regardless of flag/identity, using our own identity as a stand-in recipient). Run the three tests. Expected: `sendMessageFlagFalseSendsOpportunisticOnly` FAILS and `sendMessageFlagTrueUnknownIdentitySkipsPropagation` FAILS (both now `.propagated`); `sendMessageFlagTrueKnownIdentitySendsBoth` still passes. Revert.

Run once more clean: all three pass.

- [ ] **Step 6: Commit (pods repo)**

Write the message to `/tmp/ReTiCaMsgr/s3t1.txt`, then:
```
git -C /Users/ell/development/ios/pods/ReTiCA add Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFNodeSendMessageTests.swift
git -C /Users/ell/development/ios/pods/ReTiCA commit -F /tmp/ReTiCaMsgr/s3t1.txt
git -C /Users/ell/development/ios/pods/ReTiCA log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'
```
Message body (trailers at column 0):
```
feat: LXMFNode.sendMessage — one message via opportunistic + propagation

sendMessage(message:alsoViaPropagation:) routes a single prebuilt LXMessage
via router.send(.opportunistic) and, when alsoViaPropagation and the
recipient identity is in transport.learned, also router.sendViaPropagation
(pack to recipient). Same message → same hash on both routes so the receiver
dedups by message.hash. 3 TestStore tests, mutation-verified (two passes).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Task 2: App — `AppFeature` propagation wiring + `MessageStatus.propagated`

**Repo:** `/Users/ell/development/ios/apps/ReTiCaMsgr`
**Files:**
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Message.swift`
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift`
- Modify: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`

**Interfaces:**
- Consumes: `LXMFNode.Action.sendMessage(message:alsoViaPropagation:)` (Task 1), `.setPropagationNode(destinationHash:)`, `.syncFromPropagationNode`, delegate `.propagationAccepted(messageHash:)`.
- Produces: `AppFeature.Action` gains `setPropagationNode(String)` and `syncTapped`; State gains `@Shared propagationNodeHex`; `MessageStatus.propagated == "stored"`.

- [ ] **Step 1: Add the `propagated` status**

In `Message.swift`, add to `enum MessageStatus`:
```swift
    public static let propagated = "stored"
```

- [ ] **Step 2: Wire the reducer**

In `AppFeature.swift`:

(a) Add the shared field to `State` (after `reachablePeers`):
```swift
        @Shared(.appStorage("propagationNodeHex")) public var propagationNodeHex: String = ""
```

(b) Add two cases to `enum Action` (after `startConversation`):
```swift
        case setPropagationNode(String)
        case syncTapped
```

(c) Replace the `interfaceConnected` case with:
```swift
            case .node(.endpoint(.transport(.interfaceConnected(_)))):
                state.connection = .connected
                var effects: [Effect<Action>] = [.send(.node(.registerDelivery))]
                if let pn = Data(hexString: state.propagationNodeHex), pn.count == 16 {
                    effects.append(.send(.node(.setPropagationNode(destinationHash: pn))))
                    effects.append(.send(.node(.syncFromPropagationNode)))
                }
                return .merge(effects)
```

(d) In `sendTapped`, replace the final `.run` block's node dispatch. The block currently ends with `await send(.node(.send(destinationHash: peer, title: title, content: content, method: .opportunistic)))`. Change the run to route via `sendMessage`, capturing whether a PN is set:
```swift
                let alsoViaPropagation = !state.propagationNodeHex.isEmpty
                state.draft = ""
                return .run { [database] send in
                    try await database.write { try Message.insert { row }.execute($0) }
                    try await reloadThread(database, peerHex, send)
                    try await reloadConversations(database, send)
                    await send(.node(.sendMessage(message: msg, alsoViaPropagation: alsoViaPropagation)))
                }
```
(Keep everything above it — `msg`, `row`, guards — unchanged. `msg` and `alsoViaPropagation` are captured by the closure; both are Sendable.)

(e) Add the new cases (place before `case .node, .binding`):
```swift
            case let .setPropagationNode(hex):
                state.$propagationNodeHex.withLock { $0 = hex }
                guard let pn = Data(hexString: hex), pn.count == 16 else { return .none }
                return .merge(
                    .send(.node(.setPropagationNode(destinationHash: pn))),
                    .send(.node(.syncFromPropagationNode))
                )

            case .syncTapped:
                return .send(.node(.syncFromPropagationNode))

            case let .node(.delegate(.propagationAccepted(hash))):
                let hex = hash.hexString
                let openPeer = state.openPeerHex
                return .run { [database] send in
                    try await database.write {
                        try Message.where { $0.messageHash.eq(hex) }
                            .update { $0.status = MessageStatus.propagated }
                            .execute($0)
                    }
                    try await reloadConversations(database, send)
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                }
```

- [ ] **Step 3: Confirm it compiles**

Run: `swift build --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`
Expected: builds (tests updated next).

- [ ] **Step 4: Add the reducer tests**

Append these to `AppFeatureTests.swift` (they use the existing `makeStore(configure:)` helper, `uuid(_:)`, `seed(_:_:)`, `peerA`, and the `.off` patterns already in the file — reuse them; do not redefine). If `makeStore` does not already accept a `configure: ((inout AppFeature.State) -> Void)?` closure, extend it to (matching how the slice-2 tests set initial state).

```swift
private let pnHex = String(repeating: "c", count: 32)   // valid 16-byte hex

@MainActor @Test func sendWithPropagationNodeUsesSendMessageBoth() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "hi"
        s.$propagationNodeHex.withLock { $0 = pnHex }
    }
    await store.send(.sendTapped)
    await store.receive { action in
        if case let .node(.sendMessage(_, alsoViaPropagation)) = action { return alsoViaPropagation }
        return false
    }
}

@MainActor @Test func sendWithoutPropagationNodeUsesSendMessageDirectOnly() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "hi"
    }
    await store.send(.sendTapped)
    await store.receive { action in
        if case let .node(.sendMessage(_, alsoViaPropagation)) = action { return !alsoViaPropagation }
        return false
    }
}

@MainActor @Test func interfaceConnectedWithPNConfiguresAndSyncs() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.$propagationNodeHex.withLock { $0 = pnHex }
    }
    await store.send(.node(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"))))))
    await store.receive { if case .node(.setPropagationNode) = $0 { return true }; return false }
    await store.receive { if case .node(.syncFromPropagationNode) = $0 { return true }; return false }
    #expect(store.state.node.router.outboundPropagationNode == Data(hexString: pnHex))
}

@MainActor @Test func interfaceConnectedWithoutPNDoesNotConfigure() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.node(.endpoint(.transport(.interfaceConnected(InterfaceID("tcp"))))))
    await store.receive { if case .node(.registerDelivery) = $0 { return true }; return false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.router.outboundPropagationNode == nil)
}

@MainActor @Test func setPropagationNodePersistsAndConfigures() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.setPropagationNode(pnHex))
    await store.receive { if case .node(.syncFromPropagationNode) = $0 { return true }; return false }
    #expect(store.state.propagationNodeHex == pnHex)
    #expect(store.state.node.router.outboundPropagationNode == Data(hexString: pnHex))
}

@MainActor @Test func setPropagationNodeInvalidDoesNotConfigure() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.setPropagationNode("nothex"))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.router.outboundPropagationNode == nil)
}

@MainActor @Test func syncTappedRequestsSync() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.syncTapped)
    await store.receive { if case .node(.syncFromPropagationNode) = $0 { return true }; return false }
}

@MainActor @Test func propagationAcceptedMarksStored() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "hi"
    }
    await store.send(.sendTapped)
    await store.receive { if case .node(.sendMessage) = $0 { return true }; return false }
    let sent = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }
    let hashHex = sent.first!.messageHash
    let hashData = Data(hexString: hashHex)!
    await store.send(.node(.delegate(.propagationAccepted(messageHash: hashData))))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadMessages.first { $0.messageHash == hashHex }?.status == MessageStatus.propagated)
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`
Expected: all pass (these 8 + the existing slice-1/2 tests).

- [ ] **Step 6: Mutation-verify**

Batch these (each targets a distinct test; all can fail in one run):
- In `sendTapped`, change `let alsoViaPropagation = !state.propagationNodeHex.isEmpty` to `let alsoViaPropagation = false` → `sendWithPropagationNodeUsesSendMessageBoth` fails.
- In `interfaceConnected`, change the `if let pn = ...` guard body to do nothing (delete the two appended effects) → `interfaceConnectedWithPNConfiguresAndSyncs` fails.
- In `setPropagationNode`, change `MessageStatus`… no — change the `.merge(...)` to `return .none` after the withLock → `setPropagationNodePersistsAndConfigures` fails.
- In `syncTapped`, change `.send(.node(.syncFromPropagationNode))` to `.none` → `syncTappedRequestsSync` fails.
- In `propagationAccepted`, change `MessageStatus.propagated` to `MessageStatus.sent` in the `.update` → `propagationAcceptedMarksStored` fails.
Run once; confirm each listed test fails. Then revert ALL and rerun → all pass. (`interfaceConnectedWithoutPNDoesNotConfigure` and `setPropagationNodeInvalidDoesNotConfigure` are absence tests; they stay green under these mutations, which is correct.)

- [ ] **Step 7: Commit (app repo)**

Write to `/tmp/ReTiCaMsgr/s3t2.txt`, then:
```
git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/ ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/
git -C /Users/ell/development/ios/apps/ReTiCaMsgr commit -F /tmp/ReTiCaMsgr/s3t2.txt
git -C /Users/ell/development/ios/apps/ReTiCaMsgr log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'
```
Message body (trailers at column 0):
```
feat: AppFeature propagation routing + sync (slice 3 task 2)

sendTapped routes via node.sendMessage(alsoViaPropagation: PN configured);
interfaceConnected sets PN + syncs when configured; setPropagationNode
(Settings) persists + configures + syncs; syncTapped manual sync;
propagationAccepted marks the row MessageStatus.propagated ("stored").
8 TestStore tests, mutation-verified.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Task 3: App — Settings PN field + conversation-list Sync button

**Repo:** `/Users/ell/development/ios/apps/ReTiCaMsgr`
**Files:**
- Modify: `ReTiCaMsgr/SettingsView.swift`
- Modify: `ReTiCaMsgr/ConversationListView.swift`

**Interfaces:**
- Consumes: `AppFeature.Action.setPropagationNode(String)`, `.syncTapped`; state `propagationNodeHex`; `isValidPeerAddress(_:)`.
- Produces: UI only; verified by `xcodebuild`.

- [ ] **Step 1: Add the Propagation node section to Settings**

Replace `SettingsView.swift` with:

```swift
//
//  SettingsView.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

struct SettingsView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var pnInput: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Node Connection") {
                    TextField("Host", text: $store.host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", value: $store.port, format: .number)
                        .keyboardType(.numberPad)
                    HStack {
                        Button("Connect") { store.send(.connectTapped) }
                            .buttonStyle(.bordered)
                        Button("Disconnect") { store.send(.disconnectTapped) }
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }
                }

                Section("Propagation Node") {
                    TextField("Node LXMF address (hex)", text: $pnInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                    Button("Save node") { store.send(.setPropagationNode(pnInput)) }
                        .disabled(!isValidPeerAddress(pnInput))
                    if !store.propagationNodeHex.isEmpty {
                        Text("Current: \(store.propagationNodeHex)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
```

- [ ] **Step 2: Add a Sync toolbar button to the conversation list**

In `ConversationListView.swift`, inside the `.toolbar { ... }`, add a second trailing item next to the existing `+` button (leave the leading connection dot and the `+` item unchanged):

```swift
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { store.send(.syncTapped) } label: { Image(systemName: "arrow.clockwise") }
                }
```

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Re-run the package tests**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`
Expected: all pass (UI changes must not have broken the reducer/tests).

- [ ] **Step 5: Commit (app repo)**

Write to `/tmp/ReTiCaMsgr/s3t3.txt`, then:
```
git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgr/SettingsView.swift ReTiCaMsgr/ConversationListView.swift
git -C /Users/ell/development/ios/apps/ReTiCaMsgr commit -F /tmp/ReTiCaMsgr/s3t3.txt
git -C /Users/ell/development/ios/apps/ReTiCaMsgr log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'
```
Message body (trailers at column 0):
```
feat: propagation node settings + Sync button (slice 3 task 3)

SettingsView gains a Propagation Node section (hex field + Save, gated by
isValidPeerAddress, shows current). ConversationListView gains a Sync
toolbar button (.syncTapped). xcodebuild BUILD SUCCEEDED.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Live validation (controller-run, after Task 3 — no commit)

Not a subagent task. Run with the XcodeBuildMCP CLI + reference daemons, as in the slice-2 verification (see the `sim-verification-harness` memory):
1. Start `rnsd` hub (TCP server 4242, transport) and a reference **`lxmd`** propagation node connected to it; note `lxmd`'s propagation-destination address.
2. Build/install/launch on two iOS-26.4 sims; in each, set host/port to the hub and the Propagation Node to `lxmd`'s address (Settings → Save node).
3. **Offline delivery:** on the receiver, disconnect (or terminate the app); from the sender, open the conversation and send → the row should reach `"stored"`. Re-launch the receiver → it auto-syncs on connect → the message appears in the right conversation.
4. **No duplicate online:** both connected, send → the receiver shows exactly one message (dedup by `message.hash`), and a subsequent manual Sync does not add a duplicate.

---

## Self-Review (completed)

- **Spec coverage:** `sendMessage` addition → Task 1. Routing (opportunistic + PN-when-configured) → Task 2 `sendTapped`. Sync on connect + manual → Task 2 `interfaceConnected` + `syncTapped`, Task 3 Sync button. PN config → Task 2 `setPropagationNode` + Task 3 Settings. `propagated`/"stored" status → Task 2 `Message` + `propagationAccepted`. Downloaded messages reuse `messageReceived` (no change) — noted. Live validation → final section. All spec test cases present (3 ReTiCA + 8 app; the app set covers the spec's 5 by splitting with/without cases).
- **Placeholder scan:** none — every step has concrete code.
- **Type consistency:** `sendMessage(message:alsoViaPropagation:)`, `setPropagationNode(String)` (app) vs `.node(.setPropagationNode(destinationHash:))` (node) are distinct and used consistently; `MessageStatus.propagated`, `propagationNodeHex`, `isValidPeerAddress`, `pendingDeliveries[...].resend` spellings match across tasks. Absence tests assert `router.outboundPropagationNode == nil`, which the mutation batch leaves green (correct).
- **Cross-repo:** Task 1 commits to the pods repo; Tasks 2–3 to the app repo; local-path dependency means no version bump.
