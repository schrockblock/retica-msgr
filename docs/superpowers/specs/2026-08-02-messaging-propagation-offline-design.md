# ReTiCAMsgr Slice 3 — Propagation / Offline Delivery (Design)

## Goal

Let a user reliably message a peer who is offline: send a copy to a
configured LXMF **propagation node** (store-and-forward), and sync messages
the node is holding when the app connects. Direct/opportunistic delivery
stays for immediacy; propagation adds the "it eventually arrives" guarantee.

## Context

Builds on the slice-2 multi-conversation app (spec
`2026-08-01-messaging-multi-conversation-design.md`). That app delivers
**opportunistically only** — both parties must be online, and RNS gives no
delivery receipt, so a message to an offline peer silently vanishes.

The propagation machinery already exists and is integration-tested in the
ReTiCA package: `LXMFNode` exposes `setPropagationNode`,
`sendViaPropagation`, and `syncFromPropagationNode`, and implements the full
client sync protocol (IDENTIFY → message-list request → wanted/haves →
download → `messageReceived`) plus the `sendPropagated` /
`propagationAccepted` delegates. Covered by `LXMFNodePropagationTests`,
`LXMFNodeSyncTests`, `LXMFPropagationCapstoneTests`. So this slice is
**app-layer wiring plus one small ReTiCA addition** — not new propagation
plumbing.

## Scope decisions (settled during brainstorming)

- **Client of a propagation node, not a node.** The app sends via a PN and
  syncs from a PN. It does not itself run a propagation node. The PN is an
  external LXMF node; we validate against the reference **`lxmd`** daemon
  (present in the `rns` conda env).
- **Routing = PN-backed reliability + opportunistic immediacy.** On send the
  app builds one `LXMessage` and always dispatches the opportunistic
  (direct) send; if a PN is configured **and** the peer's identity is known,
  it also sends via propagation. The recipient dedups by `message.hash`, so
  an online peer that receives both copies sees only one message. No PN
  configured → today's opportunistic-only behavior, unchanged.
- **Same message on both routes (the reason for the ReTiCA addition).**
  `LXMFNode.send` and `.sendViaPropagation` each *rebuild* the `LXMessage`
  internally from `(dest, title, content)` with their own `date.now`, so
  dispatching both would produce two different-hashed messages and a visible
  duplicate. A new `LXMFNode.sendMessage(message:alsoViaPropagation:)` takes
  a prebuilt `LXMessage` and routes that single instance both ways, so the
  hashes match and the recipient dedups. This also fixes a latent slice-2
  bug where the outgoing row's `messageHash` could drift from the
  actually-sent message.
- **Sync = on connect + manual.** Auto-sync once on `interfaceConnected`
  when a PN is configured; plus a manual Sync button on the conversation
  list. Downloaded messages flow through the existing `messageReceived` →
  persist → reload path.
- **Identity precondition.** You can only send to a peer whose identity you
  have heard (an announce) — the same precondition slice 2's reachability
  gate already enforces. Propagation to a peer unheard for > 1 week (path
  expired from `transport.learned`) silently no-ops; acceptable for MVP.

## Non-goals

- Running an in-app propagation node (serving other clients).
- Periodic/background sync polling (deferred; on-connect + manual only).
- PN auto-discovery via `pn_announce` (PN address is entered manually).
- Delivery receipts / read receipts / true online-presence detection (RNS
  does not provide these for opportunistic delivery).
- Pruning `reachablePeers` on path expiry (carried-over slice-2 minor;
  unchanged).

## Architecture

Two repos, thin in each.

### ReTiCA package — `LXMFNode` addition

New action:

```swift
case sendMessage(message: LXMessage, alsoViaPropagation: Bool)
```

Handler:

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

The existing `.send(destinationHash:title:content:method:)` stays for
compatibility. Propagation is skipped when the recipient identity is not in
`transport.learned`, so callers may pass `alsoViaPropagation: true`
unconditionally.

### App — `AppFeature`

**State:** add `@Shared(.appStorage("propagationNodeHex")) var propagationNodeHex: String = ""`.
Add `MessageStatus.propagated = "stored"`.

**Actions & wiring:**
- `sendTapped` — build `msg` (as today, for the row hash), persist the
  outgoing row, then dispatch
  `.node(.sendMessage(message: msg, alsoViaPropagation: !propagationNodeHex.isEmpty))`
  instead of `.node(.send(…))`. Reload thread + conversations as today. The
  **Send gate is unchanged** (`reachablePeers.contains(peer)`), which already
  means "identity known" — the precondition for both routes.
- `.node(.endpoint(.transport(.interfaceConnected(_))))` — in addition to
  `connection = .connected` + `.node(.registerDelivery)`, if
  `propagationNodeHex` decodes to a 16-byte hash, also dispatch
  `.node(.setPropagationNode(destinationHash:))` then
  `.node(.syncFromPropagationNode)`.
- `.setPropagationNode(String)` (new) — from Settings: persist the hex into
  `propagationNodeHex`; if it is a valid 16-byte hash, dispatch
  `.node(.setPropagationNode(destinationHash:))` + `.node(.syncFromPropagationNode)`;
  invalid → persist only (no node dispatch).
- `.syncTapped` (new) — dispatch `.node(.syncFromPropagationNode)`.
- `.node(.delegate(.propagationAccepted(hash)))` (new) — update the row whose
  `messageHash == hash.hexString` to `MessageStatus.propagated`, then reload
  thread-if-open + conversations (same effect shape as `deliveryFailed`).
- Downloaded messages — no new handling; they arrive via the existing
  `.node(.delegate(.messageReceived))` handler.

The derived-conversation, thread, `openConversation`/`startConversation`,
and `messageReceived`/`deliveryFailed` logic are otherwise untouched.

## UI

- **`SettingsView`** — new "Propagation node" section below "Node
  Connection": a monospaced `TextField` for the PN LXMF address (hex) + a
  Save button sending `.setPropagationNode(input)` (disabled until the input
  is a valid 16-byte hex, via `isValidPeerAddress`), and a line showing the
  current `propagationNodeHex` when set.
- **`ConversationListView`** — a **Sync** toolbar button (`arrow.clockwise`)
  beside the `+`, sending `.syncTapped`.
- **`MessageBubble`** — no change; it already renders `message.status` for
  outgoing rows, so `"stored"` displays once `propagationAccepted` lands.

## Testing

### ReTiCA — `LXMFNode.sendMessage` (TestStore, mutation-verified)
1. `alsoViaPropagation: false` → only `router.send(.opportunistic)` fires.
2. `alsoViaPropagation: true` with `transport.learned[dest].identity` seeded →
   both `router.send(.opportunistic)` and `router.sendViaPropagation` fire,
   carrying the same message.
3. `alsoViaPropagation: true` with identity unknown → only opportunistic.

### App — `AppFeature` (TestStore, `.off`; slice-2 harness patterns; mutation-verified)
1. `sendTapped` with a PN set → dispatches
   `.node(.sendMessage(alsoViaPropagation: true))`; without a PN →
   `alsoViaPropagation: false`.
2. `interfaceConnected` with a valid PN configured → dispatches
   `setPropagationNode` + `syncFromPropagationNode`; with no PN → neither.
3. `setPropagationNode(validHex)` → persists `propagationNodeHex` + dispatches
   node set + sync; invalid hex → persists only, no node dispatch.
4. `syncTapped` → dispatches `syncFromPropagationNode`.
5. `propagationAccepted(hash)` for an outgoing row → that row's status
   becomes `MessageStatus.propagated` and the thread reloads.

### Live two-simulator validation (documented; run at the end)
Reference `lxmd` propagation node + `rnsd` hub on the same network; both sims
configured with `lxmd`'s propagation-destination address.
- **Offline delivery:** disconnect/close the recipient sim, send from the
  sender (routes to the PN), reopen the recipient → auto-sync on connect →
  the message appears in the right conversation.
- **No duplicate online:** both online, send → the recipient shows exactly
  one message (dedup by `message.hash` across the direct + PN copies).

## Files

**ReTiCA package:**
- Modify `Sources/ReTiCANode/LXMFNode.swift` — add the `sendMessage` action + handler.
- Modify/create `Tests/ReTiCANodeTests/LXMFNodePropagationTests.swift` (or a new
  test file) — the three `sendMessage` tests.

**App:**
- Modify `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Message.swift` — add
  `MessageStatus.propagated`.
- Modify `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift` — state field,
  `sendTapped` re-route, `interfaceConnected` sync, `setPropagationNode`,
  `syncTapped`, `propagationAccepted`.
- Modify `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` — the
  five app tests.
- Modify `ReTiCAMsgr/SettingsView.swift` — Propagation node section.
- Modify `ReTiCAMsgr/ConversationListView.swift` — Sync toolbar button.
- **No change** to `Conversation.swift`, `Database.swift`, `IdentityStore.swift`,
  `Data+Hex.swift`, `ChatView.swift`, `ContentView.swift`, the DB migration, or
  either `Package.swift`.

## Decomposition

Single slice, one implementation plan, but two-repo. Suggested task order:
(1) ReTiCA `LXMFNode.sendMessage` + tests [swift test in the pods repo];
(2) app `AppFeature`/`Message` wiring + tests [swift test in the app package];
(3) app UI (`SettingsView`, `ConversationListView`) [xcodebuild];
(4) live `lxmd` two-simulator validation. Tasks 1–2 are headless
`swift test`; task 3 needs `xcodebuild`; task 4 is manual/scripted with the
XcodeBuildMCP CLI + `lxmd`.
