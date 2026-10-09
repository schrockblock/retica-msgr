# Group chats — design

**Date:** 2026-10-09. **Scope:** ReTiCaMsgr app only (Core package plus app UI); no ReTiCA
changes. **Follows:** the decision record `docs/superpowers/2026-10-02-groups-vs-disappearing-messages.md`
and the two research reports under `reports/` ("Reticulum group chat and channel designs",
2026-10-02, and "Reticulum group chat cross client support", 2026-10-07).

## Goal

Let up to twelve people share one conversation with no server: every post is an ordinary LXMF
message sent once per member, so the app keeps what it already has (pairwise forward secrecy,
per-recipient single-packet proofs, propagation-node offline delivery, push wake-ups). Members on
other LXMF clients receive each post as a direct message labelled with the group name; they cannot
post to the group, and the UI says so.

## Decisions taken while brainstorming

- **Use case.** Small groups of friends and neighbourhood mutual-aid groups, mostly over TCP but
  spanning local Wi-Fi, a LoRa hop and chained BLE. Ceiling: 12 members including the creator.
- **Serverless fan-out, not a hub.** The 2026-10-07 research found that only an LXMF hub bot
  reaches every client, at the cost of a neighbour's device reading every message in plaintext.
  The user declined that cost. A hub-aware mode stays on the roadmap.
- **Good-faith legibility for other clients, no contortions.** The LXMF title carries the group
  name (Sideband and NomadNet show it); control messages have readable bodies. No body prefixes,
  no bridging of replies from unaware members.
- **Own wire convention, not Retichat's.** Retichat's layout is mid-migration, fans out over links
  (never proved on a suspended iPhone), has quadratic invites and a frozen roster.
- **Creator is the roster authority** (Briar's model). The creator invites, removes, renames and
  deletes; anyone may leave. Every roster message carries the full roster and a revision number,
  so members converge on the creator's view.
- **Scope of v1: text, replies, reactions.** Attachments and disappearing timers stay one-to-one.
- **Storage: one row per post plus a per-member delivery table.** Each member's copy has its own
  LXMF hash and delivery outcome; the post's status is derived from them.
- **Members with no known path get a deferred copy.** Encrypting to a member needs their announce
  (ReTiCA takes the key from the learned-path table), so a copy waits until a path is learned.
  Carrying member public keys in invites, as Retichat does, needs a ReTiCA change and is deferred.
- **Group post ids.** Each member receives a different LXMF message for the same post, so replies
  and reactions in a group reference a 16-byte post id rather than an LXMF hash. The standard reply
  and reaction codecs already accept 16-byte targets.

## 1. Wire format

Everything rides in `FIELD_CUSTOM_META` (0xFD), the string-keyed msgpack map the app already uses
for expiry, under two new keys. Other clients ignore the map and see an ordinary message.

| key | value | present on |
|---|---|---|
| `reticamsgr.group` | array `[group id bin16, post id bin16]` | posts |
| `reticamsgr.group` | array `[group id bin16]` | reactions, control messages |
| `reticamsgr.group.ctl` | map, see below | control messages only |

Four message kinds:

- **Post.** `content` is the text. `title` is the group name (UTF-8, at most 32 bytes). A reply
  carries `FIELD_REPLY_TO` (0x30) with the original's 16-byte post id and `FIELD_REPLY_QUOTE`
  (0x31) as today.
- **Reaction.** `FIELD_REACTION` (0x40) with the post id as target and the emoji as content, empty
  `title` and `content`, plus the `[group id]` entry. Sideband stores nothing for a message with
  no body and no title, which is the wanted behaviour.
- **Roster.** Creator only. `reticamsgr.group.ctl` = `{ "a": "roster", "n": name str,
  "m": [member bin16, …], "r": revision uint }`, always the full roster including the creator, at
  most 12 entries. The same message is the invite: a recipient with no record of the group treats
  it as one. `title` is the group name and `content` a readable sentence for other clients, e.g.
  `Alice invited you to the group Mutual Aid in ReTiCaMsgr`. This app ignores the body and renders
  its own line from the diff against the stored roster (as timer-change lines do, amendment A13 of
  the disappearing-messages spec).
- **Leave.** Any member, to every member; a declined invite is a leave sent to the creator only.
  `reticamsgr.group.ctl` = `{ "a": "leave" }`, readable body, group name as title. The creator's device answers with a new roster without the leaver.
  The creator cannot leave in v1: their action is "Delete group", a roster with an empty member
  list that marks the group dissolved on every device.

Identifiers: group id and post id are 16 random bytes each (`SystemRandomNumberGenerator`).
`revision` is an unsigned counter the creator increments on every roster change, starting at 1.

Receive rules, each requiring a validated signature as the expiry field does:

- a roster is applied only when it comes from the group's stored creator and its revision is
  strictly higher than the stored one. The first roster ever seen for a group id establishes its
  creator as that message's sender;
- a post, reaction or leave is accepted into the group only when the sender is on the current
  roster and the group is `active` or `invited`. Otherwise the message is stored as an ordinary
  one-to-one message from that sender with the field ignored. A post that arrives before its
  group's first roster therefore lands as a direct message; accepted for v1;
- a duplicate post id within a group is dropped (seen hash recorded, no row).

Size: the post entry costs about 56 bytes and the title up to 32, leaving roughly 200 bytes of
text inside the single-packet budget. Longer posts go by link, as long one-to-one messages do.

### `GroupWire` (Core, pure)

Follows `ExpiryWire`: constants, caps (`maxNameBytes = 32`, `maxMembers = 12`),
`encodePost(groupId:postId:)`, `encodeMarker(groupId:)` for reactions,
`encodeRoster(groupId:name:members:revision:)`, `encodeLeave(groupId:)`, each returning the 0xFD
entries to merge with any other 0xFD content, and one lenient `decode(fields:)` returning
`.post(groupId, postId)`, `.marker(groupId)`, `.roster(groupId, name, members, revision)`,
`.leave(groupId)` or nil. Decode returns nil for: no 0xFD, a non-map 0xFD, no group key, a
non-array value, an id of the wrong length, a roster over 12 members or with a malformed entry, a
name over the cap, an unknown action. Extra keys are ignored. A malformed field never drops the
message. Because expiry and group entries share the 0xFD map, the two codecs encode into one map:
`sendTapped` merges their entries.

## 2. Data model

One append-only GRDB migration, `createGroups`, after `addExpiresAtIndex`.

| table.column | type | notes |
|---|---|---|
| `groups.groupHex` | TEXT PK | 16-byte id as hex |
| `groups.name` | TEXT NOT NULL | |
| `groups.creatorHex` | TEXT NOT NULL | the sender of the first roster, or `myAddressHex` |
| `groups.revision` | INTEGER NOT NULL | last applied roster revision |
| `groups.state` | TEXT NOT NULL | `GroupState.invited`, `active`, `left`, `dissolved` |
| `groups.updatedAt` | DOUBLE NOT NULL | |
| `groupMembers.groupHex` | TEXT | PK with `memberHex`; `ON DELETE CASCADE` from groups |
| `groupMembers.memberHex` | TEXT | includes the creator and me |
| `messages.groupHex` | TEXT NULL | null for one-to-one rows |
| `messages.groupPostId` | TEXT NULL | hex; set on every group post, null on event lines |
| `messages.isGroupEvent` | INTEGER NOT NULL DEFAULT 0 | roster and leave lines, rendered like timer-change lines |
| `groupDeliveries.messageId` | TEXT | PK with `memberHex`; `ON DELETE CASCADE` from messages |
| `groupDeliveries.memberHex` | TEXT | |
| `groupDeliveries.messageHash` | TEXT NULL | null while `waiting` |
| `groupDeliveries.status` | TEXT NOT NULL | `GroupDeliveryStatus.waiting`, then the `MessageStatus` values |
| `groupDeliveries.storedAt`, `deliveredAt`, `failedAt` | DOUBLE NULL | first-time milestones, as on messages |

Indexes: `groupDeliveries(messageHash)` for delegate lookups; a unique partial index on
`messages(groupHex, groupPostId)` where both are non-null, the duplicate-post guard.

Meaning of existing columns on group rows:

- **`peerHex` is the sender** on incoming posts and `myAddressHex` on outgoing ones. Non-null, so
  nothing that reads it breaks.
- **`status` on an outgoing group post is derived** from its delivery rows by a pure helper:
  `sending` while any row is `sending` or `waiting`; `delivered` when every row is `delivered`;
  `failed` when every row is `failed` or `cancelled`; otherwise `sent`. The reducer writes it back
  after every delegate, so the bubble, preview and Info sheet keep reading one column.
- **`reactions.messageHash` holds the post id hex** for group posts. The thread reaction filter
  becomes "reactor is me or a current member" for groups.
- **`conversationSettings` is untouched.** Timers stay one-to-one in v1.

`Conversation` gains `kind` (`.peer` or `.group`), `groupHex` and `title`; its derivation keys on
`groupHex ?? peerHex`. An `invited` group appears in the list with its invite line so the user can
open it and accept. `Message` gains `groupHex: String?`, `groupPostId: String?` and
`isGroupEvent: Bool`, all defaulted. New `@Table` structs `Group`, `GroupMember` and
`GroupDelivery` mirror the tables.

## 3. Core logic and reducer changes

### Pure types (Core)

- **`GroupRoster`**: `applies(roster, to stored: Group?) -> Bool` (creator match or first sight,
  strictly higher revision), `diff(old: [String], new: [String], oldName:, newName:)` giving the
  added, removed and renamed facts, `maySend(_ senderHex:, in group:, members:) -> Bool`, and
  `derivedStatus(_ rows: [GroupDelivery]) -> String`.
- **`GroupEventText`** follows `ExpiryPreset`: `invited(by:name:)`, `added(by:who:)`,
  `removed(by:who:)`, `renamed(by:to:)`, `left(who:)`, `deleted(by:)`, plus the readable wire body
  for each outgoing control message. Names come from announces with the `ReplyPreview.them`-style
  fallback to a short hex. Lines never expire and carry no reactions.

### Reducer, by flow

- **Creating and editing.** `createGroup(name:members:)` mints the id, writes the group (`active`,
  revision 1) and members (me included), inserts an outgoing event line, and sends one roster
  message per member. `addMembers`, `removeMember`, `renameGroup` and `deleteGroup` bump the
  revision, write, insert their line, and fan the new roster to every current member, the removed
  one included so their device marks the group `left`. `leaveGroup` sends the leave to every member
  and marks the group `left` locally. `acceptInvite` flips `invited` to `active`. `declineInvite`
  sends a leave to the creator and deletes the group locally (its rows cascade).
- **Sending a post** reuses `sendTapped`. With a group open it mints a post id, writes the message
  row (`groupHex`, `groupPostId`, `peerHex = me`, status `sending`) and one `groupDeliveries` row
  per member other than me in one transaction, then for each member either builds that member's
  `LXMessage` (own hash, same body, title and fields) and sends it through the existing
  `sendMessage` action with the usual propagation setting, moving the row to `sending` with its
  hash, or, when the member is not in `reachablePeers`, leaves the row `waiting` and sends a path
  request. Reactions use the same fan-out without rows: one reaction message per reachable member
  (unreachable members miss it; accepted, as one-to-one reactions are gated on reachability today).
- **Deferred copies.** `pathLearned` already fires for every announce. It now also selects
  `waiting` rows for that member, builds and sends their copies, and moves the rows to `sending`.
  Launch does the same for members already reachable once `seedReachablePeers` runs. A `waiting`
  row has no age limit in v1.
- **Delivery delegates** (`deliveryConfirmed`, `propagationAccepted`, `deliveryFailed`,
  `deliveryRejected`, `deliveryCancelled`) first update the message row by hash as today. When no
  outgoing message row matched, they update the `groupDeliveries` row with that hash under the
  same guards and first-milestone rules, recompute the post's derived status and write it to the
  message row. `outgoingProgress` stays keyed by hash and is not shown for group posts.
- **Receiving.** After the reaction check and before the reply decode, `GroupWire.decode` runs on
  validated messages:
  - `.post` from a current member of a known group: the row gets `groupHex`, `groupPostId`,
    `peerHex = sender`, `replyToHash` = the 16-byte target hex when present. A duplicate post id
    records the seen hash and stores nothing.
  - a reaction whose message carries `.marker`: `Reaction.apply` with `messageHash` = the 16-byte
    target hex, only when the reactor is a current member.
  - `.roster` from the stored creator with a higher revision: replace members, update name and
    revision, insert an incoming event line per diff fact. For an unknown group id: create it
    `invited` with the sender as creator, insert the invite line. For a group the user has `left`
    whose new roster lists them: back to `invited`. An empty member list sets `dissolved`.
  - `.leave` from a current member: remove them, insert the line; when I am the creator, bump the
    revision and fan a new roster.
  - anything failing the rules: stored as an ordinary one-to-one message from the sender.
- **State.** `openPeerHex` stays the navigation key and holds the group hex for a group thread;
  `openConversationKind` says which. The thread load also reads the group, its members and the
  delivery rows of outgoing posts into `openGroup`, `openGroupMembers` and `deliveriesByMessageId`.
  The reply target and reaction lookups use `groupPostId` in a group thread. The Send gate for a
  group is "at least one member other than me is reachable". The disappearing-messages setting is
  never read for a group thread.

### Errors

- A copy that cannot be built because the member's key is gone between the path check and the
  send fails that member's row only; the others proceed.
- A roster message that fails to reach a member leaves them one revision behind. The creator's
  device re-sends its current roster to a member whenever that member's roster delivery row is
  `failed` and their path is learned again. Roster messages therefore also get delivery rows,
  attached to their event line's message row.
- A control message with a bad field from a valid member is shown as its readable body, as a
  one-to-one message, never as a group line.

## 4. UI

- **Creating a group.** The compose sheet gains a "New group" entry opening a form: name, and a
  member list built from the announce list (display names where known) plus the hex field and QR
  scan used for one-to-one starts, for members not yet heard. The member count shows against the
  ceiling; Create is disabled above 12 including me, with an empty name, or with no members.
- **Conversation list.** A group row shows the group name instead of a short hex, with the usual
  preview. An `invited` group shows its invite line and an "Invited" badge.
- **Group thread.** `ChatView` serves both kinds. Incoming bubbles in a group carry a small sender
  name line above the text. Outgoing bubbles show the derived status; the label reads "Delivered to
  3 of 11" while partial. Event rows reuse the system-line look of timer changes. The reply quote
  and reaction palette work unchanged, with the sender label resolved per message. The
  disappearing-messages menu is hidden in groups.
- **Invite bar.** An `invited` group shows Accept and Decline in place of the composer.
- **Group info screen.** Reached from the navigation title: name, member list with reachability
  dots, and the actions the user's role allows. Creator: add members, remove a member, rename,
  delete group. Member: leave. A one-line caveat states that members on other apps see posts as
  separate direct messages and cannot reply to the group.
- **Message Info sheet.** For an outgoing group post, a Members section lists each member with
  status and first-delivery time from the delivery rows. The payload section names the new 0xFD
  keys.
- **Left or dissolved groups** stay readable with the composer replaced by a line saying why.

## 5. Testing

One named mutation per test, listed in the implementation plan, per the project's plan-mutation
rule.

- **`GroupWireTests`:** each kind encodes to the expected 0xFD entries; decode round-trips each;
  nil for a missing key, a non-array value, a wrong-length id, a roster over 12 members, a name
  over the cap, an unknown action; extra map keys ignored; a post entry beside an expiry entry
  decodes under both codecs.
- **`GroupRosterTests`:** a roster from a non-creator is rejected; an equal or lower revision is
  rejected; the first roster establishes the creator; the diff yields the right added, removed and
  renamed facts; the derived status for each combination of member row states.
- **`DatabaseTests`:** the migration creates the tables; the unique partial index rejects a
  duplicate post id in one group and allows it across groups; deleting a message cascades its
  delivery rows; deleting a group cascades its members.
- **`ConversationTests`:** group rows collapse by group id, one-to-one rows by peer, the newest
  wins within each, and the group title is carried.
- **`AppFeatureTests`:** creating a group sends one roster per member and writes the rows; sending
  a post writes one delivery row per member, sends copies to reachable members and leaves the rest
  `waiting`; a learned path sends the waiting copy; a delivery confirmed for a member's hash updates
  that row and the derived status; the status becomes `delivered` only when every member proved;
  receiving a post from a member lands in the group thread; the same post id twice stores one row;
  a post from a non-member is stored as a one-to-one message; a roster for an unknown group creates
  an `invited` group; a higher-revision roster replaces members and inserts a line; a lower one is
  ignored; a leave removes the member and, when I am the creator, sends a new roster; a group
  reaction with a 16-byte target attaches to the post; a reply with a post id target resolves in the
  thread; accept and decline do what they say; an empty roster marks the group dissolved.

## Out of scope

- Attachments and disappearing timers in groups.
- Carrying member public keys in invites (needs a ReTiCA change to seed a key without a path).
- App-layer pacing of the fan-out burst for LoRa; RNode firmware queues bursts today.
- Re-fanning replies from members on other clients, and a hub-aware mode.
- Reading Retichat's group fields.
- Creator transfer, and any history for late joiners.
- An age limit on `waiting` copies.
- Group reactions to members who are unreachable at the time of the tap.

## Amendments at planning time (2026-10-09)

Decisions the implementation plan (`docs/superpowers/plans/2026-10-09-group-chats.md`) forced
while turning §1–§5 into code. Where they differ from the text above, these win.

- **A1. Names.** The Swift type is `ChatGroup` and the table `chatGroups`: SwiftUI owns `Group`,
  and `GROUPS` is an SQLite keyword. Dates are stored as `.datetime` like every other table, not
  DOUBLE.
- **A2. Post id in `messageHash`.** A group post row stores its post id hex in `messageHash` as
  well as `groupPostId`, so reactions, reply targets and the context menu work unchanged. The
  per-member LXMF hashes live only in `groupDeliveries`.
- **A3. `messages.groupControl`.** A nullable TEXT column (`roster` or `leave`) marks an outgoing
  event line that carries a message to the members, so a deferred copy can be rebuilt from the
  row and the group's current state. A rebuilt copy uses the dispatch time as its LXMF timestamp,
  so every attempt has a fresh hash.
- **A4. Wire bodies.** Every roster message carries `<inviter> invited you to the group <name> in
  ReTiCaMsgr`; a delete carries `<who> deleted the group <name>`; a leave `<who> left the group
  <name>`.
- **A5. Stale rosters.** A roster from the stored creator whose revision is not higher is dropped
  silently (seen hash only). A roster for a known group from anyone else, a roster that does not
  list its own sender, and a roster for an unknown group that does not list me, are stored as the
  plain one-to-one message their body is. A roster never applies to a `dissolved` group.
- **A6. Decline.** Declining marks the group `left` (not deleted), inserts "You declined the
  invitation", and sends the leave to the creator only. The conversation stays in the list,
  read-only.
- **A7. A leave reaching the creator.** The creator's line for it ("<who> left the group") is an
  outgoing roster row whose delivery rows carry the bumped roster to the remaining members; the
  reachable ones get it at once, the rest when their path is learned.
- **A8. Derived status order.** `sending` while any copy is waiting or sending; `delivered` when
  every copy was proved; `stored` when every copy was proved or stored and at least one was
  stored; `failed` when every copy failed or was cancelled; otherwise `sent`. The bubble label is
  "Delivered to d of n" while 0 < d < n, else the status word.
- **A9. No timers in groups.** Group sends never carry the expiry entry, so the two codecs never
  merge one 0xFD map; an expiry entry on a received group post is ignored. Group reactions go to
  the members reachable at the tap.
- **A10. No Cancel Send on group posts.**
- **A11. `Conversation.peerHex` is the list key:** the peer's address, or a group's id. `kind`,
  `title` and `groupState` are added.
- **A12. Re-sends.** A `failed` roster delivery is re-armed and re-sent when the member's path is
  learned; a failed post delivery is not.
- **A13. Thread query.** A thread's rows are those with `groupHex = key`, or `groupHex IS NULL
  AND peerHex = key`.
- **A14. Event lines from a diff** are inserted 1 ms apart in the order added, removed, renamed,
  naming members by their announce display name or the first eight hex characters.
