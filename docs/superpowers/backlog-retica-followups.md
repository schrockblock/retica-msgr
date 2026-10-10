# Backlog: ReTiCA-side follow-ups

**Started:** 2026-09-26. These are items deliberately left out of app-only features so they could
ship without a second repo. Each one needs a ReTiCA change (worktree + merge-order: ReTiCA first,
app immediately after, because the app depends on `../../../pods/ReTiCA` by path).

## Surface more per-message metadata to the app (deferred from the message Info feature)

The Info sheet (2026-09-26 spec) shows everything the app can already see. These three would make
it a better mesh-debugging tool but are dropped inside ReTiCA before the app hears about a message:

- **Hop count.** How many relays the inbound packet crossed. Transport knows `packet.hops` when it
  delivers; `Transport.Delegate.received` / `TransportEndpoint.messageReceived` /
  `LXMFNode.Delegate.messageReceived` would each need to carry it. (Propagated downloads have no
  meaningful hop count — report nil.)
- **Arrival interface.** Which interface the message came in on (TCP, BLE peer, listener).
  `TransportEndpoint.messageReceived` already carries `interfaceID` since the proofs work;
  `LXMFNode.Delegate.messageReceived` doesn't pass it up. Consider mapping `InterfaceID` to a
  human-readable label (e.g. "TCP 127.0.0.1:4242", "BLE ab12…").
- **Retry count for outgoing messages.** How many attempts a copy took before it was confirmed or
  failed. `LXMFRouter.pendingDeliveries[key].attempts` has it, but the entry is removed on
  success/failure; `deliveryConfirmed` / `propagationAccepted` / `deliveryFailed` would need an
  `attempts:` value (per copy).

## Delivery-status correctness (left from the single-packet proofs work)

See ReTiCA spec `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md`, "Amendments at
planning time", item 3. (The false "failed" with a propagation node configured is fixed by ReTiCA's
transfer-aware delivery work, `2026-09-27-transfer-aware-delivery-design.md` §6.)

- **Delivery-stamp search gaps.** `.cancelDeliveryStamps` emits `deliveryFailed` directly
  (bypassing `fail`), and a delivery copy still in its stamp search isn't counted as outstanding.
  Affects peers with a delivery stamp cost.
- **Late proof after the last retry.** A proof arriving after the final `retryDue` already failed
  the delivery copy is dropped (`succeed` guard). Reference would still mark it delivered. Consider
  letting a late `opportunisticDelivered` for a recently failed hash emit `deliveryConfirmed`.
- **Unreceipted direct link sends.** Small messages sent over an established link (`sendOverLink`)
  get no receipt, so they resend and end in a false `deliveryFailed`. (Pre-existing.)
- **Relay proof routing.** A ReTiCA node in relay mode doesn't route proofs for third parties (no
  reverse table). (Reference gap-analysis §1.6, relay half.)

## Left from the transfer-aware delivery work (2026-09-28)

See ReTiCA spec `docs/superpowers/specs/2026-09-27-transfer-aware-delivery-design.md` and the
final-review notes in its SDD ledger. Each is reference parity or pre-existing behaviour that the
files/images feature may want to revisit:

- **A receiver-side timeout counts as a rejection.** Both ReTiCA's and reference's receiver send
  RESOURCE_RCL when their part retries are exhausted, so the sender gets `deliveryRejected` and never
  retries. Over flaky BLE/LoRa a user sending an image would expect a retry. Options: an app-level
  "retry" on rejected rows, or ReTiCA distinguishing a timeout RCL from a policy reject (not on the
  wire today).
- **Attempts burn while a link re-establishes slowly.** After a non-rejected transfer failure each
  10 s `retryDue` that finds no active link consumes an attempt, so a slow re-establish can exhaust
  the copy without a second transfer. Pre-existing `retryDue` semantics (reference counts attempts
  the same way).
- **Sending the same hash twice re-arms and re-sends it.** `arm` resets a copy in flight to
  attempt 1 and a second transfer of the same bytes starts behind the first; its progress can arrive
  after `deliveryConfirmed`. Only reachable by the app sending one `LXMessage` twice — don't.
  Likewise a hash that already succeeded on one copy and was then cancelled must not be re-sent:
  the cancel is silent, the copy's last progress value stays as a monotonic floor, and the re-send
  gets no terminal because the router still remembers the success. Build a new message instead.

## Left from the attachments work (2026-09-29)

Set aside by the final review as policy calls or pre-existing behaviour; each is a small, contained
change if wanted.

- **No memory ceiling for huge files.** The spec says "no hard cap"; a picked file is held in memory
  several times over (picker bytes, the pending attachment, the LXMF payload, its signature copies).
  A 100 MB+ document can be killed by iOS for memory. A warn-or-refuse threshold is a policy call.
- **A JPEG picked via Document keeps its EXIF/GPS.** Only photos from the Photo Library are
  re-encoded (and stripped); a file is sent byte-for-byte by design. A one-line hint in the composer
  bar would tell a privacy-minded user.
- **Received photos are all named `image.<format>`** (LXMF `FIELD_IMAGE` carries no name), so saving
  several to Files auto-renames. `IMG_<first 8 hex of the hash>.<format>` would be friendlier — a
  spec amendment.
- **`threadLoaded` has no peer check** (pre-existing, likelier now that a large attachment send
  writes to disk before reloading): switching conversations during a slow send can land the previous
  thread's rows in the new one for a moment. Fix: carry `peerHex` in `threadLoaded` and drop
  mismatches; `attachmentSendFailed(draft:)` has the same shape.
- **A picker failure carries no conversation.** `attachmentFailed` sent by the view has no peer
  guard, so a failed read started in conversation A can show its error in B and cancel B's
  preparation; a view-side `attachmentLoadFailed(peerHex:reason:)` guarded like
  `attachmentLoadStarted` closes it.
- **`propagationAccepted` never clears `outgoingProgress`** (by design — the direct copy decides);
  if the direct copy then ends with no delegate the entry leaks for the session (hidden by the
  status gate).
- **Public surface:** `ImageEncoder.containerType`/`hasLocationOrOrientationMetadata`/`isDecodable`,
  `AttachmentStore.fileName`/`sanitizedExtension`/`exists`/`delete`, all of `AttachmentWire` and
  `AttachmentPreparation` are `public` but used only inside the package — could be `internal`.
- **Bubbles show the raw status string** ("cancelled", like "failed"/"sending") — a capitalised
  label would be a style change across all statuses.
- **Sideband voice messages (`FIELD_AUDIO 0x07`) render as empty bubbles** (pre-existing, out of
  scope); **propagation-node sync downloads show no "Receiving…" capsule** (attributed to the node's
  hash).

## Left from the send-gate fix (2026-09-29)

The app now sends a path request when a direct message arrives from a peer it has no path to, and
again when that conversation is opened or started; the reply unlocks Send through `pathLearned`.
Two edges remain:

- **A stale path is never replaced by an equal-time reply.** If the stored path points at a dead
  interface, a path reply carrying the same announce time and hop count is not adopted
  (`Transport.shouldReplace`), so `pathLearned` never fires and Send stays disabled until the peer
  re-announces. Needs a ReTiCA change: prefer a reply that arrives on a live interface when the
  stored one is dead, or expire paths whose interface went away.
- **No throttling of path requests.** One request goes out per received message from a peer outside
  the gate, and ReTiCA's `Transport` (around lines 1065–1081) does not coalesce repeats for the same
  destination. Harmless at chat volumes; a "request pending for this hash" guard in the app, or
  coalescing in ReTiCA, would close it.

## Push wake-ups (spec 2026-10-01)

Shipped app-side with no ReTiCA changes. Known limits, all documented in the spec and in
`ReTiCAPush/docs/server-contract.md`:

- The service extension proves only single-packet DATA copies and skips IFAC-flagged packets;
  registration happens over the hub's Reticulum link (not HTTP). **Verified 2026-10-01**: extension
  not observed on the Simulator; device run outstanding. Built and installed on the booted iPhone 17
  Simulator (confirmed `UIBackgroundModes` includes `remote-notification` and the embedded
  `ReTiCaMsgrNotificationService.appex`'s `NSExtensionPointIdentifier` is
  `com.apple.usernotifications.service`), enabled the push toggle, backgrounded the app, and sent
  `xcrun simctl push` with the spec's `rns.packets: ["AAABAgM="]` payload. `usernotificationsd`
  processed and queued the notification (full `NotificationsPipeline` trace ending "Request:
  Completed"/"success"), but the app group's `ReTiCAPush/inbox/` stayed empty and `log show`
  around the push shows zero `PlugInKit`/`pkd:` activity for
  `co.lithobyte.ReTiCaMsgr.NotificationService` (only at install time) — this Simulator does not
  invoke the Notification Service Extension for a `simctl push`-simulated remote notification, so
  the device run against a real hub remains the outstanding manual check.
- Delivery confirmation depends on the push, wake and proof fitting inside the sender's receipt
  window (6 s + 6 s/hop per attempt, five attempts 10 s apart). A longer receipt lifetime for
  push-registered peers would be a ReTiCA change.
- Server and APNs are out of scope; the contract is the deliverable.

**Device findings 2026-10-02** (hub inspected live over ssh; see the memory note "push hub
debugging" for the recipes):

- The hub side (binding on announce, dormancy, retirement, pathing) behaved exactly as the contract
  says. Pushes did fire; what they carried was a LINKREQUEST, because **Retichat, Sideband and
  NomadNet all deliver over Links (LXMF DIRECT)**. The extension cannot answer a handshake and the
  app cannot answer it late, so "banner, tap, no message, sender shows failure" is the documented
  limit, not a drain bug. Push wake-ups deliver the message itself only for single-packet
  (OPPORTUNISTIC) senders such as another ReTiCaMsgr.
- **Fix shipped:** the scene's `.background` phase now sends `.backgrounded`, which closes the hub
  socket (`.endpoint(.tcpClient(.disconnect))`). A suspended app's socket otherwise stays alive to
  the hub for 2–15 minutes on cellular (the kernel keeps answering keepalives), the hub writes into
  it, and nothing is pushed in that window. ReTiCA's endpoint now deregisters the interface on an
  explicit disconnect (it previously only did so for a dropped socket), so the foreground re-dial
  still fires.
- **Open:** a registration link in flight when the app backgrounds dies with the socket and the
  attempt reports a failure; it is retried only on the next launch or token change. Rare, but a
  retry on the next `.foregrounded` would close it.
- **Open:** after a content-available background wake the re-dialled socket is left open when the
  hold ends and iOS suspends the process again, reopening the no-push window. Closing it when the
  hold ends and the app is still in the background would need an `applicationState` probe in
  `AppRuntime.pushWake`.
- **Open (product):** link-based senders need a propagation node to reach a suspended ReTiCaMsgr.
  The app already syncs from its configured propagation node on every reconnect, including the
  one a push wake triggers, so the push from a failed link request can be the wake that fetches
  the message from the PN. Documenting this for users (and considering a PN on the hub) is the
  remaining work.
- Two apps on one phone (ReTiCaMsgr and Retichat both on Atli) can never complete a Link through
  the hub: the foreground app suspends the other. Only propagation bridges that case.
- `rnpath`/`rnprobe` against the hub report "not found"/"timed out" even when the path exists,
  because the shared instance answers local path requests only from its announce cache, which
  misses. `rnpath -t` (full table) is the authoritative check.

## Disappearing messages (2026-10-05)

Left out by design (spec "Out of scope"): read receipts, a live countdown on bubbles, manual
delete-message and delete-conversation (the `MessagePurge` primitives make both small), groups.
Follow-ups noticed while implementing:

- The convergence line uses the peer's announce display name at receive time; a later announce
  with a new name does not rewrite earlier lines.
- `isForeground` starts true, so a push-wake launch counts as foreground until the first
  `.backgrounded`; harmless today because no thread can be open then.
- The Simulator cannot reach a peer, so the toolbar menu, the system line after choosing a preset, the title subtitle and the bubble glyph after a send were only code-reviewed, never seen. Check them on a device with a reachable ReTiCaMsgr peer, and check ChatTitle for clipping with a long title plus "4 weeks".
- Test-helper duplication left by the plan: MessageInfoTests' expiryInfo helpers duplicate the file's info(_:)/utc/peer32/hash64; ExpiryPreset.swift has an unused import Foundation and rebuilds its units array per call.
- Fixed on 2026-10-05 (spec amendments A15–A17, branch `fix/disappearing-followups`): the
  out-of-order purge-completion race, the purge's full-row scan, the send-before-setting-loaded
  gap, the reachability gate on the menu, orphan reaction rows, the thumbnail cache, and the
  learned-display-name test.
- Still open: a sheet presented over ChatView keeps `chatVisible` true, so an arrival while a sheet
  is up counts as viewed. ChatView's onAppear double-stamps right after `.openConversation`
  (harmless: the second stamp finds nothing).

## Group chats (2026-10-09)

Left out by design (spec "Out of scope"): attachments and disappearing timers in groups, member
public keys in invites (a ReTiCA change: seed a recipient key without a path so a copy can be
encrypted before the member's announce is heard), app-layer pacing of the fan-out burst for LoRa,
re-fanning replies from members on other clients, reading Retichat's group fields, creator
transfer, history for late joiners, an age limit on waiting copies, group reactions to members
unreachable at the tap.
Follow-ups noticed while implementing:

- A deferred copy is re-stamped with the dispatch time, so a receiver's "Written" row shows when
  the copy went out, not when the post was typed.
- A member's path learned while the app holds many waiting copies sends them all in one burst
  (the dispatcher has no pacing); the RNode firmware queues them.
- A post arriving before its group's first roster lands as a one-to-one message and is never
  re-homed into the group when the roster arrives.
- Event lines use announce display names at write time; a later announce with a new name does
  not rewrite earlier lines.
- `interfaceConnected` and the launch seeding call the dispatcher but have no test of their own
  (a live interface registration cannot be simulated in the TestStore today).
- A leave sent by a group's creator is applied like any member's (`GroupControlApply.applyLeave` does not check `senderHex != stored.creatorHex`); the spec says the creator cannot leave.
- `.leaveGroup` is accepted on an `invited` group and sends the leave to every member, whereas decline sends it to the creator only; `groupChange` checks its guards against state that may be stale by the time its write runs (a dissolve roster landing before the reload).
- Three same-shaped lines (`guard let row = try T.where { ... }.fetchOne(db)` in the dispatcher and in `GroupDelivery.applyOutcome`, and the duplicate-post check in the receive path) emit a "trailing closure confusable with the body" compiler warning; bind the fetch to a `let` first.
- Several failed roster rows for one member are all re-sent when their path is learned; only the newest needs re-arming.
- `addGroupMembers` checks the member cap against `openGroupMembers`, which may be stale by the time the write runs.
- Group reactions are not gated on the group's state (a left, dissolved or invited group still sends them).
- `cancelSendTapped` has no reducer guard for group rows (the UI hides it, amendment A10, but the action would run).
- Reply labels in groups mis-infer "You" / "Them" when the original is missing from the thread or its sender never announced.
- The Info payload section does not name the 0xFD map keys (the spec §4 line was dropped and needs a decision).
- Waiting post copies outlive membership: a member removed before their path is learned still gets the post later.
- The open-thread reset block is duplicated across the open and create cases, and the reaction branches repeat the same optimistic-update lines.
- `AppFeature.swift` is about 2,700 lines; move the group helpers to `AppFeature+Groups.swift`.
- The `groupSends` test helper appends inside a `receive` predicate, which can run more than once per action, so `sent` may hold duplicates.
- A duplicate group post carrying an attachment leaves its saved file orphaned.
- A group post carrying an expiry "change" entry takes the timer sentence as its body.
