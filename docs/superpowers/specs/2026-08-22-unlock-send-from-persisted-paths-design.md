# Unlock Send from persisted paths on reconnect

**Written:** 2026-08-22. **Repo:** ReTiCaMsgr (`/Users/ell/development/ios/apps/ReTiCaMsgr`),
logic in `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift`. Target: `main`.

## Goal

After a relaunch or reconnect, the Send button is enabled for any peer the user has a persisted,
now-live path to — without waiting for a fresh inbound announce from that peer.

## Why this, not "announce on connect"

The request began as "announce on connect if I have previous conversations," but the underlying
goal is **unlock the Send button after returning**. Investigation showed announcing cannot achieve
that, and already happens regardless:

- **Send gate.** `ChatView.canSend` requires `store.reachablePeers.contains(peer)`
  (`ChatView.swift:15-18`), and the button is `.disabled(!canSend)` (`ChatView.swift:34`).
- **`reachablePeers` is session-only and inbound-only.** Declared
  `public var reachablePeers: Set<String> = []` (`AppFeature.swift:39-40`); its sole write site is
  `state.reachablePeers.insert(h.hexString)` inside the `.pathLearned` handler
  (`AppFeature.swift:448`). It is never persisted, never cleared, and starts empty on every launch.
- **`.pathLearned` is inbound-only.** It originates in the Transport reducer
  (`ReTiCA/Sources/ReTiCATransport/Transport.swift:524-525`) only when a *remote* peer's announce
  is received and adopted. Broadcasting our own delivery destination transmits outward and never
  fires `pathLearned`, so **announcing ourselves does not populate `reachablePeers`.**
- **The app already announces on every connect.** `interfaceConnected` fires `registerDelivery`
  (`AppFeature.swift:312`), which re-announces our delivery destination with our display name.
- **Path persistence restores the path but not the gate.** `rehydrateLearnedDestinations` writes
  `Transport.learned` from disk and returns `.none`, emitting no `.pathLearned`
  (`Transport.swift:333-349`). So after relaunch a valid persisted path exists in `Transport.learned`
  while `reachablePeers` is empty → `canSend` is false → Send stays disabled despite a usable path.

The existing test `learnedPathSurvivesRestartAndIsReachableWithoutAnnounce`
(`AppFeatureTests.swift:1169`) confirms the path survives restart **at the transport level only**:
its clause 3 asserts a `Transport.send` returns `.interfaceUnavailable` (routed) rather than
`.notLearned`. It never asserts `reachablePeers` or that Send is enabled. "IsReachable" in that name
means *transport-routable*, not *UI-sendable* — which is precisely the gap this change closes.

## Change

App-side only, in `AppFeature` (ReTiCaMsgrCore). **No library (ReTiCA) change. No new announce.**

Make `reachablePeers` a faithful projection of "can I actually send right now," seeded from
persisted paths at the moment they become usable.

### Reachability definition

A learned destination is reachable when it is present in `…transport.learned` **and** its
`interfaceID` is present in `…transport.interfaces`. This is the same `learned ∩ interfaces` test
`DiagnosticsSnapshot` already uses (`DiagnosticsSnapshot.swift:147-149`) and the same
`reachableLearned` semantics the real send path enforces (`Transport.swift:159-163`), so Send is
only ever enabled when a send would actually route. Rehydrated entries are unreachable until an
interface registers (the F8 gate), which is why seeding is tied to interface connection, not to
rehydration alone.

### Seed points (one shared helper, idempotent set-inserts)

1. **Primary — `interfaceConnected` (`AppFeature.swift:295`).** After the interface registers,
   insert into `reachablePeers` every destination in `…transport.learned` whose `interfaceID` is
   now present in `…transport.interfaces`.

2. **Launch-ordering guard — the `rehydrateLearnedDestinations` app handler
   (`AppFeature.swift:679-689`).** Rehydration (dispatched in `onLaunch`) and the TCP connect race;
   rehydration almost always applies first, but to be correct rather than lucky: if
   `state.connection == .connected` when rehydration is applied, also seed from the incoming
   payload's destinations whose `interfaceID` is currently registered. (The app holds the payload
   here, so this is race-free and does not depend on Transport having applied the write yet.)

Both points call one shared helper and insert into a `Set`, so whichever lands second fills any gap.

### Scope decisions

- **Seed all currently-reachable persisted peers, not only conversation peers.** This matches the
  existing live behavior: today `pathLearned` inserts *every* peer whose announce is heard, not just
  ones the user has chatted with. Seeding all reachable on reconnect is the consistent choice and
  avoids intersecting with the conversation list.
- **Removal is out of scope.** Today `reachablePeers` is never removed from, so Send can remain
  enabled after a path goes stale mid-session (the send then fails at the transport). This change
  does not alter that; making the gate track real-time reachability (add *and* remove) is a larger
  "gate on real reachability" refactor and is deliberately excluded here. Documented as a known
  limitation.

## Data flow

```
Launch:  onLaunch ──dispatch──▶ read LearnedDestinationRow (pruned of expired)
                   └─▶ rehydrateLearnedDestinations(payload) ─▶ Transport.learned filled
                   └─▶ endpoint start ─▶ TCP connect ─▶ interfaceConnected

Seed:    interfaceConnected ─▶ seedReachableFromLearned(&state)   [reads learned ∩ interfaces]
         rehydrate handler (if already .connected) ─▶ seed from payload ∩ registered interfaces

Gate:    ChatView.canSend = reachablePeers.contains(openPeer) && !draft.isEmpty
```

## Error handling / edge cases

- **No persisted paths / fresh install:** learned is empty → helper inserts nothing → Send stays
  disabled, as today. No regression.
- **Path expired between prune and use:** the launch prune (`AppFeature.swift:212-240`) and
  Transport's own expiry sweep (`Transport.swift:333-349`) keep the seed set aligned with
  `Transport.learned`; a narrowly-timed expiry is the same "stale path, send fails once" case that
  exists today for any path.
- **Reconnect after mid-session disconnect:** `interfaceConnected` re-seeds idempotently; no
  duplicates (Set), no removal of entries that are still valid.
- **Hash spaces already agree:** `pathLearned`'s hash, `Transport.learned`'s key,
  `Conversation.peerHex`, and `openPeerHex` are all the peer's LXMF delivery destination hash — the
  live Send path already relies on this equivalence.

## Testing

Follow the repo's three-step verification (run green → mutate to force red → revert to green), per
the user's global CLAUDE.md.

- **New sibling test to `learnedPathSurvivesRestartAndIsReachableWithoutAnnounce`:** session-2
  restart → `onLaunch` (rehydrate) → **register the interface** via `interfaceConnected` → assert
  the prior peer is in `state.reachablePeers` (Send would be enabled), with **no** inbound announce.
  Mutation: drop the seed helper call → this assertion fails; the existing transport-level test
  stays green (proving the two assert different things).
- **Launch-race variant:** deliver `interfaceConnected` *before* `rehydrateLearnedDestinations`,
  then rehydrate while `.connected` → assert the peer ends up in `reachablePeers` (the guard path).
  Mutation: drop the guard-path seed → assertion fails.
- **No-path variant:** restart with an empty DB → after `interfaceConnected`, `reachablePeers`
  stays empty (Send disabled). Guards against seeding phantom peers.

## Out of scope

- Any change to ReTiCA (the transport library) or the announce mechanism.
- Removing peers from `reachablePeers` when a path goes stale or the interface drops.
- Actively issuing `requestPath` to re-verify or re-learn paths on connect.
- Delivering via propagation when no direct path exists (Send remains path-gated, as today).
