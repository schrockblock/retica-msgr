# Emoji reactions on messages

**Written:** 2026-09-25. **Repo:** ReTiCAMsgr (`/Users/ell/development/ios/apps/ReTiCAMsgr`),
logic in `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/`, UI in `ReTiCAMsgr/ChatView.swift`. Target: `main`.

## Goal

Long-pressing a message bubble lifts and highlights it (system context menu, like Signal/iMessage)
and offers a row of quick reactions — ❤️ 👍 👎 😂 😮 😢 — plus a ＋ button that opens a searchable
picker of the full emoji set. The chosen reaction is shown as a badge on the bubble and is delivered
to the peer over LXMF, so both sides see it.

## Decisions (agreed during brainstorming)

- **Wire format: our own, first.** Reactions use LXMF's reserved custom-extension fields. A
  human-readable text fallback for other clients (`Reacted ❤️ to "…"`) is a later phase; this spec
  leaves room for it (see *Reaction messages never become bubbles*).
- **One reaction per person per message** (Signal/iMessage semantics). Picking a different emoji
  replaces yours; picking your current one removes it.
- **Context menu actions: Copy only**, beneath the emoji row.
- **UI approach: native SwiftUI `.contextMenu` with a palette row** (not a custom overlay). If it
  doesn't feel close enough, a custom overlay can replace the view layer later without touching
  the data layer.

## Current state (what this builds on)

- `Message` (`Message.swift:7-37`) is a SQLiteData `@Table`. Outgoing rows store
  `messageHash = LXMessage.hash.hexString`; **incoming rows store `""`**
  (`AppFeature.swift` `messageReceived` handler, `messageHash: ""`).
- `sendTapped` (`AppFeature.swift:473-506`) builds `LXMessage.create(... title:content:)` with no
  `fields` and sends via `.node(.client(.sendMessage(message:alsoViaPropagation:)))`.
- `messageReceived` (`AppFeature.swift:558-614`) decodes `content` into `body`, ignores `fields`
  (other than a diagnostic log line), inserts a `Message`, upserts a `SeenHashRow`, and reloads.
- `LXMessage.create` already accepts `fields: [MsgPackValue.IntPair]`, and unpack parses the fields
  map (ReTiCA `LXMF/LXMessage.swift:108-128, 208-211`). **No ReTiCA library changes are needed.**
- `MessageBubble` (`ChatView.swift:43-65`) has no gestures or context menu.

## Wire format

A reaction is a standalone LXMF message to the peer with empty `title`, empty `content`, and:

| Field key | Value |
|---|---|
| `FIELD_CUSTOM_TYPE` (`0xFB`) | string `"reticamsgr.reaction"` |
| `FIELD_CUSTOM_DATA` (`0xFC`) | map `{ "target": bin, "emoji": str }` |

- `target` — the raw LXMF hash (bytes) of the message being reacted to. Accepted length 16–32 bytes.
- `emoji` — the reaction, UTF-8, at most 64 bytes (room for any ZWJ sequence with skin tones a
  future client might send). **Empty string = "I removed my reaction."**
- Ordering clock is the reaction LXMessage's own `timestamp` (sender's clock). Each reactor only
  ever overwrites their own reaction, so comparisons are always within one clock. The sender makes
  its own timestamps strictly monotonic per message (`max(now, previous + 0.001)`), so two taps in
  one clock tick still apply in order on both ends.
- Sent via the existing `.sendMessage(message:alsoViaPropagation:)`, so reactions get direct
  delivery and propagation-node store-and-forward exactly like text. Fire-and-forget: no delivery
  status or failure UI for reactions.

### Receive rules

- **Reaction messages never become bubbles.** If `FIELD_CUSTOM_TYPE == "reticamsgr.reaction"`, the
  message is handled as a reaction regardless of `content`. (Phase 2 will put fallback text in
  `content`; our app must already ignore it.) If the type matches but `FIELD_CUSTOM_DATA` is
  malformed, the message is dropped (not rendered as an empty bubble).
- Unvalidated (`validated == false`) reactions are dropped — they can't be attributed.
- Reactions record a `SeenHashRow` like any message (same dedup path).
- A reaction may arrive before its target (propagation reordering). It is stored anyway and shows
  once the target message arrives.

## Data model

1. **Incoming messages store their hash.** No schema change — `messageHash` exists. The receive
   path writes `m.hash.hexString` instead of `""`. Existing incoming rows keep `""` and **cannot be
   reacted to** (their menu shows Copy only).
2. **`reactions` table** — one new migration, `createReactions`, registered after the existing ones
   in `AppDatabase.migrator()` (`Database.swift`):

   | Column | Type | Notes |
   |---|---|---|
   | `messageHash` | TEXT NOT NULL | hex of target LXMF hash |
   | `reactorHex` | TEXT NOT NULL | peer hex, or own identity's delivery-destination hex |
   | `emoji` | TEXT NOT NULL | `""` = tombstone (removed) |
   | `sentAt` | REAL/DATETIME NOT NULL | reaction's LXMF timestamp |

   Primary key `(messageHash, reactorHex)`. Index on `messageHash`.

`Reaction.apply(_:db)` upserts **only if the incoming `sentAt` is strictly newer** than the stored
row's. Removals are stored as tombstones (`emoji = ""`), never deleted, so a late-arriving older
"❤️" cannot resurrect a removed reaction.

### Display filtering

`reloadThread` loads reactions for the thread's non-empty message hashes and keeps only those whose
`reactorHex` is the local identity or that thread's `peerHex`. A third party that learns a message
hash therefore cannot inject a reaction into someone else's conversation view.

## Core components (`ReTiCAMsgrCore`)

- **`ReactionWire`** — pure `encode(target: Data, emoji: String) -> [MsgPackValue.IntPair]` and
  `decode(_ fields: [MsgPackValue.IntPair]) -> Decoded?` where `Decoded` distinguishes
  *not a reaction* (fall through to text), *reaction* `(target, emoji)`, and *malformed reaction*
  (drop). Enforces the length limits above.
- **`Reaction`** — `@Table` row per *Data model*, plus `apply(_:db)`.
- **`ReactionSummary`** — pure `summarize([Reaction], me: String) -> [Item]` with
  `Item { emoji, count, includesMe }`; drops tombstones; ordered by earliest `sentAt` per emoji.
- **`QuickReactions.default`** — `["❤️", "👍", "👎", "😂", "😮", "😢"]`.
- **`EmojiCatalog`** — loads a bundled SPM resource: a trimmed Unicode `emoji-test.txt`
  (fully-qualified entries only, **no skin-tone variants**). Exposes `groups: [Group]` where
  `Group { name, emojis: [Entry] }`, `Entry { emoji, name }`, and `search(_ query:) -> [Entry]`
  (case-insensitive name substring). Roughly 1,900 entries, < 100 KB.

### `AppFeature` changes

- **State:** `threadReactions: [String: [ReactionSummary.Item]]` keyed by message hash hex.
  `.threadLoaded` carries reactions alongside messages; `.closeConversation` clears them.
- **Action `.reactionSelected(messageHash: String, emoji: String)`:**
  - No-op if `messageHash` is empty or no conversation is open.
  - Look up my current emoji on that message. Same emoji → send `""` (remove); otherwise send the
    new emoji.
  - Build the reaction `LXMessage` (`timestamp = date.now`), `Reaction.apply` my own row
    immediately (optimistic), send via `.sendMessage(alsoViaPropagation: !propagationNodeHex.isEmpty)`,
    reload the thread.
  - No reachability gate in the reducer (matches `sendTapped`); the UI gates.
- **`messageReceived`:** at the top, `ReactionWire.decode(m.fields)`:
  - *reaction*: if `validated`, `Reaction.apply` with `reactorHex = m.sourceHash.hexString`,
    `sentAt = m.timestamp`; always write the `SeenHashRow` + prune; reload the thread if that peer's
    conversation is open. **Do not** insert a `Message` or reload conversations — reactions don't
    affect the conversation list preview or ordering.
  - *malformed reaction*: write the `SeenHashRow`, nothing else.
  - *not a reaction*: existing behavior, but `messageHash: m.hash.hexString`.

## UI (`ReTiCAMsgr` app target)

- **`MessageBubble`** gets
  `.contextMenu { ReactionPaletteMenu(...) ; Button("Copy") } preview: { MessageBubble(...) }`.
  The system provides the lift, highlight, blur, and haptic.
  - Copy writes `message.body` to `UIPasteboard.general.string`.
  - Bubbles with empty `messageHash` omit the palette (Copy only).
  - When the peer is not reachable (same condition as the Send button, minus the draft check), the
    palette is shown disabled.
- **`ReactionPaletteMenu`** — encapsulates the palette row: six quick emoji + ＋. Implementation
  mechanism is decided by the first plan task, a UI spike, choosing between:
  - `Picker(selection:)` + `.pickerStyle(.palette)` — free "selected" state for my current
    reaction; must verify re-tapping the selected item fires (needed for toggle-off).
  - `ControlGroup { Button… }` + `.controlGroupStyle(.palette)` — explicit taps always fire; showing
    the current selection is harder.
  - The spike also confirms emoji `Text` renders well in a palette; fallback is pre-rendered
    `Image`s via `ImageRenderer`.
- **Badge** — a small capsule overlapping the bubble's bottom corner (trailing side for outgoing,
  leading for incoming) showing each summary item's emoji, with a count when `count > 1`, and a
  tinted border when `includesMe`. Not tappable in v1.
- **`EmojiPickerSheet`** — presented by ＋. `.presentationDetents([.medium, .large])`,
  `.searchable` over `EmojiCatalog.search`, `LazyVGrid` sectioned by group. Tapping an emoji sends
  `.reactionSelected` and dismisses. Grid cells use
  `.frame(maxWidth: .infinity).contentShape(Rectangle())` so the whole cell is tappable.

## Testing

Core tests use Swift Testing in `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/`, run with
`swift test --package-path ReTiCAMsgrCore`. Every new test goes through the mutate → red → revert →
green verification.

- **`ReactionWire`**: round-trip through a real `LXMessage.create` → pack → unpack; empty emoji
  round-trips as removal; decode returns *not a reaction* for no/other custom type; *malformed* for
  missing target, bad target length, non-string emoji, emoji > 64 bytes.
- **`Reaction.apply`**: newer replaces; older ignored; equal ignored; tombstone beats late older add.
- **`ReactionSummary`**: tombstones dropped; count and `includesMe` correct; ordering by earliest
  `sentAt`.
- **`EmojiCatalog`**: resource loads, is non-empty, contains all six quick reactions, no skin-tone
  modifiers present, search matches by name case-insensitively.
- **`AppFeature` (TestStore, `exhaustivity = .off`)**:
  - incoming text message stores `m.hash.hexString` as `messageHash`;
  - incoming reaction inserts no `Message`, stores a `Reaction`, writes the seen hash, and appears
    in `threadReactions` when that thread is open;
  - unvalidated reaction is dropped; malformed reaction is dropped (no `Message`);
  - reaction from a peer other than the thread's peer is not shown in that thread;
  - `.reactionSelected` sets, replaces, and toggles off (sends `""`), and the sent `LXMessage`'s
    fields decode back via `ReactionWire`;
  - `.reactionSelected` with empty hash is a no-op.
- **UI**: manual verification in the simulator with screenshots — long-press highlight, palette
  row, toggle off, ＋ sheet + search, badges on both sides, Copy.

## Out of scope

- Text fallback in `content` for non-ReTiCAMsgr clients (phase 2). Until then, Sideband/MeshChat
  users will likely see reaction messages as blank bubbles.
- Skin-tone variants; recently-used emoji.
- Tappable badges / "who reacted" list.
- Info and Delete context-menu actions.
- Reactions in the conversation-list preview or affecting conversation order.
- Reacting to legacy incoming messages stored with an empty hash.
