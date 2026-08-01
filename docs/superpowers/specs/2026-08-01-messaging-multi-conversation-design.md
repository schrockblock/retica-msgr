# ReTiCaMsgr Slice 2 — Multiple Conversations (Design)

## Goal

Turn the one-conversation MVP into a multi-conversation messenger: a
conversation list, per-peer message threads, and a compose entry point for
starting a new conversation by peer address. Delivery stays **opportunistic
(both online)** — store-and-forward / propagation is deferred to slice 3.

## Context

Builds directly on the one-conversation MVP (spec
`2026-08-01-messaging-mvp-one-conversation-design.md`). That MVP is a single
`AppFeature` reducer (in the local SPM package `ReTiCaMsgrCore`) scoping
`LXMFNode` from the ReTiCA/LXMF package, with SQLiteData (`@Table Message`) for
persistence and three SwiftUI screens (Chat / Address / Settings) in a TabView.

The MVP models exactly one peer: a `@Shared("peerAddressHex")`, a flat
`messages: [Message]` array, `ChatView` showing all messages, and the peer set
from `SettingsView`. Slice 2 generalizes this to many peers.

## Scope decisions (settled during brainstorming)

- **Address-only, no contact names.** There is **no** `Contact` table.
  Conversations are *derived* from the distinct `peerHex` values already in the
  `messages` table. List rows show truncated hex only.
- **List → thread navigation with a compose button.** The Chat tab becomes a
  `NavigationStack`: a conversation list (most-recent-first) drills into a
  per-peer thread. A `+` toolbar button opens a sheet to paste a peer address,
  which pushes an (initially empty) thread. Address + Settings remain sibling
  tabs. The old "set peer" field leaves Settings.
- **Per-peer reachability gate.** Track a `Set<String>` of reachable `peerHex`,
  populated from `pathLearned` delegates. In a thread, Send is enabled only when
  that peer's path is known (the MVP's `peerReachable` rule, generalized).
- **Opportunistic only.** Store-and-forward exists at the protocol layer
  (LXMF-4d) but is **not** wired into the app's live `LXMFNode` composition.
  Wiring it (PN Endpoint/Transport glue + sync + PN settings) is slice 3, not
  part of this slice.

## Non-goals

- No contact names / address book / CRUD.
- No propagation / offline delivery / message sync from a propagation node.
- No message deletion, editing, read receipts, or unread badges.
- No DB schema migration (the `messages` table is unchanged).

## Architecture

Everything stays in the existing single `AppFeature` reducer + SwiftUI views —
no new child reducers beyond the already-scoped `LXMFNode`. The `Message`
`@Table` and the GRDB migration are untouched. Conversations are computed from
messages on demand; reachability is session-only in-memory state.

### Derived type

```swift
public struct Conversation: Identifiable, Equatable, Sendable {
    public var peerHex: String     // id
    public var lastBody: String
    public var lastTimestamp: Date
    public var id: String { peerHex }
}
```

Never persisted. Built by reading all messages ordered by `timestamp` and
keeping the newest row per `peerHex`, then sorting most-recent-first (grouped in
Swift rather than via SQL `GROUP BY`/`MAX` — acceptable at messenger scale). A
conversation with zero messages does not appear in the list until its first
message exists (consistent with the derived model).

### `AppFeature.State` changes

**Remove:** `@Shared("peerAddressHex") peerAddressHex`, the flat
`messages: [Message]`, and `peerReachable: Bool`.

**Add:**
- `conversations: [Conversation] = []` — the list; reloaded after every write.
- `openPeerHex: String? = nil` — the thread currently pushed; drives navigation.
- `threadMessages: [Message] = []` — messages for `openPeerHex`.
- `reachablePeers: Set<String> = []` — populated from `pathLearned`.

**Keep:** `node`, `identity`, `myAddressHex`, `@Shared host`, `@Shared port`,
`draft`, `connection`.

### Actions & wiring

- `.onLaunch` — set `connection = .connecting`, dispatch `node.endpoint(.connect)`
  **and** kick a conversations reload.
- `.conversationsLoaded([Conversation])` — `state.conversations = rows`.
- `.threadLoaded([Message])` — `state.threadMessages = rows`.
- `.openConversation(String)` — set `openPeerHex`, load that peer's thread
  (read `Message.where { $0.peerHex.eq(peer) }.order(by: \.timestamp)`).
- `.closeConversation` — set `openPeerHex = nil`, `threadMessages = []`.
- `.startConversation(String)` — from the compose sheet: validate the hex
  (`Data(hexString:)` decodes AND is 16 bytes, the lxmf.delivery hash length);
  on valid, behave like `.openConversation` for a possibly-empty thread; on
  invalid, no state change.
- `.sendTapped` — guard `draft` non-empty and `openPeerHex` present + valid;
  create the `LXMessage`, insert an outgoing `Message(status: .sending)` for
  `openPeerHex`, clear `draft`, then reload **both** the thread and the
  conversation list, and dispatch
  `node.send(destinationHash:title:content:method:.opportunistic)`.
- `.node(.delegate(.messageReceived(m, validated)))` — insert an incoming
  `Message(isOutgoing: false, peerHex: m.sourceHash.hexString, validated:)`,
  reload the conversation list, and reload the thread **only if**
  `m.sourceHash.hexString == openPeerHex` (the peer-filter; fixes MVP Task 4
  minor a).
- `.node(.delegate(.deliveryFailed(hash)))` — update the matching row's status
  to `.failed` by `messageHash`, then reload thread-if-open + conversation list.
- `.node(.endpoint(.delegate(.pathLearned(h, _))))` — insert `h.hexString` into
  `reachablePeers`.
- `.node(.endpoint(.transport(.interfaceConnected)))` → `connection = .connected`
  + `node.registerDelivery`; `.interfaceDisconnected` → `connection = .disconnected`
  (unchanged from MVP).
- `.connectTapped` / `.disconnectTapped` (unchanged from MVP).

Note: `m.sourceHash` is the sender's **lxmf.delivery** hash (LXMF uses
delivery-destination hashes for source/dest), so incoming `peerHex` matches the
outgoing `peerHex` for the same peer — the conversation groups correctly.

## UI

### `ConversationListView` (new) — Chat tab root inside a `NavigationStack`
- `List(store.conversations)`; each row shows truncated `peerHex` (first 4 + `…`
  + last 2), the `lastBody` preview, and a relative timestamp.
- Row tap → `.openConversation(peerHex)`, push `ChatView`.
- `+` toolbar button → compose sheet: one `TextField` for a peer address + a
  Start button disabled until the hex validates (decodes to a 16-byte hash).
  Start → `.startConversation(hex)`, dismiss, push the thread.
- Connection-status dot lives here (tab root).
- Navigation binding: `NavigationStack` with `openPeerHex` driving a
  `.navigationDestination` push (exact SwiftUI binding is a plan detail);
  back/disappear → `.closeConversation`.

### `ChatView` (per-peer thread — existing view, re-parameterized)
- Renders `store.threadMessages` (was the flat `messages`). `MessageBubble`
  unchanged.
- Send row gated on `store.reachablePeers.contains(openPeerHex) && !draft.isEmpty`.
- Navigation title = truncated peer hex.

### `SettingsView`
- Drop the peer-address field (moved into per-conversation compose). Keep
  host/port + connect/disconnect.

### `AddressView`
- Unchanged (shows `myAddressHex`).

## Testing

TestStore, reducer only (views untested, as in the MVP): `.off` exhaustivity,
in-memory DB (`AppDatabase.makeInMemory`), `$0.uuid = .incrementing`, mock
`TCPConnection`. Each new/changed test gets the three-step mutation
verification (pass → mutate production to break → confirm fail → revert →
pass).

1. **`onLaunchLoadsConversations`** — seed rows for two peers; `.onLaunch` →
   `.conversationsLoaded` reflects both, most-recent-first.
2. **`openConversationLoadsThatPeersThread`** — seed A and B; `.openConversation(A)`
   → `threadMessages` are A's only, in timestamp order.
3. **`sendPersistsToOpenPeerAndReloadsBoth`** — with A open, `.sendTapped` →
   outgoing row for A persisted, thread + conversations reload, `node.send`
   dispatched with `.opportunistic`.
4. **`receivedFromOpenPeerReloadsThread`** — with A open, inbound from A →
   `threadMessages` refreshed to include it.
5. **`receivedFromOtherPeerDoesNotReloadThread`** — with A open, inbound from B →
   `conversations` refreshed, `threadMessages` unchanged (still A's).
6. **`deliveryFailedMarksFailedAndReloads`** — outgoing row → `deliveryFailed(hash)`
   → that row's status `.failed`, thread reloaded.
7. **`pathLearnedMarksPeerReachable`** — `pathLearned(A)` →
   `reachablePeers.contains(A.hex)`.
8. **`startConversationRejectsInvalidHex`** — malformed / wrong-length hex → no
   `openPeerHex` change.

## Files

- **Modify** `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` — state,
  actions, wiring per above.
- **Create** `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Conversation.swift` — the
  derived struct + the group-latest-per-peer helper.
- **Modify** `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` —
  the eight tests above (replacing the three MVP tests where they overlap).
- **Create** `ReTiCaMsgr/ConversationListView.swift` — list + compose sheet.
- **Modify** `ReTiCaMsgr/ChatView.swift` — render `threadMessages`, per-peer gate.
- **Modify** `ReTiCaMsgr/SettingsView.swift` — remove the peer field.
- **Modify** `ReTiCaMsgr/ContentView.swift` (RootView) — Chat tab now hosts
  `ConversationListView` in a `NavigationStack`.
- **No change** to `Message.swift`, `Database.swift`, `IdentityStore.swift`,
  `Data+Hex.swift`, the DB migration, or `Package.swift`.

## Decomposition

Single slice, one implementation plan. Suggested task order: (1)
`Conversation` type + latest-per-peer helper (+ unit test); (2) `AppFeature`
state/action refactor + the eight reducer tests; (3) SwiftUI views
(`ConversationListView`, `ChatView`, `SettingsView`, `RootView`) + xcodebuild.
Tasks 1–2 are `swift test`-verifiable headlessly; task 3 needs `xcodebuild`.
