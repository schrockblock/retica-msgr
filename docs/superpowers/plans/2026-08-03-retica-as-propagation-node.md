# ReTiCA-as-Propagation-Node (iOS node-mode, serve-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let ReTiCaMsgr act as an LXMF propagation node — register `lxmf.propagation`, accept store-and-forward offers from real LXMF clients, persist them across restarts, and serve their two-phase `/get` downloads.

**Architecture:** A new `LXMFServiceNode` reducer composes the existing `LXMFNode` (client, owns the single `TransportEndpoint`) with the existing `PropagationNode` (store + serve logic), adding only serve-translation over the shared endpoint. All serve behavior is gated on `nodeModeEnabled`. Persistence lives in the app (GRDB), keeping the library pure.

**Tech Stack:** Swift 6, The Composable Architecture (TCA), swift-testing (`@Test`/`#expect`), GRDB + SQLiteData (app), ReTiCA (ReTiCA / ReTiCANode / ReTiCATransport / ReTiCAInterfaces).

**Spec:** `/Users/ell/development/ios/apps/ReTiCaMsgr/docs/superpowers/specs/2026-08-03-retica-as-propagation-node-design.md`

## Global Constraints

- **TWO REPOS.** Tasks 1–4 → ReTiCA pods `/Users/ell/development/ios/pods/ReTiCA`. Tasks 5–7 → app `/Users/ell/development/ios/apps/ReTiCaMsgr`. Commit directly to `main` in BOTH; no feature branches.
- **Commit trailers must start at COLUMN 0 (no indent)**, exactly:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`
- **Use `git commit -F <file>`, NEVER `-m`** (trailers contain `;` and the shell rule below forbids it). After each commit verify:
  `git -C <repo> log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'` must print the URL.
- **No compound shell commands.** One command per invocation: no `&&`, `||`, `;`, pipes, `xargs`, or inline interpreter scripts (`python -c`, heredocs). A single `>` redirect of a real command is allowed. Write scripts to a file under `/tmp/ReTiCaMsgr/` and run that file.
- **Stage only your own files.** `git add <explicit paths>` — never `git add -A` or `git add .` (concurrent BLE work is in flight; broad adds have swept unrelated files into commits before).
- **Three-step mutation verification for every new/changed test:** (a) run, all pass; (b) mutate the production code they cover in ONE batch so they should fail, run, confirm they all fail; (c) revert, run, confirm green. Only then commit.
- **TCA tests are non-exhaustive:** set `store.exhaustivity = .off` and assert outcomes/behavior, not implementation path.
- Temp files go under `/tmp/ReTiCaMsgr/`.
- Library code stays pure — **no file I/O in ReTiCA**. Persistence is app-side only.
- Run library tests with `swift test` from `/Users/ell/development/ios/pods/ReTiCA`.
- **`swift package clean`** if you hit a signal-11/stale-link failure after changing MsgPack/transport code.

---

## File Structure

**Library (`pods/ReTiCA`)**

| File | Responsibility |
| --- | --- |
| `Sources/ReTiCANode/PropagationNode.swift` (modify) | Add `storedEntries` + `purged` delegates so a host can mirror the store to disk |
| `Sources/ReTiCANode/LXMFNode.swift` (modify) | Link classification: track `linkID → destinationHash`; skip direct-message handling on the served propagation link |
| `Sources/ReTiCANode/LXMFServiceNode.swift` (new) | The combined node: `LXMFNode` + `PropagationNode` + serve-translation, gated on `nodeModeEnabled` |
| `Tests/ReTiCANodeTests/PropagationNodeTests.swift` (modify) | Cover the two new delegates |
| `Tests/ReTiCANodeTests/LXMFServiceNodeTests.swift` (new) | Unit + real-link integration coverage of the combined node |

**App (`apps/ReTiCaMsgr`)**

| File | Responsibility |
| --- | --- |
| `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` (modify) | Rewire to `LXMFServiceNode`; node-mode lifecycle; persistence mirror + rehydrate |
| `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/PropagationEntryRow.swift` (new) | `@Table` row for a stored propagation entry |
| `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Database.swift` (modify) | Migration creating `propagationEntries` |
| `ReTiCaMsgr/SettingsView.swift` (modify) | "Act as a propagation node" toggle |
| `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (modify) | Node-mode + persistence wiring tests |

---

### Task 1: `PropagationNode` — persistence delegates

**Repo:** pods `/Users/ell/development/ios/pods/ReTiCA`

**Files:**
- Modify: `Sources/ReTiCANode/PropagationNode.swift`
- Test: `Tests/ReTiCANodeTests/PropagationNodeTests.swift`

**Why:** the app must mirror the in-memory store to disk. Today `stored(transientIds:)` carries only ids (not the bytes to write), and nothing signals removal. Both additions are **additive** — existing cases keep their shape so `PNNode` and all current tests are unaffected.

**Interfaces:**
- Consumes: `PropagationStore.Entry` (`transientId`, `destinationHash`, `lxmfData` are `public`; `sequence` is internal).
- Produces, on `PropagationNode.Action.Delegate`:
  - `case storedEntries(entries: [PropagationStore.Entry])` — emitted with `stored` on ingest.
  - `case purged(transientIds: [Data])` — emitted whenever entries leave the store.
- Produces: a **public** `PropagationStore.Entry` initializer (see Step 0) — required because `Entry`'s
  memberwise init is currently internal (`sequence` is not public), so a host module cannot construct one
  in its own tests even though the delegate hands it across the module boundary.

- [ ] **Step 0: Make `Entry` constructible outside the module**

In `Sources/ReTiCA/LXMF/PropagationStore.swift`, add a public init to `Entry` (leave the stored properties and `sequence` exactly as they are):

```swift
        /// Public construction for hosts mirroring the store (persistence, tests). `sequence` is the
        /// store's internal ordering and is not part of a host's contract, so it defaults to 0 —
        /// entries built this way are values to persist/compare, not to insert into a store.
        public init(transientId: Data, destinationHash: Data, lxmfData: Data) {
            self.transientId = transientId
            self.destinationHash = destinationHash
            self.lxmfData = lxmfData
            self.sequence = 0
        }
```

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCANodeTests/PropagationNodeTests.swift`:

```swift
@Test @MainActor func propagationNodeEmitsStoredEntriesForPersistence() async {
    let e = entry(dest: 0xAA, tail: "persist-me")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let store = TestStore(initialState: PropagationNode.State(minStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e])))
    await store.receive { action in
        if case let .delegate(.storedEntries(entries)) = action {
            #expect(entries.count == 1)
            #expect(entries[0].transientId == tid)
            #expect(entries[0].lxmfData == e)            // the bytes the host must write
            #expect(entries[0].destinationHash == Data(repeating: 0xAA, count: LXMessage.destinationLength))
            return true
        }
        return false
    }
}

/// Entries leave the store by two routes — the `haves` purge inside messagesRequested and the
/// messagesDelivered action. BOTH must signal, or the host's mirror drifts from the store.
@Test @MainActor func propagationNodeEmitsPurgedOnBothRemovalPaths() async {
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let tidA1 = LXMFPropagation.transientId(lxmfData: a1)
    let tidA2 = LXMFPropagation.transientId(lxmfData: a2)
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let store = TestStore(initialState: PropagationNode.State(minStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, a2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }

    // Route 1: the `haves` purge inside messagesRequested.
    await store.send(.messagesRequested(destinationHash: destA, wants: [tidA2], haves: [tidA1]))
    await store.receive { action in
        if case let .delegate(.purged(ids)) = action { #expect(ids == [tidA1]); return true }
        return false
    }
    #expect(store.state.store.contains(transientId: tidA1) == false)

    // Route 2: messagesDelivered.
    await store.send(.messagesDelivered(transientIds: [tidA2]))
    await store.receive { action in
        if case let .delegate(.purged(ids)) = action { #expect(ids == [tidA2]); return true }
        return false
    }
    #expect(store.state.store.contains(transientId: tidA2) == false)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "propagationNodeEmitsStoredEntriesForPersistence|propagationNodeEmitsPurgedOnBothRemovalPaths"`
Expected: FAIL — `storedEntries`/`purged` are not members of `Delegate`.

- [ ] **Step 3: Add the delegate cases**

In `Sources/ReTiCANode/PropagationNode.swift`, add to `Action.Delegate` (keep every existing case unchanged):

```swift
            /// The full entries just ingested — the bytes a host persists. Emitted alongside `stored`.
            case storedEntries(entries: [PropagationStore.Entry])
            /// Transient ids just removed from the store (client purge or delivery confirmation), so a
            /// host can delete its mirrored copies.
            case purged(transientIds: [Data])
```

- [ ] **Step 4: Emit them**

Replace the three affected cases in the `Reduce`:

```swift
            case let .ingestContainer(data):
                let added = state.store.ingest(container: data)
                let entries = state.store.entries(forTransientIds: added)
                return .merge(.send(.delegate(.stored(transientIds: added))),
                              .send(.delegate(.storedEntries(entries: entries))))

            case let .messagesRequested(destinationHash, wants, haves):
                let purged = haves.filter { state.store.contains(transientId: $0) }
                for tid in haves { state.store.remove(transientId: tid) }          // purge what the client already has
                let wantSet = Set(wants)
                let entries = state.store.entries(forDestination: destinationHash)
                    .filter { wantSet.contains($0.transientId) }
                    .map { LXMFPropagation.strippedCore(lxmfData: $0.lxmfData) }   // serve stampless (reference LXMRouter.py:1551)
                var effects: [Effect<Action>] = [
                    .send(.delegate(.deliverMessages(destinationHash: destinationHash, entries: entries)))
                ]
                if !purged.isEmpty { effects.append(.send(.delegate(.purged(transientIds: purged)))) }
                return .merge(effects)

            case let .messagesDelivered(transientIds):
                let purged = transientIds.filter { state.store.contains(transientId: $0) }
                for tid in transientIds { state.store.remove(transientId: tid) }
                guard !purged.isEmpty else { return .none }
                return .send(.delegate(.purged(transientIds: purged)))
```

Note: `purged` reports only ids that were actually present, so the host never deletes rows for ids the store never had.

- [ ] **Step 5: Run the new tests — expect PASS**

Run: `swift test --filter "propagationNodeEmitsStoredEntriesForPersistence|propagationNodeEmitsPurgedOnBothRemovalPaths"`

- [ ] **Step 6: Run the full suite (no regressions in `PNNode`/`PropagationNode`)**

Run: `swift test`
Expected: all pass (613 + 2 new).

- [ ] **Step 7: Mutation-verify (three-step, per Global Constraints)**

Mutate in ONE batch: in `ingestContainer` change `entries` to `[]`; in `messagesRequested` change `let purged = haves.filter {...}` to `let purged: [Data] = []`; in `messagesDelivered` likewise. Run the two new tests — all must FAIL. Revert all three; run again — all must PASS.

- [ ] **Step 8: Commit**

Write the message to `/tmp/ReTiCaMsgr/commit-task1.txt` (trailers at column 0), then:

```bash
git -C /Users/ell/development/ios/pods/ReTiCA add Sources/ReTiCA/LXMF/PropagationStore.swift Sources/ReTiCANode/PropagationNode.swift Tests/ReTiCANodeTests/PropagationNodeTests.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCA commit -F /tmp/ReTiCaMsgr/commit-task1.txt
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCA log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'
```

---

### Task 2: `LXMFNode` — link classification

**Repo:** pods `/Users/ell/development/ios/pods/ReTiCA`

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Test: `Tests/ReTiCANodeTests/LXMFServiceNodeTests.swift` (new file; created here, extended in Tasks 3–4)

**Why (read carefully — this is the subtle part):** `LXMFNode` currently treats *every* inbound `linkDataReceived` / `resourceReceived` as a direct LXMF message (`LXMFNode.swift:245-249`). Once the same endpoint also serves `lxmf.propagation`, an inbound propagation **offer** arrives through those same two delegates. Without classification the client would try to unpack a container as a message.

The disambiguator: for an **inbound** link, `linkEstablished(linkID:destinationHash:)` carries **our own local destination** (`TCPEndpoint.swift:131-136` resolves it from `transport.localDestinations`), while our client's **outbound** sync link to a remote node carries the *remote* hash. They never collide.

Do **not** rely on "a container will fail `LXMessage.unpack`" — that is probabilistic, and a parse that did succeed would surface a bogus message.

**Interfaces:**
- Produces (used by Task 3):
  - `LXMFNode.State.propagationDestinationHash: Data?` — set when node-mode serves; `nil` = not serving.
  - `LXMFNode.State.linkDestinations: [Data: Data]` — `linkID → destinationHash`, populated from `linkEstablished`, cleared on `linkClosed`.

- [ ] **Step 1: Write the failing test**

Create `Tests/ReTiCANodeTests/LXMFServiceNodeTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// Link classification: data arriving on the link that terminates on OUR served lxmf.propagation
/// destination is a propagation offer, not a direct message — the client must NOT try to deliver it.
/// Data on any other link keeps the existing direct-message behavior.
@MainActor @Test func clientIgnoresLinkDataOnServedPropagationLink() async {
    let identity = Identity()
    let servedPropHash = Data(repeating: 0x9A, count: 16)
    let otherHash = Data(repeating: 0x5B, count: 16)
    let servedLink = Data(repeating: 0xC1, count: 16)
    let otherLink = Data(repeating: 0xC2, count: 16)

    var initial = LXMFNode.State(identity: identity,
                                 endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    initial.propagationDestinationHash = servedPropHash

    let store = TestStore(initialState: initial) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    // Both links establish; only the first terminates on our served propagation destination.
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: servedLink, destinationHash: servedPropHash))))
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: otherLink, destinationHash: otherHash))))
    #expect(store.state.linkDestinations[servedLink] == servedPropHash)
    #expect(store.state.linkDestinations[otherLink] == otherHash)

    // Data on the served propagation link must NOT reach the router.
    let sawRouterReceived = LockIsolated(false)
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: servedLink, data: Data("container".utf8)))))
    await store.receive({ action in
        if case .router(.received) = action { sawRouterReceived.setValue(true); return true }
        return false
    }, timeout: .zero) // no-op if nothing arrives
    #expect(sawRouterReceived.value == false, "propagation-link data must not be delivered as a direct message")

    // Data on any other link keeps the existing direct-message path.
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: otherLink, data: Data("msg".utf8)))))
    await store.receive { if case .router(.received) = $0 { return true }; return false }
}
```

**Implementer note on the negative assertion.** The `sawRouterReceived` / `timeout: .zero` sketch above is not a real swift-testing idiom — replace it with this repo's established "no action emitted" pattern. The reliable one used elsewhere in this codebase: send the action while `exhaustivity = .off`, then let the store **deinit** assert no unhandled actions remain (a stray `.router(.received)` fails teardown). Concretely, replace that block with:

```swift
    // Data on the served propagation link must NOT reach the router: with exhaustivity .off an
    // unreceived .router(.received) is caught by the TestStore's end-of-test unhandled-action check.
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: servedLink, data: Data("container".utf8)))))
```

and keep the positive assertion (the `otherLink` send + `await store.receive { ... .router(.received) ... }`) as written — it proves the guard is not simply disabling everything. The requirement: **prove no `.router(.received)` is emitted for propagation-link data, and that it still is for other links.**

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter clientIgnoresLinkDataOnServedPropagationLink`
Expected: FAIL — `propagationDestinationHash` / `linkDestinations` don't exist.

- [ ] **Step 3: Add the state**

In `LXMFNode.State`, after `syncPhase`:

```swift
        /// linkID → the destination hash that link terminates on. For an inbound (responder) link this is
        /// OUR local destination; for an outbound link it is the remote one.
        public var linkDestinations: [Data: Data] = [:]
        /// Our served `lxmf.propagation` destination hash while node-mode is on (nil = not serving).
        /// Data arriving on a link to this destination is a propagation offer, not a direct message.
        public var propagationDestinationHash: Data?
```

- [ ] **Step 4: Track and use the classification**

In the `Reduce`, record link destinations. `LXMFNode` already handles `linkEstablished` for its own outbound direct/sync links — find that case and add the bookkeeping line without changing its existing behavior; if it does not already match `linkEstablished`, add:

```swift
            case let .endpoint(.delegate(.linkEstablished(linkID, destinationHash))):
                state.linkDestinations[linkID] = destinationHash
                return .none    // (merge with the existing linkEstablished handling if one exists)
```

Add a helper just above the `switch` (inside the `Reduce` closure):

```swift
            func isServedPropagationLink(_ state: LXMFNode.State, _ linkID: Data) -> Bool {
                guard let served = state.propagationDestinationHash else { return false }
                return state.linkDestinations[linkID] == served
            }
```

Then guard the two direct-message handlers (currently `LXMFNode.swift:245-249`):

```swift
            case let .endpoint(.delegate(.linkDataReceived(linkID, data))):
                // On our served lxmf.propagation link this is an offer for the node, not a message for us.
                guard !isServedPropagationLink(state, linkID) else { return .none }
                return .send(.router(.received(method: .direct, destinationHash: Data(), data: data)))

            case let .endpoint(.delegate(.resourceReceived(linkID, data))):
                guard !isServedPropagationLink(state, linkID) else { return .none }
                return .send(.router(.received(method: .direct, destinationHash: Data(), data: data)))
```

Clear the map on close — add to the existing `linkClosed` handling (or add the case if absent):

```swift
                state.linkDestinations[linkID] = nil
```

- [ ] **Step 5: Run the new test — expect PASS**

Run: `swift test --filter clientIgnoresLinkDataOnServedPropagationLink`

- [ ] **Step 6: Full suite**

Run: `swift test`
Expected: all pass. With `propagationDestinationHash == nil` (every existing test) behavior is unchanged.

- [ ] **Step 7: Mutation-verify**

Mutate: change the two guards to `guard true else { return .none }` (i.e. delete the classification). Run the new test — must FAIL. Revert; run — must PASS.

- [ ] **Step 8: Commit**

```bash
git -C /Users/ell/development/ios/pods/ReTiCA add Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFServiceNodeTests.swift
```
Then `git commit -F /tmp/ReTiCaMsgr/commit-task2.txt` and verify the trailer.

---

### Task 3: `LXMFServiceNode` — the combined node

**Repo:** pods `/Users/ell/development/ios/pods/ReTiCA`

**Files:**
- Create: `Sources/ReTiCANode/LXMFServiceNode.swift`
- Test: `Tests/ReTiCANodeTests/LXMFServiceNodeTests.swift` (append)

**Interfaces:**
- Consumes: Task 1's `PropagationNode.Action.Delegate.storedEntries(entries:)` / `.purged(transientIds:)`; Task 2's `LXMFNode.State.propagationDestinationHash` / `.linkDestinations`.
- Produces (used by Tasks 5–7, the app):
  - `LXMFServiceNode.State(identity:endpoint:storageLimitBytes:minStampCost:)`, plus convenience inits taking `TCPEndpoint.State` / `BLEEndpoint.State`.
  - `LXMFServiceNode.Action.client(LXMFNode.Action)` — every existing app action path moves under this.
  - `LXMFServiceNode.Action.setNodeMode(Bool)` and `.registerPropagation`.
  - `LXMFServiceNode.Action.Delegate.messagesStored(entries: [PropagationStore.Entry])` and `.messagesPurged(transientIds: [Data])`.
  - `LXMFServiceNode.State.defaultStorageLimitBytes: Int` = `32 * 1024 * 1024`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCANodeTests/LXMFServiceNodeTests.swift`:

```swift
private func makeServiceNode(_ identity: Identity, nodeMode: Bool)
    -> TestStore<LXMFServiceNode.State, LXMFServiceNode.Action> {
    var initial = LXMFServiceNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false),
        minStampCost: 0)                       // 0 → accept synthetic unstamped test entries
    initial.nodeModeEnabled = nodeMode
    let store = TestStore(initialState: initial) { LXMFServiceNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

/// registerPropagation registers lxmf.propagation, announces it, and the announce advertises exactly
/// the stamp cost the store enforces (advertised == enforced).
@MainActor @Test func serviceNodeRegistersPropagationAndAdvertisesEnforcedCost() async {
    let identity = Identity()
    var initial = LXMFServiceNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false),
        minStampCost: 12)
    initial.nodeModeEnabled = true
    let store = TestStore(initialState: initial) { LXMFServiceNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    let expected = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    await store.send(.registerPropagation)
    await store.receive { action in
        if case let .client(.endpoint(.registerLocalDestination(d))) = action {
            #expect(d.hash == expected.hash); return true
        }
        return false
    }
    await store.receive { action in
        if case let .client(.endpoint(.announce(hash, appData))) = action {
            #expect(hash == expected.hash)
            let parsed = PNAnnounce.parse(appData ?? Data())
            #expect(parsed?.targetStampCost == 12)      // advertised == enforced
            #expect(parsed?.nodeState == true)
            return true
        }
        return false
    }
    // The client learns which destination it serves, so it stops treating that link's data as messages.
    #expect(store.state.client.propagationDestinationHash == expected.hash)
}

/// A client's offer arriving on the served propagation link is ingested and surfaced for persistence.
@MainActor @Test func serviceNodeIngestsOfferOnPropagationLink() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let e = Data(repeating: 0xAA, count: LXMessage.destinationLength) + Data("offered".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))

    await store.receive { action in
        if case let .delegate(.messagesStored(entries)) = action {
            #expect(entries.map(\.transientId) == [tid]); return true
        }
        return false
    }
    #expect(store.state.pn.store.contains(transientId: tid))
}

/// With node-mode OFF nothing is registered, ingested, or served — a plain client.
@MainActor @Test func serviceNodeDoesNotServeWhenNodeModeOff() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: false)
    let container = LXMFPropagation.container(
        timestamp: 1700000000.5,
        entries: [Data(repeating: 0xAA, count: LXMessage.destinationLength) + Data("ignored".utf8)])
    let linkID = Data(repeating: 0xC1, count: 16)

    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: Identity())))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([1]),
        pathHash: Crypto.truncatedHash(Data("/get".utf8)),
        data: MsgPack.encode(.array([.null, .null])))))))

    #expect(store.state.pn.store.count == 0)          // nothing ingested
    #expect(store.state.clientIdentities.isEmpty)     // no serve bookkeeping
    // No response emitted: a stray .client(.endpoint(.sendResponseOverLink)) fails teardown.
}

/// Two-phase /get. Only IDENTIFY'd clients are served (reference LXMRouter.py:1483 ERROR_NO_IDENTITY).
@MainActor @Test func serviceNodeServesTwoPhaseGetForIdentifiedClient() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let client = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let e = clientHash + Data("for-client".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)
    let getPath = Crypto.truncatedHash(Data("/get".utf8))

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }

    // No IDENTIFY yet → dropped (no response; a stray response fails teardown).
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([9]), pathHash: getPath,
        data: MsgPack.encode(.array([.null, .null])))))))

    // IDENTIFY, then phase-1 → id list.
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: client)))))
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([1]), pathHash: getPath,
        data: MsgPack.encode(.array([.null, .null])))))))
    await store.receive { action in
        if case let .client(.endpoint(.sendResponseOverLink(lid, rid, data))) = action {
            #expect(lid == linkID); #expect(rid == Data([1]))
            #expect(MsgPack.decodeValue(data) == .array([.bin(tid)])); return true
        }
        return false
    }

    // Phase-2 → the blob (served stampless; this synthetic entry is already stampless).
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([2]), pathHash: getPath,
        data: MsgPack.encode(.array([.array([.bin(tid)]), .array([])])))))))
    await store.receive { action in
        if case let .client(.endpoint(.sendResponseOverLink(_, rid, data))) = action {
            #expect(rid == Data([2]))
            #expect(MsgPack.decodeValue(data) == .array([.bin(e)])); return true
        }
        return false
    }
}

/// Phase-3 purge: the client's `haves` evict from the store and surface for the host's mirror.
@MainActor @Test func serviceNodePurgesOnHavesAndSurfacesIt() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let client = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let e = clientHash + Data("purge-me".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: client)))))

    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([3]), pathHash: Crypto.truncatedHash(Data("/get".utf8)),
        data: MsgPack.encode(.array([.null, .array([.bin(tid)])])))))))

    await store.receive { action in
        if case let .delegate(.messagesPurged(ids)) = action { #expect(ids == [tid]); return true }
        return false
    }
    #expect(store.state.pn.store.contains(transientId: tid) == false)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter serviceNode`
Expected: FAIL — `LXMFServiceNode` does not exist.

- [ ] **Step 3: Create `Sources/ReTiCANode/LXMFServiceNode.swift`**

```swift
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// A node that is BOTH an LXMF client and (optionally) an LXMF propagation node over ONE endpoint —
/// the shape reference LXMF uses: one identity, one connection, both destinations registered.
///
/// Composes the unchanged `LXMFNode` (client; owns the `TransportEndpoint`) with the unchanged
/// `PropagationNode` (store + serve logic), adding only the translation between the endpoint's inbound
/// delegates and the propagation node's actions. Every serve behavior is gated on `nodeModeEnabled`, so
/// with node-mode off this behaves exactly like a bare `LXMFNode`.
///
/// Serve scope is client-facing only (register/announce, ingest offers, two-phase `/get`). PN↔PN mesh
/// peering, inbound proving, and time-based expiry are out of scope — see `PNNode` for the peering path.
@Reducer
public struct LXMFServiceNode {
    @ObservableState
    public struct State: Equatable {
        public var client: LXMFNode.State
        public var pn: PropagationNode.State
        /// While false, nothing is registered, ingested, or served.
        public var nodeModeEnabled: Bool = false
        /// The stamp cost this node ENFORCES on inbound entries, and therefore also ADVERTISES.
        public var minStampCost: Int
        /// linkID → the IDENTIFY'd remote client on that link. A `/get` without one is dropped.
        public var clientIdentities: [Data: Identity] = [:]
        /// client delivery hash → the request awaiting a response.
        public var pendingGet: [Data: PendingGet] = [:]

        /// 32 MB — a mobile-appropriate cap for the store-and-forward backlog.
        public static let defaultStorageLimitBytes: Int = 32 * 1024 * 1024

        public init(identity: Identity, endpoint: TransportEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    minStampCost: Int = LXMFPropagation.defaultPropagationStampCost) {
            self.client = LXMFNode.State(identity: identity, endpoint: endpoint)
            self.pn = PropagationNode.State(storageLimitBytes: storageLimitBytes, minStampCost: minStampCost)
            self.minStampCost = minStampCost
        }

        /// Convenience: run this node over TCP.
        public init(identity: Identity, endpoint: TCPEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    minStampCost: Int = LXMFPropagation.defaultPropagationStampCost) {
            self.init(identity: identity, endpoint: .tcp(endpoint),
                      storageLimitBytes: storageLimitBytes, minStampCost: minStampCost)
        }

        /// Convenience: run this node over BLE.
        public init(identity: Identity, endpoint: BLEEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    minStampCost: Int = LXMFPropagation.defaultPropagationStampCost) {
            self.init(identity: identity, endpoint: .ble(endpoint),
                      storageLimitBytes: storageLimitBytes, minStampCost: minStampCost)
        }
    }

    public struct PendingGet: Equatable {
        public var linkID: Data
        public var requestID: Data
    }

    public enum Action: Equatable {
        case client(LXMFNode.Action)
        case pn(PropagationNode.Action)
        case registerPropagation
        case setNodeMode(Bool)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// Entries just accepted into the store — the host persists these.
            case messagesStored(entries: [PropagationStore.Entry])
            /// Entries just removed — the host deletes its mirrored copies.
            case messagesPurged(transientIds: [Data])
        }
    }

    @Dependency(\.date) var date
    public init() {}

    private static func arrayOfBin(_ value: MsgPackValue) -> [Data] {
        guard case let .array(items) = value else { return [] }
        return items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
    }

    public var body: some ReducerOf<Self> {
        Scope(state: \.client, action: \.client) { LXMFNode() }
        Scope(state: \.pn, action: \.pn) { PropagationNode() }
        Reduce { [date] state, action in
            /// True when this link terminates on the lxmf.propagation destination WE serve — i.e. the
            /// peer is a propagation client of ours, not a direct correspondent.
            func isPropagationLink(_ state: State, _ linkID: Data) -> Bool {
                guard let served = state.client.propagationDestinationHash else { return false }
                return state.client.linkDestinations[linkID] == served
            }

            switch action {
            case let .setNodeMode(enabled):
                state.nodeModeEnabled = enabled
                if enabled { return .send(.registerPropagation) }
                state.client.propagationDestinationHash = nil    // client resumes normal handling
                state.clientIdentities = [:]
                state.pendingGet = [:]
                return .none

            case .registerPropagation:
                guard state.nodeModeEnabled,
                      let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: ["propagation"], identity: state.client.identity)
                else { return .none }
                state.client.propagationDestinationHash = d.hash
                let appData = PNAnnounce(timebase: Int(date.now.timeIntervalSince1970), nodeState: true,
                                         perTransferLimit: 0, perSyncLimit: 0,
                                         targetStampCost: state.minStampCost,   // advertised == enforced
                                         stampCostFlexibility: 0, peeringCost: 0).packed
                return .merge(
                    .send(.client(.endpoint(.registerLocalDestination(d)))),
                    .send(.client(.endpoint(.announce(destinationHash: d.hash, appData: appData)))))

            // --- Inbound offers (only on the link to the destination we serve) ---
            case let .client(.endpoint(.delegate(.resourceReceived(linkID, data)))):
                guard state.nodeModeEnabled, isPropagationLink(state, linkID) else { return .none }
                return .send(.pn(.ingestContainer(data)))

            case let .client(.endpoint(.delegate(.linkDataReceived(linkID, data)))):
                guard state.nodeModeEnabled, isPropagationLink(state, linkID) else { return .none }
                return .send(.pn(.ingestContainer(data)))

            case let .client(.endpoint(.delegate(.linkIdentified(linkID, remoteIdentity)))):
                guard state.nodeModeEnabled else { return .none }
                state.clientIdentities[linkID] = remoteIdentity
                return .none

            // --- Two-phase /get ---
            case let .client(.endpoint(.delegate(.requestReceived(linkID, requestID, pathHash, data)))):
                guard state.nodeModeEnabled,
                      pathHash == Crypto.truncatedHash(Data("/get".utf8)),
                      let clientIdentity = state.clientIdentities[linkID]   // no IDENTIFY → drop
                else { return .none }
                guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2 else { return .none }
                let clientHash = LXMessage.deliveryHash(identityHash: clientIdentity.hash)
                state.pendingGet[clientHash] = PendingGet(linkID: linkID, requestID: requestID)
                if case .null = items[0], case .null = items[1] {
                    return .send(.pn(.messageListRequested(destinationHash: clientHash)))
                }
                return .send(.pn(.messagesRequested(destinationHash: clientHash,
                                                    wants: LXMFServiceNode.arrayOfBin(items[0]),
                                                    haves: LXMFServiceNode.arrayOfBin(items[1]))))

            case let .pn(.delegate(.deliverMessageList(dest, ids))):
                guard let p = state.pendingGet[dest] else { return .none }
                state.pendingGet[dest] = nil
                return .send(.client(.endpoint(.sendResponseOverLink(
                    linkID: p.linkID, requestID: p.requestID,
                    data: MsgPack.encode(.array(ids.map { .bin($0) }))))))

            case let .pn(.delegate(.deliverMessages(dest, entries))):
                guard let p = state.pendingGet[dest] else { return .none }
                state.pendingGet[dest] = nil
                return .send(.client(.endpoint(.sendResponseOverLink(
                    linkID: p.linkID, requestID: p.requestID,
                    data: MsgPack.encode(.array(entries.map { .bin($0) }))))))

            // --- Persistence signals out to the host ---
            case let .pn(.delegate(.storedEntries(entries))):
                guard !entries.isEmpty else { return .none }
                return .send(.delegate(.messagesStored(entries: entries)))

            case let .pn(.delegate(.purged(ids))):
                guard !ids.isEmpty else { return .none }
                return .send(.delegate(.messagesPurged(transientIds: ids)))

            // --- Link lifecycle cleanup ---
            case let .client(.endpoint(.delegate(.linkClosed(linkID, _)))):
                state.clientIdentities[linkID] = nil
                state.pendingGet = state.pendingGet.filter { $0.value.linkID != linkID }
                return .none

            case let .client(.endpoint(.delegate(.requestFailed(linkID, _)))):
                state.pendingGet = state.pendingGet.filter { $0.value.linkID != linkID }
                return .none

            case .client, .pn, .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 4: Run the new tests — expect PASS**

Run: `swift test --filter serviceNode`

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 6: Mutation-verify**

Mutate in ONE batch: (1) in `registerPropagation` change `targetStampCost: state.minStampCost` to `targetStampCost: 0`; (2) delete the `let clientIdentity = state.clientIdentities[linkID]` condition from the `requestReceived` guard (serve without IDENTIFY — bind it separately so it still compiles); (3) change the `resourceReceived` guard to `guard state.nodeModeEnabled else { return .none }`. Run `swift test --filter serviceNode` — the cost, IDENTIFY, and node-mode-off tests must FAIL. Revert all three; run — must PASS.

- [ ] **Step 7: Commit**

```bash
git -C /Users/ell/development/ios/pods/ReTiCA add Sources/ReTiCANode/LXMFServiceNode.swift Tests/ReTiCANodeTests/LXMFServiceNodeTests.swift
```
Then `git commit -F /tmp/ReTiCaMsgr/commit-task3.txt` and verify the trailer.

---

### Task 4: Real-link integration capstone

**Repo:** pods `/Users/ell/development/ios/pods/ReTiCA`

**Files:**
- Test: `Tests/ReTiCANodeTests/LXMFServiceNodeTests.swift` (append)

**Why:** Task 3's tests inject endpoint delegates directly. This proves the same flow over a **real link** — genuine LINKREQUEST/LRPROOF/LRRTT handshake, a real Resource transfer, real IDENTIFY, real REQUEST/RESPONSE framing — with a **stamped** entry at the node's real enforced cost. Stub-only coverage is what hid all three previous propagation interop bugs.

**Interfaces:**
- Consumes: `LXMFServiceNode` (Task 3). No production code changes — this task is test-only. If it fails, fix the production defect it exposes and note it in the report.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ReTiCANodeTests/LXMFServiceNodeTests.swift`. This mirrors the established harness in `PNNodeIntegrationTests.swift` — read that file first for the bridging idiom.

```swift
/// End-to-end over a REAL link: client C offers a stamped container to an LXMFServiceNode in node-mode
/// (ingested + persisted-signal), then IDENTIFYs and runs the two-phase /get; the node serves C's id list
/// and blob, and C opens the blob to the original signature-valid message.
@Test @MainActor func serviceNodeIngestsAndServesOverRealLink() async {
    let clock = TestClock()
    let nodeIdentity = Identity()
    let cIdentity = Identity()      // the client AND the recipient of the stored message
    let sIdentity = Identity()      // the original sender
    let cDeliveryHash = LXMessage.deliveryHash(identityHash: cIdentity.hash)

    // A real stamped container at the cost the node enforces.
    let msg = LXMessage.create(source: sIdentity, destinationHash: cDeliveryHash,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi C".utf8))
    let (container, tid) = LXMFPropagation.pack(message: msg, recipientIdentity: cIdentity,
                                                timestamp: 1700000000.5, stampCost: 4)

    func makeNode(_ host: String, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFServiceNode.State, LXMFServiceNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        var initial = LXMFServiceNode.State(
            identity: nodeIdentity,
            endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false),
            minStampCost: 4)
        initial.nodeModeEnabled = true
        let store = TestStore(initialState: initial) { LXMFServiceNode() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func makeClient(_ host: String, _ sent: LockIsolated<[Data]>)
        -> (TestStore<TCPEndpoint.State, TCPEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false)) {
            TCPEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func nodeSend(_ act: LXMFServiceNode.Action) -> Bool {
        if case .client(.endpoint(.tcp(.interface(.send)))) = act { return true }; return false
    }
    func cSend(_ act: TCPEndpoint.Action) -> Bool { if case .interface(.send) = act { return true }; return false }

    let sentNode = LockIsolated<[Data]>([])
    let sentC = LockIsolated<[Data]>([])
    let (node, eventsNode) = makeNode("node", sentNode)
    let (c, eventsC) = makeClient("c", sentC)

    await node.send(.client(.endpoint(.connect))); eventsNode.yield(.connected)
    await c.send(.connect); eventsC.yield(.connected)

    // Node registers + announces lxmf.propagation; bridge the announce so C learns its path + identity.
    await node.send(.registerPropagation)
    await node.receive { if case .client(.endpoint(.registerLocalDestination)) = $0 { return true }; return false }
    await node.receive(nodeSend)   // announce frame out
    eventsC.yield(.data(sentNode.value.last!))
    await c.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    // C opens a link to the node's propagation destination.
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: nodeIdentity)!
    await c.send(.openLink(destinationHash: propDest.hash))
    await c.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await c.receive(cSend)         // LINKREQUEST out

    // Handshake: LINKREQUEST → node (LRPROOF out); LRPROOF → C (LRRTT out); LRRTT → node (both active).
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive(nodeSend)   // LRPROOF out
    let lrrttIdx = sentC.value.count
    eventsC.yield(.data(sentNode.value.last!))
    await c.receive(cSend)         // LRRTT out
    let lrrttBytes = sentC.value[lrrttIdx]
    eventsNode.yield(.data(lrrttBytes))
    await c.receive { if case .delegate(.linkEstablished) = $0 { return true }; return false }
    await node.receive { if case .client(.endpoint(.delegate(.linkEstablished))) = $0 { return true }; return false }

    let linkID = c.state.links[0].linkID

    // C offers the container as a Resource.
    await c.send(.sendResourceOverLink(linkID: linkID, data: container))
    await c.receive(cSend)         // RESOURCE_ADV out
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive(nodeSend)   // RESOURCE_REQ out
    eventsC.yield(.data(sentNode.value.last!))
    let partCount = c.state.links[0].transfers[0].parts.count
    for _ in 0..<partCount { await c.receive(cSend) }

    let parts = Array(sentC.value.suffix(partCount))
    for (i, frame) in parts.enumerated() {
        eventsNode.yield(.data(frame))
        if i == partCount - 1 {
            await node.receive(nodeSend)   // RESOURCE_PRF out
            await node.receive { action in
                if case let .delegate(.messagesStored(entries)) = action {
                    #expect(entries.map(\.transientId) == [tid]); return true
                }
                return false
            }
        }
    }

    // C identifies.
    await c.send(.identifyOverLink(linkID: linkID, identity: cIdentity))
    await c.receive(cSend)
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive { if case .client(.endpoint(.delegate(.linkIdentified))) = $0 { return true }; return false }

    // Phase-1 /get → id list.
    await c.send(.sendRequestOverLink(linkID: linkID, path: "/get",
                                      data: MsgPack.encode(.array([.null, .null]))))
    await c.receive(cSend)
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive { if case .client(.endpoint(.delegate(.requestReceived))) = $0 { return true }; return false }
    await node.receive(nodeSend)   // response frame out
    let gotList = LockIsolated<Data?>(nil)
    eventsC.yield(.data(sentNode.value.last!))
    await c.receive { action in
        if case let .delegate(.responseReceived(_, _, d)) = action { gotList.setValue(d); return true }
        return false
    }
    #expect(MsgPack.decodeValue(gotList.value!) == .array([.bin(tid)]))

    // Phase-2 /get → the blob, served STAMPLESS (reference LXMRouter.py:1551).
    await c.send(.sendRequestOverLink(linkID: linkID, path: "/get",
                                      data: MsgPack.encode(.array([.array([.bin(tid)]), .array([])]))))
    await c.receive(cSend)
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive { if case .client(.endpoint(.delegate(.requestReceived))) = $0 { return true }; return false }
    await node.receive(nodeSend)   // response frame out
    let gotBlob = LockIsolated<Data?>(nil)
    eventsC.yield(.data(sentNode.value.last!))
    await c.receive { action in
        if case let .delegate(.responseReceived(_, _, d)) = action { gotBlob.setValue(d); return true }
        return false
    }

    // The served blob opens to the original signature-valid message, and its full_hash == the stored key
    // (so a reference client's phase-3 purge would match — the invariant the live purge bug violated).
    guard case let .array(items)? = MsgPack.decodeValue(gotBlob.value!), case let .bin(served)? = items.first
    else { Issue.record("phase-2 response was not [bin]"); return }
    #expect(LXMFPropagation.transientId(lxmfData: served) == tid)
    let recovered = LXMFPropagation.open(lxmfData: served, recipientIdentity: cIdentity)
    #expect(recovered?.content == Data("hi C".utf8))
    #expect(recovered?.validateSignature(source: sIdentity) == true)

    await node.send(.client(.endpoint(.disconnect))); await c.send(.disconnect)
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter serviceNodeIngestsAndServesOverRealLink`
Expected: PASS. If it fails, the failure is a real defect in Task 2/3 production code (or a harness mismatch) — diagnose and fix the production code, do not weaken the assertions.

- [ ] **Step 3: Full suite**

Run: `swift test`

- [ ] **Step 4: Mutation-verify**

Mutate: in `LXMFServiceNode.registerPropagation` change the aspects to `["propagation2"]` (C then links to a destination the node does not serve). Run — this test must FAIL. Revert; run — must PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/ell/development/ios/pods/ReTiCA add Tests/ReTiCANodeTests/LXMFServiceNodeTests.swift
```
Then `git commit -F /tmp/ReTiCaMsgr/commit-task4.txt` and verify the trailer.

---

### Task 5: App — rewire to `LXMFServiceNode` (and repair the BLE-refactor break)

**Repo:** app `/Users/ell/development/ios/apps/ReTiCaMsgr`

**Files:**
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift`
- Test: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`

**IMPORTANT — the app core does NOT currently compile.** A concurrent ReTiCA BLE refactor replaced the endpoint action surface, and `AppFeature` still uses the old names. Verify first:

```bash
swift build --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore
```

You will see errors around `AppFeature.swift:68`. This task repairs that **and** performs the rewire — they touch the same lines, so doing them together avoids double churn. Renames required (old → new):

| Old (broken) | New |
| --- | --- |
| `.node(.endpoint(.connect))` | `.node(.client(.endpoint(.start)))` |
| `.node(.endpoint(.disconnect))` | `.node(.client(.endpoint(.stop)))` |
| `.node(.endpoint(.transport(.interfaceConnected(_))))` | `.node(.client(.endpoint(.tcp(.transport(.interfaceConnected(_))))))` |
| `.node(.endpoint(.transport(.interfaceDisconnected(_))))` | `.node(.client(.endpoint(.tcp(.transport(.interfaceDisconnected(_))))))` |
| `.node(.endpoint(.delegate(.pathLearned(h, _))))` | `.node(.client(.endpoint(.delegate(.pathLearned(h, _)))))` |
| `.node(.delegate(.messageReceived(m, validated)))` | `.node(.client(.delegate(.messageReceived(m, validated))))` |
| `.node(.delegate(.deliveryFailed(hash)))` | `.node(.client(.delegate(.deliveryFailed(hash))))` |
| `.node(.delegate(.propagationAccepted(hash)))` | `.node(.client(.delegate(.propagationAccepted(hash))))` |
| `.node(.registerDelivery)` | `.node(.client(.registerDelivery))` |
| `.node(.setPropagationNode(destinationHash:))` | `.node(.client(.setPropagationNode(destinationHash:)))` |
| `.node(.syncFromPropagationNode)` | `.node(.client(.syncFromPropagationNode))` |
| `.node(.sendMessage(message:alsoViaPropagation:))` | `.node(.client(.sendMessage(message:alsoViaPropagation:)))` |

**Interfaces:**
- Consumes: `LXMFServiceNode` (Task 3).
- Produces: `AppFeature.State.node` is now `LXMFServiceNode.State`; `AppFeature.Action.node(LXMFServiceNode.Action)`. Tasks 6–7 build on this.

- [ ] **Step 1: Change the state and scope**

In `AppFeature.State.init` replace the node construction:

```swift
            self.node = LXMFServiceNode.State(
                identity: identity,
                endpoint: TCPEndpoint.State(host: host, port: UInt16(port), reconnectOnDrop: true)
            )
```

Change the declaration `public var node: LXMFNode.State` → `public var node: LXMFServiceNode.State`, the action case `case node(LXMFNode.Action)` → `case node(LXMFServiceNode.Action)`, and the scope:

```swift
        Scope(state: \.node, action: \.node) { LXMFServiceNode() }
```

- [ ] **Step 2: Apply every rename from the table above**

Work through `AppFeature.swift` case by case. Every previously-working behavior must be preserved exactly — this step changes only action paths, never logic.

- [ ] **Step 3: Build**

Run: `swift build --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`
Expected: builds clean (the pre-existing break is now repaired).

- [ ] **Step 4: Run the existing app tests**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`
Expected: all existing tests pass. Update any test that references the old action paths using the same table — assertions and behavior must not change, only paths.

- [ ] **Step 5: Mutation-verify**

The existing app tests already cover this wiring (send, receive, deliveryFailed, propagationAccepted). Mutate: in `AppFeature`, change the `.sendTapped` effect to send `.node(.client(.syncFromPropagationNode))` instead of `.node(.client(.sendMessage(...)))`. Run the app tests — the send test must FAIL. Revert; run — must PASS.

- [ ] **Step 6: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift
```
Then `git commit -F /tmp/ReTiCaMsgr/commit-task5.txt` and verify the trailer.

---

### Task 6: App — node-mode toggle and lifecycle

**Repo:** app `/Users/ell/development/ios/apps/ReTiCaMsgr`

**Files:**
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift`
- Modify: `ReTiCaMsgr/SettingsView.swift`
- Test: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`

**Interfaces:**
- Consumes: `LXMFServiceNode.Action.setNodeMode(Bool)` (Task 3); the rewired paths (Task 5).
- Produces: `AppFeature.State.nodeModeEnabled` (`@Shared(.appStorage("propagationNodeModeEnabled"))`), `AppFeature.Action.setNodeMode(Bool)`.

- [ ] **Step 1: Write the failing tests**

Append to `AppFeatureTests.swift`. It already has the helper
`makeStore(_ db: any DatabaseWriter, identity: Identity, configure: ((inout AppFeature.State) -> Void)? = nil)`
(sets `exhaustivity = .off` for you) and builds its database with `AppDatabase.makeInMemory()` — use both.

```swift
/// Turning node-mode on enables serving and registers/announces lxmf.propagation.
@MainActor @Test func nodeModeToggleEnablesServing() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.setNodeMode(true))
    await store.receive { if case .node(.setNodeMode(true)) = $0 { return true }; return false }
    #expect(store.state.nodeModeEnabled == true)
    #expect(store.state.node.nodeModeEnabled == true)
}

/// On connect, a persisted node-mode setting is applied — the node serves again after relaunch.
@MainActor @Test func persistedNodeModeIsAppliedOnConnect() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { $0.$nodeModeEnabled.withLock { $0 = true } }
    await store.send(.node(.client(.endpoint(.tcp(.transport(.interfaceConnected(InterfaceID(rawValue: 0))))))))
    await store.receive { if case .node(.setNodeMode(true)) = $0 { return true }; return false }
}
```

**Implementer note:** read `AppFeatureTests.swift` first for how it constructs an `InterfaceID` in existing `interfaceConnected` assertions and use that form; `InterfaceID(rawValue: 0)` above is a best guess at the initializer.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter NodeMode`
Expected: FAIL — `setNodeMode` / `nodeModeEnabled` don't exist on `AppFeature`.

- [ ] **Step 3: Add the shared setting and action**

In `AppFeature.State`, beside `propagationNodeHex`:

```swift
        @Shared(.appStorage("propagationNodeModeEnabled")) public var nodeModeEnabled: Bool = false
```

In `AppFeature.Action`:

```swift
        case setNodeMode(Bool)
```

- [ ] **Step 4: Handle the action and apply on connect**

Add the case:

```swift
            case let .setNodeMode(enabled):
                state.$nodeModeEnabled.withLock { $0 = enabled }
                return .send(.node(.setNodeMode(enabled)))
```

In the existing `interfaceConnected` handler, append node-mode to the effects it already builds (keep `registerDelivery` and the propagation-client wiring exactly as they are):

```swift
                if state.nodeModeEnabled {
                    effects.append(.send(.node(.setNodeMode(true))))
                }
```

- [ ] **Step 5: Add the Settings toggle**

In `ReTiCaMsgr/SettingsView.swift`, add a section (the `Propagation Node` section configures the node we *use*; this one is about *being* one):

```swift
                Section("Run as Propagation Node") {
                    Toggle("Act as a propagation node", isOn: Binding(
                        get: { store.nodeModeEnabled },
                        set: { store.send(.setNodeMode($0)) }
                    ))
                    Text("Stores and forwards messages for other users while this app is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
```

- [ ] **Step 6: Run the tests — expect PASS**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`

- [ ] **Step 7: Mutation-verify**

Mutate in ONE batch: in `.setNodeMode` return `.none` instead of forwarding; and delete the `if state.nodeModeEnabled` block from `interfaceConnected`. Run both new tests — both must FAIL. Revert; run — must PASS.

- [ ] **Step 8: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgr/SettingsView.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift
```
Then `git commit -F /tmp/ReTiCaMsgr/commit-task6.txt` and verify the trailer.

---

### Task 7: App — persistence and launch rehydrate

**Repo:** app `/Users/ell/development/ios/apps/ReTiCaMsgr`

**Files:**
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/PropagationEntryRow.swift`
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Database.swift`
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift`
- Test: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`

**Why:** a node that forgets its backlog on relaunch is not a node. The library stays pure (no file I/O in ReTiCA), so the host mirrors the store using Task 1's `storedEntries` / `purged` signals, surfaced by Task 3 as `messagesStored` / `messagesPurged`.

**Interfaces:**
- Consumes: `LXMFServiceNode.Action.Delegate.messagesStored(entries:)` / `.messagesPurged(transientIds:)` (Task 3); `PropagationStore.Entry` (`transientId`, `destinationHash`, `lxmfData`).
- Produces: table `propagationEntries`; `AppFeature.Action.rehydratePropagationStore([Data])`.

- [ ] **Step 1: Write the failing tests**

Append to `AppFeatureTests.swift`:

```swift
/// Ingested entries are mirrored to the database so they survive relaunch.
@MainActor @Test func storedPropagationEntriesArePersisted() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    let tid = Data(repeating: 0x11, count: 32)
    let dest = Data(repeating: 0xAA, count: 16)
    let bytes = dest + Data("payload".utf8)
    let entry = PropagationStore.Entry(transientId: tid, destinationHash: dest, lxmfData: bytes)

    await store.send(.node(.delegate(.messagesStored(entries: [entry]))))
    try await Task.sleep(nanoseconds: 50_000_000)

    let rows = try await db.read { try PropagationEntryRow.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows[0].transientIdHex == tid.hexString)
    #expect(rows[0].lxmfData == bytes)
}

/// Purged entries are deleted from the mirror, so the database cannot drift from the store.
@MainActor @Test func purgedPropagationEntriesAreDeleted() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    let tid = Data(repeating: 0x22, count: 32)
    let dest = Data(repeating: 0xBB, count: 16)
    let entry = PropagationStore.Entry(transientId: tid, destinationHash: dest,
                                       lxmfData: dest + Data("gone".utf8))

    await store.send(.node(.delegate(.messagesStored(entries: [entry]))))
    try await Task.sleep(nanoseconds: 50_000_000)
    await store.send(.node(.delegate(.messagesPurged(transientIds: [tid]))))
    try await Task.sleep(nanoseconds: 50_000_000)

    let rows = try await db.read { try PropagationEntryRow.all.fetchAll($0) }
    #expect(rows.isEmpty)
}

/// On launch the persisted backlog is restored into the in-memory store, so the node serves it again.
@MainActor @Test func propagationStoreRehydratesOnLaunch() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { $0.$nodeModeEnabled.withLock { $0 = true } }
    await store.send(.setNodeMode(true))

    // A real stamped entry so it survives the store's stamp enforcement.
    let recipient = Identity()
    let sender = Identity()
    let msg = LXMessage.create(source: sender,
                               destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("kept".utf8))
    let (container, tid) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient,
                                                timestamp: 1700000000.5, stampCost: 4)
    let entryBytes = LXMFPropagation.parseContainer(container)!.entries[0]

    try await db.write {
        try PropagationEntryRow.insert {
            PropagationEntryRow(transientIdHex: tid.hexString,
                                destinationHashHex: LXMFPropagation.destinationHash(lxmfData: entryBytes)!.hexString,
                                lxmfData: entryBytes,
                                storedAt: Date(timeIntervalSince1970: 1700000000.5))
        }.execute($0)
    }

    await store.send(.onLaunch)
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(store.state.node.pn.store.contains(transientId: tid))
}
```

**Implementer note:** if this test file has an established way to await effect completion (rather than `Task.sleep`), use it. Also set the app's `minStampCost` so `stampCost: 4` entries are accepted — see Step 4.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter Propagation`
Expected: FAIL — `PropagationEntryRow` does not exist.

- [ ] **Step 3: Create the row type**

`ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/PropagationEntryRow.swift`:

```swift
import Foundation
import SQLiteData

/// One stored propagation entry, mirrored from the in-memory `PropagationStore` so a node's
/// store-and-forward backlog survives relaunch. `transientIdHex` is the LXMF transient_id (hex) —
/// the store's dedup key; `lxmfData` is the exact stamped bytes the node ingested and re-serves.
@Table
public struct PropagationEntryRow: Identifiable, Equatable, Sendable {
    public var id: String { transientIdHex }
    public var transientIdHex: String
    public var destinationHashHex: String
    public var lxmfData: Data
    public var storedAt: Date

    public init(transientIdHex: String, destinationHashHex: String, lxmfData: Data, storedAt: Date) {
        self.transientIdHex = transientIdHex
        self.destinationHashHex = destinationHashHex
        self.lxmfData = lxmfData
        self.storedAt = storedAt
    }
}
```

- [ ] **Step 4: Add the migration**

In `Database.swift`, inside `migrator()` before `return m`:

```swift
        m.registerMigration("createPropagationEntries") { db in
            try db.create(table: "propagationEntryRows") { t in
                t.primaryKey("transientIdHex", .text).notNull()
                t.column("destinationHashHex", .text).notNull()
                t.column("lxmfData", .blob).notNull()
                t.column("storedAt", .datetime).notNull()
            }
        }
```

**Implementer note:** the table name must match what `@Table` derives for `PropagationEntryRow` (the existing `Message` type maps to `messages`). Check the derived name and use it — if it differs from `propagationEntryRows`, use the derived one, or set it explicitly the way this codebase does for `Message`.

- [ ] **Step 5: Mirror and rehydrate in `AppFeature`**

Add the rehydrate action to `AppFeature.Action`:

```swift
        case rehydratePropagationStore([Data])
```

Add the three cases:

```swift
            case let .node(.delegate(.messagesStored(entries))):
                let rows = entries.map {
                    PropagationEntryRow(transientIdHex: $0.transientId.hexString,
                                        destinationHashHex: $0.destinationHash.hexString,
                                        lxmfData: $0.lxmfData,
                                        storedAt: date.now)
                }
                return .run { [database] _ in
                    try await database.write { db in
                        for row in rows { try PropagationEntryRow.upsert { row }.execute(db) }
                    }
                }
```

**This MUST be insert-or-replace, not a plain insert.** On launch, rehydrate feeds the persisted
entries back through `ingestContainer`; the in-memory store is empty, so every entry counts as newly
added and `messagesStored` fires again — for rows that are already in the database. A plain
`PropagationEntryRow.insert` would then throw on the `transientIdHex` primary key. Use this codebase's
SQLiteData idiom for upsert / insert-or-replace (check what `Message` uses and what the installed
SQLiteData version exposes; if `upsert` is unavailable, delete-then-insert inside the same `write`
transaction, or add an `OR REPLACE` conflict policy). Verify with the rehydrate test in Step 1 — run it
twice in a row if needed to prove no PK error.

```swift

            case let .node(.delegate(.messagesPurged(ids))):
                let hexes = ids.map(\.hexString)
                return .run { [database] _ in
                    try await database.write { db in
                        try PropagationEntryRow.where { $0.transientIdHex.in(hexes) }.delete().execute(db)
                    }
                }

            case let .rehydratePropagationStore(entries):
                // Restore through the tested ingest path (re-validates + re-dedups) rather than a bypass.
                guard !entries.isEmpty else { return .none }
                let container = LXMFPropagation.container(timestamp: date.now.timeIntervalSince1970,
                                                          entries: entries)
                return .send(.node(.pn(.ingestContainer(container))))
```

In `.onLaunch`, add a third effect that loads the backlog:

```swift
                    .run { [database] send in
                        let rows = try await database.read { try PropagationEntryRow.all.fetchAll($0) }
                        await send(.rehydratePropagationStore(rows.map(\.lxmfData)))
                    }
```

**Stamp-cost note:** rehydrated entries pass back through stamp validation, so the app's node must enforce a cost these entries satisfy. Construct the node with the app's chosen `minStampCost` in `AppFeature.State.init` (Task 3 default is `LXMFPropagation.defaultPropagationStampCost`); for the test above to pass, the app's value must be ≤ 4, so pass `minStampCost: 4` explicitly in `AppFeature.State.init` and note it in your report as the app's advertised/enforced cost.

- [ ] **Step 6: Run the tests — expect PASS**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`

- [ ] **Step 7: Mutation-verify**

Mutate in ONE batch: make `messagesStored` return `.none`; make `messagesPurged` return `.none`; make `rehydratePropagationStore` return `.none`. Run the three new tests — all must FAIL. Revert; run — must PASS.

- [ ] **Step 8: Build the iOS app**

Run:
```bash
xcodebuildmcp simulator build --simulator-id 5AF38BDA-B932-4C8F-AA6E-AD46A4688FE3 --project-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgr.xcodeproj --scheme ReTiCaMsgr
```
Expected: build succeeds (catches SwiftUI-side breakage the SwiftPM build misses).

- [ ] **Step 9: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/PropagationEntryRow.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Database.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift
```
Then `git commit -F /tmp/ReTiCaMsgr/commit-task7.txt` and verify the trailer.

---

## Live interop validation (controller-run, after Task 7)

Not optional. Every propagation interop bug found so far — the missing PN stamp, the link-request double-encoding, the purge transient_id double-strip — was invisible to stub-based unit tests and surfaced only against real reference code. This is the mirror of the client-side validation already done against `lxmd`.

1. Start the hub: `rnsd --config /tmp/ReTiCaMsgr/reticulum -v` (background).
2. Build/run ReTiCaMsgr on a simulator, Settings → enable **Act as a propagation node**, and note the app's propagation address.
3. Drive a **reference Python LXMF client** (env `rns`, `/Users/ell/opt/anaconda3/envs/rns/bin/python`) that: sets `outbound_propagation_node` to the app's address, sends a message addressed to a second identity via propagation, then syncs as that second identity and downloads it. Write the driver to `/tmp/ReTiCaMsgr/` as a file and run it as one command (no `python -c`).
4. Confirm: the app ingests and persists the offer; the reference client's phase-1 list returns the transient_id; phase-2 returns a blob that opens to the original message; phase-3 purge **evicts** (this is the exact invariant the earlier double-strip bug broke — verify the row disappears from the app's database).
5. Relaunch the app and confirm the backlog is still served (persistence).

Record the outcome in the ledger. Any mismatch is a real interop defect — diagnose with `superpowers:systematic-debugging` before declaring done.

---

## Deferred (explicitly out of scope)

PN↔PN mesh peering / peer registry / auto-sync · inbound proving for genuine client acks · time-based expiry/GC · headless macOS daemon · periodic re-announce · BLE-as-PN specifics · destination unregistration on disable.
