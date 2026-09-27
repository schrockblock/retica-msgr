# Message replies

**Written:** 2026-09-27. **Repo:** ReTiCaMsgr (`/Users/ell/development/ios/apps/ReTiCaMsgr`).
- **Logic:** `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/`.
- **UI:** `ReTiCaMsgr/`.
- **Implementation:** in the worktree `/Users/ell/development/ios/apps/ReTiCaMsgr-replies` on branch `feat/message-replies`, merged to `main`.

## Goal

A message can be replied to from its long-press menu:
- The message being replied to appears in a bar above the text field.
- The sent reply shows a quoted preview of the original inside its bubble.
- Tapping that preview scrolls to the original and briefly highlights it.

## Decisions (agreed during brainstorming)

- **No swipe gesture.** Replies start only from a **Reply** row in the context menu.
  - Signal-iOS was studied for a gesture. It uses a collection-view pan that yields to the navigation pop and to iOS 26's full-screen content pop.
  - That was deferred because it conflicts with iOS 26's swipe-anywhere-to-go-back.
- **Standard LXMF fields**, per reference `LXMF/LXMF.py:23-24`:
  - `FIELD_REPLY_TO = 0x30`: the original's full `LXMessage.hash`, as bytes.
  - `FIELD_REPLY_QUOTE = 0x31`: the quoted content, as UTF-8 bytes.
- **The quote is included**, trimmed to 100 characters (grapheme clusters) plus "…" when cut.
  - This keeps the preview working when the recipient lacks the original.
  - It costs at most a few hundred bytes per reply.
- **Replyable messages:** any bubble with a non-empty `messageHash`, incoming or outgoing.
  - Legacy hashless messages get no Reply row.

## Current state

- **`ChatView`** renders `List(store.threadMessages)`. Each row carries a `.contextMenu` with, in order:
  - the `ReactionPaletteMenu` (only for rows with a hash);
  - **Info**, then **Copy**.

  It already has a `sheet(item:)` for `EmojiPickerSheet` and one for `MessageInfoSheet`.
- **`sendTapped`** in `AppFeature` builds the `LXMessage` from `state.draft`, with no fields. It inserts the outgoing row, including the Info metadata columns.
- **`messageReceived`** routes on `ReactionWire.decode(m.fields)`: reaction, malformed reaction, or ordinary message.
  - For an ordinary message, it inserts a row with the Info metadata (`MessageMetadata`).
- **`MessageInfo`** already names field keys `0x30 reply to` and `0x31 reply quote`.
- **`threadMessages`** holds every message for the open peer (`reloadThread`), so any original in this conversation is present in state.

## Wire format

- **Send:** a reply is a normal text message (`content` = the reply text) with:
  - `fields = [0x30: .bin(originalHash 32 bytes), 0x31: .bin(trimmedQuote UTF-8)]`.
  - No other fields are added. Clients without reply support show the text as a normal message.
- **Receive:**
  - If `ReactionWire.decode` classifies the message as a reaction (or a malformed reaction), that handling is unchanged. Reply fields on such a message are ignored.
  - Otherwise, `ReplyWire.decode(fields)` returns `(replyTo: Data, quote: String?)?`, following these rules:
    - `0x30` missing, not `.bin`, or of length outside 16–32 → `nil` (not a reply; `0x31` is also ignored).
    - `0x31` present, `.bin`, ≤ 400 bytes, and valid UTF-8 (strict round-trip, as in `ReactionWire`) → it becomes `quote`. Otherwise `quote = nil`, but the reply is kept.
  - A message with `0x31` but no `0x30` is not a reply.
- **Trim rule** (`ReplyWire.trimQuote(_:)`):
  - If the text has at most 100 `Character`s, it is used unchanged.
  - Otherwise it becomes the first 100 `Character`s + "…".
  - Leading and trailing whitespace and newlines are trimmed first.
  - **Amendment (plan time):** after the character cut, whole trailing characters are dropped until
    the result, including "…", is at most `maxQuoteBytes` (400) UTF-8 bytes. Without this, 100 wide
    characters (for example ZWJ family emoji at 25 bytes each) would exceed the receiver's decode cap
    and be dropped by every client running this app. Plain text is unaffected.
  - **Amendment (final review):**
    - The receiver accepts `0x31` as msgpack `str` as well as `bin`, under the same caps.
    - The sender omits `0x31` when the trimmed quote is empty.
    - `openConversation` and `startConversation` clear the reply target.

## Data model

Migration `addReplies` is registered after `addMessageInfo` in `Database.swift`. It adds two nullable columns to `messages`:

| Column | Type | Meaning |
|---|---|---|
| `replyToHash` | text / `String?` | hex of the original's LXMF hash |
| `replyQuote` | text / `String?` | the quote as sent or received (trimmed) |

- **New properties:** `Message` gains `replyToHash: String? = nil` and `replyQuote: String? = nil`, appended after the Info fields. Existing construction sites keep compiling.
- **Outgoing** replies store both columns.
- **Incoming** replies store `replyToHash`, and `replyQuote` when the decoded quote is present.
- Legacy rows read back `nil`.

## Core logic

- **`ReplyWire`** (new, pure):
  - `encode(replyTo: Data, quote: String) -> [MsgPackValue.IntPair]` produces the two fields, with the quote already trimmed by the caller.
  - `decode(_ fields:) -> (replyTo: Data, quote: String?)?`.
  - `trimQuote(_:) -> String`.
  - Constants: `fieldReplyTo = 0x30`, `fieldReplyQuote = 0x31`, `maxQuoteBytes = 400`, `quoteCharacterLimit = 100`.
- **`AppFeature`**:
  - **State:** `replyTarget: ReplyTarget?`. `ReplyTarget` is `Equatable` and holds `messageHash: String`, `body: String` and `isOutgoing: Bool`.
  - **Actions:**
    - `.replyTapped(Message.ID)`: finds the message in `threadMessages` and sets `replyTarget` if its `messageHash` is non-empty. Otherwise it does nothing.
    - `.replyCancelled`: clears `replyTarget`.
  - **`sendTapped`:** when `replyTarget` is set:
    - it adds `ReplyWire.encode(replyTo: <hash bytes>, quote: ReplyWire.trimQuote(target.body))` to the `LXMessage`;
    - it stores `replyToHash` and `replyQuote` on the outgoing row;
    - it clears `replyTarget`.

    Without a target, behaviour is unchanged.
  - **`closeConversation`:** clears `replyTarget`.
  - **`messageReceived`:** on the ordinary-message path, decodes `ReplyWire` and stores the columns in the same insert.
- **`ReplyPreview`** (new, pure): `resolve(for message: Message, in thread: [Message], peerName: String?) -> ReplyPreview.Resolved?`, where `Resolved` has `senderLabel`, `text` and `originalID: Message.ID?`.
  - It returns `nil` when `message.replyToHash == nil`.
  - **Original found** (a message in `thread` whose `messageHash == replyToHash`):
    - `senderLabel` is "You" if the original is outgoing, otherwise `peerName ?? "Them"`.
    - `text` is `ReplyWire.trimQuote(original.body)`.
    - `originalID` is the original's id.
  - **Only a quote:** the sender comes from the reply's direction. An incoming reply quotes our message, so it gets "You"; an outgoing reply quotes theirs, so it gets `peerName ?? "Them"`. `text` is the quote, and `originalID` is `nil`.
  - **Neither:** `senderLabel` follows the same direction rule, `text` is "Original message not available", and `originalID` is `nil`.
- **`peerName`:** the peer's announced display name, if the app already has one available for the open conversation. Otherwise it is `nil`. The plan confirms the exact source.

## UI

- **Menu:** `Button("Reply", systemImage: "arrowshape.turn.up.left")` in the context menu, placed after the reaction items and before Info.
  - It is shown only when `!message.messageHash.isEmpty`.
  - It sends `.replyTapped(message.id)` and focuses the draft `TextField` (via `@FocusState`).
- **Composer bar:** shown above the `TextField` row when `store.replyTarget != nil`. It contains:
  - a 3 pt accent-coloured vertical bar;
  - "Replying to You" or "Replying to <name/Them>", in caption, semibold;
  - one line of `ReplyWire.trimQuote(target.body)`, secondary style;
  - a trailing ✕ button that sends `.replyCancelled`, with a ≥ 44 pt hit area using `.frame(…)` + `.contentShape(Rectangle())`.
- **Bubble quote block:** for a message whose `ReplyPreview.resolve(...)` is non-nil, the bubble shows a quote block above its text.
  - It is a rounded panel with a 3 pt leading bar.
  - Its background contrasts with the bubble: white at low opacity on outgoing (blue) bubbles, and primary at low opacity on incoming ones.
  - It shows `senderLabel` (caption, semibold) and `text` (caption, 2-line limit).
  - **Tap-to-scroll:**
    - When `originalID != nil`, the block is tappable. Tapping scrolls the `List` (wrapped in `ScrollViewReader`) to `originalID` with `anchor: .center`.
    - It then sets `highlightedMessageID`, which draws an accent outline on that bubble and fades it out over about 1 second.
    - When `originalID == nil`, the block is not tappable.
- **Accessibility:** the quote block gets the label "Reply to <sender>: <text>" and, when scrollable, the hint "Shows the original message".

## Testing

Swift Testing in `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/`. Every new test goes through mutate → red → revert → green, with no new known issues.

- **`ReplyWire`**
  - Round trip through a real `LXMessage.create` → pack → unpack.
  - Byte-level comparison against reference `umsgpack` output for `{0x30: hash, 0x31: quote}`, using a script in `/tmp/ReTiCaMsgr/` run with `/Users/ell/opt/anaconda3/envs/rns/bin/python`.
  - Trim: ≤ 100 characters is unchanged, > 100 is cut to 100 + "…", surrounding whitespace is trimmed, and a ZWJ emoji at the boundary is not split.
  - Invalid `0x30` (missing, not bin, 15 or 33 bytes) → `nil`.
  - Invalid `0x31` (not bin, 401 bytes, invalid UTF-8) → the reply is kept with `quote == nil`.
  - `0x31` without `0x30` → `nil`.
- **Migration:** a legacy row reads back with `replyToHash`/`replyQuote` nil, and both columns round-trip.
- **`AppFeature`**
  - `replyTapped` sets the target; on a hashless message it does nothing.
  - `replyCancelled` clears the target.
  - `sendTapped` with a target:
    - the sent `LXMessage.fields` decode via `ReplyWire` to the target hash and trimmed quote;
    - the outgoing row stores both columns;
    - the target is cleared.
  - `sendTapped` without a target sends no reply fields and stores nil.
  - `closeConversation` clears the target.
  - An incoming reply stores both columns.
  - An incoming reply with an invalid quote stores `replyToHash` and nil `replyQuote`.
  - A message carrying a valid `0x40` reaction and reply fields is still stored only as a reaction.
- **`ReplyPreview`:** original found (outgoing original → "You"; incoming original with and without `peerName`); quote only; neither; not a reply → nil.
- **UI (manual, simulator):** uses a temporary seed scaffold that is reverted in code only, and the app is not uninstalled. Check:
  - the Reply row on hash and hashless bubbles;
  - the composer bar and its ✕;
  - sending a reply shows the quote block;
  - tap-to-scroll with the highlight;
  - "Original message not available";
  - the Info sheet lists `0x30 reply to` / `0x31 reply quote`.

## Out of scope

- Swipe-to-reply, and swipe-left-for-Info.
- Replying to hashless legacy messages.
- Threads and nested quote chains. A quoted reply shows only its own text.
- Editing the quote.
- A reply preview in the conversation list.
- `FIELD_COMMENT` and `FIELD_CONTINUATION`.
