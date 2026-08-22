# Unlock Send from Persisted Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a relaunch or reconnect, enable the Send button for any peer with a persisted, now-live path — without waiting for a fresh inbound announce.

**Architecture:** The Send gate reads `AppFeature.State.reachablePeers`, a session-only set written only by the inbound `.pathLearned` handler. Path persistence restores `Transport.learned` from disk but emits no `.pathLearned`, so the set is empty after launch. Add a file-scope helper that seeds `reachablePeers` from currently-reachable learned destinations (present in `learned` AND whose `interfaceID` is a registered interface), and call it at the two points where reachability becomes true: `interfaceConnected` (primary) and the app's `rehydrateLearnedDestinations` handler (launch-race guard). App-side only — no change to the ReTiCA library, no new announce.

**Tech Stack:** Swift, The Composable Architecture (TCA / swift-testing), GRDB via SQLiteData. Package: `ReTiCaMsgrCore` (a local SPM package inside the ReTiCaMsgr app repo).

## Global Constraints

- Repo: `/Users/ell/development/ios/apps/ReTiCaMsgr`. All edits are in the `ReTiCaMsgrCore` package. **No edits to the ReTiCA library** (`/Users/ell/development/ios/pods/ReTiCA`).
- Commit directly to `main`. No feature branch.
- Commit trailers must start at **column 0** (no indent) or git cannot parse them. Every commit ends with exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
  ```
  After committing, verify with: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr log -1 --format='%(trailers:key=Claude-Session)'` (must echo the trailer, not empty).
- **One command per shell invocation.** No `|`, `&&`, `||`, `;`, `$(...)`, or `xargs`. Redirect a single command's output to a file and read it back if you need to inspect it.
- Run tests with: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter <TestName>` (single test) or without `--filter` for the full suite (91 tests today, ~3 s).
- **Mutation verification is mandatory** (user's global rule): after a task's tests are green, apply the stated mutation, run the task's tests, confirm they go RED, then revert and confirm GREEN again before committing. Do the mutation as a real behavioral change (comment out the seed call), not a syntax break.
- **Do NOT flip `store.exhaustivity` to `.on`.** `makeStore` sets `.off`. `interfaceConnected` arms a long-running maintenance timer; an `.off` store tolerates that in-flight effect at `store.finish()`, an `.on` store rejects it.

---

### Task 1: Seed `reachablePeers` on `interfaceConnected`

Introduce the seed helper and call it when an interface registers. This is the primary fix: after rehydration has filled `Transport.learned` (the common launch ordering), the interface connecting makes those paths usable and unlocks Send.

**Files:**
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` — add a file-scope helper near `syncEndpointHostPort` (currently at `:732`) and add two lines to the `interfaceConnected` handler (`:295-296`).
- Test: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` — add two `@Test` functions.

**Interfaces:**
- Consumes (existing, from ReTiCATransport, already imported/in scope):
  - `LearnedDestination(identity: Identity, appData: Data?, ratchet: Data?, interfaceID: InterfaceID, hops: UInt8, nextHop: Data?, announceEmitted: UInt64, learnedAt: Date = ...)` — has `.interfaceID: InterfaceID`.
  - `InterfaceID(_ rawValue: String)`; `InterfaceProfile.tcp` (a ready-made value for tests).
  - `state.node.client.endpoint.learned: [Data: LearnedDestination]` and `state.node.client.endpoint.interfaces: [InterfaceID: InterfaceProfile]`.
  - `Transport.Action.interfaceConnected(InterfaceID, InterfaceProfile)`, reachable in the app as `.node(.client(.endpoint(.transport(.interfaceConnected(_, _)))))`.
  - `Data.hexString`.
- Produces (used by Task 2):
  - `private func seedReachablePeers(_ state: inout AppFeature.State, from destinations: [Data: LearnedDestination])` — a file-scope free function in `AppFeature.swift`.

- [ ] **Step 1: Write the failing tests**

Add these two functions to `AppFeatureTests.swift` (anywhere among the other `@Test`s; the imports it needs — `ReTiCATransport`, `ReTiCANode`, `@testable ReTiCaMsgrCore` — are already at the top of the file):

```swift
/// After restart, a persisted path that is now reachable (interface registered) must unlock Send —
/// i.e. land in `reachablePeers` — WITHOUT any inbound announce. This is the UI-gate assertion the
/// sibling test `learnedPathSurvivesRestartAndIsReachableWithoutAnnounce` deliberately does NOT make
/// (that one proves only transport-level routability).
@MainActor @Test func persistedPathUnlocksSendOnInterfaceConnect() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let peer = Identity()
    let peerDeliveryHash = LXMessage.deliveryHash(identityHash: peer.hash)
    let peerDeliveryHex = peerDeliveryHash.hexString

    let destination = LearnedDestination(
        identity: peer,
        appData: nil,
        ratchet: nil,
        interfaceID: InterfaceID("tcp"),
        hops: 1,
        nextHop: nil,
        announceEmitted: 1700000000,
        learnedAt: Date(timeIntervalSince1970: 1700000000)
    )

    let store = makeStore(db, identity: me)

    // Rehydrate the persisted path into Transport.learned (no inbound announce, no interface yet).
    await store.send(.node(.client(.endpoint(.transport(
        .rehydrateLearnedDestinations([peerDeliveryHash: destination]))))))

    // Precondition: the path is in learned but Send is still gated (interface not registered).
    #expect(!store.state.reachablePeers.contains(peerDeliveryHex),
            "before an interface registers, the rehydrated path is not yet reachable")

    // The interface registers → paths become usable → seed runs inside the interfaceConnected handler.
    await store.send(.node(.client(.endpoint(.transport(
        .interfaceConnected(InterfaceID("tcp"), .tcp))))))

    #expect(store.state.reachablePeers.contains(peerDeliveryHex),
            "a persisted, now-reachable path must unlock Send without an inbound announce")

    await store.skipReceivedActions(strict: false)
    await store.finish()
}

/// With no persisted path, connecting must NOT seed any phantom peer — Send stays gated.
@MainActor @Test func noPersistedPathLeavesSendGatedOnConnect() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())

    await store.send(.node(.client(.endpoint(.transport(
        .interfaceConnected(InterfaceID("tcp"), .tcp))))))

    #expect(store.state.reachablePeers.isEmpty,
            "no persisted path → nothing to seed → Send stays gated after connect")

    await store.skipReceivedActions(strict: false)
    await store.finish()
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter persistedPathUnlocksSendOnInterfaceConnect`

Expected: `persistedPathUnlocksSendOnInterfaceConnect` FAILS at the final `#expect` (reachablePeers does not contain the peer, because nothing seeds it yet). `noPersistedPathLeavesSendGatedOnConnect` will PASS already (it asserts the set stays empty) — that is fine; it is a guard against the fix over-seeding.

- [ ] **Step 3: Add the seed helper**

In `AppFeature.swift`, next to the other file-scope helpers (just after `syncEndpointHostPort(_:)` ends at `:758`, before `reloadConversations` at `:761`), add:

```swift
// Seed `reachablePeers` (the Send gate) from learned destinations that are reachable RIGHT NOW:
// present in `destinations` AND whose interface is currently registered. `interfaces` is EMPTY
// whenever the socket is down (every interface deregisters), so this no-ops until an interface
// registers — the same reachability test `reachableLearned` uses (ReTiCA Transport.swift:159-163)
// and DiagnosticsSnapshot's pathsLayer uses. Idempotent (Set insert); safe to call from multiple
// sites. Read `interfaces` into a local FIRST so we are not reading and mutating `state` in the
// same access.
private func seedReachablePeers(_ state: inout AppFeature.State,
                                from destinations: [Data: LearnedDestination]) {
    let interfaces = state.node.client.endpoint.interfaces
    guard !interfaces.isEmpty else { return }
    for (hash, entry) in destinations where interfaces[entry.interfaceID] != nil {
        state.reachablePeers.insert(hash.hexString)
    }
}
```

- [ ] **Step 4: Call the helper from `interfaceConnected`**

In the `interfaceConnected` handler, immediately after `state.connection = .connected` (`AppFeature.swift:296`) and before the `let launchName = ...` line (`:309`), insert:

```swift
// Restore the Send gate for peers whose persisted path is now usable (interface just registered).
// The Transport Scope has already run (child reducers reduce before this Reduce body — see the
// pathLearned comment), so `endpoint.interfaces` already contains the new interface here.
let learnedForSeed = state.node.client.endpoint.learned
seedReachablePeers(&state, from: learnedForSeed)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter persistedPathUnlocksSendOnInterfaceConnect`
Expected: PASS.

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter noPersistedPathLeavesSendGatedOnConnect`
Expected: PASS.

- [ ] **Step 6: Mutation-verify the seed is load-bearing**

Comment out the `seedReachablePeers(&state, from: learnedForSeed)` call added in Step 4 (leave the `let learnedForSeed` line or comment both).

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter persistedPathUnlocksSendOnInterfaceConnect`
Expected: FAIL (final `#expect`). `noPersistedPathLeavesSendGatedOnConnect` still passes — expected, it is not the target of this mutation.

Then revert the mutation (restore the call).

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter persistedPathUnlocksSendOnInterfaceConnect`
Expected: PASS.

- [ ] **Step 7: Run the full package suite (regression check)**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`
Expected: all tests pass (was 91; now 93 with the two new tests). If an existing *exhaustive* (`.on`) test that sends `interfaceConnected` now fails because it asserts full post-action state, update that test's expected state to include the `reachablePeers` insertion — do not weaken the new behavior. (No such test is expected; most stores are `.off`.)

- [ ] **Step 8: Commit**

Stage only the two files:
`git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`

Commit (write the message to a temp file and use `-F`, since the trailers must be at column 0):
```
feat: seed reachablePeers from persisted paths on interface connect

Path persistence restored Transport.learned across relaunch but the Send
gate (reachablePeers) was written only by inbound pathLearned, so Send
stayed disabled after returning despite a usable persisted path. Seed
reachablePeers from currently-reachable learned destinations when an
interface registers.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```

Then verify the trailer parsed:
`git -C /Users/ell/development/ios/apps/ReTiCaMsgr log -1 --format='%(trailers:key=Claude-Session)'`
Expected: prints the `Claude-Session:` line (not empty).

---

### Task 2: Launch-race guard in the rehydrate handler

Cover the ordering where the interface connects *before* the DB rehydration lands. In that case `interfaceConnected`'s seed (Task 1) ran against an empty `learned` and missed the peer. The app holds the rehydration payload in its own `rehydrateLearnedDestinations` handler, so seed from the payload there when already connected.

**Files:**
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` — the `.rehydrateLearnedDestinations` handler (`:679-689`).
- Test: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` — add one `@Test`.

**Interfaces:**
- Consumes: `seedReachablePeers(_:from:)` from Task 1; the app action `AppFeature.Action.rehydrateLearnedDestinations([Data: LearnedDestination])` (case at `:679`); `state.connection` (`Connection` enum with `.connected`).
- Produces: nothing new (final task).

- [ ] **Step 1: Write the failing test**

Add to `AppFeatureTests.swift`:

```swift
/// Launch race: rehydration and the TCP connect are both dispatched from onLaunch. If the interface
/// registers BEFORE the DB read lands, interfaceConnected's seed found an empty learned table. The
/// rehydrate handler must then seed from its own payload so Send still unlocks.
@MainActor @Test func rehydrationAfterConnectStillUnlocksSend() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let peer = Identity()
    let peerDeliveryHash = LXMessage.deliveryHash(identityHash: peer.hash)
    let peerDeliveryHex = peerDeliveryHash.hexString

    let destination = LearnedDestination(
        identity: peer,
        appData: nil,
        ratchet: nil,
        interfaceID: InterfaceID("tcp"),
        hops: 1,
        nextHop: nil,
        announceEmitted: 1700000000,
        learnedAt: Date(timeIntervalSince1970: 1700000000)
    )

    let store = makeStore(db, identity: me)

    // Interface connects FIRST — learned is still empty, so this seed finds nothing.
    await store.send(.node(.client(.endpoint(.transport(
        .interfaceConnected(InterfaceID("tcp"), .tcp))))))
    #expect(!store.state.reachablePeers.contains(peerDeliveryHex),
            "connect-before-rehydrate: nothing to seed yet")

    // Rehydration lands AFTER connect — the app-level handler seeds from the payload.
    await store.send(.rehydrateLearnedDestinations([peerDeliveryHash: destination]))

    #expect(store.state.reachablePeers.contains(peerDeliveryHex),
            "rehydration after connect must unlock Send via the launch-race guard")

    await store.skipReceivedActions(strict: false)
    await store.finish()
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter rehydrationAfterConnectStillUnlocksSend`
Expected: FAIL at the final `#expect` (the current rehydrate handler only forwards to Transport; it does not seed `reachablePeers`, and Task 1's seed already ran while `learned` was empty).

- [ ] **Step 3: Add the guard to the rehydrate handler**

In the `.rehydrateLearnedDestinations` handler (`AppFeature.swift:679-689`), after the `guard !destinations.isEmpty else { return .none }` line (`:688`) and before the `return .send(...)` (`:689`), insert:

```swift
// Launch race: if the interface already registered before this DB read landed, the seed in
// interfaceConnected (Task 1) ran against an empty learned table and missed these entries. Seed
// from the payload now — only those whose interface is currently registered (same reachability
// test). No-op when disconnected: interfaceConnected will seed from Transport.learned instead.
if state.connection == .connected {
    seedReachablePeers(&state, from: destinations)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter rehydrationAfterConnectStillUnlocksSend`
Expected: PASS.

- [ ] **Step 5: Mutation-verify the guard is load-bearing**

Comment out the `if state.connection == .connected { seedReachablePeers(&state, from: destinations) }` block from Step 3.

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter rehydrationAfterConnectStillUnlocksSend`
Expected: FAIL.

Revert the mutation.

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter rehydrationAfterConnectStillUnlocksSend`
Expected: PASS.

- [ ] **Step 6: Run the full package suite (regression check)**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`
Expected: all pass (94 tests now). In particular `learnedPathSurvivesRestartAndIsReachableWithoutAnnounce` and `rapidPathLearnedEventsAreCoalesced` still pass — the rehydrate handler still forwards to Transport unchanged.

- [ ] **Step 7: Commit**

Stage only:
`git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`

Commit with `-F` (trailers at column 0):
```
feat: seed reachablePeers when rehydration lands after connect

Covers the launch ordering where the interface registers before the DB
rehydration completes: interfaceConnected's seed found an empty learned
table, so seed from the rehydration payload in the app handler when
already connected.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```

Verify: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr log -1 --format='%(trailers:key=Claude-Session)'` prints the trailer.

---

## Notes for the executor

- **Known limitation, intentional (do not "fix"):** `reachablePeers` is still never *removed* from. A peer stays in the set after its path goes stale mid-session (the send then fails at the transport). Making the gate track real-time reachability (add *and* remove) is a separate, larger change deliberately out of scope for this plan (see the spec's "Out of scope").
- **No ReTiCA edits.** If a step seems to want a library change, stop — it does not; everything is in `ReTiCaMsgrCore`.
- **Verifying the device behavior** (Send enabled after a real relaunch) is not part of these tests; it is covered by the separate device-test procedure. These tests prove the reducer wiring; the device pass confirms the end-to-end effect.
