# Attachments (images and files) — design

**Date:** 2026-09-28. **Scope:** ReTiCaMsgr app only (the ReTiCA prerequisite, transfer-aware
delivery, merged 2026-09-28 at ReTiCA main b6a53bf). **Depends on:** ReTiCA delegates
`deliveryProgress`, `propagationProgress`, `inboundTransferProgress`, `propagationRefused`,
`deliveryRejected`, `deliveryCancelled` and the action `cancelOutbound`.

## Goal

Send one photo (from the photo library) or one file (from Files) per message, receive both from
ReTiCaMsgr and Sideband peers, show images inline and files as an openable/shareable row, and show
transfer progress with a cancel, using LXMF's standard attachment fields so other clients
interoperate.

## Decisions taken while brainstorming

- **One attachment per message** (image *or* file), with an optional caption in `content`.
- **Images go out as JPEG.** Default: long edge ≤ 1280 px, quality 0.75 (≈ 200–450 KB). An
  **Original** toggle per send skips the downscale (re-encoded as JPEG 0.92, orientation baked in,
  metadata stripped). iOS ImageIO decodes WebP but cannot encode it, hence JPEG.
- **Files have no hard cap.** The composer shows the size and, when applicable, a note:
  "> 256 KB — direct only, won't be stored at the propagation node" or "> 1 MB — may be refused by
  other clients". Same notes for images sent as Original. Informational, never blocking.
- **Why those numbers:** a reference LXMF router refuses incoming deliveries over its
  `delivery_limit` (default 1 000 KB, LXMRouter.py:1979, not announced) and propagation nodes
  accept ≤ `PROPAGATION_LIMIT` 256 KB by default (announced, and ReTiCA now refuses an oversize
  propagated copy up front). ReTiCA's own receiver accepts any size (LinkSession.swift:639-658),
  so ReTiCaMsgr↔ReTiCaMsgr has no ceiling beyond transfer time and memory.
- **Storage model B:** a normalised `attachments` table plus bytes on disk (chosen over columns on
  `messages` and over SQLite blobs).

## 1. Data model and storage

### `attachments` table — migration `createAttachments` (after `addReplies`)

| column | type | notes |
|---|---|---|
| `id` | UUID | primary key |
| `messageId` | UUID | FK → `messages.id`, `ON DELETE CASCADE`, indexed (one per message today — enforced by the app, not the schema) |
| `kind` | TEXT | `"image"` or `"file"` |
| `name` | TEXT | file name; images get `IMG_<yyyyMMdd_HHmmss>.jpg` when sent, or the sender's name if the wire carried one |
| `format` | TEXT | images: `jpeg`/`webp`/`png`/`heic`; files: extension without the dot, `""` if none |
| `size` | INTEGER | bytes as sent/received |
| `width`, `height` | INTEGER NULL | images only, read from `CGImageSource` properties (no full decode) |
| `path` | TEXT | relative to the attachments directory |

`Attachment` is a SQLiteData `@Table` struct beside `Message` and `Reaction`.

The same migration adds two nullable columns to `messages`: `failureReason` (`"rejected"` /
`"cancelled"` / NULL) and `propagationRefused` (`"too large for node"` / NULL).

### Bytes on disk — `AttachmentStore` (in `ReTiCaMsgrCore`)

- Directory: `<Application Support>/Attachments/`, created lazily, excluded from iCloud backup,
  `.completeFileProtection`.
- File name: `<messageHash>-<in|out>.<ext>` — direction included because an incoming and an
  outgoing row can share a hash (the delivery-status code already guards that collision).
- API: `store(_ bytes: Data, messageHash: String, outgoing: Bool, ext: String) throws -> String`
  (relative path), `url(for: Attachment) -> URL`, `delete(_ attachment:)`, `exists(_:)`.
- Nothing else in the app touches `FileManager` for attachments.

### Thread loading

`reloadThread` fetches the visible messages, then their attachments in one query
(`WHERE messageId IN (…)`), exposed as `State.attachmentsByMessageId: [UUID: Attachment]` (same
shape as `threadReactions`). Thumbnails are decoded on demand with ImageIO at a capped pixel
size and cached in an `NSCache`; nothing derived is stored.

### Transfer state (memory only)

- `State.outgoingProgress: [String: Double]` keyed by message hash, from `deliveryProgress`.
  The propagated copy's progress is not shown (the direct copy is what the user waits for).
- `State.inboundTransfers: [Data: InboundTransfer]` keyed by link ID, from
  `inboundTransferProgress`: `fraction`, `sourceHash: Data?`, `updatedAt`.
- Both cleared on the terminal delegate (outgoing) or at 1.0 / link close / 60 s silence (inbound).

### Info sheet

New "Attachment" section: kind, name, format, size, dimensions. New rows: failure reason
("rejected by recipient" / "cancelled") and propagation ("refused: too large for node").

## 2. Wire format and the image pipeline

### `AttachmentWire` (core) — beside `ReplyWire` and `ReactionWire`

Encode:
- image → `FIELD_IMAGE 0x06 = [ "jpeg", <bin> ]` (MsgPack array: str, bin) — Sideband's shape;
- file → `FIELD_FILE_ATTACHMENTS 0x05 = [ [ "<name>", <bin> ] ]` (one pair);
- fields ordered `[0x05|0x06, 0x30, 0x31…]` with any reply fields; `content` is the caption
  (may be empty, as Sideband does for image-only messages); title stays empty.

Decode (`decode(_ fields:) -> Decoded?`, lenient):
- `0x06`: `[format, bin]`, `format` as str or bin, case-insensitive; `webp`/`jpeg`/`jpg`/`png`/
  `heic`/`heif` are images; any other format is kept as a *file* named `image.<format>`.
- `0x05`: array of `[name, bin]` pairs, name str or bin; the **first** pair becomes the
  attachment, further pairs are logged and dropped (known limit; the Info sheet's field list still
  shows `0x05`).
- Both `0x06` and `0x05` present: the image wins, files are dropped (same note).
- Malformed field: no attachment; the message is still stored with its text.
- No size cap on accepted bytes (matches ReTiCA's receiver); the payload is copied at most once.

### `ImageEncoder` (app target — UIKit/ImageIO)

- Input: picker bytes (`PhotosPicker` transfer representation); decoded with `CGImageSource`,
  EXIF orientation honoured.
- Output: orientation baked in, **all metadata stripped** (no GPS leaves the phone).
- Default preset: long edge ≤ 1280 px (never upscaled), JPEG 0.75 via `CGImageDestination`.
- Original: JPEG 0.92 at source dimensions, same orientation/metadata handling. HEIC, PNG and
  GIF sources become JPEG too (screenshots lose losslessness — accepted).
- Returns `(data, width, height)`; the composer shows the resulting size.

Incoming images are decoded by ImageIO for display (WebP included on iOS 14+); an undecodable
image is shown as a file row.

## 3. Send flow

### Composer

- A paperclip button left of the text field opens a menu: **Photo Library** (`PhotosPicker`,
  images only, one item) and **Document** (`fileImporter`, any type, one item). Picking replaces
  any pending attachment.
- An **attachment bar** above the text field (where the reply bar sits; both can show at once):
  thumbnail or document icon, `name · 342 KB`, the size notes, an **Original** toggle (images
  only), and × to remove.
- Send is enabled when there is text *or* an attachment.

### Preparation (asynchronous)

`.attachmentPicked(PickedItem)` → effect reads the bytes and, for images, runs `ImageEncoder`
off the main thread → `.attachmentPrepared(PendingAttachment)` sets
`State.pendingAttachment { kind, name, format, data, width, height, originalSource: Data? }`.
Toggling Original re-runs the encoder from `originalSource`. A spinner shows meanwhile;
`.attachmentFailed(reason)` shows a one-line error in the bar and keeps the composer usable.

### Sending

`sendTapped`: `fields = AttachmentWire.encode(pending) + reply fields`; create the `LXMessage`;
write the bytes with `AttachmentStore` (`<hash>-out.<ext>`); insert the `Message` row and the
`Attachment` row in one transaction; send with `alsoViaPropagation` as today. `wireSize`
includes the attachment. `pendingAttachment` and `draft` clear synchronously.

### Progress

`deliveryProgress(hash, fraction)` → `outgoingProgress[hash]`. An outgoing bubble with an
attachment in `.sending` shows a thin progress bar under the thumbnail/file row: indeterminate
below 0.10 ("waiting for link"), then the fraction. Text-only messages ignore progress.

### Cancel

Context menu on an outgoing `.sending` message: **Cancel Send** → `cancelOutbound(messageHash:)`.
New `MessageStatus.cancelled = "cancelled"`: `deliveryCancelled` maps to it with the same
delivered/outgoing guards and `failedAt` milestone as `failed`; the bubble shows "Cancelled". No
retry (ReTiCA forbids re-sending a hash; the user re-attaches). `deliveryRejected` stays
`failed` with `failureReason = "rejected"`.

### Propagation

`propagationRefused(hash, .tooLargeForNode)` → `messages.propagationRefused`, shown in the Info
sheet. No alert: the size note warned before sending.

## 4. Receive flow and display

### Receiving

In `messageReceived`, after the reaction and reply decoders, `AttachmentWire.decode` runs. On a
hit: bytes → `AttachmentStore` (`<hash>-in.<ext>`), then the `Message` and `Attachment` rows in
one transaction; dimensions from `CGImageSource` properties. `body` is the caption. If the disk
write fails, the message is stored without its attachment and the bubble says "Attachment could
not be saved" — text is never lost.

### Bubbles (`MessageBubble` gains an attachment slot above the caption)

- **Image:** thumbnail sized from the stored width/height (max ≈ 240 pt wide, aspect kept),
  decoded at thumbnail resolution and cached. Tap → full-screen viewer (zoom, swipe down to
  dismiss) with a share button.
- **File:** row with a document icon, name, size. Tap → `QuickLook` preview with the system
  share / save-to-Files action (this is the "download").
- Outgoing bubbles render from the same table plus the progress bar.
- Reply quotes and the conversation-list preview use the caption, or `📷 Photo` /
  `📎 <name>` when the caption is empty (`ReplyWire.trimQuote` receives that text).

### Inbound progress

`inboundTransferProgress(sourceHash: nil, …)` cannot name the sender: a small
**"Receiving… 43 %"** capsule shows at the top of the open thread *and* in the conversation
list toolbar. With a non-nil `sourceHash` (a link we opened) it shows only in that peer's
thread. Cleared at 1.0, on link close, or after 60 s without an update.

### Privacy keys

None needed: `PhotosPicker` and `fileImporter` run out of process; there is no camera capture.

### Errors

| situation | behaviour |
|---|---|
| picker read failure / undecodable image | inline error in the attachment bar |
| store write failure on send | alert "Couldn't save attachment", nothing sent |
| store write failure on receive | message kept, attachment dropped, bubble note |
| file missing on disk for a row | bubble shows "Attachment unavailable" |
| `propagationRefused` / `deliveryRejected` / `deliveryCancelled` | as §3 |

## 5. Testing

**Core package (Swift Testing, `swift test`), every test mutation-verified:**
- `AttachmentWire`: exact encode shapes; decode of Sideband variants (str/bin format and name,
  every image format, unknown format → file, several files → first, image + files → image,
  malformed → nil); round trips.
- `AttachmentStore` on a temporary directory: naming by hash + direction, overwrite, delete,
  missing-file lookup.
- Migration on top of the existing chain; `Attachment` insert/query; the two new `messages`
  columns.
- `AppFeature` (TestStore; `.off` for flows, exhaustive windows for absence; see the TestStore
  notes from the transfer-aware delivery run): send with image / with file writes rows, file and
  fields; receive `0x06` / `0x05` / malformed; `deliveryProgress` updates and every terminal
  clears; `deliveryCancelled` → `cancelled` with guards; `deliveryRejected` → `failed` + reason;
  `propagationRefused` → column; cancel action → `cancelOutbound`; inbound progress keyed by
  link, attributed when `sourceHash` is set, cleared on 1.0 / close / silence; thread load
  exposes `attachmentsByMessageId`; reply-quote placeholders.

**App target (UIKit/ImageIO):** `ImageEncoder` — long edge ≤ 1280 never upscaled, orientation
baked in, EXIF/GPS stripped, Original keeps dimensions, HEIC/PNG become JPEG. Views are not
unit-tested (as elsewhere); the Xcode app-target build must succeed.

**Manual:** a photo to a Sideband peer renders there; a Sideband WebP renders here; a PDF over
BLE shows progress and can be cancelled.

## Amendments at planning time (2026-09-28)

A pre-flight scan of the implementation plan against the code surfaced these corrections. They
override the text above where they conflict.

1. **File protection is "until first user authentication", not "complete".** The app receives
   over BLE in the background; with complete protection a message arriving while the phone is
   locked could not be written and would always land as "attachment could not be saved". The
   SQLite file uses the same class.
2. **A reply to a photo that is still in the thread quotes `📷 Photo`.** `ReplyPreview.resolve`
   takes the thread's attachments so the quote block does not read "Original message not
   available" for an image-only original.
3. **Sharing and QuickLook use the real file name.** `AttachmentStore.exportURL(for:)` copies the
   bytes to a temporary directory under `attachment.name` before presenting them; the stored file
   keeps its hash-based name.
4. **A send-side store failure shows in the attachment bar and restores the caption** (no alert):
   `attachmentSendFailed(draft:)` puts the typed text back so nothing is lost.
5. **The viewer dismisses on a downward drag** (over 120 pt at zoom 1) as well as with Done.
6. **File rows distinguish "could not be saved" (never written) from "unavailable" (written,
   then removed).**
7. **Dropped `0x05` entries are counted** (`Decoded.droppedFileCount`) and logged, never silently
   discarded.
8. **`ImageEncoder` lives in the core package** (ImageIO only) so `swift test` covers it on
   macOS; §5's "app target" placement no longer applies.
9. **`AttachmentStore`'s API** is `store(_:messageHash:outgoing:ext:) -> String`,
   `url(forRelativePath:)`, `url(for:) -> URL?`, `exists(_:)`, `delete(_:)`, `exportURL(for:)`.
10. **Test files disambiguate the model with a scoped import:** Swift Testing exports its own
    generic `Attachment<AttachableValue>`, and a `typealias Attachment = ReTiCaMsgrCore.Attachment`
    does not compile (the module also exposes `public enum ReTiCaMsgrCore`), so a test file that
    names the type adds `import struct ReTiCaMsgrCore.Attachment`. The model keeps its name.

## Out of scope

Multiple attachments per message; camera capture; audio (`FIELD_AUDIO`); retrying a failed or
cancelled attachment message (needs a new message); voice/animated formats; per-peer delivery
limits (not announced by LXMF).
