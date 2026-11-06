# LXMF Propagation Follow-ups (Design)

## Goal

Close the deferred follow-ups from the LXMF offline-delivery fix: make
`propagationAccepted` a genuine PN acceptance signal, harden the sync
protocol (IDENTIFY ordering, purge-after-download), make ReTiCA a compliant
propagation-node *receiver* (inbound stamp validation), and small cleanups
(shared stamp-strip helper, app test tightenings).

## Context

Offline delivery now works end-to-end against reference `lxmd` after two
fixes: the propagation PoW stamp (pods `6cbf9a7`) and the `LinkSession`
request-data double-encoding (pods `1ab19d1`). During that work several
smaller items were deferred; this design covers all of them. The live
`rnsd` hub + `lxmd` + two-simulator harness (see the `sim-verification-harness`
memory) is used to re-validate the two behavioral items.

Repos: the library changes land in the **ReTiCA pods repo**
(`/Users/ell/development/ios/pods/ReTiCA`); the app test tightenings land in
the **app repo** (`/Users/ell/development/ios/apps/ReTiCAMsgr`).

## Scope decisions (settled in brainstorming)

- `propagationAccepted` → **full packet+proof** treatment (not YAGNI): send a
  small propagation offer as a proof-requesting link data packet and gate
  `propagationAccepted` on the PN's packet proof; keep Resource for large
  offers. This requires adding general link data-packet proof/receipt support
  to `LinkSession` first.
- All six items are in scope.

## Items & approach

### 1. Genuine propagation ack — link data-packet proofs + packet-when-small

**1a. `LinkSession` link data-packet proof/receipt (new Link capability).**
Mirror RNS link packet proofs:
- **Outbound (sender):** a "send data packet requesting proof" path — transmit
  a `.data` context-`none` link packet with the proof-request flag set, and
  record a pending receipt keyed by the packet hash (`Packet.truncatedHash`).
- **Inbound proof (sender side):** on a `.proof` packet whose payload proves a
  pending packet hash, resolve the receipt → `.delegate(.packetDelivered(hash))`,
  and cancel the receipt-timeout.
- **Inbound data packet requesting a proof (receiver side):** after delivering
  the data to the app, if the packet requested a proof, transmit a `.proof`
  packet back (signed/derived per RNS link-proof rules). This lets
  ReTiCA-as-PN prove, and keeps the mechanism symmetric.
- Timeout: reuse the existing request-timeout pattern (cancellable), firing a
  `packetDeliveryFailed(hash)` (or reusing an existing failure signal) if no
  proof arrives.

**1b. Propagation send representation switch (`LXMFRouter`/`LXMFNode`).**
When the propagation container fits in the link MDU (`<= 431` bytes, the
common small-message case), send it as a **proof-requesting link data packet**
(new `sendPropagatedPacket` delegate → `LinkSession` outbound-with-proof)
instead of a Resource. Correlate the returned `packetDelivered` → the router's
`.delivered` → `propagationAccepted` — a genuine acceptance, since the PN only
proves after `validate_pn_stamp` passes. Containers over the MDU keep the
existing Resource path (`sendResourceOverLink` → `resourceDeliveredOnLink` →
`.delivered` → `propagationAccepted`), matching reference's Resource-path
limitation.

**Validation (live):** small message → `lxmd` proves the packet →
`propagationAccepted` fires on the real proof.

### 2. Sync robustness (`LXMFNode`)

**2a. IDENTIFY before request.** Replace `.merge(identifyOverLink, sendRequestOverLink)`
in `requestMessageList` with a single `.run` effect that `await`s the
identify send, then the `/get` send — the IDENTIFY packet is transmitted
before the request, so the PN never returns `ERROR_NO_IDENTITY (0xf0)`.

**2b. Phase-3 purge.** After `messagesDownloaded`, send a final `/get` with
`[nil, haves]` carrying the just-downloaded `transient_id`s so the PN purges
its served copies. **Live re-validation:** `lxmd`'s `messagestore` empties
after the recipient syncs.

**2c. Fetch request 3-element.** Send `[wants, haves, delivery_per_transfer_limit]`
(the reference shape) instead of `[wants, haves]`. The limit value can be a
sensible default constant.

### 3. PN-side inbound stamp validation (`PropagationStore`/`PropagationNode`)

On the PN ingest path, validate each incoming entry via
`LXStamper.validatePnStamp(transientData:targetCost:)` against a configured
minimum cost; **reject** (do not store) unstamped/under-cost entries. This
makes ReTiCA a compliant receiver PN (today it only sends compliant stamps).
The minimum cost is a parameter/config on the store/node (default the RNS
`PROPAGATION_COST = 16`). Pure unit-test coverage — the app runs no ReTiCA PN.

### 4. Cleanup

**4a. Shared stamp-strip helper.** Extract the three ad-hoc "strip trailing
32-byte stamp" sites (`recoverPacked`, the `LXMFNode` `awaitingMessages` sync
handler, `PropagationStore.ingest`) into one helper,
`LXMFPropagation.strippedCore(lxmfData:) -> Data` (returns the entry minus a
trailing stamp when present, per the HMAC-safe size heuristic already in use),
and call it from all three sites.

**4b. App test tightenings (app repo).** Add the `registerDelivery` receive
assertion to `interfaceConnectedWithPNConfiguresAndSyncs`, and the
`conversationsLoaded` receive assertion to `propagationAcceptedMarksStored`,
in `AppFeatureTests.swift`.

## Testing

- **Unit tests (mutation-verified) for every change:**
  - 1a: `LinkSession` sends a proof-requesting data packet and resolves
    `packetDelivered` on a matching inbound proof; and proves an inbound
    proof-requesting data packet. TestStore, mutation-verified.
  - 1b: propagation send chooses packet vs Resource by size; `propagationAccepted`
    fires on `packetDelivered` for the packet path (and still on
    `resourceDeliveredOnLink` for the Resource path).
  - 2a: `requestMessageList` sends IDENTIFY before the `/get` request (order).
  - 2b: after `messagesDownloaded`, a purge `/get [nil, haves]` is sent.
  - 3: PN ingest rejects an unstamped/under-cost entry and accepts a valid one.
  - 4a: the shared helper strips a stamped entry and leaves a stampless one
    (the existing round-trip/ingest tests exercise the call sites).
  - 4b: the two added app assertions.
- **Live lxmd re-validation:** genuine ack (1) — small message → real packet
  proof → `propagationAccepted`; purge (2b) — `lxmd` `messagestore` empties
  after the recipient syncs; and the full offline round-trip still works.

## Files (indicative)

**ReTiCA pods repo:**
- `Sources/ReTiCATransport/LinkSession.swift` — link data-packet proof/receipt (1a).
- `Sources/ReTiCANode/LXMFRouter.swift`, `LXMFNode.swift` — propagation
  representation switch + `propagationAccepted` correlation (1b); sync IDENTIFY
  ordering, purge, 3-element fetch (2).
- `Sources/ReTiCANode/Endpoint.swift` — thread the new send-packet-with-proof /
  proof-delegate through Endpoint if needed.
- `Sources/ReTiCANode/PropagationStore.swift` (and/or `PropagationNode.swift`) —
  inbound stamp validation (3).
- `Sources/ReTiCA/LXMF/LXMFPropagation*.swift` — `strippedCore` helper (4a),
  used by `recoverPacked`, the sync handler, and `PropagationStore.ingest`.
- Corresponding tests under `Tests/`.

**App repo:**
- `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` — 4b.

## Non-goals

- No new app-facing features or UI changes.
- No change to the opportunistic/direct delivery paths beyond what the
  packet-proof mechanism naturally enables.
- PN peer-to-peer mesh sync behavior is unchanged (only inbound stamp
  validation is added to ingest).

## Decomposition

Suggested task order (each independently testable):
1. `LinkSession` link data-packet proof/receipt (1a) — foundational.
2. Propagation packet-when-small + genuine `propagationAccepted` (1b) —
   depends on task 1; live-validated.
3. Sync IDENTIFY ordering + purge + 3-element fetch (2) — live-validated (purge).
4. PN-side inbound stamp validation (3).
5. Cleanup: `strippedCore` helper (4a) + app test tightenings (4b).
