# Disappearing messages — design

**Date:** 2026-10-05. **Scope:** ReTiCAMsgr app only (Core package plus app UI); no ReTiCA
changes. **Follows:** the decision record `docs/superpowers/2026-10-02-groups-vs-disappearing-messages.md`,
which chose this feature over group chats and listed five open questions. All five are answered
below.

## Goal

Give a conversation a shared timer, in the style of Signal and WhatsApp, after which each message
is deleted from this device: the row, its attachment file and export copies, and its reactions.
The timer is carried on the wire in a custom LXMF field so two ReTiCAMsgr peers behave the same
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

  Sideband, NomadNet and Retichat show that sentence; ReTiCAMsgr renders it as a system line.
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
  `ExpiryPreset` cases with a checkmark on the current value, and a footer line "Only ReTiCAMsgr
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

## Amendments at planning time (2026-10-05)

Decisions the implementation plan (`docs/superpowers/plans/2026-10-05-disappearing-messages.md`)
forced while turning §1–§4 into code. Where they differ from the text above, these win.

- **A1. Timer-change recognition.** A timer-change message is recognised by a second key in the
  0xFD map, `reticamsgr.expiry.change` = `true`, not by matching the body against the announcement
  strings. The body stays the readable sentence. `ExpiryWire.decode` returns
  `Decoded(seconds:isChange:)`; `encode(seconds:)` writes only the duration, `encodeChange(seconds:)`
  adds the flag.
- **A2. Purge result.** `MessagePurge.run` returns `Result(purged: Int, nextDue: Date?)`. The
  reducer reloads the thread and conversations only when `purged > 0`, so purge-and-reschedule can
  be appended after every existing reload without a second reload in the common case.
- **A3. Due comparison in Swift.** The purge fetches rows with a non-null `expiresAt` and compares
  in Swift (`<= now`), rather than comparing an optional column in SQL. The set is small.
- **A4. Explicit zero.** An ordinary message carrying `reticamsgr.expiry` = 0 means "the peer's
  timer is off": it converges the local setting to off with a line, like any other differing value.
  A message with no field at all still leaves the setting alone.
- **A5. Foreground flag.** `State.isForeground` starts `true`, becomes `false` on `.backgrounded`
  and `true` on `.foregrounded`. Opening a thread stamps regardless (a user action). A message
  arriving into the open thread is stamped only while `isForeground`.
- **A6. Reachability gate is UI-only.** The toolbar menu is disabled while the peer is unreachable,
  exactly as the reaction palette is. The reducer does not check reachability.
- **A7. Setting reaches state through its own action.** `reloadThread` also reads
  `conversationSettings` and sends `conversationExpiryLoaded(peerHex:seconds:)` after `threadLoaded`,
  guarded on the open peer, instead of widening `threadLoaded`.
- **A8. Convergence line details.** The inserted line is an incoming `isTimerChange` row with an
  empty `messageHash`, `fieldKeys` `""`, and a timestamp 1 ms before the message that triggered it,
  so it sorts above that message. The peer name comes from the stored announce and falls back to
  "Them" (`ReplyPreview.them`). A received change message with an empty body gets the same local
  text.
- **A9. Only validated senders.** The 0xFD field is decoded only when the message's signature
  validated. An unvalidated message is stored as plain text and never touches the setting.

## Amendments at final review (2026-10-05)

Rulings from the whole-branch review. Where they differ from the text or amendments above, these
win.

- **A10. Convergence respects time, not arrival order.** `ConversationSetting.updatedAt` is the time
  the current value was set: `date.now` for a local pick, and for a value adopted from the peer the
  sender's LXMF timestamp capped at the receive time (a future-dated clock cannot lock the timer).
  An incoming field, change or ordinary, is applied only when its effective time is strictly newer
  than the stored `updatedAt`. No stored row means adopt. A change message that is not newer is
  still stored as its `isTimerChange` line, but the setting does not move. A late ordinary message
  still keeps the duration it carried on its own row.
- **A11. "Viewed" needs the chat on screen.** `State.chatVisible` is true while ChatView is
  showing: set by `.openConversation`, `.startConversation` and `.chatAppeared`, cleared by
  `.closeConversation` and `.chatDisappeared` (ChatView's onAppear and onDisappear). An arrival is
  stamped only when it is for the open peer, `isForeground` and `chatVisible`. The `.foregrounded`
  stamp needs `chatVisible` too. `.chatAppeared` stamps the open thread, reloads it if anything
  changed and purges, exactly like `.foregrounded`. This refines A5: the open thread on another tab
  is not being looked at.
- **A12. Field-less messages take the local timer.** When a timer is on for the conversation and an
  incoming message carries no decodable expiry (no 0xFD, a foreign or malformed 0xFD, or an
  unvalidated sender), its row takes `expirySeconds` from the local setting and is stamped on first
  view like any other, so this device deletes the whole conversation on the user's own timer. Such a
  message still never changes the setting (§3 stands). The caveat text is unchanged: the peer's
  device keeps its copies.
- **A13. Incoming change rows are rendered locally.** Replaces the "empty body" clause of A8. An
  incoming change row's stored body is always `ExpiryPreset.peerAnnouncement(peerName:seconds:)` for
  the decoded value. The received body is ignored, so a line cannot claim a different value than
  the field set. Outgoing change rows keep the wire body ("Disappearing messages set to …"), which
  already reads as the local user's action.
- **A14. Smaller rulings.** Re-picking the value already in force is a no-op (no message, no row).
  A change message never stores an attachment (its row renders as a line with no attachment view).
  An outgoing change line shows its send status beside the text until it is delivered or
  propagated.

## Amendments from the follow-up pass (2026-10-05)

The deferred items from the final review, fixed on `fix/disappearing-followups`.

- **A15. The sleeper tracks its armed deadline.** `State.armedExpiry` holds the deadline the
  sleeper waits for. A purge completion re-arms only when nothing is armed or its `nextDue` is
  earlier; a completion with nothing due, or with a later deadline, is left alone because it may be
  stale (two purges racing). `.expiryDue` clears the deadline before purging. A completion whose
  deadline is already past arms a zero-delay sleeper rather than waiting for the next trigger.
  `MessagePurge` reads only `id` and `messageHash` of the due rows and takes the next deadline as
  `MIN(expiresAt)` over a new partial index on `messages.expiresAt` (migration `addExpiresAtIndex`),
  replacing A3's Swift-side scan.
- **A16. A send reads the stored timer until the thread's setting has loaded.**
  `State.openConversationExpiryLoaded` is false from `.openConversation`/`.startConversation` until
  `conversationExpiryLoaded` lands (and true right after `expirySelected`). While false, the send
  effect reads `ConversationSetting.expiry` from the database; once true, the state value is
  authoritative, so a pick that has not yet been written is still honoured. Both send paths build
  the message inside their effect.
- **A17. Smaller rulings.** The toolbar menu is no longer gated on reachability (replaces A6): the
  pick applies locally at once, the change line shows a failed send, and every later message carries
  the timer so the peer converges anyway. Launch deletes reaction rows whose target message is gone
  and whose `sentAt` is older than 24 hours (`Reaction.pruneOrphans`), leaving fresh orphans for
  messages still in flight. The purge hands the ids of deleted attachment rows to
  `AttachmentCacheEvictor`, which the app wires to `ThumbnailCache.evict(attachmentIds:)`, so decoded
  images leave memory with their files.
