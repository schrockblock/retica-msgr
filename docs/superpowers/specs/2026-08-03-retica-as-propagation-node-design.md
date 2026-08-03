# ReTiCA-as-Propagation-Node (iOS node-mode, serve-only) — Design

**Date:** 2026-08-03
**Status:** Approved (design); implementation plan to follow
**Repos:** library changes → `pods/ReTiCA`; app changes → `apps/ReTiCaMsgr`

## Goal

Let ReTiCaMsgr act as an LXMF **propagation node**: while the app runs with
node-mode enabled, it registers `lxmf.propagation`, accepts store-and-forward
offers from real LXMF clients, persists them across restarts, and serves those
clients' two-phase `/get` downloads.

Today ReTiCA is only a propagation *client* (it sends via, and syncs from, a
node — proven live against reference `lxmd`). This slice makes it a *server*
too, and proves that against a real reference LXMF client.

## Context: what already exists

The pure and decoupled pieces are built and tested — this slice is composition
and productionization, not new protocol work.

- `PropagationStore` (pure): ingest → PN-stamp-validate → dedup by
  `transient_id` → storage-cap eviction → `entries(forDestination:)`.
  In-memory only; no persistence, no time-based expiry.
- `PropagationNode` (reducer): store lifecycle + serve logic
  (`ingestContainer`, `messageListRequested`, `messagesRequested`,
  `messagesDelivered`) with `stored` / `deliverMessageList` / `deliverMessages`
  delegates. Client-download serve strips the PoW stamp (RNS-faithful,
  `LXMRouter.py:1551`).
- `PNNode` (reducer): a `TCPEndpoint` + `PropagationNode` composition that
  already does register/announce, offer ingest, IDENTIFY, two-phase `/get`, and
  `/offer` PN↔PN peering — with integration and mesh tests over real links.
- `LXMFNode` (reducer): the client composition the app uses. Owns one
  `TransportEndpoint` (TCP or BLE) + `LXMFRouter`.

**Key scoping finding:** the "raw Endpoint glue" previously recorded as
deferred is largely *done* — `PNNode` is that glue. What is genuinely missing
is a **host that runs a PN in production**, **persistence**, and consistency
between the announced and enforced stamp cost. `PNNode` is instantiated only in
tests; nothing in `Sources/` or the app runs a node.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Host | iOS node-mode in ReTiCaMsgr | Demonstrable on-device; foreground-only is acceptable for this slice |
| Scope | Serve-only to clients | Leanest thing that is a real node; mesh peering is a separate subsystem |
| Architecture | Unified combined node (one endpoint) | Matches reference LXMF: one identity, one connection, both destinations |

Foreground-only (iOS suspends background execution) is an accepted limitation:
it makes 24/7 concerns — mesh auto-sync, aggressive GC, re-announce timers —
low-priority, keeping this slice lean.

## Architecture

A new reducer, **`LXMFServiceNode`** (`Sources/ReTiCANode/LXMFServiceNode.swift`),
composes the existing client and server reducers over a **single** endpoint:

```
LXMFServiceNode.State
├── client: LXMFNode.State        // owns the ONE TransportEndpoint + LXMFRouter
├── pn: PropagationNode.State     // message store + serve logic
└── nodeModeEnabled: Bool
```

`Scope(\.client) { LXMFNode() }` + `Scope(\.pn) { PropagationNode() }` plus a
parent `Reduce` containing **only serve-translation**:

- **Inbound → PN.** From the client endpoint's delegates:
  `requestReceived` (path `/get`) → `messageListRequested` (phase-1 `[nil,nil]`)
  or `messagesRequested` (phase-2 fetch / phase-3 purge);
  `resourceReceived` and `linkDataReceived` → `ingestContainer` (large offers
  arrive as Resources, small ones as link data packets);
  `linkIdentified` → record `linkID → client Identity`.
- **PN → outbound.** `deliverMessageList` / `deliverMessages` →
  `.client(.endpoint(.sendResponseOverLink(linkID:requestID:data:)))`, matched
  through a `pendingGet[clientDeliveryHash] = (linkID, requestID)` map.
- **Link lifecycle.** `linkClosed` / `requestFailed` clear that link's
  identity and pending entries.

Rationale:

- **No duplicated client logic** — `LXMFNode` is unchanged and keeps owning the
  endpoint, so the concurrent BLE/`TransportEndpoint` work is untouched.
- **No duplicated store logic** — reuses `PropagationNode`.
- **`requestReceived` has no conflict** — a client consumes `responseReceived`
  (its own sync); a server consumes `requestReceived` (inbound `/get`), which
  `LXMFNode` ignores today.

**Link classification (required — inbound data IS ambiguous).** `LXMFNode`
already consumes `linkDataReceived` and `resourceReceived` as *direct client
messages* (`LXMFNode.swift:245-249`), and the serve path needs those same two
delegates as *propagation offers*. The disambiguator is **which local
destination the link terminates on**: for an inbound link, `linkEstablished`
carries our own local destination hash (`TCPEndpoint` resolves it via
`transport.localDestinations`), whereas our client's outbound sync link carries
the *remote* node's hash — so the two never collide.

Therefore:

- `LXMFNode` records `linkID → destinationHash` from `linkEstablished` and gains
  an optional `propagationDestinationHash`. When a link's destination equals it,
  `LXMFNode` skips its direct-message handling — that data belongs to the server.
- `LXMFServiceNode` routes exactly those links' `linkDataReceived` /
  `resourceReceived` to `ingestContainer`, and sets/clears
  `propagationDestinationHash` when node-mode is enabled/disabled.

Relying instead on "a container will fail `LXMessage.unpack`" is rejected: it is
probabilistic, and a parse that *did* succeed would surface a bogus message to
the user. Classification makes it correct by construction.
- The new code is a **serve-only subset** of `PNNode` (no `/offer`, no peering,
  no peer-sync).
- Every serve handler is gated on `nodeModeEnabled`; with it off,
  `LXMFServiceNode` behaves identically to today's `LXMFNode`.

`PNNode` is left untouched — it remains the basis for a future headless daemon
and the mesh slice.

**App rewiring:** `AppFeature`'s `Scope(\.node)` changes from `LXMFNode()` to
`LXMFServiceNode()`, and existing action paths gain a `.client` hop
(e.g. `.node(.endpoint(...))` → `.node(.client(.endpoint(...)))`).

Only IDENTIFY'd clients are served: a `/get` on a link with no recorded
identity is dropped, matching `PNNode` and reference LXMF
(`LXMRouter.py:1483`, `ERROR_NO_IDENTITY`).

## Node-mode lifecycle & UI

- Settings toggle **"Act as a propagation node"**, backed by
  `@Shared(.appStorage("propagationNodeModeEnabled"))` — mirrors the existing
  `propagationNodeHex` pattern.
- New action `LXMFServiceNode.registerPropagation`: registers the
  `lxmf.propagation` destination on the client's endpoint and announces it with
  `PNAnnounce` app-data. The serve-side analog of `registerDelivery`.
- **Enable:** on `interfaceConnected` (and when the toggle flips on while
  connected), if the setting is on, `AppFeature` sets `nodeModeEnabled = true`
  and sends `registerPropagation` — slotting in beside the existing
  `registerDelivery`.
- **Disable:** set `nodeModeEnabled = false`; serve handlers no-op and we stop
  announcing. Destination *unregistration* is deferred — harmless, since the
  flag stops all serving.

## Persistence

The library stays pure (no file I/O in ReTiCA). Persistence lives in the **app**,
using its existing GRDB/SQLiteData stack, alongside client messages.

- New table `PropagationEntry(transientId PK, destinationHash, lxmfData,
  sequence, storedAt)`.
- `PropagationNode` delegates drive the mirror. Two additive changes to its
  delegate surface (existing cases keep their current shape so present tests and
  `PNNode` are unaffected):
  - `stored(transientIds:)` must also convey the **entry bytes** the app has to
    write — either by extending it to carry entries or by adding a companion
    case. Implementer's choice; it must not break `PNNode`'s existing use.
  - a **purge** signal emitted whenever entries leave the store — both branches
    that remove them: the `haves` purge inside `messagesRequested` and the
    `messagesDelivered` action.
- **Launch rehydrate:** the app loads persisted rows and restores the in-memory
  store by feeding them back through `ingestContainer` (wrapping them in a
  container). This reuses the tested ingest path — re-validating and re-deduping
  is harmless for already-valid entries — instead of adding a bypass.

Storage cap: `PropagationNode.State.storageLimitBytes` is set to a
mobile-appropriate default (existing oldest-first eviction applies).

## Announce / stamp-cost consistency

Today `PNNode` announces `targetStampCost: 0` while `PropagationStore`
enforces `minStampCost` (default 16) — advertised ≠ enforced. This slice makes
**the node advertise exactly what it enforces**:

- `LXMFServiceNode` takes a configured `minStampCost` and threads it into both
  `PropagationNode.State.minStampCost` (enforcement) and
  `PNAnnounce.targetStampCost` (advertisement).
- Default: `LXMFPropagation.defaultPropagationStampCost` (16, the LXMF default).
  This interops — reference clients and ReTiCA's own send path source the
  required cost from the PN announce, so offers arrive correctly stamped and
  pass enforcement.

## Testing

Standard project rules apply: three-step mutation verification for every new or
changed test; TCA tests non-exhaustive (`.off`), asserting outcomes.

- **`LXMFServiceNode` unit/integration:** inbound `/get` phase-1 list, phase-2
  fetch, phase-3 purge → correct responses over a real link; offer ingest via
  both Resource and link-data-packet; `/get` without IDENTIFY is dropped;
  node-mode-off → serve handlers no-op (and client behavior unchanged);
  `registerPropagation` announces the enforced stamp cost. Reuses the
  `PNNodeIntegrationTests` two-store link-bridging pattern.
- **Persistence (app):** `stored`/`messagesPurged` mirror to GRDB; launch
  rehydrate restores entries and the node serves them.
- **App wiring:** toggle on → register + announce after `interfaceConnected`;
  toggle off → no serving.
- **Live interop (the payoff):** app in node-mode on a simulator over an `rnsd`
  hub; drive a **reference Python LXMF client** to offer a message to the app's
  propagation address and then download it — proving ReTiCA-as-PN interops with
  real LXMF, the mirror of the client-side interop already proven against
  `lxmd`. Plus a persist → relaunch → still-serves check.

Live interop is required, not optional: every propagation interop bug found so
far (missing PN stamp, link-request double-encoding, purge transient_id
double-strip) was invisible to stub-based unit tests and surfaced only against
real reference code.

## Scope

**In:** `LXMFServiceNode` combined node (serve-only) · node-mode toggle and
register/announce lifecycle · GRDB persistence with launch rehydrate ·
advertised == enforced stamp cost · mobile storage cap · unit, app, and live
interop tests.

**Out (follow-on slices):** PN↔PN mesh peering, peer registry, auto-sync ·
inbound proving for genuine client acks (the deferred Option-3 item) ·
time-based expiry/GC · headless macOS daemon · periodic re-announce timer ·
BLE-as-PN specifics · destination unregistration on disable.
