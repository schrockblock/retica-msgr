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
