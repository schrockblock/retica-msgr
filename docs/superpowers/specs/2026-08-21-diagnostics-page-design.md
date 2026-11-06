# Diagnostics page — design

**Written:** 2026-08-21. **Status:** approved, not yet implemented.

A read-only triage screen in ReTiCAMsgr Settings that answers one question:
**which layer is broken?** Born out of a debugging session where three device
symptoms took a full investigation to attribute, and where two of the three would
have been a single glance had this screen existed.

---

## Why this shape

Scope was settled by four decisions, recorded so a later reader does not reopen
them:

1. **Field triage, not a state dump.** Optimised for "is it working, and if not,
   where" while standing somewhere with one hand free. Completeness loses to
   legibility wherever they conflict.
2. **Read-only.** No reconnect / request-path / re-announce buttons. Settings
   already has Connect and Disconnect; a diagnostics screen that mutates state is
   a diagnostics screen you cannot trust to be showing you the fault.
3. **Live while open**, via ordinary TCA observation. No timer, no stored
   snapshot, no refresh action.
4. **Shareable as text.** The bottleneck in the session that prompted this was
   getting evidence off the device at all.

**Deliberately excluded:** an event log. It is the right tool for intermittent
faults, but it needs a capture mechanism that does not exist yet, and the two
cross-checks below cover the faults actually seen so far. Revisit if a fault
appears that is invisible in instantaneous state.

---

## Architecture

**`DiagnosticsSnapshot`** — a new pure value type in `ReTiCAMsgrCore`.

```swift
public struct DiagnosticsSnapshot: Equatable {
    public enum Health: Equatable { case ok, warn, problem }
    public struct Row: Equatable { public let label: String; public let value: String }
    public struct Layer: Equatable {
        public let title: String
        public let health: Health
        public let reason: String?      // nil when .ok
        public let rows: [Row]
    }
    public let generatedAt: Date
    public let layers: [Layer]
    public var text: String { ... }

    public init(from state: AppFeature.State, at date: Date)
}
```

**`DiagnosticsView`** — a new view in the app target. Builds
`DiagnosticsSnapshot(from: store.state, at: Date())` inside `body` and renders it.
Reading observable state inside `body` is what makes it live; nothing else is
required. The **view** supplies the wall clock; the **type** never reads one (see
below), which is the split that keeps `text` deterministic under test.

**State access paths**, spelled out because the nesting is deep and an implementer
should not have to rediscover it:

| Needed | Path from `AppFeature.State` |
|---|---|
| app connection | `.connection` |
| interface status / host / port | `.node.client.endpoint` → `.tcp(s)` → `s.interface` |
| interfaces, learned | `.node.client.endpoint.interfaces` (new), `.learned` |
| links | `.node.client.endpoint.links` |
| peers | `.node.client.learnedPeers` |
| delivery destination | `.node.client.deliveryDestinationHash` |
| router tables | `.node.client.router` |

**`TransportEndpoint.State.interfaces`** — one accessor added to ReTiCA.
`learned`, `links` and `registrations` are already exposed there; `interfaces` is
not, and the app should not have to switch on `.tcp` / `.ble` to reach it.

Placement: a `NavigationLink("Diagnostics")` in a new final Section of
`SettingsView`.

### Why a separate type rather than reading state in the view

All derivation — the health rules and the export text — is a pure function of
`AppFeature.State`, so it is unit-testable. The view becomes rendering only. This
matters most for the export: the text is the artifact that gets pasted into a bug
report and read by someone who was not there, so it should be produced by tested
code rather than by string interpolation inside a `Text`.

### Date is injected, not read

`init(from:at:)` takes the timestamp. Nothing calls `Date()` inside, so `text` is
deterministic under test.

---

## Security rule: allowlist, never reflection

`LinkSession.State` carries `sessionKey: Data` and `ephemeral: Identity`
(`LinkSession.swift:43,48`). Neither may ever appear in the rendered snapshot.

**The snapshot is assembled from a hand-written list of fields.** No reflection,
no `Mirror`, no generic "dump every property" helper — those are exactly what
turns "we added a field" into "we leaked a session key into a pasted bug report".
This is pinned by a test (below), not merely by convention.

---

## Layers

Six, in this order, each rendering a status dot, a one-line reason when not `ok`,
and its rows.

### 1. Socket

| Row | Source |
|---|---|
| app connection | `AppFeature.State.connection` |
| interface status | `TCPClientInterface.State.status` (`.disconnected` / `.connecting` / `.online`) |
| dialing | `interface.host` : `interface.port` |
| interfaces | `transport.interfaces` — `InterfaceID` → `InterfaceProfile` |

Rules, **evaluated in this order — the first match wins**, so a disagreement is
reported as a disagreement rather than being masked by the milder rule beneath it:

1. **problem** — app reports `.connected` and interface is not `.online`, or the
   interface is `.online` and the app does not report `.connected`. **These two
   disagreed for the entire duration of the stale-callback reconnect bug** (ReTiCA
   `5d310f7`), which is why they are separate rows rather than one merged status.
2. **problem** — interface `.online` but `transport.interfaces` is empty: the
   socket is up but Transport does not know about it, so nothing will route.
3. **warn** — both agree on `.connecting` (in progress, not yet a fault).
4. **ok** — app `.connected` and interface `.online` and interfaces non-empty.

Note rule 3 is reachable only when rule 1 did not match, i.e. app and interface
agree.

### 2. Identity

| Row | Source |
|---|---|
| address | `AppFeature.State.myAddressHex` |
| display name | `AppFeature.State.displayName`, or "(unset)" |
| delivery registered | `LXMFNode.State.deliveryDestinationHash != nil` |
| node mode | `AppFeature.State.nodeModeEnabled` |

- **problem** — `deliveryDestinationHash == nil`. We never registered a delivery
  destination, so nothing can reach us regardless of how healthy the socket is.

### 3. Paths

From `endpoint.learned` (`[Data: LearnedDestination]`). One row per entry:
destination, `hops`, `nextHop` (or "direct" when nil), `interfaceID`, and
**reachable** — whether `interfaceID` is present in `transport.interfaces`.

- **warn** — any entry unreachable.

**This is the F8 cross-check.** `learned` is deliberately non-destructive, so a
path outlives the interface it was heard on. Before ReTiCA `c4d00b2`,
`TCPEndpoint.openLink` did not test this and transmitted into a dead interface,
failing only at the 15s establishment deadline — and reporting it as
`.establishmentTimedOut`, which is PATH-shaped, so a dead socket was laundered
into a dead route.

### 4. Peers

From `LXMFNode.State.learnedPeers` (`[Data: LearnedPeer]`). One row per peer:
display name, hash, `learnedAt`, `stampCost`, and **has path** — whether the same
hash is present in `endpoint.learned`.

- **warn** — any peer without a path.

**This is the F20 cross-check.** `learnedPeers` is persisted by the app;
`LearnedDestination` — which holds the identity and the route — is not. After a
cold launch the Announce tab can list peers the app cannot message, because
opportunistic send needs the recipient identity and `openLink` needs the path.
That is the "send button won't enable" symptom, and this row names it directly.

### 5. Links

From `endpoint.links` (`IdentifiedArrayOf<LinkSession.State>`). One row per link:
`role` (`initiator` / `responder`), `status` (`pending` / `handshake` / `active` /
`closed`), short `linkID`, short `destinationHash`, `rtt`, `transfers.count`, and
ages derived from `activatedAt` / `lastInbound` / `lastData`.

- **warn** — an initiator link in `.handshake` (establishment in flight or stalled;
  the deadline is 15s).

Note `lastInbound` and `lastData` differ deliberately: `lastData` advances only on
traffic that decrypted. Showing both distinguishes "a peer is talking to us" from
"a peer is authenticated and talking to us".

### 6. Delivery

From `LXMFNode.State.router`:

| Row | Source |
|---|---|
| direct links | `directLinks` — dest → `.awaitingPath` / `.establishing` / `.active` |
| known paths | `knownPaths.count` |
| pending deliveries | `pendingDeliveries` — message hash → `attempts` |
| propagation node | `outboundPropagationNode`, or "(none)" |

- **warn** — `pendingDeliveries` non-empty with no `.active` entry in
  `directLinks` (messages queued with nowhere to go).

---

## Export

A `ShareLink(item: snapshot.text)` and a Copy button at the top of the screen.

Two deliberate differences from the on-screen rendering:

- **Identifiers are FULL in the text, truncated to 8 characters on screen.** That
  means destination hashes, link IDs, next-hop transport IDs and message hashes —
  everything the on-screen view abbreviates with an ellipsis. The screen needs to
  be readable; a pasted dump needs to be correlated against rnsd logs and against
  the other end's client. It does **not** extend to anything on the deny list
  above: `sessionKey` and `ephemeral` appear in neither form.
- The timestamp is included, from the injected date.

```
ReTiCAMsgr diagnostics — 2026-08-21T18:40:12Z

SOCKET  [problem] app reports connected, interface reports connecting
  app connection       connected
  interface status     connecting
  dialing              gaefu.ddns.net:4243
  interfaces           tcp (tcp)

PATHS (2)  [warn] 1 path names an interface that is gone
  3191467162a5e5dd4b42647c8d3dd93c  hops=1 next=7cfc2be2a1004f39b8d5c6e2f0a3b719 if=tcp reachable=NO
  a82f63559c5e9170ce0701656530a4ee  hops=0 next=direct                          if=tcp reachable=yes
```

(Full identifiers, per the rule above — the on-screen version of these same two
rows shows `31914671…` and `a82f6355…`.)

---

## Testing

Unit tests in `ReTiCAMsgrCoreTests`, over hand-built `AppFeature.State` fixtures.
The view itself is not tested; it holds no logic.

**One test per health rule, asserting BOTH the `Health` and the reason string.** A
correct verdict with a wrong stated reason is the specific failure this codebase
keeps hitting, and it is worse than an obvious break because nobody re-derives a
reason that looks plausible.

Pinned cases:

- socket disagreement (app `.connected`, interface `.connecting`) → `problem`
- interface `.online` with empty `transport.interfaces` → `problem`
- `deliveryDestinationHash == nil` → `problem`
- a learned path whose `interfaceID` is absent from `interfaces` → `warn`, and the
  reachable column reads `NO` (the F8 cross-check)
- a peer in `learnedPeers` with no entry in `learned` → `warn` (the F20
  cross-check)
- `pendingDeliveries` non-empty with no active `directLinks` entry → `warn`
- an all-healthy fixture → every layer `ok`, every reason nil

**Fixtures must be coherent.** Seeding `learned` without `interfaces` builds a
state the runtime cannot produce; that incoherence is itself one of the conditions
under test here, so each fixture states explicitly which of the two tables it is
populating and why. (Two ReTiCA test fixtures had exactly this defect and only
surfaced when `c4d00b2` made something read both tables together.)

**One security test, which is not about correctness:** build a state containing a
live `LinkSession` with a recognisable `sessionKey`, render `text`, and assert the
key's hex does not appear anywhere in it. This is what stops a later "render all
the fields" change from putting session keys into a shared bug report.

All of the above mutation-verified per the project's standard process: confirm
green, break each rule in a batch, confirm the matching tests fail, revert,
confirm green.

---

## Out of scope

- Actions of any kind (reconnect, request path, re-announce).
- An event log / rolling history.
- Any change to what the app persists. F20 is *displayed* here, not fixed.
