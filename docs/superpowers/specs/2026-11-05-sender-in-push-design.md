# Sender name and picture in push banners — design

**Date:** 2026-11-05. **Scope:** two repositories. ReTiCAPush (`ReTiCAPushCore`,
`ReTiCAPushExtension`: verified sender attribution and a shared sender directory) and the
ReTiCAMsgr app (Core package: writing the directory; the Notification Service Extension: drawing
the banner; project settings: the Communication Notifications capability).

## Intent

Today every push banner reads "New message", whoever sent it. The hub fixes that title on
purpose (it never learns or carries anything about the sender, `ReTiCAPush/docs/server-contract.md`
§3). On the phone, though, the extension already decrypts each packet far enough to read the
sender's hash (`BlockedSenderFilter.sourceHash`, for blocking). This feature uses that, on the
device only, to show the sender the way Messages does: their name as the title and their picture
on the banner.

The hub, the push payload and what leaves the phone stay exactly as they are. Only the phone
turns a hash into a name, using data the app already holds.

The user asked for this and skipped the brainstorming questions. Every decision below not quoted
from them is marked **(my call)**.

## Goals

- When a pushed message can be attributed to one sender **whose signature verifies**, and the
  app knows a name for them, the banner's title is that name.
- When the app also has a picture for them, the banner shows it as a Communication Notification
  (round avatar on the banner, like Messages and Signal).
- Pushed banners from one sender group together in Notification Center.

## Non-goals

- **Custom per-sender sounds.** The user is still deciding. The design leaves room for them (a
  directory entry can grow fields) but builds nothing for them.
- **Message text in the banner.** The banner body stays generic. The extension reads the sender
  and nothing else from the message.
- **Group names.** A group post is a direct message from a member, and the group id lives in the
  message fields. The banner names the member and does not mention the group.
- **Changing what tapping a banner does.** Tapping still opens the app and drains the inbox.
  (Opening that sender's chat is a natural follow-up, since the sender hash will be known, but
  it is not part of this.)
- **Hub or server-contract changes**, including `apns-collapse-id` (see Known limits).
- **The app's own local notifications** (today only "Message not sent"). Unchanged.

## Anti-goals

- **A forged sender gets a real person's name and face.** Today an unauthenticated sender hash can
  only *suppress* a banner (block spec, A6), which is harmless. Putting a name and photo on a
  banner is different: anyone who knows my address and Alice's could make Alice's face appear
  over their message. So **attribution for display requires a valid LXMF signature against the
  sender's known public key.** No key, or a bad signature, means the generic banner.
- **The sender, or any directory data, leaving the device.** Nothing new goes to the hub.
- **A banner that names the wrong person**, e.g. when one push carries packets from two people.
- **The extension timing out or crashing** because of this. Every failure falls back to the
  original "New message" banner, as the timeout path already does.

## Constraints

- The extension links no TCA or SQLite (`ReTiCAMsgrPushService` depends only on
  `ReTiCAPushExtension`). It can't read the app's database or `AvatarStore`, which lives in the
  app's own Application Support folder outside the app group.
- The extension has a 30-second budget and runs while the phone is locked after first unlock.
  The handler already races a 20 s deadline.
- The extension already decrypts with the identity's static key, and since ReTiCAPush
  `d1ce28f` also with the host's own ratchet ring (read-only). Link requests cannot be
  attributed, and neither can packets encrypted to a ratchet the ring doesn't hold or can't be read
  (`BlockedSenderFilter` doc comment).
- Server contract §3 says "the client's service extension never changes [the title]", and §4
  item 2 says the extension "never decrypts anything and never changes the notification" (already
  stale since blocking). This feature changes the title on the device, so both sentences get
  amended in ReTiCAPush to describe what the extension now does. The hub's behaviour is
  unchanged.
- Communication Notifications need the `com.apple.developer.usernotifications.communication`
  entitlement (a plain capability in the developer portal, no request to Apple) on both the app
  and the extension, and `INSendMessageIntent` in the app's `NSUserActivityTypes`. Without it,
  `content.updating(from:)` still works, but iOS draws no avatar.
- The Mac target builds the same Core and must still compile. Whether Mac pushes get the avatar
  is untested, and is not a goal.

## Design

### 1. Sender directory (ReTiCAPushCore)

A new `SenderDirectoryStore` next to `BlockedSenderStore`, with the same pattern: the app owns the
truth and writes a mirror on every change and on launch, and the extension reads it once per push.

- **Location (my call):** files in the app-group container, not UserDefaults, because it holds
  images: `<container>/ReTiCAPush/senders/directory.json` plus one image file per sender in the
  same folder. Add a `PushStorage.senderDirectory` accessor beside `blockedSenders`.
- **Entry** (keyed by lowercase lxmf.delivery hex):
  - `name: String?`, the display name the app would show.
  - `publicKey: Data`, the sender identity's 64-byte public key, for signature checks.
  - `image: String?`, a file name inside the folder; nil when there is no picture.
- **Writes** are atomic (write the JSON to a temporary file, then replace). Image files are named
  after a hash of their content **(my call)**, so a changed picture gets a new file and an
  extension mid-read never sees half a file. Files no entry names any more are deleted after the
  JSON is replaced.
- **File protection:** `completeUntilFirstUserAuthentication`, like `AvatarStore`, because the
  extension runs while locked. Excluded from backup.
- **Decoding:** a missing or undecodable file means an empty directory, never a throw.
- **Versioning:** a `v` field. An extension that doesn't know the version treats the directory as
  empty.

### 2. Verified attribution (ReTiCAPushCore / ReTiCAPushExtension)

- A new `PushSender.verifiedSource(of:identity:deliveryHash:publicKeyFor:) -> Data?`. It does what
  `BlockedSenderFilter.sourceHash` does (same packet checks, same decrypt, same
  `LXMessage.fromOpportunistic`), then looks up the sender's public key, builds
  `Identity(publicKey:)`, checks that the identity's lxmf.delivery hash equals `sourceHash`, and
  returns the hash only if `message.validateSignature(source:)` is true. Factor out the shared
  decrypt-and-unpack step rather than copying it.
- `BlockedSenderFilter` stays unauthenticated and unchanged in behaviour: suppression must keep
  working for senders with no known key.
- **`PushServiceHandler.handle` returns a `PushOutcome`** instead of a bare `PushVerdict`:
  `verdict` (unchanged rules) plus `sender: SenderDirectory.Entry?`, with the matched hex. The
  sender is set only when **every** packet in the push verifies to the **same** sender
  **(my call, mirrors A6)**. Any unattributable packet, a bad signature, or a second sender means
  nil. The handler loads the directory itself, alongside the blocklist, in `live(storage:)`.
- Attribution runs whether or not the blocklist is empty. Today `verdict(for:)` returns
  `.deliverOriginal` straight away when the blocklist is empty, so sender attribution must not
  sit behind that check.
- When `verdict == .suppress`, `sender` is irrelevant. Suppression wins.
- The sender is decided before the network wait, in the same locked box as the verdict, so a
  slow proof upload never costs the name.

### 3. The banner (app: `ReTiCAMsgrNotificationService`)

`NotificationService.content(for:original:)` takes the `PushOutcome`. The extension target has
no tests, so this function moves into `ReTiCAMsgrPushService` (which has them) and the extension
calls it. That target then links `Intents`, which is also available on macOS. For
`.deliverOriginal` with a sender:

1. Copy the original content and badge it, as now.
2. Set `threadIdentifier` to the sender hex **(my call)**, so their banners group together.
3. Build an `INPerson` for the sender: handle = the hex (`.unknown` type), display name = entry
   name, or, for a picture-only entry, the short hex the app already uses for unnamed people
   (`GroupEventText.fallbackName`, the first eight hex characters) **(my call)**, and image =
   `INImage(url:)` on the directory file when there is one.
4. Build an `INSendMessageIntent` with that sender, `conversationIdentifier` = the hex,
   `content` nil (the extension never reads the text), and donate an incoming `INInteraction`. Then
   `content.updating(from: intent)`.
5. If any step throws, fall back to the copied content with the title set to the person's
   display name from step 3. Whether `updating(from:)` throws or quietly drops the avatar when
   the entitlement is missing is unconfirmed, and this fallback covers both cases.

The hub sends only a title ("New message") and no body. When the sender is named, the title
becomes their name and "New message" moves into the body **(my call: the banner reads
"Alice / New message")**. Localize it like the rest of the app. With no sender, the original is
untouched: title "New message", no body.

### 4. Who goes in the directory (app: Core)

- **Which peers (my call):** everyone with a conversation (any message row), plus
  contact-linked peers, plus the members of **every group I'm in** (the `GroupMember` table, not
  `state.openGroupMembers`, which only holds the group on screen). Not the whole learned-announce
  table. That can
  be tens of thousands of strangers (the 2026-11-01 rehydrate incident saw 24,603 rows), and a
  stranger naming themselves on my lock screen is spam-friendly. A peer with no known public key
  (`router.knownIdentities`) is left out, since they couldn't be verified anyway.
- **Blocked peers** are left out. They get suppressed or a generic banner.
- **Name:** `State.peerDisplayName(hex)`, the same precedence the app uses everywhere (linked
  contact name, then the newer of the message-carried and announce names). If there's no name,
  the entry is still written when there's a picture.
- **Picture:** `AvatarSource.resolve`. A received photo means copying the JPEG. A linked
  contact's thumbnail means writing that data. An icon or initials means no picture
  **(my call: iOS draws its own monogram from the name; rendering the SwiftUI icon to a file
  isn't worth it for v1)**. Downscale to at most 256 px on the long side before writing.
- **When to write:** on launch after the tables load, and after any change to the inputs (a
  received name or photo, a contact link or card change, a block or unblock, a new conversation,
  an identity learned for a conversation peer). Debounce, around 1 s, and write the whole
  directory each time; it's small. Group membership changes (joining, roster updates, leaving,
  being removed) are triggers too. The structure is close to `BlockingReducer`, but the peer set
  comes from the database: the effect reads the conversation peers and every group's members,
  joins them with the names, profiles, links and known identities captured from state, and
  writes through a dependency. Tests read the store after the effect.
- **Contact thumbnails** load lazily today (`contactCards`, filled when an avatar view appears).
  The directory writer fetches missing thumbnails for linked peers through `ContactsClient`
  when it builds the snapshot **(my call)**. Without Contacts access there are simply no
  contact pictures.

### 5. Project settings

- Add the Communication Notifications capability to the iOS app and the extension (entitlements
  files plus the provisioning profiles), and `NSUserActivityTypes = [INSendMessageIntent]` to the
  app's Info.plist. Link `Intents` in the extension.
- The user needs to enable the capability on both App IDs in the developer portal and
  regenerate the profiles. Write this down in the plan as a manual step.

## Known limits (accepted)

- **Generic banner** when the sender can't be named: link requests (e.g. Retichat, per the
  2026-10-02 push finding), packets encrypted to a ratchet not in the readable own ring, "propagated" pushes (no packets), a
  batch with more than one sender, a sender whose key we haven't learned, or a message from
  someone with no conversation yet.
- **Collapse id.** The hub sets `apns-collapse-id` to *my* destination hash, so a newer push
  replaces the previous banner even when it's from someone else. That's existing behaviour,
  just more visible once banners carry names. Out of scope; it would be a hub change.
- **Stale directory.** A name changed while the app hasn't run since shows the old name until
  the app next writes the directory.

## Testing

- **ReTiCAPush:** `verifiedSource` returns the hash for a properly signed packet, and nil for:
  a tampered signature, a public key whose delivery hash doesn't match, an unknown sender, a
  link request, and another destination. Also the `PushOutcome.sender` rules (one sender: set;
  two senders, one unattributable, or one unverified: nil; suppress unaffected), and a
  `SenderDirectoryStore` round trip (atomic replace, orphan image cleanup, undecodable means
  empty). Build the signed packets with ReTiCA's own `LXMessage` packing, as the existing
  `PushVerdictTests` do.
- **App Core:** the directory snapshot (who is included, name precedence, picture source,
  blocked peers excluded, peers with no key excluded) and that the write happens after the
  triggering actions. Use TestStore against a temporary `PushStorage`.
- **Extension content:** `content(for:original:)` as a pure function. Name only sets the title
  and thread. No sender returns the original. Suppress returns empty. The intent path is
  exercised as far as the simulator allows.
- **On-device check (owed by the user):** a signed message from a named contact with a photo
  shows name and avatar on the lock screen. A Sideband sender shows their name. A link-based
  sender shows "New message".

## Left to the builder

- Exact type and file names, and whether `PushOutcome` replaces or wraps `PushVerdict`.
- The JSON shape beyond the fields listed.
- How the debounce is built (`Clock` dependency, as elsewhere).
- Whether the downscale happens in Core (`ImageEncoder`) or at the call site.
