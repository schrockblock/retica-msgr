# ReTiCaMsgr

ReTiCaMsgr is a messaging app for iPhone, iPad and Mac that runs over
[Reticulum](https://reticulum.network), using the [LXMF](https://github.com/markqvist/LXMF)
message format. It is built in SwiftUI with The Composable Architecture, on top of
[ReTiCA](../../pods/ReTiCA), a Swift implementation of Reticulum and LXMF that lives in its own
repository.

The app is not published on the App Store, and this repository has no license file.

## What it is

Most messengers route every message through the company that runs them. ReTiCaMsgr does not
have a company server in the middle. Your device holds a cryptographic identity, and your address
is derived from it. Messages are encrypted on your device to the recipient's identity and handed
across whatever Reticulum network is available: an internet connection to a Reticulum node, a
Bluetooth link to a nearby device, or a LoRa radio.

In practice that means:

- **No account, no phone number.** On first launch the app creates an identity. Your address is
  32 hex characters (it looks like `0123456789abcdef0123456789abcdef`). You share it as text or as a
  QR code, and people reach you by that address.
- **End-to-end encrypted by default.** The nodes, relays and pickup points that carry a message
  cannot read it.
- **Offline delivery through propagation nodes.** If the recipient cannot be reached, the app
  retries, then leaves an encrypted copy at a propagation node ("pickup point" in the app) for
  them to collect later.
- **More than one way to connect.** The internet (TCP to one or more Reticulum nodes), Bluetooth
  LE to nearby Reticulum devices, and LoRa through a paired Meshtastic radio. No phone signal is
  needed if another path exists.
- **It speaks standard LXMF**, so it can message people using other Reticulum clients. See
  [Working with other Reticulum apps](#working-with-other-reticulum-apps) for what carries over
  and what does not.

The app tries to explain Reticulum in plain words. The empty Chats screen describes what is
different about it, and each message shows its live send stage ("Looking for them", "Connecting",
"Leaving it for pickup", "Stored for pickup") with an info button that explains the step.

## Features

What is on `main` today.

### Conversations

- One-to-one chats, started by pasting an address, scanning a QR code, or picking someone from
  the **Announces** list (peers whose apps have announced themselves on the network).
- Live send status, Retry for failed messages, and Cancel Send for one in flight. A local
  notification says when a message could not be sent. Messages left "sending" when the app was
  killed are resent on the next launch.
- Replies (quoting the original), and emoji reactions with a full emoji picker.
- Attachments: one photo or one file per message, with an optional caption and transfer
  progress. Photos go out as JPEG, downscaled to 1280 px on the long edge unless you choose
  Original.
- Tappable links in messages: web, phone numbers and `lxmf://` addresses.
- Disappearing messages: a per-conversation timer (Signal-style presets up to four weeks), set by
  either person. One-to-one chats only.
- Drafts are kept per conversation and shown in the chat list.
- Unread counts on each chat row and on the app icon.
- Delete a conversation from this device.
- A message Info sheet with delivery details and the LXMF fields the message carried.
- A sender whose signature cannot be checked yet (their identity is not known) is marked
  **Unverified sender**. The message is kept apart and re-checked once their identity is learned.
- If a recipient asks for proof-of-work stamps (LXMF's anti-spam measure), the app computes one
  before sending (shown as "Preparing").

### Groups

- Groups of up to 12 people, including the creator, with no server. Each post is sent as a
  separate LXMF message to every member, so each member's copy has its own delivery status.
- The creator invites, removes, renames and deletes the group; anyone can leave.
- Groups carry text, replies and reactions. Attachments and disappearing timers are one-to-one
  only.

### Profile and contacts

- A display name and a profile photo, sent to the people you message. Contact photos and
  Sideband-style icons are shown as avatars.
- **My QR Code & Address** in Settings, and a QR scanner for adding people (iOS only; hidden on
  the Mac).
- Contact links: attach a Reticulum address to an iOS contact so chats show the contact's name.
  Optionally, **Save addresses to Contacts** writes addresses onto contact cards and offers to
  import addresses it finds there.

### Safety

- Block and unblock people, from a chat, a peer's info or a group's info. Blocked senders'
  messages are dropped, and the app does not send to them.
- Report: the code builds a report email to a support address, but the address is empty in
  `ReportDraft.swift` (`SupportContact.reportAddress`), so the Report actions are hidden in this
  build.
- Hiding the push banner for a blocked sender needs Apple's notification-filtering entitlement.
  The extension already returns empty content for blocked senders, but the entitlement is
  commented out in `ReTiCaMsgrNotificationService.entitlements` until Apple grants it, so the
  banner still shows.

### Identity

- The identity key lives in the Keychain, in an access group shared with the developer's other
  Reticulum apps (`co.lithobyte.reticulum.identity`), so they present the same identity.
- There is no identity export in the app. If the key goes missing (for example after restoring
  from an unencrypted backup) but your conversations remain, a recovery screen lets you restore
  it from a Sideband or `rnid` text backup (base32) or a NomadNet / `rnid` identity file
  (64 bytes). The restore must match the identity your conversations used.

### Network

All of this is under Settings > Network.

- **Nodes.** A list of Reticulum TCP nodes to connect to. The app ships with one built-in node,
  the developer's hub "Gaefu" (`gaefu.ddns.net:4242`), which also provides push notifications
  and a propagation node. You can add your own nodes, turn the built-in one off, or delete the
  ones you added.
- **Bluetooth.** Connects directly to nearby Reticulum devices (other iPhones, Raspberry Pis)
  over Bluetooth LE. Off by default.
- **Meshtastic.** Sends and receives over LoRa through a Meshtastic radio paired over Bluetooth.
  The radio should use a Short preset (ShortTurbo or ShortFast) and must not be connected to the
  Meshtastic app at the same time. Off by default.
- **Direct connections.** Listens for Reticulum TCP connections from other nodes on your local
  network (port 4242 by default). Off by default.
- **Relay.** Forwards other people's traffic and answers path requests, like a Reticulum
  transport node. Off by default.
- **Propagation node.** Uses the built-in node's propagation node by default, or one you enter by
  address.
- **Run as propagation node.** Stores and forwards messages for others while the app is open.
- **Diagnostics.** Connection, paths, peers, links and delivery state, with a shareable snapshot
  for bug reports.

The app has no direct RNode (LoRa via KISS) interface. You can still reach LoRa users through a
node that has one, or through a Meshtastic radio.

### Notifications

- Optional push notifications ("Notify me when the app is closed"), off by default. They need a
  node that runs a push hub; the built-in node does. See [How push works](#how-push-works).
- Notifications only ever say "New message". Sender and content are never in the push.

### Mac

The Mac app is the same multiplatform target as the iOS app (native SwiftUI, not Catalyst). It
adds a menu bar icon with an unread dot and a launch-at-login option. Known gaps on the Mac:

- No new-message notifications. The Mac keeps its connection open, so the hub never needs to
  push to it, and there is no local notification for incoming messages yet.
- No QR scanning.

## Working with other Reticulum apps

ReTiCaMsgr uses LXMF, the same message format as
[Sideband](https://github.com/markqvist/Sideband),
[NomadNet](https://github.com/markqvist/NomadNet), MeshChat, Columba and Retichat. Plain text
messages work in both directions with any of them: give them your address, or find them in
Announces.

What carries over beyond plain text:

| Feature | How it is sent | What other clients see |
|---|---|---|
| Photos and files | Standard LXMF image (0x06) and file (0x05) fields | Sideband shows them. Over 1 MB may be refused by reference LXMF routers (their default delivery limit); over 256 KB will not be stored at a default propagation node, so it can only go direct. The app warns about both but does not block. |
| Replies | Standard reply fields (0x30, 0x31) from LXMF | Clients that do not implement them show the reply as an ordinary message. |
| Reactions | Standard reaction field (0x40) from LXMF | No other client is known to implement it yet. Reactions are sent with no text, so other clients show nothing. |
| Display name | The LXMF announce, plus field 0xA1 on messages (this app's own) | Other clients use the announce name. |
| Profile photo | Field 0xA0 (this app's own) | Ignored. Sideband's icon field (0x04) is shown here as an avatar, but never sent. |
| Disappearing messages | A custom metadata field (0xFD) | Other clients keep the messages. A timer change arrives as a readable sentence, such as "Disappearing messages set to 1 day". |
| Groups | A custom metadata field (0xFD) | Each post arrives as a direct message titled with the group name. Members on other clients cannot post to the group. |

Push has one important limit with other clients; see the next section.

## How push works

iOS suspends apps in the background, so a Reticulum connection cannot stay open. Push wake-ups
fill that gap without a message server.

1. The app's TCP node is a **push hub**: a normal Reticulum transport node running the `rns-push`
   interface (a separate Python package, repository `schrockblock/rns-push`). The built-in node
   Gaefu runs it.
2. When you turn notifications on, the app registers its Apple push token with the hub over a
   Reticulum link, identified with your Reticulum identity. Registration is only accepted over a
   direct connection to the hub.
3. When the app goes to the background it closes its connection. The hub keeps your connection's
   interface "dormant" instead of dropping it.
4. Anything the hub would have written to your connection that is addressed to you is sent as an
   Apple push instead: the same encrypted Reticulum packet bytes. The push's visible text is
   always "New message".
5. The Notification Service Extension stores the packet for the app and sends the sender the
   standard Reticulum delivery proof, so the sender sees the message as delivered. The extension
   never decrypts the message. The app reads it the next time it runs.

What the hub learns: your Apple push token, and the Reticulum address it wakes. It sees the same
encrypted packets any Reticulum node on the path sees, and it cannot read them. Apple sees an
opaque payload and a fixed "New message" title.

Limits:

- **Only single-packet messages arrive through the push itself.** Short text from another
  ReTiCaMsgr is sent this way. Larger messages, and messages from clients that send over a link
  (LXMF "direct" delivery: Sideband, NomadNet, Retichat), arrive as a link request that a
  suspended phone cannot answer in time. The banner still appears, and the message reaches you
  through a propagation node.
- **Propagation-node pushes.** The app also handles a push that says a message is waiting at the
  hub's own propagation node, and fetches waiting messages when it opens. This needs the hub to
  watch its propagation node's store, which is a hub-side setting.
- The hub only pushes to app bundle IDs on its allow-list and with its own APNs key, so a fork
  with a different bundle ID needs its own hub.

The client side is the [ReTiCAPush](../../pods/ReTiCAPush) package. Its
`docs/server-contract.md` is the exact contract a hub must follow. The design record is
[docs/superpowers/specs/2026-10-01-push-relay-design.md](docs/superpowers/specs/2026-10-01-push-relay-design.md).

## Building

### Requirements

- Xcode 26.4 or later (the project was last upgraded with Xcode 26.4; ReTiCA uses Swift tools
  6.3).
- Deployment targets: iOS 26.4 and macOS 26.4 for the app. The `ReTiCaMsgrCore` package itself
  declares iOS 17 and macOS 14.
- An Apple developer account to run on a device, because the app uses an app group, a shared
  Keychain access group and push notifications.

### Sibling checkouts

The app depends on several packages by local path, not by URL. `ReTiCaMsgrCore/Package.swift`
expects this layout:

```
<root>/
  apps/
    ReTiCaMsgr/          this repository
  pods/
    ReTiCA/             Reticulum and LXMF in Swift
    ReTiCAPush/         push wake-ups (depends on ../ReTiCA)
    MeshtasticKit/      Meshtastic radio support
    FCB/                Bluetooth helpers (ReTiCA and MeshtasticKit depend on ../FCB)
```

ReTiCA's remote is `github.com/schrockblock/retica`. ReTiCAPush, MeshtasticKit and FCB have no
published remote at the moment, so building outside the developer's machine needs copies of them.

Worktrees of this repository placed next to it (for example `apps/ReTiCaMsgr-feature`) resolve
the same paths.

The other dependencies are fetched by Swift Package Manager: Point-Free's
[sqlite-data](https://github.com/pointfreeco/sqlite-data) and
[swift-composable-architecture](https://github.com/pointfreeco/swift-composable-architecture),
plus what ReTiCA and MeshtasticKit pull in (swift-protobuf, IOS-CoreBluetooth-Mock, SwiftEdDSA).

### Running

Open `ReTiCaMsgr.xcodeproj`, choose the `ReTiCaMsgr` scheme, and run on a device, a simulator or
My Mac. Bluetooth, Meshtastic and push need a real device.

### Signing, for a fork

The identifiers are tied to the developer's team. A fork needs to change:

- `DEVELOPMENT_TEAM` (`HK6WSAR793`) and the bundle IDs (`co.lithobyte.ReTiCaMsgr`,
  `co.lithobyte.ReTiCaMsgr.NotificationService`, and the two test bundles) in the project.
- The app group `group.co.lithobyte.ReTiCaMsgr` in all four `.entitlements` files and in
  `ReTiCaMsgrCore/Sources/ReTiCaMsgrPushService/ReTiCaMsgrPush.swift` (`appGroupID`).
- The Keychain access group `co.lithobyte.reticulum.identity` in the entitlements files, and
  `SharedIdentityLocation.accessGroup` in
  `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/IdentityStore.swift`, which hard-codes the team prefix.
  `ReTiCaMsgrTests/TestHostScanTests.swift` checks that value.
- The built-in node in `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/DefaultNode.swift`, if you do not
  want the app to connect to the developer's hub. Push through it will not work for a different
  bundle ID anyway (see above).
- `aps-environment` is `development` in the entitlements.
- `SupportContact.reportAddress` in `ReportDraft.swift`, if you want the Report actions.

### Tests

Most of the logic, and most of the tests, are in the `ReTiCaMsgrCore` package. They run on the
Mac host:

```
swift test --package-path ReTiCaMsgrCore
```

The suite has about 1,000 tests. A cold build plus a full run takes several minutes. A few
Meshtastic tests wait on real timeouts and can fail when the machine is heavily loaded; rerun them
on their own with `--filter mesh`.

The app target has a smaller set of hosted tests (`ReTiCaMsgrTests`) for the runtime, Keychain,
push glue and platform helpers. Run them from Xcode, or with `xcodebuild test` against an iOS
simulator. On the Mac, run only that target with an arm64 destination
(`-destination 'platform=macOS,arch=arm64' -only-testing:ReTiCaMsgrTests`); a full macOS scheme
run fails on an x86_64 swift-syntax build error.

Setting `RETICAMSGR_TEST_HOST=1` in the environment starts the app with an in-memory identity and
database, which is useful for unsigned smoke runs.

## Project layout

```
ReTiCaMsgr/                    the app target (iOS and macOS): SwiftUI views, AppDelegate,
                               AppRuntime, platform glue
  Platform/                    Mac/iOS differences: images, pasteboard, menu bar presence
ReTiCaMsgrCore/                Swift package with the app's logic
  Sources/ReTiCaMsgrCore/      AppFeature (the root TCA reducer) and its extensions, the
                               database (sqlite-data), wire codecs for LXMF fields, groups,
                               attachments, contacts, blocking, identity
  Sources/ReTiCaMsgrPushService/
                               what the notification extension links (no TCA, no SQLite)
  Tests/ReTiCaMsgrCoreTests/   the main test suite
ReTiCaMsgrNotificationService/ Notification Service Extension (iOS only)
ReTiCaMsgrTests/               app-hosted tests
ReTiCaMsgrUITests/             UI test target
scripts/                       trim-emoji-test.swift: rebuilds the bundled emoji list
docs/superpowers/specs/        design records, one per feature, with amendments
docs/superpowers/plans/        the implementation plans that followed them
```

The design records are the best place to learn why something works the way it does. Some later
features (contact links, blocking, profile photos, propagation pushes, the Reticulum explainers)
were built from design records that are not committed to this repository yet.
