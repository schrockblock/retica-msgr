# Disappearing messages — design

**Date:** 2026-10-05. **Scope:** ReTiCaMsgr app only (Core package plus app UI); no ReTiCA
changes. **Follows:** the decision record `docs/superpowers/2026-10-02-groups-vs-disappearing-messages.md`,
which chose this feature over group chats and listed five open questions. All five are answered
below.

## Goal

Give a conversation a shared timer, in the style of Signal and WhatsApp, after which each message
is deleted from this device: the row, its attachment file and export copies, and its reactions.
The timer is carried on the wire in a custom LXMF field so two ReTiCaMsgr peers behave the same
way; other LXMF clients ignore it and keep the message, and the UI says so.

## Decisions taken while brainstorming

- **Purpose: feature parity.** Users expect the Signal/WhatsApp model; match it as closely as
  LXMF allows. Forensic hardening is not the goal.
- **Timer start: Signal model.** The recipient's copy starts when they first view it in the open
  thread. The sender's copy starts at send. On Reticulum a message can sit undelivered for days,
  so the sender's copy may vanish before delivery; accepted, as Signal accepts it.
- **Scope: shared per-conversation setting.** Either party sets the timer. The change goes out as
  a message carrying the new duration and a readable body, so the peer adopts it and
  non-honouring clients still see a sentence. Every message in the conversation also carries the
  duration, so the receiving side applies it per message and the two sides converge after a
  missed timer-change message.
- **Wire field: `FIELD_CUSTOM_META` (0xFD)** holding a msgpack map keyed by a namespaced string.
  Chosen over the 0xFB/0xFC type+data pair (a single slot per message, and Retichat already uses it
  for key transfer) and over misusing a standard field. Upstream `LXMF.py` was re-checked on
  2026-10-05: no expiry, TTL or ephemeral field exists; the only expiries are router-side
  (30-day propagation store, 21-day tickets).
- **UI: chat toolbar menu** with Signal's presets. No conversation details screen, no composer
  control.
- **Expiry driver: AppFeature glue plus pure helpers.** An `expiresAt` column, a pure schedule
  helper, a `MessagePurge` type for the database and file work, and one cancellable clock sleeper
  in the reducer. A child `ExpiryFeature` reducer was rejected as ceremony; view-side filtering
  was rejected because expired rows would stay on disk.
- **Timer-change announcements never expire** and are stored as their own row kind. Signal does
  the same.
- **A reply to a purged message keeps its embedded quote** (0x31 already carries the text). Signal
  does the same.
- **This is the app's first message deletion.** Nothing deletes a `messages` row today; the purge
  introduces it and owns every on-disk consequence.

## 1. Wire format

Every outgoing message in a conversation with an active timer carries field 0xFD:

| field | type | content |
|---|---|---|
| `0xFD` `FIELD_CUSTOM_META` | msgpack map | `{ "reticamsgr.expiry": <uint seconds> }` |

- `reticamsgr.expiry` is the duration in seconds the message should live after the recipient first
  views it. Range 1 … 2 419 200 (4 weeks). On a timer-change message the value may be `0`,
  meaning the timer is turned off.
- A **timer-change message** is an ordinary LXMF message whose body is readable text and whose
  0xFD field carries the new value:

  ```
  Disappearing messages set to 1 day
  Disappearing messages turned off
  ```

  Sideband, NomadNet and Retichat show that sentence; ReTiCaMsgr renders it as a system line.
- **Reactions** are content-less messages that are never stored, so they carry no field.

### `ExpiryWire` (Core, pure)

Follows `AttachmentWire` / `ReplyWire`: constants, cap, `encode(seconds:) -> [MsgPackValue.IntPair]`
and a lenient `decode(fields:) -> Int?`.

Decode returns `nil` ("no expiry") for: no 0xFD field; a 0xFD value that is not a map
(lxmf-group-hub puts other data there); a map without our key; a value that is not an integer; a
negative value; a value above the cap. Extra keys in the map are ignored. A malformed field never
drops the message, matching the other codecs.

The Info sheet's field-name table (`MessageInfo.swift`) names 0xFD "Custom meta" if it does not
already.

## 2. Data model

One append-only GRDB migration, `addDisappearingMessages`, after `createAttachments`:

| table.column | type | notes |
|---|---|---|
| `messages.expirySeconds` | INTEGER NULL | the duration carried on the wire; null = never disappears |
| `messages.expiresAt` | DOUBLE NULL | absolute wall-clock deletion time; null with non-null `expirySeconds` = received, not yet viewed |
| `messages.isTimerChange` | INTEGER NOT NULL DEFAULT 0 | announcement rows: rendered as a system line, no attachment, no reactions, never expire |
| `conversationSettings.peerHex` | TEXT PRIMARY KEY | |
| `conversationSettings.expirySeconds` | INTEGER NULL | null or 0 = off |
| `conversationSettings.updatedAt` | DOUBLE NOT NULL | |

- `Message` gains `expirySeconds: Int?`, `expiresAt: Date?` (stored like `deliveredAt`) and
  `isTimerChange: Bool`, all with defaulted init parameters.
- New `@Table struct ConversationSetting` mirrors `conversationSettings`.
- The setting cannot live in `learnedPeerRows`: that table is an announce cache, pruned after
  45 days and replaced on every announce.
- `AppFeature.State` gains `openConversationExpiry: Int?`, loaded with the thread and cleared on
  `closeConversation`.
- The purge reads only `expiresAt`. `expirySeconds` is kept for the bubble marker and the Info
  sheet.

## 3. Core logic and AppFeature changes

### `ExpiryPreset` (Core, pure)

An enum of the menu values with `seconds`, a short `label` ("30 seconds", "5 minutes", "1 hour",
"8 hours", "1 day", "1 week", "4 weeks", "Off") and
`announcement(seconds:) -> String` producing the bodies in §1. Also `label(forSeconds:)` for a
value received from a peer that is not a preset (format the seconds plainly).

### Setting the timer (`.expirySelected(seconds:)`)

1. Upsert `conversationSettings` for the open peer; set `openConversationExpiry`.
2. Insert a local outgoing `Message` with `isTimerChange = true`, body = announcement, no expiry.
3. Send that body as an LXMF message with the 0xFD field through `outgoing(fields:)`, so it gets
   the usual status, proof and failure handling. On failure the row shows the failed status and
   the local setting still applies (as in Signal).
4. Gated on peer reachability like the reaction palette, because the change must go out.

### Sending (`sendTapped`)

With a timer active for the open conversation: append the 0xFD field (after attachment and reply
fields) and store the row with `expirySeconds = setting` and `expiresAt = date.now + setting`.
Then run the purge-and-reschedule step (§ Purge).

### Receiving (`.messageReceived`)

Decode order becomes reaction → reply → attachment → expiry.

- **Body-bearing message with a duration:** store `expirySeconds`, leave `expiresAt` null. If the
  duration differs from the stored conversation setting (treating null and 0 as equal), update the
  setting and insert an incoming `isTimerChange` row with body
  `<peer display name> set disappearing messages to <label>` (or `… turned disappearing messages off`).
  This is the convergence rule for a missed timer-change message.
- **Timer-change message** (recognised by the 0xFD value together with a body equal to one of the
  announcement strings for that value): update the setting and store the row as an incoming
  `isTimerChange` row, body as received. The convergence rule does not also fire, so one line
  appears.
- **Message without the field:** stored as today. The conversation timer is left alone, so a
  non-honouring peer does not keep switching it off.
- If the thread for that peer is open and the app is active, the new row is stamped at once
  (§ First view).

### First view

A received message is viewed when it is in `threadMessages` while that thread is open and the app
is active. Three reducer moments cover that; each stamps
`expiresAt = date.now + expirySeconds` on every row of the open thread that has a duration and no
stamp, then runs purge-and-reschedule:

- `.openConversation` / `.startConversation`, after `reloadThread` completes;
- `.messageReceived` for the open peer;
- `.foregrounded` with `openPeerHex` set.

`.backgrounded` and scene phase `.inactive` do not stamp. A notification preview is not a view.
State gets a `isForeground: Bool` flag, set by `.foregrounded` / `.backgrounded`, so the
received-into-open-thread case stamps only while active.

### Purge

`MessagePurge` (Core) exposes `run(database, attachmentStore, now) async throws -> Date?`:

1. Select rows with `expiresAt <= now`.
2. For each: delete the export copies under `tmp/AttachmentExports/<attachment id>/`, delete the
   attachment file via `attachmentStore.delete`, delete reaction rows for its `messageHash` (no
   foreign key there), then delete the `messages` row (the `attachments` row goes by cascade).
3. Keep seen hashes, so a late propagation copy is not re-stored.
4. Return the earliest remaining `expiresAt`, or nil.

The reducer's purge-and-reschedule step calls `run`, then sends `.purgeCompleted(next:)`, which
reloads the thread and conversations through the existing `reloadThread` / `reloadConversations`
and, if `next` is non-nil, sleeps on `continuousClock` until then under `CancelID.expiry` with
`cancelInFlight: true`, sending `.expiryDue` on wake. `.expiryDue` runs the step again.

The step runs on: `.onLaunch`, `.foregrounded`, thread open, after every stamp, after every send
with a timer, and `.expiryDue`. Nothing runs while suspended; launch and foreground catch up.
Because the thread, previews and Info sheet all derive from reloaded state, they update by
themselves; an Info sheet open on a purged row already shows "Message unavailable".

## 4. UI

- **Toolbar menu.** ChatView's navigation bar gets a `Menu` with a timer glyph listing the
  `ExpiryPreset` cases with a checkmark on the current value, and a footer line "Only ReTiCaMsgr
  peers honour this. Other apps keep messages." Disabled while the peer is unreachable.
- **Title indicator.** With a timer active, a small timer glyph and the duration label sit next to
  the peer name.
- **System line.** `isTimerChange` rows render as a centred, secondary-styled single line in place
  of `MessageBubble`, with no context menu, reactions or reply.
- **Bubble marker.** Messages with `expirySeconds` show a small timer glyph in the bubble's status
  area. No live countdown and no per-bubble ticker.
- **Removal.** Expired rows leave the `List` when `threadMessages` reloads, with the default
  animation.
- **Conversation list.** No change. A timer-change body is a sensible preview; a conversation whose
  rows have all expired drops out by the existing derivation.
- **Info sheet.** Payload section lists 0xFD among the field keys; Timeline gains an "Expires"
  row when `expiresAt` is set and a "Disappears after" row when only `expirySeconds` is.

## 5. Testing

- **`ExpiryWireTests`:** encode yields one 0xFD IntPair with the expected map; decode
  round-trips; decode is nil for a missing field, a non-map 0xFD, a missing key, a string value,
  a negative value and a value over the cap; a map with extra keys still decodes ours.
- **`ExpiryPresetTests`:** seconds and label per preset; announcement body for a value and for off;
  label for a non-preset value.
- **`MessagePurgeTests`** (temporary database, `AttachmentStore.makeStore`): due rows are deleted
  with attachment file, export copy, attachment row and reaction rows; later rows survive and the
  returned next-due time is theirs; a row with null `expiresAt` is never touched; seen hashes
  survive.
- **`AppFeatureTests`** (TestStore, TestClock, moved `date` dependency):
  - selecting a timer writes the setting, inserts the announcement row, and sends a message with
    the 0xFD field and readable body;
  - sending with a timer active stores `expiresAt = now + duration` and includes the field;
  - receiving with a duration stores the row unstamped; equal setting left alone; different
    setting updated with one convergence line;
  - receiving a timer-change message updates the setting and stores only the announcement row;
  - opening a thread stamps unstamped rows; arriving into an open thread while active stamps at
    once; arriving while closed or backgrounded does not;
  - advancing the clock past `expiresAt` purges the row and reloads the thread; a 30-second timer
    with an open thread fires on time; a nearer expiry rescheduled the sleeper;
  - launch and foreground purge rows that fell due while suspended;
  - a message without the field leaves the conversation timer unchanged.
- **Mutation coverage:** one named mutation per test, listed in the implementation plan, per the
  project's plan-mutation rule.

## Out of scope

- Read receipts or any signal to the sender about when the recipient viewed a message.
- A live countdown on bubbles.
- Deleting messages manually, or deleting whole conversations (the purge primitives make these
  easy later).
- Honouring the field for messages that arrive via push wake-up but are never opened: they are
  stamped only on first view, as designed.
- Group conversations.
