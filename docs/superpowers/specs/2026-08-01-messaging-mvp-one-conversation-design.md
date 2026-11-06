# ReTiCAMsgr MVP — One Conversation, Send + Receive — Design

**Date:** 2026-08-01
**Status:** Approved (design)

## Context

`ReTiCAMsgr` is an iOS SwiftUI app (iOS 26.4, Swift) that will be a
Reticulum/LXMF messenger built on the local `ReTiCA` Swift package
(`../../pods/ReTiCA`), whose `ReTiCANode` library provides `LXMFNode` (an
`LXMFRouter` + `Endpoint` TCA composition for send/receive) and `PNNode`. The
package ships **live** dependencies — notably a real `NWConnection`-backed
`TCPConnection` — so the app supplies a `host:port` and gets a working socket.

This is **slice 1** of the app: the thinnest real vertical — one conversation,
opportunistic send + receive between two online devices — proving identity +
transport + `LXMFNode` + basic UI end to end.

## Full-app decomposition (each a later spec → plan → build)

1. **Slice 1 (this):** one conversation — identity, configurable connection,
   opportunistic send/receive, chat screen, persistence.
2. Contacts + multiple conversations (list, per-peer threads).
3. Propagation / offline delivery (reuse the built `PNNode`).
4. Polish — announce/contact discovery, notifications, delivery-status UI.

## Scope (slice 1)

**In scope:** persistent identity; configurable connection to a Reticulum TCP
interface; register + announce your `lxmf.delivery` destination; add one peer by
their delivery-hash; opportunistic send + receive; a chat screen, an
address/share screen, and a settings screen; message + settings persistence.

**Out of scope:** contacts list / multiple conversations; propagation (offline
delivery); notifications; delivery receipts beyond best-effort; contact
discovery; a design system.

## Architecture

**Full TCA.** One `AppFeature` `@Reducer` composes `LXMFNode` via `Scope`;
SwiftUI views observe a `Store`. Production uses the package's **live**
dependencies (real socket, `date`, `uuid`, `randomBytes`); tests inject mocks.

**Packages:** add local `ReTiCA` (link `ReTiCANode`) and
`pointfreeco/sharing-grdb` (product `SharingGRDB`) to the Xcode project.

### `AppFeature` reducer

**State**
- `identity: Identity`
- `node: LXMFNode.State`
- `myAddressHex: String` — your `lxmf.delivery` hash (`LXMessage.deliveryHash(identityHash:)`), for sharing
- `peerAddressHex: String?` — the peer's delivery-hash (persisted)
- `peerReachable: Bool` — set once the peer's announce is heard (`pathLearned`)
- `connection: {disconnected, connecting, connected}`
- `settings: {host: String, port: UInt16}`
- `draft: String`
- the message list is a SharingGRDB `@FetchAll` (see Persistence), not a manual array

**Body:** `Scope(state: \.node, action: \.node) { LXMFNode() }` + a `Reduce`:
- `.onLaunch` → `.node(.endpoint(.connect))`; set `connection = .connecting`
- `node.endpoint.delegate.connected`-equivalent (interface connected) →
  `.node(.registerDelivery)`; `connection = .connected`
- `.node(.endpoint(.delegate(.pathLearned(h, _))))` → if `h == peerDeliveryHash`
  set `peerReachable = true`
- `.setPeer(hex)` → validate + parse hex → `peerAddressHex` (persist)
- `.draftChanged(String)` → `draft`
- `.sendTapped` (guard peer set + non-empty draft) → insert an outgoing
  `Message(status: .sending)` into the DB → `.node(.send(destinationHash:
  peerHash, title: Data(), content: Data(draft.utf8), method: .opportunistic))`;
  clear `draft`
- `node.delegate.messageReceived(m, validated)` → insert an incoming `Message`
  (store `validated`)
- `node.delegate.deliveryFailed(hash)` → update that message's status → `.failed`
- `.settingsChanged(host, port)` → persist; if connected, reconnect
- `.connectTapped` / `.disconnectTapped` → `.node(.endpoint(.connect/.disconnect))`

Opportunistic delivery is best-effort in this stack (no `deliveryConfirmed`), so
an outgoing message goes `.sending → .sent` optimistically and only flips to
`.failed` on `deliveryFailed`.

### Identity — `IdentityStore` (Keychain)

At launch (in `ReTiCAMsgrApp`, before the `Store` is built): read the 64-byte
`privateKey` from Keychain → `Identity(privateKey:)`; if absent, `Identity()`
and store it (Security framework). The initial `AppFeature.State` is built with
this identity + `LXMFNode.State(identity:, endpoint: Endpoint.State(host:,
port:, reconnectOnDrop: true))`. Identity is **stable across launches**, so your
address never changes.

### Persistence — SharingGRDB

- `Message` is a `@Table` struct: `id: UUID`, `peerHex: String`, `isOutgoing:
  Bool`, `body: String`, `timestamp: Date`, `status: String`
  (sending/sent/failed/received), `validated: Bool`.
- At launch, configure `\.defaultDatabase` — a GRDB database + a migration that
  creates the `messages` table.
- The chat view / state uses `@FetchAll` filtered by the current `peerHex`,
  ordered by `timestamp` — it auto-observes DB changes so inserts appear without
  manual reload.
- Sends/receives persist via `database.write { … }` in an effect.
- Settings (`host`/`port`) and `peerAddressHex` persist in `@Shared(.appStorage)`
  / `UserDefaults`.

## Data flow

```
launch → load identity (Keychain) + settings → configure defaultDatabase → build Store
  → .onLaunch → node.endpoint.connect → (connected) → node.registerDelivery (announce lxmf.delivery)
peer added (paste their delivery-hash) → peerAddressHex; peerReachable=false
  → peer's announce heard → node.pathLearned → peerReachable=true (composer enabled)
send: draft → insert outgoing Message(.sending) → node.send(peerHash, content, .opportunistic)
  → (best-effort) status .sent ; deliveryFailed → .failed
receive: node.delegate.messageReceived(m, validated) → insert incoming Message
```

## The addressing reality

Opportunistic send requires the sender to have **heard the peer's announce**
(to learn their identity for encryption + a path). So:
- The composer is enabled only when `peerReachable` (their `pathLearned` fired).
- Both devices must be connected + announcing for the first exchange;
  `registerDelivery` announces on connect. Periodic re-announce is a later slice.

## UI (three lightweight SwiftUI screens)

1. **Chat** — message bubbles from `@FetchAll`, a composer (disabled until
   `peerReachable`, with a hint), a connection indicator.
2. **Your address** — `myAddressHex` + copy/share (QR optional).
3. **Settings** — `host`/`port`, connect/disconnect, and the peer-address entry
   field (paste hex; validation error on malformed input).

No design system yet — plain SwiftUI.

## Error handling

- Connection drop → `connection` reflects it; `Endpoint`'s `reconnectOnDrop`
  retries.
- Peer not reachable → composer disabled with a hint.
- Malformed pasted address → inline validation error (must be valid hex of the
  delivery-hash length).
- Identity load failure → regenerate + warn that the address changed.

## Testing

- `AppFeature` `TestStore` unit tests with a mocked `tcpConnection` + an
  in-memory GRDB database: assert `onLaunch → connect → registerDelivery`;
  `sendTapped → node.send(...)` + an outgoing row persisted; `messageReceived →`
  an incoming row persisted; `pathLearned(peerHash) → peerReachable`.
- The transport/LXMF layer is already exhaustively tested in the package; app
  tests cover the **wiring**.
- UI is thin — verify manually + a smoke UI test.

## Success criteria

Two devices, each pointed at the same reachable hub, add each other by address;
a message typed on one appears on the other; both survive an app relaunch (same
identity, message history intact).
