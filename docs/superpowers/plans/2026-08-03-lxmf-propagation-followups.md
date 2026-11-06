# LXMF Propagation Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the deferred LXMF-propagation follow-ups: a genuine `propagationAccepted` (via link data-packet proofs), sync hardening (IDENTIFY ordering, purge, 3-element fetch), PN-side inbound stamp validation, and small cleanups.

**Architecture:** Add a general link data-packet proof/receipt capability to `LinkSession` (RNS-conformant), then send small propagation offers as proof-requesting link packets and gate `propagationAccepted` on the PN's proof (Resource path unchanged for large). Independent, smaller changes to the sync path, the PN ingest, and a shared strip helper. One app-repo task adds two test assertions.

**Tech Stack:** Swift 6, TCA (ComposableArchitecture), ReTiCA (RNS/LXMF), SQLiteData (app tests only).

## Global Constraints

- **Two repos.** Tasks 1–5 = **ReTiCA pods repo** `/Users/ell/development/ios/pods/ReTiCA` (`git -C /Users/ell/development/ios/pods/ReTiCA`). Task 6 = **app repo** `/Users/ell/development/ios/apps/ReTiCAMsgr` (`git -C /Users/ell/development/ios/apps/ReTiCAMsgr`). Both commit directly to `main`.
- **Commit message trailers, verbatim, at COLUMN 0 (no leading whitespace):**
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
  Commit with `git commit -F <file>` (NEVER `-m` — trailers contain `;`); write the message to a file under `/tmp/ReTiCAMsgr/` via an editor tool. After each commit verify: `git -C <repo> log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'` must print the URL; if empty, `git commit --amend -F <file>`.
- **No compound shell commands:** one command per invocation; no `&&`/`||`/`;`/pipes/`xargs`/inline interpreter scripts. A single `>` redirect IS allowed. Edit files with editor tools, never `echo`/heredoc.
- **Three-step mutation verification for every new/changed test.** Where two tests assert opposite branches, use separate mutation passes (revert between).
- **Test commands:** ReTiCA — `swift test --package-path /Users/ell/development/ios/pods/ReTiCA` (large; first build slow; `--filter <name>` for one test). App — `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore`.
- **`.off` TestStore harness (verified this session):** default new TCA tests to `store.exhaustivity = .off`; assert an action did NOT fire by asserting resulting state, using `await store.finish()` + `await store.skipReceivedActions(strict: false)` before the assertion. `TestStore.state` is get-only — arrange initial state at construction.
- **GOTCHA:** after a change to msgpack usage or LinkSession wire code, if a later unrelated test flakes with signal-11/10, run `swift package clean` once.
- **Reference wire format — link data-packet PROOF** (from RNS `Link.prove_packet`/`Packet.validate_link_proof`): a `.proof` packet, `destinationType = .link`, `context = .none`, `contextFlag = false`, `destinationHash = linkID`, **payload = `packetHash(32) ‖ ed25519_signature(64)` = 96 bytes, NOT encrypted**. `packetHash` is the full 32-byte SHA-256 (`Packet.packetHash`) of the DATA packet being proved. The signature is the link peer's Ed25519 signature over that 32-byte hash. The sender matches an inbound proof by `proof.payload.prefix(32) == sentPacket.packetHash` and validates `peerIdentity.validate(signature: proof.payload.suffix(64), message: packetHash)` where, for an initiator, `peerIdentity == state.destinationIdentity` (its Ed25519 half).

---

## Task 1: `LinkSession` link data-packet receipt (send-with-receipt + inbound proof)

**Repo:** ReTiCA pods. **Files:** Modify `Sources/ReTiCATransport/LinkSession.swift`; Test `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift` (or a new `LinkSessionReceiptTests.swift`).

**Interfaces — Produces:**
- `LinkSession.Action.sendWithReceipt(data: Data, token: Data)` — like `.send(data)` but records a delivery receipt; `token` is an opaque caller correlation id.
- `LinkSession.Action.Delegate.packetDelivered(token: Data)` — fires when a matching proof arrives.
- `LinkSession.Action.Delegate.packetDeliveryFailed(token: Data)` — fires on receipt timeout.

Scope note: this task implements only the **sender/initiator** receipt path (send a data packet, receive+validate the peer's proof). ReTiCA *proving* inbound data packets (receiver/PN side) is intentionally OUT of scope here (not needed by the app; would change direct-over-link behavior) — deferred with the PN-serve integration.

- [ ] **Step 1: Write the failing tests**

Add to the test file (uses the existing LinkSession test harness — mirror how `LinkSessionRequestTests` builds an active link between an initiator store and a responder identity; reuse that setup). Two tests:

```swift
// Sender records a receipt and transmits; a valid proof fires packetDelivered(token).
@MainActor @Test func sendWithReceiptDeliveredOnValidProof() async {
    // Build an ACTIVE initiator link whose peer (destinationIdentity) is `pn` (an Identity the test owns).
    // ... (reuse existing harness to reach state == .active with state.destinationIdentity == pn) ...
    let token = Data(repeating: 0x11, count: 32)
    await store.send(.sendWithReceipt(data: Data("hello".utf8), token: token))
    // Capture the transmitted DATA packet from the .transmit delegate, recover its packetHash.
    // (The harness collects transmits; parse the last one with Packet.init(packed:) to get .packetHash.)
    let sentHash = /* packetHash of the transmitted data packet */
    // Build the reference-format proof: payload = sentHash(32) ‖ pn.sign(sentHash)(64), send it inbound.
    let proofPayload = sentHash + pn.sign(sentHash)
    let proofPacket = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                             destinationType: .link, context: .none, contextFlag: false, hops: 0,
                             destinationHash: linkID, transportId: nil, payload: proofPayload)
    await store.send(.received(try! proofPacket... /* however the harness injects an inbound packet */))
    await store.receive { if case .delegate(.packetDelivered(token)) = $0 { return true }; return false }
}

// A proof with a bad signature does NOT fire packetDelivered.
@MainActor @Test func sendWithReceiptIgnoresInvalidProof() async {
    // same setup + send .sendWithReceipt(token)
    let sentHash = /* ... */
    let badProof = sentHash + Data(repeating: 0, count: 64)   // wrong signature
    // inject badProof packet
    await store.finish()
    await store.skipReceivedActions(strict: false)
    // packetDelivered must NOT have fired: assert the receipt is still pending
    #expect(store.state.pendingDataReceipts[sentHash] != nil)
}
```
(Fill the harness-specific setup/injection by copying the active-link construction and inbound-packet injection already used in `LinkSessionRequestTests`. The point: a byte-correct reference proof resolves the receipt; a bad-signature proof does not.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter LinkSession` (the new tests fail: `sendWithReceipt`/`packetDelivered`/`pendingDataReceipts` undefined).

- [ ] **Step 3: Implement**

In `LinkSession.State` add:
```swift
public var pendingDataReceipts: [Data: Data] = [:]   // sentPacketHash(32) → caller token
```
Add a `CancelID` case: `case receipt(Data)`.
Add `Action` cases (next to `.sendRequest`):
```swift
case sendWithReceipt(data: Data, token: Data)
case dataProofDeadline(packetHash: Data)
```
Add `Delegate` cases:
```swift
case packetDelivered(token: Data)
case packetDeliveryFailed(token: Data)
```
Handle `.sendWithReceipt` (mirror the existing `.send(data)` at ~line 479, but keep the packet's `packetHash` and record the receipt):
```swift
case let .sendWithReceipt(data, token):
    guard state.status == .active else { return .none }
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .none, contextFlag: false, hops: 0,
                        destinationHash: state.linkID, transportId: nil,
                        payload: Link.encrypt(data, sessionKey: state.sessionKey))
    let packetHash = packet.packetHash            // 32-byte full hash
    guard let raw = try? packet.packed() else { return .none }
    state.pendingDataReceipts[packetHash] = token
    let timeout = (state.rtt ?? 0.5) * 6 + 11.25
    return .merge(
        .send(.delegate(.transmit(state.interfaceID, raw))),
        .run { send in
            try await clock.sleep(for: .seconds(timeout)); await send(.dataProofDeadline(packetHash: packetHash))
        }.cancellable(id: CancelID.receipt(packetHash), cancelInFlight: true))
```
Add the timeout handler:
```swift
case let .dataProofDeadline(packetHash):
    guard let token = state.pendingDataReceipts[packetHash] else { return .none }
    state.pendingDataReceipts[packetHash] = nil
    return .send(.delegate(.packetDeliveryFailed(token: token)))
```
Add an inbound case in the big `received` switch (near the other proof cases). A link data-packet proof is `packetType == .proof`, `context == .none`, unencrypted 96-byte payload:
```swift
case (_, .active, .proof, .none):
    guard packet.payload.count == 96 else { return .none }
    let proofHash = Data(packet.payload.prefix(32))
    let signature = Data(packet.payload.suffix(64))
    guard let token = state.pendingDataReceipts[proofHash],
          let peer = state.destinationIdentity,             // initiator: peer we opened the link to
          peer.validate(signature: signature, message: proofHash)
    else { return .none }
    state.pendingDataReceipts[proofHash] = nil
    return .merge(.cancel(id: CancelID.receipt(proofHash)),
                  .send(.delegate(.packetDelivered(token: token))))
```
(If `Identity.validate(signature:message:)` is not the exact spelling, use the same validate call the existing `Link.validateProof` path uses; the message is the 32-byte `proofHash`, the key is the peer's Ed25519 half — for an initiator that is `state.destinationIdentity`.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter LinkSession` → PASS. Then the full suite once: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA` (existing link/resource/request tests must stay green — this only ADDS actions/cases).

- [ ] **Step 5: Mutation-verify**

Mutation A: in the inbound proof case, drop the `peer.validate(...)` guard (accept any proof) → `sendWithReceiptIgnoresInvalidProof` fails (delivers on a bad sig). Revert.
Mutation B: in `.sendWithReceipt`, do not insert into `pendingDataReceipts` → `sendWithReceiptDeliveredOnValidProof` fails (no receipt to match). Revert. Rerun clean → pass.

- [ ] **Step 6: Commit**

Message subject: `feat: LinkSession link data-packet receipt (send-with-receipt + proof)`. Stage the two changed files. Commit with `-F`, verify the trailer parses.

---

## Task 2: Propagation packet-when-small + genuine `propagationAccepted`

**Repo:** ReTiCA pods. **Files:** Modify `Sources/ReTiCANode/LXMFRouter.swift`, `Sources/ReTiCANode/LXMFNode.swift`, `Sources/ReTiCANode/Endpoint.swift` (thread the new send); Test `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (or the propagation test file).

**Interfaces — Consumes:** `LinkSession.Action.sendWithReceipt(data:token:)` + `Delegate.packetDelivered(token:)` (Task 1). **Produces:** the propagation send chooses a link packet (with receipt, token = `message.hash`) when the container fits, else a Resource.

- [ ] **Step 1: Write the failing test**

In the router test file, drive an active-PN-link propagation send and assert the SMALL-container path uses the packet+receipt route and that a `packetDelivered(token: message.hash)` resolves to `propagationAccepted`:

```swift
// With an active PN link, a small propagation container is sent as a proof-requesting packet,
// and a matching packetDelivered → propagationAccepted for that message.hash.
@MainActor @Test func propagationSmallSendsPacketAndAcceptsOnProof() async {
    // Reuse the router harness: set outboundPropagationNode = pn, mark the PN link active,
    // dispatch .sendViaPropagation(message:, propagationPacked:) with a small container (<= 431 bytes).
    // Assert the delegate emitted is the packet route (see Produces below), carrying token == message.hash.
    // Then feed .delivered(messageHash: message.hash) (the router's existing delivered path, which the
    // node maps from packetDelivered) and assert .delegate(.propagationAccepted(messageHash: message.hash)).
}
```
(Exact assertions depend on which delegate the router emits for the packet route — define that in Step 3 and match the test to it.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter propagationSmallSendsPacket` → FAIL (packet route not implemented).

- [ ] **Step 3: Implement**

In `LXMFRouter`, the propagation send (currently, on an active PN link, emits `.delegate(.sendPropagated(linkID:, propagationPacked:))`). Split by size using the link MDU constant (431):
```swift
// where it currently emits .sendPropagated for an active link:
if propagationPacked.count <= 431 {
    // small: send as a proof-requesting link packet; token correlates the eventual proof to this message
    return .merge(.send(.delegate(.sendPropagatedPacket(linkID: linkID, propagationPacked: propagationPacked,
                                                        messageHash: message.hash))),
                  /* keep the existing arm(...propagated...) + timer logic */)
} else {
    return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: propagationPacked))),
                  /* existing arm/timer */)
}
```
Add the delegate case `case sendPropagatedPacket(linkID: Data, propagationPacked: Data, messageHash: Data)`.
In `LXMFNode`, map the new delegate to `LinkSession` send-with-receipt (via `Endpoint`), and map `packetDelivered(token)` back to the router's delivered path:
```swift
case let .router(.delegate(.sendPropagatedPacket(linkID, packed, messageHash))):
    return .send(.endpoint(.sendWithReceiptOverLink(linkID: linkID, data: packed, token: messageHash)))

case let .endpoint(.delegate(.packetDelivered(token))):
    return .send(.router(.delivered(messageHash: token)))     // token == message.hash → propagationAccepted
```
Add `Endpoint.Action.sendWithReceiptOverLink(linkID:data:token:)` that forwards to the target `LinkSession`'s `.sendWithReceipt(data:token:)`, and surface `LinkSession`'s `packetDelivered`/`packetDeliveryFailed` as `Endpoint.delegate(.packetDelivered/​.packetDeliveryFailed)` (mirror how `resourceConcluded`/`linkDataReceived` are already surfaced through Endpoint). Also map `packetDeliveryFailed(token)` → `.router(.retryDue(messageHash: token))` or the existing failure path so the message isn't lost (mirror the Resource failure handling).

(The router's existing `.delivered(messageHash:)` → `propagationAccepted` mapping for a `.propagated` resend is unchanged — Task 2 just feeds it from `packetDelivered` instead of only `resourceDeliveredOnLink`.)

- [ ] **Step 4: Run to verify it passes**

Run the filtered test, then the full suite. Existing propagation/sync tests that assumed the Resource route for small containers must be updated to expect the packet route (or seed a large container to keep the Resource route). Update them; keep assertions intact.

- [ ] **Step 5: Mutation-verify**

Mutation: invert the size guard (`> 431` instead of `<= 431`) → `propagationSmallSendsPacketAndAcceptsOnProof` fails (small goes Resource route). Revert → pass.

- [ ] **Step 6: Commit**

Subject: `feat: propagation send-as-packet-when-small + genuine propagationAccepted`.

---

## Task 3: Sync — IDENTIFY-before-request ordering + phase-3 purge + 3-element fetch

**Repo:** ReTiCA pods. **Files:** Modify `Sources/ReTiCANode/LXMFNode.swift` (sync handlers) and `Sources/ReTiCANode/LXMFRouter.swift` if the purge needs a router→node hop; Test `Tests/ReTiCANodeTests/LXMFNodeSyncTests.swift`.

- [ ] **Step 1: Write the failing tests**

```swift
// requestMessageList sends IDENTIFY before the /get request (order matters).
@MainActor @Test func syncIdentifiesBeforeRequesting() async {
    // Drive .router(.delegate(.requestMessageList(linkID))); collect the ordered endpoint effects;
    // assert identifyOverLink is emitted/transmitted before sendRequestOverLink("/get").
}

// After messagesDownloaded, a purge /get [nil, haves] is sent carrying the downloaded transient_ids.
@MainActor @Test func syncPurgesAfterDownload() async {
    // Drive the awaitingMessages responseReceived path with 1 blob; after messagesDownloaded,
    // assert a sendRequestOverLink(path:"/get", data: msgpack([.null, .array([.bin(tid)])])) is emitted.
}
```

- [ ] **Step 2: Run to verify they fail.**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter LXMFNodeSync` → FAIL.

- [ ] **Step 3: Implement**

**3a — ordering:** replace the current `requestMessageList` `.merge(identify, request)` with a single sequential `.run`:
```swift
case let .router(.delegate(.requestMessageList(linkID))):
    state.syncPhase[linkID] = .awaitingList
    let identity = state.identity
    return .run { send in
        await send(.endpoint(.identifyOverLink(linkID: linkID, identity: identity)))
        await send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/get",
                                                  data: MsgPack.encode(.array([.null, .null])))))
    }
```
**3b — purge:** in the `.awaitingMessages` branch of `responseReceived`, after computing `tids` and sending `messagesDownloaded`, also send the purge request:
```swift
if !tids.isEmpty {
    effects.append(.send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/get",
        data: MsgPack.encode(.array([.null, .array(tids.map { .bin($0) })]))))))
}
```
**3c — 3-element fetch:** in the `.awaitingList`→`requestMessages` path (`LXMFRouter.requestMessages`/the node's phase-2 send), change the payload from `[wants, haves]` to `[wants, haves, limit]` where `limit` is a new constant, e.g. `LXMFRouter.propagationTransferLimitKB = 0` (0 = no limit; a `.uint(0)` third element):
```swift
let payload = MsgPack.encode(.array([.array(wants.map { .bin($0) }),
                                     .array(haves.map { .bin($0) }),
                                     .uint(0)]))
```

- [ ] **Step 4: Run to verify they pass** (filtered, then full suite; update any existing sync test that asserted the 2-element fetch or the `.merge` ordering).

- [ ] **Step 5: Mutation-verify**

Mutation A: swap the two `await send` lines in 3a (request before identify) → `syncIdentifiesBeforeRequesting` fails. Mutation B: remove the purge append → `syncPurgesAfterDownload` fails. Revert both → pass.

- [ ] **Step 6: Commit**

Subject: `feat: LXMF sync — identify-before-request, phase-3 purge, 3-element fetch`.

---

## Task 4: PN-side inbound stamp validation

**Repo:** ReTiCA pods. **Files:** Modify `Sources/ReTiCANode/PropagationStore.swift` (and/or `PropagationNode.swift`); Test the corresponding test file.

**Interfaces — Consumes:** `LXStamper.validatePnStamp(transientData:targetCost:)`.

- [ ] **Step 1: Write the failing test**

```swift
// ingest rejects an entry whose stamp is under the min cost / absent; accepts a valid one.
@Test func ingestRejectsUnderCostStamp() {
    var store = PropagationStore(/* ... minStampCost: 8 ... */)
    let validEntry = /* destHash‖ciphertext‖ generatePnStamp(tid, targetCost: 8) */
    let badEntry   = /* same core, but a random 32-byte tail (invalid stamp) */
    store.ingest(container(with: validEntry))
    store.ingest(container(with: badEntry))
    #expect(store.transientIds.count == 1)          // only the valid one stored
}
```

- [ ] **Step 2: Run to verify it fails.** (`ingest` currently stores unconditionally.)

- [ ] **Step 3: Implement**

Give the store/node a `minStampCost: Int` (default `LXMFPropagation.defaultPropagationStampCost` = 16; the test uses a lower value). In `ingest`, before storing each entry, require a valid stamp:
```swift
guard LXStamper.validatePnStamp(transientData: entry, targetCost: minStampCost) != nil else { continue }
```
`validatePnStamp` recomputes `transient_id = full_hash(entry.dropLast(32))` — use its returned `transientId` as the dedup key (consistent with the sender + the strip logic).

- [ ] **Step 4: Run to verify it passes** (filtered + full suite).

- [ ] **Step 5: Mutation-verify**

Mutation: change the guard to always-accept → `ingestRejectsUnderCostStamp` fails (stores 2). Revert → pass.

- [ ] **Step 6: Commit**

Subject: `feat: propagation-node ingest validates inbound PN stamps`.

---

## Task 5: Shared `strippedCore` helper

**Repo:** ReTiCA pods. **Files:** Modify `Sources/ReTiCA/LXMF/LXMFPropagation+Message.swift` (add helper), and the three call sites: `recoverPacked` (same file), `Sources/ReTiCANode/LXMFNode.swift` (sync `awaitingMessages`), `Sources/ReTiCANode/PropagationStore.swift` (`ingest`); Test where `LXMFPropagation` tests live.

- [ ] **Step 1: Write the failing test**

```swift
@Test func strippedCoreDropsStampWhenPresent() {
    let core = Data(repeating: 0xAB, count: 200)          // a plausible stampless entry
    let stamped = core + Data(repeating: 0xCD, count: 32)  // + 32-byte stamp
    #expect(LXMFPropagation.strippedCore(lxmfData: stamped) == core)
    // A stampless entry recovered via the authenticated path is unchanged by callers; the helper's
    // contract is "drop the trailing 32 bytes if length > destLen+stampSize", matching current sites.
    #expect(LXMFPropagation.strippedCore(lxmfData: core).count == core.count - 32)  // size-based drop
}
```
(Match the helper's exact contract to whatever the three existing sites currently compute — read them first; the helper must be a behavior-preserving extraction, not a new rule.)

- [ ] **Step 2: Run to verify it fails** (`strippedCore` undefined).

- [ ] **Step 3: Implement**

Add `public static func strippedCore(lxmfData: Data) -> Data` capturing the existing size-based strip (drop trailing `LXStamper.stampSize` bytes when the entry is long enough — copy the exact threshold each site uses today). Replace the inline strip at all three call sites with a call to it. Behavior must be identical (the existing propagation round-trip/ingest/sync tests must stay green).

- [ ] **Step 4: Run to verify it passes** (filtered + full suite — the existing round-trip/ingest/sync tests are the real coverage that the extraction preserved behavior).

- [ ] **Step 5: Mutation-verify**

Mutation: make `strippedCore` return `lxmfData` unchanged (no strip) → `strippedCoreDropsStampWhenPresent` fails AND the existing propagation round-trip tests fail. Revert → pass.

- [ ] **Step 6: Commit**

Subject: `refactor: shared LXMFPropagation.strippedCore for the 3 stamp-strip sites`.

---

## Task 6: App test tightenings

**Repo:** app. **Files:** Modify `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift`.

- [ ] **Step 1: Add the two assertions**

In `interfaceConnectedWithPNConfiguresAndSyncs`, before the `setPropagationNode`/`syncFromPropagationNode` receives, add a `registerDelivery` receive:
```swift
await store.receive { if case .node(.registerDelivery) = $0 { return true }; return false }
```
In `propagationAcceptedMarksStored`, add a `conversationsLoaded` receive alongside the existing `threadLoaded`:
```swift
await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
```

- [ ] **Step 2: Run to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore` → all pass (these actions are already dispatched by the reducer; the assertions just lock them in).

- [ ] **Step 3: Mutation-verify**

Batch: in `AppFeature`, (a) remove `.send(.node(.registerDelivery))` from `interfaceConnected` → `interfaceConnectedWithPNConfiguresAndSyncs` fails; (b) in `propagationAccepted`, remove the `reloadConversations` call → `propagationAcceptedMarksStored` fails. Revert both → pass.

- [ ] **Step 4: Commit (app repo)**

Subject: `test: tighten propagation reducer assertions (registerDelivery, conversationsLoaded)`.

---

## Live re-validation (controller-run, after Tasks 1–3)

Using the still-running `rnsd` hub + `lxmd` (cost 4) + two sims (see the `sim-verification-harness` memory), rebuild the app onto the sims and confirm:
1. **Genuine ack (Task 2):** send a small message to a *reachable* peer with a PN configured → `propagationAccepted` fires on the PN's packet proof (row → "stored") — and it still works for an offline peer.
2. **Purge (Task 3):** after the recipient syncs, `lxmd`'s `messagestore` empties.
3. The full offline round-trip (B→lxmd→A) still works end-to-end.

---

## Self-Review (completed)

- **Spec coverage:** genuine ack (packet+proof) → Tasks 1–2; IDENTIFY ordering + purge + 3-element fetch → Task 3; PN-side stamp validation → Task 4; shared strip helper → Task 5; app test tightenings → Task 6. Live re-validation → final section. The spec's Section 1 "(c) prove inbound data packet" is intentionally scoped OUT (documented in Task 1) as not needed for the goal and deferred with PN-serve integration — surfaced to the human at handoff.
- **Placeholder scan:** Tasks 1–2 leave a few harness-specific test-wiring spots (how the LinkSession harness injects an inbound packet / which delegate the router emits) as "match the existing harness / define in Step 3" — these are genuine "read the neighbouring code" points, not code placeholders; every production change has concrete code.
- **Type consistency:** `sendWithReceipt(data:token:)`, `packetDelivered(token:)`, `pendingDataReceipts[packetHash]→token`, `sendPropagatedPacket(linkID:propagationPacked:messageHash:)`, `sendWithReceiptOverLink(linkID:data:token:)`, `strippedCore(lxmfData:)`, `validatePnStamp(transientData:targetCost:)` are spelled consistently across tasks; the token is always `message.hash`.
