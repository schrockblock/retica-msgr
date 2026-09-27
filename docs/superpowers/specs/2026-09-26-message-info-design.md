# Message Info sheet

**Written:** 2026-09-26. **Repo:** ReTiCaMsgr (`/Users/ell/development/ios/apps/ReTiCaMsgr`). The logic
is in `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/` and the UI in `ReTiCaMsgr/`. Implementation happens in
the worktree `/Users/ell/development/ios/apps/ReTiCaMsgr-message-info` on branch `feat/message-info`,
which merges to `main`.

## Goal

Long-pressing a message offers an **Info** row that opens a sheet of detailed, copyable metadata
about that message. The primary audience is the developer debugging the mesh: timelines, delivery
method, hashes, signature and stamp state, sizes, and which LXMF fields were present.

## Decisions (agreed during brainstorming)

- **The audience is debugging** (option 2). Raw technical detail is shown, not a simplified view.
- **App-only.** Hop count, arrival interface and retry count need ReTiCA changes, so they are
  deferred to `docs/superpowers/backlog-retica-followups.md`.
- **Status history uses one column per milestone** (`storedAt`, `deliveredAt`, `failedAt`) rather
  than an event log. Each records the *first* time that milestone happened and is never
  overwritten, so ordering can be worked out from the times.

## Current state

- `Message` (`Message.swift`) has `id, peerHex, isOutgoing, body, timestamp, status, validated,
  messageHash`. `MessageStatus` has `sending, sent, failed, received, propagated ("stored"),
  delivered`.
- `timestamp` is *our* clock: receive time for incoming messages, send time for outgoing ones. The
  sender's LXMF timestamp is discarded.
- ReTiCA's `LXMFNode.Delegate.messageReceived(message:signatureValidated:method:)` already reports
  the arrival method, which the app ignores (`AppFeature.swift:605`).
- The status handlers that update outgoing rows by hash are `deliveryFailed` (:683),
  `propagationAccepted` (:797) and `deliveryConfirmed` (:818). All filter on `isOutgoing`, and
  `delivered` is protected from being overwritten.
- `sendTapped` (:486) builds the `LXMessage`. Stamps are added later by LXMFNode, so the app never
  sees the outgoing stamp.
- The long-press menu in `ChatView.swift` currently holds `ReactionPaletteMenu` (six emoji plus
  "More Reactions") followed by "Copy".

## Data model

One new migration, `addMessageInfo`, registered after `createReactions` in `Database.swift`, adds
nullable columns to `messages`. Existing rows read back as `NULL`.

| Column | SQLite / Swift | Incoming | Outgoing |
|---|---|---|---|
| `senderTimestamp` | datetime / `Date?` | `Date(timeIntervalSince1970: m.timestamp)` | the send time (same as `timestamp`) |
| `arrivalMethod` | text / `String?` | `"opportunistic"` / `"direct"` / `"propagated"` | nil |
| `sentViaPropagation` | boolean / `Bool?` | nil | `!propagationNodeHex.isEmpty` at send |
| `storedAt` | datetime / `Date?` | nil | first `propagationAccepted` |
| `deliveredAt` | datetime / `Date?` | nil | first `deliveryConfirmed` |
| `failedAt` | datetime / `Date?` | nil | first `deliveryFailed` |
| `wireSize` | integer / `Int?` | `m.receivedBytes?.count` | `msg.packed.count` |
| `titleSize` | integer / `Int?` | `m.title.count` | `msg.title.count` |
| `contentSize` | integer / `Int?` | `m.content.count` | `msg.content.count` |
| `fieldKeys` | text / `String?` | lowercase hex keys in wire order, e.g. `"0xfb,0xfc"`; `""` if none | same, for what we built |
| `stampState` | text / `String?` | `"none"` (no stamp), `"unchecked"`, `"valid"`, `"invalid"` from `stamp`/`stampChecked`/`stampValid` | nil (added downstream, invisible to the app) |

- The new `Message` properties all default to `nil`, so every existing `Message(...)` construction
  site keeps compiling.
- The string values for `arrivalMethod` and `stampState` are constants on new `enum ArrivalMethod`
  and `enum StampState` namespaces, in the same style as `MessageStatus`.
- Reaction messages create no `Message` row, so they get no metadata.

### Writes

- **`messageReceived`, text path:** the new incoming columns are set in the same `Message` insert.
- **`sendTapped`:** the new outgoing columns are set in the same insert.
- **Milestones.** Each status handler gains a second update. For outgoing rows with that hash, it
  sets its milestone column **only where the column is still NULL**, to `date.now` from the injected
  `\.date` dependency. This happens even when the status update itself is suppressed. For example, a
  late `propagationAccepted` after `delivered` leaves the status as "delivered" but still records
  `storedAt`. Incoming rows are never touched, because of the existing `isOutgoing` filter.

## Presentation

### Core: `MessageInfo` (pure, unit-tested)

`MessageInfo.sections(for message: Message) -> [MessageInfo.Section]`:

- `Section { title: String, rows: [Row], footer: String? }`
- `Row { label: String, display: String, copy: String }`

This is where all formatting happens:

- **Times** are absolute, as `HH:mm:ss` in the local time zone. A time on a different calendar day
  from the message's `timestamp` is prefixed with the date.
- **Gaps** are shown relative to Sent, e.g. `+1m 21s`, `+4s`, `+2h 03m`, with negative gaps as
  `-3s`.
- **Clock skew** for incoming messages is `timestamp - senderTimestamp`, shown with its sign.
- **Hashes** display middle-shortened as `first4…last4` in hex. The copy value is the full hex.
- **Field keys** display with known names: `0x01 embedded LXMs`, `0x02 telemetry`,
  `0x03 telemetry stream`, `0x04 icon appearance`, `0x05 file attachments`, `0x06 image`,
  `0x07 audio`, `0x08 thread`, `0x09 commands`, `0x0A results`, `0x0B group`, `0x0C ticket`,
  `0x0D event`, `0x0E RNR refs`, `0x0F renderer`, `0x30 reply to`, `0x31 reply quote`,
  `0x40 reaction`, `0x41 comment`, `0x42 continuation`, `0xFB custom type`, `0xFC custom data`,
  `0xFD custom meta`, `0xFE non-specific`, `0xFF debug`. These are the names from reference
  `LXMF/LXMF.py` (LXMF 1.1.0). Unknown keys show as hex only.
- **Hidden rows:** milestone rows that never happened are omitted.
- **Missing data:** any row whose data is NULL on a legacy message shows "—".
- **Legacy footer:** the Identity section carries the footer "Some details weren't recorded for
  messages from before this feature." when `senderTimestamp == nil`.

**Sections**, in order:

1. **Timeline**
   - *Outgoing:* Sent (`timestamp`), then Stored on node / Delivered / Failed, each shown as absolute
     time plus the gap from Sent, and each only if set. Then Status (the raw `status`).
   - *Incoming:* Written (`senderTimestamp`), Received (`timestamp`), Skew, Status.
2. **Delivery**
   - *Incoming:* Arrival: Opportunistic / Direct link / Propagation node, or "—".
   - *Outgoing:* Propagation node copy: Yes / No, or "—".
3. **Identity**
   - Message hash, or "—" when empty on legacy incoming messages.
   - Peer (`peerHex`).
   - Signature: Validated / Not validated for incoming messages, "n/a" for outgoing ones.
4. **Payload**
   - Wire size (e.g. `412 B`), title and content sizes.
   - Fields: one row per key, or a single "None" row.
   - Stamp: for incoming messages, None / Not checked / Valid / Invalid; for outgoing ones, "—".

### App: `MessageInfoSheet` and `ChatView`

- **Menu row.** `ChatView`'s context menu gets `Button("Info", systemImage: "info.circle")` between
  the reaction items and "Copy". It appears on every bubble, including legacy bubbles that have no
  hash.
- **Presentation.** The sheet uses the same `sheet(item:)` pattern as `EmojiPickerSheet`, keyed by
  message id, with `.presentationDetents([.medium, .large])`.
- **Layout.** The sheet is a `NavigationStack` containing an inset-grouped `List` titled "Info",
  with a Done button. Each row has the label on the left and the display value on the right,
  monospaced and able to be truncated.
- **Tap to copy.** Tapping a row writes `copy` to `UIPasteboard.general.string` and shows a brief
  "Copied" overlay. Rows use `.frame(maxWidth: .infinity, alignment: .leading)` and
  `.contentShape(Rectangle())`, per the whole-row-tap rule.
- **Data source.** The sheet reads the `Message` from `store.threadMessages` by id, so it reflects
  live milestone updates while open.

## Testing

Swift Testing in `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/`. Every new test goes through
mutate → red → revert → green. Absence claims use exhaustive stores. The full core suite stays
green with no new known issues.

- **Migration.** A database migrated through `createReactions`, with a row inserted, then migrated
  through `addMessageInfo`, reads back that row with all new fields nil.
- **Receive.** An incoming text message stores:
  - `senderTimestamp` equal to the message's timestamp
  - `arrivalMethod` for each of the three methods
  - `wireSize`, `titleSize` and `contentSize`
  - `fieldKeys` (empty, plus a case with fields present)
  - `stampState` for none, unchecked, valid and invalid

  A reaction still creates no row.
- **Send.** The outgoing row stores its sizes, `fieldKeys == ""`, and `sentViaPropagation` both with
  and without a propagation node configured.
- **Milestones.**
  - The first `deliveryConfirmed`, `propagationAccepted` and `deliveryFailed` each set their column.
  - A repeat event doesn't move the time. Advance the test clock between events to prove it.
  - A late `propagationAccepted` after `delivered` records `storedAt` while the status stays
    `delivered`.
  - A false `failed` followed by `stored` records both times.
  - Incoming rows sharing the hash are untouched.
- **`MessageInfo`.**
  - Sections and rows for an outgoing message with all milestones.
  - An outgoing message with only Sent.
  - An incoming message with positive and negative skew.
  - A legacy incoming message (all nil, empty hash, footer present).
  - The gap and duration formats (seconds, minutes, hours, negative).
  - A cross-day time.
  - Field-key naming, including an unknown key.
  - Hash truncation and copy values.
- **UI (manual).** In the simulator, with a temporary seeded database that is removed before any
  commit:
  - the Info row appears in the menu;
  - the sheet is correct for an incoming, an outgoing, and a legacy message;
  - tap to copy works, checked by pasting into the draft field;
  - a milestone that arrives while the sheet is open updates it.

## Addendum: reactions move to the standard `FIELD_REACTION` (0x40)

**Agreed:** 2026-09-27.

Reference LXMF 1.1.0 (`LXMF/LXMF.py:25,109-110`) defines `FIELD_REACTION = 0x40`, a dict with these keys:
- `REACTION_TO` (`0x00`): the full `LXMessage.hash` of the target, as bytes;
- `REACTION_CONTENT` (`0x01`): the reaction, as UTF-8 bytes.

The emoji-reactions feature shipped on 2026-09-25 uses a custom `0xFB "reticamsgr.reaction"` / `0xFC`
format instead, because the standard was missed at the time. No known client implements `0x40` yet;
Sideband's core has no reaction handling. The standard doesn't define removal, so we choose the
convention below.

- **Send:**
  - Every reaction is sent as `fields[0x40] = .intMap([0x00: .bin(target), 0x01: .bin(emoji UTF-8)])`.
  - The legacy `0xFB`/`0xFC` fields are no longer sent.
  - **Removal is sent as empty `REACTION_CONTENT` bytes.**
  - Last-writer-wins and the monotonic own `sentAt` are unchanged, because both use the LXMF message
    timestamp.
- **Receive:**
  - Both formats are accepted. A well-formed `0x40` is tried first, then the legacy `0xFB` format.
  - A message whose `0x40` field decodes as a reaction is handled as a reaction and never becomes a
    bubble, whatever its content.
  - A `0x40` field that is present but malformed is dropped, not rendered. Malformed means any of:
    - not an int-keyed map;
    - `0x00` missing or not bin, or its length outside 16–32;
    - `0x01` missing or not bin;
    - content over `ReactionWire.maxEmojiBytes` (64);
    - content that isn't valid UTF-8.
  - A message with neither format is a normal message.
- **Code:**
  - `ReactionWire.encode` emits the standard format.
  - `ReactionWire.decode` returns the same `Decoded` cases for both formats.
  - Constants `fieldReaction = 0x40`, `reactionTo = 0x00` and `reactionContent = 0x01` are added.
  - The legacy decoding path is kept.
  - Nothing else in the reaction pipeline changes.
- **Tests:**
  - A round trip through a real `LXMessage.create` → pack → unpack in the standard format, including
    removal as empty bytes.
  - The legacy format still decodes.
  - When both fields are present, the standard format wins.
  - Each malformed standard case listed above is dropped.
  - A standard-format reaction with fallback text in `content` is not a bubble (AppFeature).
  - `reactionSelected` sends the standard format.
  - Existing reaction tests are updated to the new encoding.
  - The usual mutation check.

## Out of scope

- Everything in `docs/superpowers/backlog-retica-followups.md`: hops, interface, retry count, and
  the delivery-correctness fixes.
- Status styling in bubbles.
- An event-log history.
- Info for reaction messages.
- Exporting or sharing the info.
- The stale `DiagnosticsSnapshot` comment about unacknowledged opportunistic sends. That is a
  separate one-line cleanup.
