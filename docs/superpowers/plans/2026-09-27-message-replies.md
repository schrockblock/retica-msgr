# Message Replies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A message can be replied to from its long-press menu. The original shows in a bar above the text field, the sent reply shows a quoted preview inside its bubble, and tapping that preview scrolls to the original and briefly highlights it.

**Architecture:** One GRDB migration (`addReplies`) adds two nullable columns to `messages`. A pure `ReplyWire` codec reads and writes the standard LXMF fields `FIELD_REPLY_TO` (0x30) and `FIELD_REPLY_QUOTE` (0x31). `AppFeature` holds a `replyTarget`, attaches the fields in `sendTapped`, and stores them on the receive path. A pure `ReplyPreview` resolver turns a reply row plus the open thread into what the bubble shows. SwiftUI adds a Reply menu row, a composer bar, a quote block and scroll-to-original.

**Tech Stack:** Swift 6 (package) / Swift 5 mode (app), TCA (ComposableArchitecture), SQLiteData/StructuredQueries on GRDB, Swift Testing, SwiftUI (iOS 26.4), ReTiCA (`LXMessage`, `MsgPackValue`, `MsgPack`, `LXMFNode.LearnedPeer`).

**Spec:** `/Users/ell/development/ios/apps/ReTiCAMsgr-replies/docs/superpowers/specs/2026-09-27-message-replies-design.md`. Read it before starting. It is binding. Where this plan resolves something the spec leaves open, the resolution is listed under "Spec resolutions" below.

## Global Constraints

**Where you work**
- All work happens ONLY in the worktree `/Users/ell/development/ios/apps/ReTiCAMsgr-replies`, on branch `feat/message-replies`.
- Never commit in `/Users/ell/development/ios/apps/ReTiCAMsgr`.
- Never touch `/Users/ell/development/ios/pods/ReTiCA`: no edits, no git, no builds inside it. Another agent works there.
- **ReTiCA drift:** the package builds ReTiCA from its live checkout, and it may change mid-run. If a build or test failure traces into ReTiCA source, stop and report it. Do not work around it. A stale local `.build` directory inside the worktree (`ReTiCAMsgrCore/.build`) may be deleted if it causes a build failure.

**Shell**
- One command per Bash call. No `|`, `&&`, `||`, `;`, `$(...)` or `xargs`.
- No inline interpreters (`python -c`, `swift -e`, heredocs into interpreters, and so on). Scripts go in files under `/tmp/ReTiCAMsgr/`. Create that directory once with `mkdir -p /tmp/ReTiCAMsgr`.

**Commits**
- Stage explicit paths only: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies add <path> <path> ...`. Never `git add -A` or `git add .`. The worktree may hold unrelated untracked or modified files (xcuserdata, other plans, this plan) that must not be staged.
- **Each task writes its commit message to its own file**, `/tmp/ReTiCAMsgr/msg-replies-task-N.txt` (N = the task number), with the **Write** tool, then runs `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies commit -F /tmp/ReTiCAMsgr/msg-replies-task-N.txt`. Never reuse another task's file. A shared message file produced wrong commit messages twice before.
- No semicolons anywhere in a commit message.
- End every commit message with these two trailer lines, at column 0, after a blank line. Put the name of the model that actually wrote the commit in the first line (for example `Claude Opus 5.5`):
  ```
  Co-Authored-By: <model name> <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
  ```

**Tests**
- Command: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore [--filter X]`.
- The baseline is **202 tests, all green**.
- The whole package must compile at the end of every task.
- Each task's new tests share a unique name prefix, so one `--filter` selects exactly them:

  | Task | Prefix | New tests | Suite total after |
  |---|---|---|---|
  | 1 | `replyMigration` | 2 | 204 |
  | 2 | `replyWire` | 9 | 213 |
  | 3 | `replyTarget` | 7 | 220 |
  | 4 | `replyReceive` | 3 | 223 |
  | 5 | `replyPreview` | 7 | 230 |

**Mutation verification (mandatory for every task with tests)**
1. The new tests go green.
2. Apply the task's listed batch of production mutations, all at once. Run the task's filter and confirm that EVERY new test is red.
3. Revert every mutation BY HAND with the Edit tool. Never use `git checkout -- <file>`, `git restore` or `git stash`. Then run `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies diff` and confirm that only the intended task changes remain.
4. The new tests are green again, then the full suite is green.
- Each task's batch below has been checked so that no mutation hides another's effect, none crashes the test process, and each changes the value under test on the fixture used (fixtures are non-uniform where order or truncation matters).
- If any new test survives the batch, that test is not testing what it claims. Fix the test and restart from step 1.
- Tasks 6 and 7 have no unit tests (SwiftUI and manual) and are exempt.

**Test style**
- Keep `store.exhaustivity = .off` in the shared `makeStore` helper. Do not change the helper.
- None of this plan's tests asserts the *absence of a store action*. Absence claims ("no `Message` row", "target unchanged") are database reads after `await store.finish()`, or synchronous state reads after a `send` whose effect is `.none`.
  - If you add a store-action absence claim, turn exhaustivity `.on` for that window, or use an exhaustive no-op send probe.
  - Never call `skipInFlightEffects` while exhaustivity is `.on`, because it records a known issue.
- The suite must end with zero known issues.

**UI rule**
- Tappable custom rows and buttons get `.frame(maxWidth: .infinity, alignment: .leading)` (or ≥ 44 pt sizing) + `.contentShape(Rectangle())`.

**App build check:** `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build`

**Values from the spec, copied verbatim**
- Fields (reference `LXMF/LXMF.py:23-24`): `FIELD_REPLY_TO = 0x30` (the original's full `LXMessage.hash`, as bytes), `FIELD_REPLY_QUOTE = 0x31` (the quoted content, as UTF-8 bytes).
- `ReplyWire` constants: `fieldReplyTo = 0x30`, `fieldReplyQuote = 0x31`, `maxQuoteBytes = 400`, `quoteCharacterLimit = 100`.
- `0x30` length must be 16–32 bytes. `0x31` must be `.bin`, ≤ 400 bytes, valid UTF-8 (strict round-trip).
- Trim: leading and trailing whitespace and newlines trimmed first. ≤ 100 `Character`s unchanged, otherwise the first 100 `Character`s + "…".
- Migration `addReplies`, registered after `addMessageInfo`. Columns `replyToHash` (text, hex of the original's LXMF hash) and `replyQuote` (text, the trimmed quote).
- Labels: "You", `peerName ?? "Them"`, "Original message not available".
- Menu: `Button("Reply", systemImage: "arrowshape.turn.up.left")`, after the reaction items and before Info, only when `!message.messageHash.isEmpty`.
- Composer: 3 pt accent bar, "Replying to You" / "Replying to <name/Them>" in caption semibold, one line of `ReplyWire.trimQuote(target.body)` in secondary, trailing ✕ with a ≥ 44 pt hit area.
- Quote block: rounded panel, 3 pt leading bar, white at low opacity on outgoing bubbles and primary at low opacity on incoming, `senderLabel` caption semibold, `text` caption with a 2-line limit. Accessibility label "Reply to <sender>: <text>", hint "Shows the original message" when scrollable.
- Tap-to-scroll: `ScrollViewReader`, `anchor: .center`, `highlightedMessageID` accent outline fading over about 1 second.

**Spec resolutions (decided here, binding for this plan)**
- **`peerName` source:** a new computed property `AppFeature.State.openPeerDisplayName: String?`. It reads `node.client.learnedPeers[<open peer hash>]?.displayName` (the name from the peer's LXMF delivery announce, the same table `AnnounceListView` lists), trims whitespace and newlines, and returns `nil` when there is no open peer, no entry, no name, or a blank name. It lives in the core because `Data(hexString:)` is internal to the package, so the app cannot look the hash up itself. `ChatView` passes it to `ReplyPreview.resolve` and to the composer label.
- **Byte cap in `trimQuote`:** the spec's 100-character trim can exceed its own 400-byte decode cap (a ZWJ family emoji is 1 `Character` but 25 bytes, so 100 of them are 2 500 bytes). Such a quote would be dropped by every receiver running this app, including us. `trimQuote` therefore also drops whole trailing `Character`s until the result, including "…", fits in `maxQuoteBytes`. Plain text is unaffected (100 ASCII characters + "…" is 103 bytes).
- **Empty quote:** `ReplyPreview` treats a stored `replyQuote` of `""` as no quote, so the bubble shows "Original message not available" rather than an empty panel. (An original whose body is only whitespace trims to `""`.)
- **`ReplyTarget`** is nested as `AppFeature.ReplyTarget`, like `AppFeature.BluetoothAlert`.
- **`replyTapped` on a hashless message or an id not in `threadMessages`** leaves any current target untouched ("does nothing").
- **Undecodable target hash at send** (cannot happen for rows this app stores, since `messageHash` is always `Data.hexString`): the message is sent as a plain message with nil reply columns. The target is still cleared.
- **`ReplyPreview.senderLabel(originalIsOutgoing:peerName:)`** is a public helper shared by the resolver and the composer bar, so the "You"/name/"Them" rule exists once.
- **Reply row is not disabled when the peer is unreachable** (unlike the reaction palette): composing works offline and Send is gated on its own.
- **Quote block tap area:** ≥ 44 pt tall + `.contentShape(Rectangle())`, not `maxWidth: .infinity`, which would stretch every reply bubble to the full row width. The quote bar is white on outgoing (blue) bubbles, where an accent bar would vanish, and accent on incoming ones.
- **Highlight ring** is drawn 4 pt outside the bubble so an accent outline is visible on the blue outgoing bubble too.
- **The context-menu preview** shows the quote block too, not tappable.

## Review Focus

These are five inputs the spec does not spell out that are most likely to bite a real user. Each is pinned by a test in the task that owns the code.

1. **A quote made of wide characters** (emoji ZWJ sequences, flags, CJK with combining marks). 100 `Character`s can be far more than 400 bytes, and the receiver would silently drop the quote. The expected result is a quote capped to fit, on whole `Character`s, that our own decoder accepts.
   - Pinned by `replyWireTrimCapsWideCharactersAt400Bytes` (Task 2).
2. **Send is rejected while replying** (empty draft, or no open peer). The user has not sent anything, so the reply bar must stay.
   - Pinned by `replyTargetKeptWhenSendIsRejected` (Task 3).
3. **A stale menu or a hashless bubble.** The context menu can outlive a thread reload, so `.replyTapped` can carry an id that is no longer in `threadMessages`. Neither it nor a hashless legacy bubble may clear or replace a reply already in progress.
   - Pinned by `replyTargetTappedIgnoresHashlessAndUnknownMessages` (Task 3).
4. **An empty or whitespace-only quote.** Replying to a bubble whose body is blank sends `0x31` as empty bytes. The recipient must see "Original message not available", not an empty panel.
   - Pinned by `replyWireTrimStripsSurroundingWhitespace` (Task 2) and `replyPreviewEmptyQuoteCountsAsMissing` (Task 5).
5. **A peer that announces a blank display name.** Sideband and older clients can announce `""` or spaces. The label must fall back to "Them", never "Replying to " with nothing after it.
   - Pinned by `replyPreviewOpenPeerDisplayNameIsTrimmedAndNeverBlank` (Task 5).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Message.swift` | Modify | `replyToHash` / `replyQuote` properties and init parameters (default nil) |
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Database.swift` | Modify | `addReplies` migration |
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReplyWire.swift` | Create | Pure codec for 0x30 / 0x31 and `trimQuote` |
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift` | Modify | `ReplyTarget`, `replyTarget` state, `replyTapped` / `replyCancelled`, reply fields on send, reply columns on receive, `openPeerDisplayName` |
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReplyPreview.swift` | Create | Pure resolver: reply row + thread + peer name → what the bubble shows |
| `ReTiCAMsgr/ReplyViews.swift` | Create | `QuoteBlock` and `ReplyComposerBar` SwiftUI views |
| `ReTiCAMsgr/ChatView.swift` | Modify | Reply menu row, focus, composer bar, quote block in bubbles, scroll + highlight |
| `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DatabaseTests.swift` | Modify | Migration tests |
| `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReplyWireTests.swift` | Create | Codec tests, including the reference byte check |
| `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` | Modify | Reducer tests for target, send and receive |
| `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReplyPreviewTests.swift` | Create | Resolver and `openPeerDisplayName` tests |

The app target uses file-system-synchronized groups, so a new file in `ReTiCAMsgr/` joins the target automatically. New files in `Tests/ReTiCAMsgrCoreTests/` are picked up automatically as well.

`MessageInfo.swift` needs no change: `fieldNames` already maps `0x30: "reply to"` and `0x31: "reply quote"` (line 211), and outgoing and incoming rows already record `fieldKeys` from `msg.fields` / `m.fields`.

**`Message(` construction sites** (found by grep). The two new init parameters come last and default to `nil`, so every site keeps compiling unchanged:
- `Sources/.../AppFeature.swift:504` (`sendTapped`) and `:666` (`messageReceived`). Tasks 3 and 4 add arguments to these two.
- `Tests/.../DatabaseTests.swift:10`, `:68`
- `Tests/.../AppFeatureTests.swift:72` (the `msg` helper)
- `Tests/.../MessageInfoTests.swift:17`, `:50`, `:67`, `:103`, `:130`, `:153`
- `Tests/.../ConversationTests.swift:10`
- There are none in `ReTiCAMsgr/`. Task 7's temporary scaffold adds some and removes them again.

**Before Task 1:**
- Run `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies branch --show-current`. It must print `feat/message-replies`.
- Run `mkdir -p /tmp/ReTiCAMsgr`.
- Run the full suite once and confirm 202 tests pass with 0 known issues.

**Date storage note:** StructuredQueries stores `Date` as ISO-8601 text with millisecond precision. Test timestamps use whole seconds. `makeStore` freezes `\.date` at `1700000000` (`2023-11-14 22:13:20 UTC`).

---

### Task 1: Migration and model

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Message.swift:8-9` (doc comment), `:38` (after `stampState`), `:59` (init parameters), `:79` (assignments)
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Database.swift:103-104` (after the `addMessageInfo` migration, before `return m`)
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DatabaseTests.swift` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Message.replyToHash: String?` — lowercase hex of the original's LXMF hash.
  - `Message.replyQuote: String?` — the trimmed quote as sent or received.
  - `Message.init(..., stampState: String? = nil, replyToHash: String? = nil, replyQuote: String? = nil)` — the two new labelled parameters come after `stampState`, in that order.
  - Migration `"addReplies"`.

- [ ] **Step 1: Write the failing tests**

Append to `DatabaseTests.swift`:

```swift
// MARK: - Message replies (addReplies)

/// A row written before `addReplies` existed reads back as "not a reply".
@Test func replyMigrationLegacyRowReadsBackWithNilReplyColumns() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator().migrate(queue, upTo: "addMessageInfo")
    // Raw SQL: the Swift `Message` type already has the new columns, so it cannot insert into the
    // old schema. Values use the encodings SQLiteData writes: lowercase UUID text, ISO-8601 ms text.
    try queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO messages (id, peerHex, isOutgoing, body, timestamp, status, validated, messageHash, fieldKeys)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: ["00000000-0000-0000-0000-000000000003", String(repeating: "a", count: 32),
                        0, "before replies", "2023-11-14 22:13:20.000", MessageStatus.received, 1,
                        String(repeating: "c", count: 64), ""]
        )
    }
    try AppDatabase.migrator().migrate(queue)
    let rows = try queue.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.body == "before replies")
    #expect(row.fieldKeys == "")
    #expect(row.replyToHash == nil)
    #expect(row.replyQuote == nil)
}

/// Both columns round-trip. Literal expectations, not only `back == m`, so a model that drops a
/// field on init cannot pass by dropping it on both sides.
@Test func replyMigrationRoundTripsReplyColumns() throws {
    let db = try AppDatabase.makeInMemory()
    let m = Message(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        peerHex: String(repeating: "b", count: 32),
        isOutgoing: false,
        body: "yes!",
        timestamp: Date(timeIntervalSince1970: 1700000000),
        status: MessageStatus.received,
        validated: true,
        messageHash: String(repeating: "d", count: 64),
        fieldKeys: "0x30,0x31",
        replyToHash: "00112233445566778899aabbccddeeff0123456789abcdeffedcba9876543210",
        replyQuote: "are you coming? ☕"
    )
    try db.write { try Message.insert { m }.execute($0) }
    let back = try #require(try db.read { try Message.all.fetchAll($0) }.first)
    #expect(back.replyToHash == "00112233445566778899aabbccddeeff0123456789abcdeffedcba9876543210")
    #expect(back.replyQuote == "are you coming? ☕")
    #expect(back == m)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore --filter replyMigration`
Expected: a compile failure. `Message` has no `replyToHash` / `replyQuote`, and the init has no such parameters.

- [ ] **Step 3: Add the model properties**

In `Message.swift`, replace the doc-comment lines 8–9:

```swift
/// The optional fields after `messageHash` are debugging metadata for the Info sheet, added by the
/// `addMessageInfo` migration. Rows stored before it read back `nil` for all of them.
```

with:

```swift
/// The optional fields after `messageHash` are debugging metadata for the Info sheet, added by the
/// `addMessageInfo` migration, then the reply fields, added by `addReplies`. Rows stored before a
/// migration read back `nil` for its fields.
```

After line 38 (`public var stampState: String?`) insert:

```swift
    /// Replies (LXMF FIELD_REPLY_TO 0x30): lowercase hex of the original's full LXMF hash.
    /// nil when this message is not a reply.
    public var replyToHash: String?
    /// Replies (LXMF FIELD_REPLY_QUOTE 0x31): the quote as sent or received, already trimmed.
    /// nil when not a reply, or when a received quote was missing or unusable.
    public var replyQuote: String?
```

Replace the init's last parameter line (line 59) `        stampState: String? = nil` with:

```swift
        stampState: String? = nil,
        replyToHash: String? = nil,
        replyQuote: String? = nil
```

After the last assignment `        self.stampState = stampState` (line 79) insert:

```swift
        self.replyToHash = replyToHash
        self.replyQuote = replyQuote
```

- [ ] **Step 4: Add the migration**

In `Database.swift`, insert between the closing `}` of the `addMessageInfo` migration (line 103) and `return m` (line 104):

```swift
        m.registerMigration("addReplies") { db in
            // Message replies: LXMF FIELD_REPLY_TO (0x30) as hex, FIELD_REPLY_QUOTE (0x31) as text.
            // Nullable: rows stored before this migration, and every non-reply, read back NULL.
            try db.alter(table: "messages") { t in
                t.add(column: "replyToHash", .text)
                t.add(column: "replyQuote", .text)
            }
        }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore --filter replyMigration`
Expected: 2 tests pass.

- [ ] **Step 6: Mutation check**

Apply both mutations together:
- **M1** (`Database.swift`, `addReplies`): `t.add(column: "replyQuote", .text)` becomes `t.add(column: "replyQuote", .text).defaults(to: "")`. Reddens `replyMigrationLegacyRowReadsBackWithNilReplyColumns`: the pre-existing row gets `''`, so `replyQuote == nil` fails.
- **M2** (`Message.swift`, init): `self.replyToHash = replyToHash` becomes `self.replyToHash = nil`. Reddens `replyMigrationRoundTripsReplyColumns`: `back.replyToHash` is nil.

No masking: M1 does not touch the round trip (it inserts `replyQuote` explicitly). M2 does not change the legacy test (it expects nil anyway).

Run the filter and confirm both tests are red. Revert both by hand. Run `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies diff` and confirm no mutation text remains.

- [ ] **Step 7: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore`
Expected: 204 tests pass, 0 known issues.

- [ ] **Step 8: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Message.swift ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Database.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DatabaseTests.swift
```

Write `/tmp/ReTiCAMsgr/msg-replies-task-1.txt` with the Write tool:

```
feat: add message reply columns

The addReplies migration adds nullable replyToHash and replyQuote columns
to messages. Legacy rows and non-replies read back nil.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies commit -F /tmp/ReTiCAMsgr/msg-replies-task-1.txt`

---

### Task 2: `ReplyWire` codec

**Files:**
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReplyWire.swift`
- Create: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReplyWireTests.swift`
- Temporary (not committed): `/tmp/ReTiCAMsgr/reply_fields_reference.py`

**Interfaces:**
- Consumes: `MsgPackValue`, `MsgPackValue.IntPair`, `MsgPack.encode(_:)`, `LXMessage` from ReTiCA.
- Produces:
  ```swift
  public enum ReplyWire {
      public static let fieldReplyTo: Int          // 0x30
      public static let fieldReplyQuote: Int       // 0x31
      public static let maxQuoteBytes: Int         // 400
      public static let quoteCharacterLimit: Int   // 100
      public static let replyToLengths: ClosedRange<Int>   // 16...32
      public static let ellipsis: String           // "…"
      public static func encode(replyTo: Data, quote: String) -> [MsgPackValue.IntPair]
      public static func decode(_ fields: [MsgPackValue.IntPair]) -> (replyTo: Data, quote: String?)?
      public static func trimQuote(_ text: String) -> String
  }
  ```
  `encode` does not trim; callers pass `trimQuote(...)` output.

- [ ] **Step 1: Produce the reference bytes**

Write `/tmp/ReTiCAMsgr/reply_fields_reference.py` with the Write tool:

```python
import RNS.vendor.umsgpack as umsgpack

reply_to = bytes(range(32))
quote = "Hi ☕ there".encode("utf-8")
packed = umsgpack.packb({0x30: reply_to, 0x31: quote})
print(packed.hex())
print(len(packed))
```

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python /tmp/ReTiCAMsgr/reply_fields_reference.py`
Expected output, exactly:

```
8230c420000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f31c40c486920e29895207468657265
51
```

If the hex differs, stop and report: the test below hard-codes it.

- [ ] **Step 2: Write the failing tests**

Create `ReplyWireTests.swift`:

```swift
import Testing
import Foundation
import ReTiCA
@testable import ReTiCAMsgrCore

/// Non-uniform bytes, so a reversal or truncation changes the value.
private let originalHash = Data((0..<32).map { UInt8($0) })
private let quoteText = "Hi ☕ there"

/// Reply fields built by hand, so these tests pin the wire shape rather than `encode`.
private func replyFields(replyTo: MsgPackValue?, quote: MsgPackValue?) -> [MsgPackValue.IntPair] {
    var fields: [MsgPackValue.IntPair] = []
    if let replyTo { fields.append(.init(0x30, replyTo)) }
    if let quote { fields.append(.init(0x31, quote)) }
    return fields
}

@Test func replyWireConstantsMatchReferenceLXMF() {
    #expect(ReplyWire.fieldReplyTo == 0x30)
    #expect(ReplyWire.fieldReplyQuote == 0x31)
    #expect(ReplyWire.maxQuoteBytes == 400)
    #expect(ReplyWire.quoteCharacterLimit == 100)
}

/// The expected bytes are reference umsgpack's `packb({0x30: bytes(range(32)), 0x31: "Hi ☕ there".encode()})`,
/// from /tmp/ReTiCAMsgr/reply_fields_reference.py run with the rns env's Python.
@Test func replyWireEncodeMatchesReferenceUmsgpackBytes() throws {
    let expected = try #require(Data(hexString:
        "8230c420000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f31c40c486920e29895207468657265"))
    #expect(MsgPack.encode(.intMap(ReplyWire.encode(replyTo: originalHash, quote: quoteText))) == expected)
}

@Test func replyWireRoundTripsThroughRealLXMessage() throws {
    let m = LXMessage.create(
        source: Identity(),
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data(),
        content: Data("reply text".utf8),
        fields: ReplyWire.encode(replyTo: originalHash, quote: quoteText)
    )
    let back = try #require(LXMessage.unpack(m.packed))
    #expect(back.content == Data("reply text".utf8))
    #expect(back.fields.map(\.key) == [0x30, 0x31])
    let decoded = try #require(ReplyWire.decode(back.fields))
    #expect(decoded.replyTo == originalHash)
    #expect(decoded.quote == quoteText)
}

@Test func replyWireTrimLimitsTo100Characters() {
    let hundred = String(repeating: "a", count: 100)
    #expect(ReplyWire.trimQuote("hello") == "hello")
    #expect(ReplyWire.trimQuote(hundred) == hundred)
    #expect(ReplyWire.trimQuote(hundred + "b") == hundred + "…")
    #expect(ReplyWire.trimQuote(hundred + String(repeating: "c", count: 50)) == hundred + "…")
}

/// Review Focus 4: a blank original trims to "".
@Test func replyWireTrimStripsSurroundingWhitespace() {
    #expect(ReplyWire.trimQuote("  \n see you at 6 \t\n") == "see you at 6")
    #expect(ReplyWire.trimQuote(" \n\t ") == "")
    // Trimming happens before counting: 100 characters plus padding is not cut.
    let hundred = String(repeating: "a", count: 100)
    #expect(ReplyWire.trimQuote("   " + hundred + "\n\n") == hundred)
}

@Test func replyWireTrimDoesNotSplitZWJEmojiAtBoundary() {
    let family = "👨‍👩‍👧‍👦"                                          // 1 Character, 7 scalars
    let text = String(repeating: "a", count: 99) + family + "b"   // the 100th Character is the family
    #expect(text.count == 101)
    #expect(ReplyWire.trimQuote(text) == String(repeating: "a", count: 99) + family + "…")
}

/// Review Focus 1: 100 wide Characters are far more than the 400 bytes `decode` accepts.
@Test func replyWireTrimCapsWideCharactersAt400Bytes() throws {
    let family = "👨‍👩‍👧‍👦"
    #expect(family.utf8.count == 25)
    // 15 families + "…" = 375 + 3 = 378 bytes. A 16th family would make it 403.
    let capped = String(repeating: family, count: 15) + "…"
    // Under the character limit, over the byte limit.
    #expect(ReplyWire.trimQuote(String(repeating: family, count: 20)) == capped)
    // Over both limits.
    #expect(ReplyWire.trimQuote(String(repeating: family, count: 150)) == capped)
    // The capped quote survives our own decoder, so a recipient running this app still sees it.
    let decoded = try #require(ReplyWire.decode(ReplyWire.encode(replyTo: originalHash, quote: capped)))
    #expect(decoded.quote == capped)
}

@Test func replyWireInvalidReplyToIsNotAReply() {
    let quote = MsgPackValue.bin(Data("hi".utf8))
    let cases: [(String, [MsgPackValue.IntPair])] = [
        ("0x31 without 0x30", replyFields(replyTo: nil, quote: quote)),
        ("no fields", []),
        ("0x30 not bin", replyFields(replyTo: .string("abc"), quote: quote)),
        ("0x30 empty", replyFields(replyTo: .bin(Data()), quote: quote)),
        ("0x30 15 bytes", replyFields(replyTo: .bin(Data(repeating: 1, count: 15)), quote: quote)),
        ("0x30 33 bytes", replyFields(replyTo: .bin(Data(repeating: 1, count: 33)), quote: quote)),
    ]
    for (name, fields) in cases {
        #expect(ReplyWire.decode(fields) == nil, "\(name)")
    }
    for n in [16, 32] {
        let replyTo = Data((0..<n).map { UInt8($0) })
        let decoded = ReplyWire.decode(replyFields(replyTo: .bin(replyTo), quote: quote))
        #expect(decoded?.replyTo == replyTo, "length \(n)")
        #expect(decoded?.quote == "hi", "length \(n)")
    }
}

@Test func replyWireInvalidQuoteKeepsTheReply() {
    let replyTo = MsgPackValue.bin(originalHash)
    let cases: [(String, MsgPackValue?)] = [
        ("0x31 missing", nil),
        ("0x31 not bin", .string("hi")),
        ("0x31 401 bytes", .bin(Data(repeating: 0x61, count: 401))),
        ("0x31 invalid UTF-8", .bin(Data([0xFF, 0xFE, 0xFD]))),
    ]
    for (name, quote) in cases {
        let decoded = ReplyWire.decode(replyFields(replyTo: replyTo, quote: quote))
        // `decoded?.replyTo` is nil when decode returned nil, so this also proves the reply was kept.
        #expect(decoded?.replyTo == originalHash, "\(name)")
        #expect(decoded?.quote == nil, "\(name)")
    }
    let atLimit = ReplyWire.decode(replyFields(replyTo: replyTo, quote: .bin(Data(repeating: 0x61, count: 400))))
    #expect(atLimit?.quote == String(repeating: "a", count: 400))
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore --filter replyWire`
Expected: a compile failure, `cannot find 'ReplyWire' in scope`.

- [ ] **Step 4: Write the codec**

Create `ReplyWire.swift`:

```swift
import Foundation
import ReTiCA

/// Wire codec for a reply carried in LXMF `fields`, in the standard format
/// (`LXMF/LXMF.py:23-24`): `FIELD_REPLY_TO` (0x30) holds the original's full `LXMessage.hash` as
/// bin, and `FIELD_REPLY_QUOTE` (0x31) holds the quoted text as UTF-8 bin.
///
/// A reply is otherwise a normal text message, so a client without reply support shows it as one.
/// `AppFeature` only calls `decode` on messages `ReactionWire` did not claim: reply fields on a
/// reaction are ignored.
public enum ReplyWire {
    public static let fieldReplyTo = 0x30
    public static let fieldReplyQuote = 0x31
    /// Upper bound on the quote's UTF-8 size. A larger quote is ignored, but the reply is kept.
    public static let maxQuoteBytes = 400
    public static let quoteCharacterLimit = 100
    public static let replyToLengths = 16...32
    public static let ellipsis = "…"

    /// The two reply fields. `quote` goes on the wire as given: pass `trimQuote(...)` output.
    public static func encode(replyTo: Data, quote: String) -> [MsgPackValue.IntPair] {
        [
            .init(fieldReplyTo, .bin(replyTo)),
            .init(fieldReplyQuote, .bin(Data(quote.utf8))),
        ]
    }

    /// `nil` when the message is not a reply: 0x30 missing, not bin, or not 16–32 bytes (0x31 is
    /// then ignored too). An unusable 0x31 keeps the reply with `quote == nil`.
    public static func decode(_ fields: [MsgPackValue.IntPair]) -> (replyTo: Data, quote: String?)? {
        guard case let .bin(replyTo)? = fields.first(where: { $0.key == fieldReplyTo })?.value,
              replyToLengths.contains(replyTo.count)
        else { return nil }
        return (replyTo, decodeQuote(fields))
    }

    private static func decodeQuote(_ fields: [MsgPackValue.IntPair]) -> String? {
        guard case let .bin(bytes)? = fields.first(where: { $0.key == fieldReplyQuote })?.value,
              bytes.count <= maxQuoteBytes
        else { return nil }
        // Strict UTF-8, as in ReactionWire: `String(decoding:)` repairs invalid bytes with U+FFFD,
        // so the bytes are valid exactly when they survive a round trip unchanged.
        let text = String(decoding: bytes, as: UTF8.self)
        guard Data(text.utf8) == bytes else { return nil }
        return text
    }

    /// The quote for a reply: surrounding whitespace and newlines trimmed, then at most
    /// `quoteCharacterLimit` Characters, with "…" appended when cut. Characters are grapheme
    /// clusters, so an emoji sequence is never split.
    ///
    /// It also never exceeds `maxQuoteBytes`, "…" included. 100 wide Characters (a ZWJ family is 25
    /// bytes) would otherwise be dropped by every receiver's `decode`, ours included.
    public static func trimQuote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= quoteCharacterLimit, trimmed.utf8.count <= maxQuoteBytes { return trimmed }
        var kept = trimmed.prefix(quoteCharacterLimit)
        while !kept.isEmpty, kept.utf8.count + ellipsis.utf8.count > maxQuoteBytes {
            kept = kept.dropLast()
        }
        return String(kept) + ellipsis
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore --filter replyWire`
Expected: 9 tests pass.

- [ ] **Step 6: Mutation check**

Apply all six mutations together, all in `ReplyWire.swift`:
- **M1**: `public static let maxQuoteBytes = 400` becomes `= 401`. Reddens `replyWireConstantsMatchReferenceLXMF` and `replyWireInvalidQuoteKeepsTheReply` (the 401-byte quote is now accepted).
- **M2**: in `decode`, delete the line `replyToLengths.contains(replyTo.count)` together with the comma that ends the line before it, so the guard is only the `case let .bin(replyTo)?` binding. Reddens `replyWireInvalidReplyToIsNotAReply` (empty, 15- and 33-byte hashes now decode).
- **M3**: in `encode`, `.init(fieldReplyQuote, .bin(Data(quote.utf8)))` becomes `.init(fieldReplyQuote, .string(quote))`. Reddens `replyWireEncodeMatchesReferenceUmsgpackBytes` (str tag `0xac` instead of bin `0xc4 0x0c`) and `replyWireRoundTripsThroughRealLXMessage` (the decoded quote is nil because it is not bin).
- **M4**: in `trimQuote`, `let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)` becomes `let trimmed = text`. Reddens `replyWireTrimStripsSurroundingWhitespace`.
- **M5**: in `trimQuote`, `var kept = trimmed.prefix(quoteCharacterLimit)` becomes `var kept = Substring(String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(quoteCharacterLimit))))`. This cuts by Unicode scalar instead of Character. Reddens `replyWireTrimDoesNotSplitZWJEmojiAtBoundary` (the result ends in a lone "👨" + "…").
- **M6**: in `trimQuote`, delete the whole `while` loop (3 lines) and change `return String(kept) + ellipsis` to `return String(kept)`. Reddens `replyWireTrimLimitsTo100Characters` (no "…") and `replyWireTrimCapsWideCharactersAt400Bytes` (20 families come back uncapped, and without "…").

Check that no mutation hides another:
- M1 changes only the byte limit. On the wide-character fixture, 16 families + "…" is 403 bytes, still over 401, so the capped value is unchanged and M6 alone decides that test.
- M4 has no effect on the other trim fixtures, which carry no surrounding whitespace.
- M5 is an ASCII no-op, so it leaves `replyWireTrimLimitsTo100Characters` to M6.
- M3 does not touch the invalid-field tests, which build their fields by hand.
- No mutation can crash. M5 builds a valid String, and M6 only removes code.

Run the filter and confirm all 9 tests are red. Revert all six by hand. Run `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies diff` and confirm no mutation text remains. (`ReplyWire.swift` and `ReplyWireTests.swift` are untracked, so check them by reading `ReplyWire.swift` against Step 4.)

- [ ] **Step 7: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore`
Expected: 213 tests pass, 0 known issues.

- [ ] **Step 8: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReplyWire.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReplyWireTests.swift
```

Write `/tmp/ReTiCAMsgr/msg-replies-task-2.txt` with the Write tool:

```
feat: add the ReplyWire codec for LXMF reply fields

Encodes and decodes the standard FIELD_REPLY_TO (0x30) and
FIELD_REPLY_QUOTE (0x31) fields. The encoded bytes match reference
umsgpack. trimQuote cuts to 100 characters plus an ellipsis and also caps
the quote at the 400 bytes the decoder accepts.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies commit -F /tmp/ReTiCAMsgr/msg-replies-task-2.txt`

---

### Task 3: Reply target and send

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift`
  - `:34-36`: add `ReplyTarget` after `PublicKeyRequestStatus`, before `@ObservableState`
  - `:55`: add `replyTarget` after `public var draft = ""`
  - `:150`: add two actions after `case reactionSelected(...)`
  - `:474-479`: `closeConversation`
  - `:486-528`: `sendTapped`
  - `:562`: new `replyTapped` / `replyCancelled` cases after the `reactionSelected` case
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` (append at the end, after line 2567)

**Interfaces:**
- Consumes: `ReplyWire.encode(replyTo:quote:)`, `ReplyWire.trimQuote(_:)` (Task 2), `Message.replyToHash` / `replyQuote` and the init parameters (Task 1).
- Produces:
  ```swift
  extension AppFeature {
      public struct ReplyTarget: Equatable, Sendable {
          public var messageHash: String
          public var body: String
          public var isOutgoing: Bool
          public init(messageHash: String, body: String, isOutgoing: Bool)
      }
  }
  AppFeature.State.replyTarget: AppFeature.ReplyTarget?   // default nil
  AppFeature.Action.replyTapped(Message.ID)
  AppFeature.Action.replyCancelled
  ```
  `sendTapped` with a target puts `ReplyWire.encode(...)` in `LXMessage.fields` and stores `replyToHash` / `replyQuote` on the outgoing row. Both `sendTapped` (after a successful send) and `closeConversation` clear the target.

- [ ] **Step 1: Write the failing tests**

Append to the end of `AppFeatureTests.swift`:

```swift
// MARK: - Replies: target and send

/// Non-uniform, so a byte-order bug in hex handling changes the value.
private let replyTargetHash = "00112233445566778899aabbccddeeff0123456789abcdeffedcba9876543210"

/// Send `draft` with `target` set, and return the LXMessage handed to the node, the stored row and
/// the reply target afterwards. Waits for `conversationsLoaded`, the last action of the send saga.
@MainActor
private func replySendAndFetch(draft: String, target: AppFeature.ReplyTarget?)
    async -> (sent: LXMessage?, row: Message?, targetAfter: AppFeature.ReplyTarget?) {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = draft
        s.replyTarget = target
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let row = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }.first
    return (sent, row, store.state.replyTarget)
}

@MainActor @Test func replyTargetTappedSetsTarget() async {
    let original = msg(1, peerA, "see you at 6", 1000, outgoing: false, status: MessageStatus.received,
                       hash: replyTargetHash)
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.threadMessages = [original]
    }
    await store.send(.replyTapped(uuid(1)))
    #expect(store.state.replyTarget
            == AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "see you at 6", isOutgoing: false))
}

/// Review Focus 3: a hashless bubble, or an id from a menu that outlived a reload, changes nothing.
@MainActor @Test func replyTargetTappedIgnoresHashlessAndUnknownMessages() async {
    let existing = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "earlier", isOutgoing: true)
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.threadMessages = [msg(1, peerA, "legacy", 1000, outgoing: false, status: MessageStatus.received, hash: "")]
        s.replyTarget = existing
    }
    await store.send(.replyTapped(uuid(1)))    // hashless: cannot be replied to
    #expect(store.state.replyTarget == existing)
    await store.send(.replyTapped(uuid(99)))   // not in the thread
    #expect(store.state.replyTarget == existing)
}

@MainActor @Test func replyTargetCancelledClearsTarget() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.replyTarget = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "x", isOutgoing: false)
    }
    await store.send(.replyCancelled)
    #expect(store.state.replyTarget == nil)
}

@MainActor @Test func replyTargetClearedOnCloseConversation() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.replyTarget = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "x", isOutgoing: false)
    }
    await store.send(.closeConversation)
    #expect(store.state.replyTarget == nil)
}

@MainActor @Test func replyTargetSendCarriesReplyFieldsAndStoresColumns() async throws {
    // Padded and over 100 characters, so the test fails unless trimQuote is applied.
    let longBody = "  " + String(repeating: "x", count: 120) + "\n"
    let expectedQuote = String(repeating: "x", count: 100) + "…"
    let (sent, row, after) = await replySendAndFetch(
        draft: "sure",
        target: AppFeature.ReplyTarget(messageHash: replyTargetHash, body: longBody, isOutgoing: false)
    )
    let wire = try #require(sent)
    #expect(wire.content == Data("sure".utf8))
    let decoded = try #require(ReplyWire.decode(wire.fields))
    #expect(decoded.replyTo == Data(hexString: replyTargetHash))
    #expect(decoded.quote == expectedQuote)
    let stored = try #require(row)
    #expect(stored.body == "sure")
    #expect(stored.replyToHash == replyTargetHash)
    #expect(stored.replyQuote == expectedQuote)
    #expect(stored.fieldKeys == "0x30,0x31")
    #expect(after == nil)
}

@MainActor @Test func replyTargetAbsentSendsNoReplyFields() async throws {
    let (sent, row, _) = await replySendAndFetch(draft: "plain", target: nil)
    let wire = try #require(sent)
    #expect(wire.fields.isEmpty)
    #expect(ReplyWire.decode(wire.fields) == nil)
    let stored = try #require(row)
    #expect(stored.replyToHash == nil)
    #expect(stored.replyQuote == nil)
}

/// Review Focus 2: nothing was sent, so the reply bar stays.
@MainActor @Test func replyTargetKeptWhenSendIsRejected() async {
    let target = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "x", isOutgoing: false)
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = ""
        s.replyTarget = target
    }
    await store.send(.sendTapped)
    #expect(store.state.replyTarget == target)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore --filter replyTarget`
Expected: a compile failure. `AppFeature.ReplyTarget`, `replyTarget`, `.replyTapped` and `.replyCancelled` do not exist.

- [ ] **Step 3: Add the type, state and actions**

In `AppFeature.swift`, after the closing `}` of `PublicKeyRequestStatus` (line 34) and before `@ObservableState` (line 36), insert:

```swift
    /// The message a reply is being composed to. Set from the long-press menu, shown above the text
    /// field, and cleared by send, cancel or leaving the conversation. `body` is the untrimmed
    /// original: `ReplyWire.trimQuote` runs at display and at send.
    public struct ReplyTarget: Equatable, Sendable {
        public var messageHash: String
        public var body: String
        public var isOutgoing: Bool

        public init(messageHash: String, body: String, isOutgoing: Bool) {
            self.messageHash = messageHash
            self.body = body
            self.isOutgoing = isOutgoing
        }
    }

```

After `public var draft = ""` (line 55) insert:

```swift
        /// The message being replied to, or nil. Session-only.
        public var replyTarget: ReplyTarget? = nil
```

After `case reactionSelected(messageHash: String, emoji: String)` (line 150) insert:

```swift
        /// Long-press → Reply. Ignored for a hashless message or one no longer in the thread.
        case replyTapped(Message.ID)
        /// The ✕ on the reply bar.
        case replyCancelled
```

- [ ] **Step 4: Handle the actions**

Replace the `closeConversation` case (lines 474–479) with:

```swift
            case .closeConversation:
                state.openPeerHex = nil
                state.threadMessages = []
                state.setThreadReactionRows([])
                state.draft = ""
                state.replyTarget = nil
                return .none
```

Replace the `sendTapped` case (lines 486–528) with:

```swift
            case .sendTapped:
                let text = state.draft
                guard !text.isEmpty,
                      let peerHex = state.openPeerHex,
                      let peer = Data(hexString: peerHex) else { return .none }
                // A reply carries the original's full hash and a trimmed quote in the standard LXMF
                // fields 0x30 / 0x31. The quote is trimmed once, and the same string goes on the wire
                // and in the row. A target whose hash does not decode is sent as a plain message.
                var replyFields: [MsgPackValue.IntPair] = []
                var replyToHash: String? = nil
                var replyQuote: String? = nil
                if let target = state.replyTarget,
                   let replyTo = Data(hexString: target.messageHash), !replyTo.isEmpty {
                    let quote = ReplyWire.trimQuote(target.body)
                    replyFields = ReplyWire.encode(replyTo: replyTo, quote: quote)
                    replyToHash = target.messageHash
                    replyQuote = quote
                }
                let title = Data()
                let content = Data(text.utf8)
                let now = date.now
                let msg = LXMessage.create(
                    source: state.identity,
                    destinationHash: peer,
                    timestamp: now.timeIntervalSince1970,
                    title: title,
                    content: content,
                    fields: replyFields
                )
                let alsoViaPropagation = !state.propagationNodeHex.isEmpty
                // Outgoing Info metadata. `wireSize` is the unstamped packed size: LXMFNode adds any
                // stamp downstream, where the app cannot see it (hence no stampState either).
                let row = Message(
                    id: UUID(),
                    peerHex: peerHex,
                    isOutgoing: true,
                    body: text,
                    timestamp: now,
                    status: MessageStatus.sending,
                    validated: false,
                    messageHash: msg.hash.hexString,
                    senderTimestamp: now,
                    sentViaPropagation: alsoViaPropagation,
                    wireSize: msg.packed.count,
                    titleSize: msg.title.count,
                    contentSize: msg.content.count,
                    fieldKeys: MessageMetadata.fieldKeys(msg.fields),
                    replyToHash: replyToHash,
                    replyQuote: replyQuote
                )
                state.draft = ""
                state.replyTarget = nil
                return .merge(
                    .send(.node(.client(.sendMessage(message: msg, alsoViaPropagation: alsoViaPropagation)))),
                    .run { [database] send in
                        try await database.write { try Message.insert { row }.execute($0) }
                        try await reloadThread(database, peerHex, send)
                        try await reloadConversations(database, send)
                    }
                )
```

After the closing `)` of the `reactionSelected` case's `return .merge(...)` (line 562), before `case let .node(.client(.endpoint(.delegate(.pathLearned(h, _)))))`, insert:

```swift

            case let .replyTapped(id):
                // Only a message with an LXMF hash can be replied to: the hash is what FIELD_REPLY_TO
                // carries. A hashless legacy row, or an id from a menu that outlived a thread reload,
                // leaves any reply already in progress alone.
                guard let message = state.threadMessages.first(where: { $0.id == id }),
                      !message.messageHash.isEmpty else { return .none }
                state.replyTarget = ReplyTarget(
                    messageHash: message.messageHash, body: message.body, isOutgoing: message.isOutgoing)
                return .none

            case .replyCancelled:
                state.replyTarget = nil
                return .none
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore --filter replyTarget`
Expected: 7 tests pass.

- [ ] **Step 6: Mutation check**

Apply all seven mutations together, all in `AppFeature.swift`:
- **M1** (`replyTapped`): `isOutgoing: message.isOutgoing)` becomes `isOutgoing: !message.isOutgoing)`. Reddens `replyTargetTappedSetsTarget`.
- **M2** (`replyTapped`): insert `state.replyTarget = nil` as the first line of the case, before the `guard`. Reddens `replyTargetTappedIgnoresHashlessAndUnknownMessages` (both taps now wipe the existing target).
- **M3** (`replyCancelled`): delete `state.replyTarget = nil`, leaving only `return .none`. Reddens `replyTargetCancelledClearsTarget`.
- **M4** (`closeConversation`): delete `state.replyTarget = nil`. Reddens `replyTargetClearedOnCloseConversation`.
- **M5** (`sendTapped`): `let quote = ReplyWire.trimQuote(target.body)` becomes `let quote = target.body`. Reddens `replyTargetSendCarriesReplyFieldsAndStoresColumns`: the wire quote and the column are the padded 120-character body, which is 123 bytes and so still decodes.
- **M6** (`sendTapped` guard): `let peer = Data(hexString: peerHex) else { return .none }` becomes
  ```swift
  let peer = Data(hexString: peerHex) else {
      state.replyTarget = nil
      return .none
  }
  ```
  This is the "a rejected send drops the reply" bug. It reddens `replyTargetKeptWhenSendIsRejected`.
- **M7** (`sendTapped` row): `replyToHash: replyToHash,` becomes `replyToHash: replyToHash ?? "",`. Reddens `replyTargetAbsentSendsNoReplyFields` (it stores `""` instead of NULL).

Check that no mutation hides another:
- M2 runs before the lookup, so it does not change what M1 produces in `replyTargetTappedSetsTarget`.
- M6 only fires on the rejected path, and the send tests pass the guard, so M5 stays visible.
- M7 only changes the no-target row. With a target, `replyToHash` is non-nil.
- Nothing can crash.

Run the filter and confirm all 7 tests are red. Revert all seven by hand. Run `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies diff` and confirm only the Step 3–4 changes remain.

- [ ] **Step 7: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore`
Expected: 220 tests pass, 0 known issues. In particular `sendPersistsToOpenPeerAndReloadsBoth` and `infoSendStoresSizesFieldKeysAndSendTime` still pass (no target → no fields, `fieldKeys == ""`).

- [ ] **Step 8: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift
```

Write `/tmp/ReTiCAMsgr/msg-replies-task-3.txt` with the Write tool:

```
feat: send replies with LXMF reply fields

AppFeature gains a reply target, set from a message with a hash and
cleared by cancel, send or leaving the conversation. A send with a target
carries FIELD_REPLY_TO and a trimmed FIELD_REPLY_QUOTE and stores both on
the outgoing row. A rejected send keeps the target.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies commit -F /tmp/ReTiCAMsgr/msg-replies-task-3.txt`

---

### Task 4: Receive path

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift`, in the `messageReceived` case: the `let row = Message(` block after `case .notReaction: break` (originally lines 666–682, about 30 lines lower after Task 3)
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` (append at the end)

**Interfaces:**
- Consumes: `ReplyWire.decode(_:)` (Task 2), `Message.replyToHash` / `replyQuote` (Task 1). Test helpers already in the file: `makeStore`, `wireMessage(from:to:at:title:content:fields:)`, `receiveAndFetch(_:me:method:)`.
- Produces: an incoming ordinary message stores `replyToHash = decoded.replyTo.hexString` and `replyQuote = decoded.quote`. Reactions and malformed reactions are unchanged and never store reply columns.

- [ ] **Step 1: Write the failing tests**

Append to the end of `AppFeatureTests.swift`:

```swift
// MARK: - Replies: receive path

/// Non-uniform 32-byte original hash.
private let replyOriginalHash = Data((0..<32).map { UInt8(($0 * 37 + 11) & 0xFF) })

@MainActor @Test func replyReceiveStoresBothColumns() async throws {
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me, at: 1699999999, content: "yes!",
                        fields: ReplyWire.encode(replyTo: replyOriginalHash, quote: "are you coming?"))
    let rows = try await receiveAndFetch(m, me: me)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.body == "yes!")
    #expect(row.replyToHash == replyOriginalHash.hexString)
    #expect(row.replyQuote == "are you coming?")
    #expect(row.fieldKeys == "0x30,0x31")
}

@MainActor @Test func replyReceiveInvalidQuoteStoresHashOnly() async throws {
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me, at: 1699999999, content: "yes!", fields: [
        .init(0x30, .bin(replyOriginalHash)),
        .init(0x31, .bin(Data([0xFF, 0xFE]))),   // invalid UTF-8
    ])
    let rows = try await receiveAndFetch(m, me: me)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.replyToHash == replyOriginalHash.hexString)
    #expect(row.replyQuote == nil)
}

/// A reaction wins over reply fields: no bubble, reply fields ignored. A malformed reaction beside
/// reply fields is still dropped.
@MainActor @Test func replyReceiveReactionWithReplyFieldsIsOnlyAReaction() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let target = Data(repeating: 0x44, count: 32)
    let store = makeStore(db, identity: me)
    let m = LXMessage.create(
        source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1700000001, title: Data(), content: Data("Reacted 👍".utf8),
        fields: ReactionWire.encode(target: target, emoji: "👍")
            + ReplyWire.encode(replyTo: replyOriginalHash, quote: "hi")
    )
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try await db.read { try Message.all.fetchAll($0) }
    let reactions = try await db.read { try Reaction.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions == [Reaction(messageHash: target.hexString, reactorHex: senderHex, emoji: "👍", sentAt: 1700000001)])

    let malformed = wireMessage(from: sender, to: me, at: 1700000002, content: "fallback",
                                fields: [.init(0x40, .bin(Data([1])))]
                                    + ReplyWire.encode(replyTo: replyOriginalHash, quote: "hi"))
    #expect(try await receiveAndFetch(malformed, me: me).isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore --filter replyReceive`
Expected: `replyReceiveStoresBothColumns` and `replyReceiveInvalidQuoteStoresHashOnly` fail, because `replyToHash` is nil. `replyReceiveReactionWithReplyFieldsIsOnlyAReaction` passes already. That is expected: it pins behaviour that exists today, and Step 5's M3 proves it can fail.

- [ ] **Step 3: Store the reply columns**

In the `messageReceived` case, replace the block from `let row = Message(` through its closing `)`, the one right after `case .notReaction: break }`, with:

```swift
                // Standard LXMF reply fields (0x30 / 0x31). Only an ordinary message gets here: a
                // reaction that also carries reply fields was handled above, reply fields ignored.
                let reply = ReplyWire.decode(m.fields)
                let row = Message(
                    id: UUID(),
                    peerHex: incomingPeer,
                    isOutgoing: false,
                    body: String(decoding: m.content, as: UTF8.self),
                    timestamp: date.now,
                    status: MessageStatus.received,
                    validated: validated,
                    messageHash: seenHashHex,
                    senderTimestamp: MessageMetadata.senderTimestamp(m.timestamp),
                    arrivalMethod: MessageMetadata.arrivalMethod(method),
                    wireSize: m.receivedBytes?.count,
                    titleSize: m.title.count,
                    contentSize: m.content.count,
                    fieldKeys: MessageMetadata.fieldKeys(m.fields),
                    stampState: MessageMetadata.stampState(m),
                    replyToHash: reply?.replyTo.hexString,
                    replyQuote: reply?.quote
                )
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore --filter replyReceive`
Expected: 3 tests pass.

- [ ] **Step 5: Mutation check**

Apply all three mutations together, all in `AppFeature.swift` `messageReceived`:
- **M1**: `replyQuote: reply?.quote` becomes `replyQuote: nil`. Reddens `replyReceiveStoresBothColumns`.
- **M2**: `replyToHash: reply?.replyTo.hexString,` becomes `replyToHash: nil,`. Reddens `replyReceiveInvalidQuoteStoresHashOnly` (and `replyReceiveStoresBothColumns` again).
- **M3**: `switch ReactionWire.decode(m.fields) {` becomes `switch ReplyWire.decode(m.fields) == nil ? ReactionWire.decode(m.fields) : ReactionWire.Decoded.notReaction {`. This is the "replies win over reactions" precedence bug. Reddens `replyReceiveReactionWithReplyFieldsIsOnlyAReaction`: both the reaction and the malformed message now store a bubble.

Check that nothing hides anything:
- M3 is a no-op for the first two tests, whose fields carry no reaction.
- M1 and M2 do not affect the reaction test, which asserts that no row exists.
- Nothing can crash.

Run the filter and confirm all 3 tests are red. Revert all three by hand. Run `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies diff` and confirm only the Step 3 change remains.

- [ ] **Step 6: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore`
Expected: 223 tests pass, 0 known issues.

- [ ] **Step 7: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift
```

Write `/tmp/ReTiCAMsgr/msg-replies-task-4.txt` with the Write tool:

```
feat: store reply fields on incoming messages

An ordinary incoming message decodes FIELD_REPLY_TO and FIELD_REPLY_QUOTE
into the new columns. An unusable quote keeps the reply with no quote.
Reactions still win and their reply fields are ignored.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies commit -F /tmp/ReTiCAMsgr/msg-replies-task-4.txt`

---

### Task 5: `ReplyPreview` resolver and the peer name

**Files:**
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReplyPreview.swift`
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift`: in `State`, after `setThreadReactionRows` (originally lines 120–123, about 17 lines lower after Task 3)
- Create: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReplyPreviewTests.swift`

**Interfaces:**
- Consumes: `ReplyWire.trimQuote(_:)` (Task 2), `Message.replyToHash` / `replyQuote` (Task 1), `LXMFNode.LearnedPeer.displayName` via `state.node.client.learnedPeers`.
- Produces:
  ```swift
  public enum ReplyPreview {
      public struct Resolved: Equatable, Sendable {
          public var senderLabel: String
          public var text: String
          public var originalID: Message.ID?
          public init(senderLabel: String, text: String, originalID: Message.ID?)
      }
      public static let you: String           // "You"
      public static let them: String          // "Them"
      public static let unavailable: String   // "Original message not available"
      public static func senderLabel(originalIsOutgoing: Bool, peerName: String?) -> String
      public static func resolve(for message: Message, in thread: [Message], peerName: String?) -> Resolved?
  }
  AppFeature.State.openPeerDisplayName: String?   // computed, read-only
  ```

- [ ] **Step 1: Write the failing tests**

Create `ReplyPreviewTests.swift`:

```swift
import Testing
import Foundation
import ReTiCA
import ReTiCANode
@testable import ReTiCAMsgrCore

private let peer = String(repeating: "ab", count: 16)
private let originalHash = String(repeating: "a1", count: 32)

private func message(_ n: Int, outgoing: Bool, body: String, hash: String = "",
                     replyTo: String? = nil, quote: String? = nil) -> Message {
    Message(id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!,
            peerHex: peer, isOutgoing: outgoing, body: body,
            timestamp: Date(timeIntervalSince1970: 1700000000 + Double(n)),
            status: outgoing ? MessageStatus.sent : MessageStatus.received,
            validated: !outgoing, messageHash: hash, replyToHash: replyTo, replyQuote: quote)
}

@Test func replyPreviewNotAReplyIsNil() {
    // A hashless legacy row is in the thread, so a resolver that looked up a missing replyToHash
    // as "" would find it.
    let legacy = message(1, outgoing: false, body: "legacy")
    let plain = message(2, outgoing: true, body: "plain", hash: originalHash)
    #expect(ReplyPreview.resolve(for: plain, in: [legacy, plain], peerName: "Alice") == nil)
}

@Test func replyPreviewOriginalOutgoingIsYou() {
    let original = message(1, outgoing: true, body: "  my original \n", hash: originalHash)
    let reply = message(2, outgoing: false, body: "ok", hash: String(repeating: "b2", count: 32),
                        replyTo: originalHash, quote: "stale quote")
    // The found original wins over the carried quote, and is trimmed like one.
    #expect(ReplyPreview.resolve(for: reply, in: [original, reply], peerName: "Alice")
            == ReplyPreview.Resolved(senderLabel: "You", text: "my original", originalID: original.id))
}

@Test func replyPreviewOriginalIncomingUsesPeerNameOrThem() {
    let original = message(1, outgoing: false, body: "their words", hash: originalHash)
    let reply = message(2, outgoing: true, body: "mine", hash: String(repeating: "b2", count: 32),
                        replyTo: originalHash, quote: "their words")
    #expect(ReplyPreview.resolve(for: reply, in: [original, reply], peerName: "Alice")
            == ReplyPreview.Resolved(senderLabel: "Alice", text: "their words", originalID: original.id))
    #expect(ReplyPreview.resolve(for: reply, in: [original, reply], peerName: nil)
            == ReplyPreview.Resolved(senderLabel: "Them", text: "their words", originalID: original.id))
}

@Test func replyPreviewQuoteOnlyUsesReplyDirection() {
    // An incoming reply quotes one of ours, and an outgoing reply quotes one of theirs.
    let incoming = message(1, outgoing: false, body: "re", replyTo: originalHash, quote: "q")
    let outgoing = message(2, outgoing: true, body: "re", replyTo: originalHash, quote: "q")
    #expect(ReplyPreview.resolve(for: incoming, in: [incoming], peerName: "Alice")
            == ReplyPreview.Resolved(senderLabel: "You", text: "q", originalID: nil))
    #expect(ReplyPreview.resolve(for: outgoing, in: [outgoing], peerName: "Alice")
            == ReplyPreview.Resolved(senderLabel: "Alice", text: "q", originalID: nil))
    #expect(ReplyPreview.resolve(for: outgoing, in: [outgoing], peerName: nil)
            == ReplyPreview.Resolved(senderLabel: "Them", text: "q", originalID: nil))
}

@Test func replyPreviewNeitherShowsUnavailable() {
    let incoming = message(1, outgoing: false, body: "re", replyTo: originalHash)
    let outgoing = message(2, outgoing: true, body: "re", replyTo: originalHash)
    #expect(ReplyPreview.resolve(for: incoming, in: [incoming], peerName: nil)
            == ReplyPreview.Resolved(senderLabel: "You", text: "Original message not available", originalID: nil))
    #expect(ReplyPreview.resolve(for: outgoing, in: [outgoing], peerName: nil)
            == ReplyPreview.Resolved(senderLabel: "Them", text: "Original message not available", originalID: nil))
}

/// Review Focus 4.
@Test func replyPreviewEmptyQuoteCountsAsMissing() {
    let incoming = message(1, outgoing: false, body: "re", replyTo: originalHash, quote: "")
    #expect(ReplyPreview.resolve(for: incoming, in: [incoming], peerName: nil)
            == ReplyPreview.Resolved(senderLabel: "You", text: "Original message not available", originalID: nil))
}

/// Review Focus 5.
@MainActor @Test func replyPreviewOpenPeerDisplayNameIsTrimmedAndNeverBlank() {
    let peerHash = Data(repeating: 0xab, count: 16)
    var state = AppFeature.State(identity: Identity())
    #expect(state.openPeerDisplayName == nil)            // no open conversation
    state.openPeerHex = peer
    #expect(state.openPeerDisplayName == nil)            // no announce heard
    state.node.client.learnedPeers[peerHash] = LXMFNode.LearnedPeer(
        displayName: "  Alice \n", stampCost: nil, supportsCompression: false,
        learnedAt: Date(timeIntervalSince1970: 1700000000))
    #expect(state.openPeerDisplayName == "Alice")
    state.node.client.learnedPeers[peerHash]?.displayName = "   "
    #expect(state.openPeerDisplayName == nil)
    state.node.client.learnedPeers[peerHash]?.displayName = nil
    #expect(state.openPeerDisplayName == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore --filter replyPreview`
Expected: a compile failure. `ReplyPreview` and `openPeerDisplayName` do not exist.

- [ ] **Step 3: Write the resolver**

Create `ReplyPreview.swift`:

```swift
import Foundation

/// What a reply's bubble shows above its text. Pure: the SwiftUI quote block only lays it out.
public enum ReplyPreview {
    public struct Resolved: Equatable, Sendable {
        /// "You", the peer's display name, or "Them".
        public var senderLabel: String
        public var text: String
        /// The original's row when it is in the thread: the quote block then scrolls to it.
        public var originalID: Message.ID?

        public init(senderLabel: String, text: String, originalID: Message.ID?) {
            self.senderLabel = senderLabel
            self.text = text
            self.originalID = originalID
        }
    }

    public static let you = "You"
    public static let them = "Them"
    public static let unavailable = "Original message not available"

    /// Who wrote the quoted message. Shared with the composer bar ("Replying to …").
    public static func senderLabel(originalIsOutgoing: Bool, peerName: String?) -> String {
        originalIsOutgoing ? you : (peerName ?? them)
    }

    /// nil when `message` is not a reply. Otherwise the original from `thread` when present (its
    /// body, trimmed like a quote), else the carried quote, else "Original message not available".
    public static func resolve(for message: Message, in thread: [Message], peerName: String?) -> Resolved? {
        guard let hash = message.replyToHash else { return nil }
        if let original = thread.first(where: { $0.messageHash == hash }) {
            return Resolved(
                senderLabel: senderLabel(originalIsOutgoing: original.isOutgoing, peerName: peerName),
                text: ReplyWire.trimQuote(original.body),
                originalID: original.id
            )
        }
        // Without the original, the reply's direction decides: a reply we received quotes one of
        // ours, and a reply we sent quotes one of theirs.
        let label = senderLabel(originalIsOutgoing: !message.isOutgoing, peerName: peerName)
        // An empty quote (a blank original) says nothing, so it counts as no quote.
        if let quote = message.replyQuote, !quote.isEmpty {
            return Resolved(senderLabel: label, text: quote, originalID: nil)
        }
        return Resolved(senderLabel: label, text: unavailable, originalID: nil)
    }
}
```

- [ ] **Step 4: Add `openPeerDisplayName`**

In `AppFeature.swift`, inside `State`, directly after the closing `}` of `setThreadReactionRows` (and before the `}` that closes `State`), insert:

```swift

        /// The open peer's display name from its LXMF delivery announce (`learnedPeers`, the table
        /// the Announces list shows), trimmed. nil when no conversation is open, no announce was
        /// heard, or the name is blank, so labels fall back to "Them" rather than "".
        public var openPeerDisplayName: String? {
            guard let hex = openPeerHex,
                  let hash = Data(hexString: hex),
                  let name = node.client.learnedPeers[hash]?.displayName?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            return name
        }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore --filter replyPreview`
Expected: 7 tests pass.

- [ ] **Step 6: Mutation check**

Apply all six mutations together:
- **M1** (`ReplyPreview.resolve`): `guard let hash = message.replyToHash else { return nil }` becomes `let hash = message.replyToHash ?? ""`. Reddens `replyPreviewNotAReplyIsNil`: it now finds the hashless legacy row.
- **M2** (`resolve`, found branch): `text: ReplyWire.trimQuote(original.body),` becomes `text: original.body,`. Reddens `replyPreviewOriginalOutgoingIsYou`, because of the padded body.
- **M3** (`senderLabel`): `originalIsOutgoing ? you : (peerName ?? them)` becomes `originalIsOutgoing ? you : them`. Reddens `replyPreviewOriginalIncomingUsesPeerNameOrThem` and `replyPreviewQuoteOnlyUsesReplyDirection` (their "Alice" cases).
- **M4** (`resolve`, no-original branch): `senderLabel(originalIsOutgoing: !message.isOutgoing, peerName: peerName)` becomes `senderLabel(originalIsOutgoing: message.isOutgoing, peerName: peerName)`. Reddens `replyPreviewNeitherShowsUnavailable` (the incoming reply now reads "Them") and `replyPreviewQuoteOnlyUsesReplyDirection`.
- **M5** (`resolve`): `if let quote = message.replyQuote, !quote.isEmpty {` becomes `if let quote = message.replyQuote {`. Reddens `replyPreviewEmptyQuoteCountsAsMissing`.
- **M6** (`AppFeature.swift`, `openPeerDisplayName`): delete the line `!name.isEmpty` and the comma that ends the line before it. Reddens `replyPreviewOpenPeerDisplayNameIsTrimmedAndNeverBlank`: `"   "` now yields `""`.

Check that no mutation hides another:
- M1 only changes nil handling. Every other fixture has a `replyToHash`.
- M2 touches only the found branch, and M4 and M5 only the other branch.
- `replyPreviewNeitherShowsUnavailable` uses `peerName: nil`, so M3 cannot mask M4 there. The incoming case becomes "Them" either way.
- Nothing can crash.

Run the filter and confirm all 7 tests are red. Revert all six by hand. Run `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies diff` and confirm only the Step 4 addition remains in `AppFeature.swift`. Read `ReplyPreview.swift` back against Step 3.

- [ ] **Step 7: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore`
Expected: 230 tests pass, 0 known issues.

- [ ] **Step 8: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReplyPreview.swift ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReplyPreviewTests.swift
```

Write `/tmp/ReTiCAMsgr/msg-replies-task-5.txt` with the Write tool:

```
feat: resolve what a reply bubble quotes

ReplyPreview picks the original from the open thread when present, else
the carried quote, else "Original message not available", and labels it
You, the peer's announced name or Them. State.openPeerDisplayName supplies
that name from learnedPeers, trimmed and never blank.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies commit -F /tmp/ReTiCAMsgr/msg-replies-task-5.txt`

---

### Task 6: UI — menu row, composer bar, quote block, scroll and highlight

**Files:**
- Create: `ReTiCAMsgr/ReplyViews.swift`
- Modify: `ReTiCAMsgr/ChatView.swift` (whole file)

**Interfaces:**
- Consumes: `AppFeature.State.replyTarget`, `.openPeerDisplayName`, `AppFeature.Action.replyTapped(_:)` / `.replyCancelled` (Tasks 3, 5); `ReplyPreview.resolve(for:in:peerName:)`, `ReplyPreview.senderLabel(originalIsOutgoing:peerName:)`, `ReplyPreview.Resolved` (Task 5); `ReplyWire.trimQuote(_:)` (Task 2).
- Produces: SwiftUI views `QuoteBlock(preview:onOutgoingBubble:onTap:)` and `ReplyComposerBar(senderLabel:text:onCancel:)`. `MessageBubble` and `BubbleText` gain optional parameters with defaults, so no other caller changes (there are none outside `ChatView.swift`).

No unit tests: this task is SwiftUI layout. The Task 7 manual check covers it.

- [ ] **Step 1: Create the reply views**

Create `ReTiCAMsgr/ReplyViews.swift`:

```swift
//
//  ReplyViews.swift
//  ReTiCAMsgr
//

import SwiftUI
import ReTiCAMsgrCore

/// The quoted original inside a reply's bubble. It can be tapped (to scroll to the original) only
/// when the original is in this thread and a tap handler is given. The context-menu preview passes none.
struct QuoteBlock: View {
    let preview: ReplyPreview.Resolved
    /// Outgoing bubbles are blue with white text, so the bar and panel are drawn in white there.
    let onOutgoingBubble: Bool
    var onTap: ((Message.ID) -> Void)? = nil

    var body: some View {
        if let originalID = preview.originalID, let onTap {
            Button { onTap(originalID) } label: { panel }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the original message")
        } else {
            panel
        }
    }

    private var panel: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(onOutgoingBubble ? Color.white : Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.senderLabel)
                    .font(.caption.weight(.semibold))
                Text(preview.text)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        // The bar takes the text's height, not the height the row proposes.
        .fixedSize(horizontal: false, vertical: true)
        .padding(6)
        // UI rule: the whole panel is the tap target, at least 44 pt tall. Not maxWidth .infinity,
        // which would stretch every reply bubble to the full row width.
        .frame(minHeight: 44, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(onOutgoingBubble ? Color.white.opacity(0.2) : Color.primary.opacity(0.08))
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reply to \(preview.senderLabel): \(preview.text)")
    }
}

/// "Replying to …" above the text field, with a ✕ that cancels the reply.
struct ReplyComposerBar: View {
    let senderLabel: String
    let text: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(senderLabel)")
                    .font(.caption.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    // UI rule: a 44 pt hit area, all of it tappable.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.top, 4)
    }
}
```

- [ ] **Step 2: Rewrite `ChatView.swift`**

Replace the whole file with:

```swift
//
//  ChatView.swift
//  ReTiCAMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import UIKit
import ComposableArchitecture
import ReTiCAMsgrCore

struct ChatView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var pickerTarget: PickerTarget?
    @State private var infoTarget: InfoTarget?
    /// The bubble briefly outlined after a quote tap scrolled to it.
    @State private var highlightedMessageID: Message.ID?
    /// Bumped per quote tap, so only the latest tap's timer clears the highlight.
    @State private var highlightGeneration = 0
    @FocusState private var draftFocused: Bool

    private var peerReachable: Bool {
        guard let peer = store.openPeerHex else { return false }
        return store.reachablePeers.contains(peer)
    }

    private var canSend: Bool {
        peerReachable && !store.draft.isEmpty
    }

    var body: some View {
        let peerName = store.openPeerDisplayName
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(store.threadMessages) { message in
                    let reactions = store.threadReactions[message.messageHash] ?? []
                    let replyPreview = ReplyPreview.resolve(for: message, in: store.threadMessages, peerName: peerName)
                    MessageBubble(
                        message: message,
                        reactions: reactions,
                        replyPreview: replyPreview,
                        isHighlighted: highlightedMessageID == message.id,
                        onQuoteTap: { showOriginal($0, proxy: proxy) }
                    )
                    .id(message.id)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        if !message.messageHash.isEmpty {
                            ReactionPaletteMenu(
                                current: reactions.first(where: \.includesMe)?.emoji,
                                onSelect: { store.send(.reactionSelected(messageHash: message.messageHash, emoji: $0)) },
                                onMore: { pickerTarget = PickerTarget(messageHash: message.messageHash) }
                            )
                            .disabled(!peerReachable)
                            // Not gated on reachability: composing works offline, and Send is gated itself.
                            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                                store.send(.replyTapped(message.id))
                                draftFocused = true
                            }
                        }
                        Button("Info", systemImage: "info.circle") {
                            infoTarget = InfoTarget(id: message.id)
                        }
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.body
                        }
                    } preview: {
                        BubbleText(message: message, replyPreview: replyPreview)
                            .padding(8)
                    }
                }
                .listStyle(.plain)
                .sheet(item: $infoTarget) { target in
                    MessageInfoSheet(store: store, messageID: target.id)
                }
            }

            Divider()

            if let target = store.replyTarget {
                ReplyComposerBar(
                    senderLabel: ReplyPreview.senderLabel(originalIsOutgoing: target.isOutgoing, peerName: peerName),
                    text: ReplyWire.trimQuote(target.body),
                    onCancel: { store.send(.replyCancelled) }
                )
            }

            HStack(spacing: 8) {
                TextField("Message", text: $store.draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($draftFocused)
                Button("Send") { store.send(.sendTapped) }
                    .disabled(!canSend)
            }
            .padding()
        }
        .navigationTitle(store.openPeerHex.map(shortHex) ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pickerTarget) { target in
            EmojiPickerSheet { emoji in
                store.send(.reactionSelected(messageHash: target.messageHash, emoji: emoji))
            }
        }
    }

    /// Scroll the original to the middle of the list, outline it, then fade the outline over ~1 s.
    private func showOriginal(_ id: Message.ID, proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(id, anchor: .center) }
        highlightGeneration += 1
        let generation = highlightGeneration
        highlightedMessageID = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))   // let the scroll land first
            guard generation == highlightGeneration else { return }
            withAnimation(.easeOut(duration: 1)) { highlightedMessageID = nil }
        }
    }
}

private struct PickerTarget: Identifiable {
    let messageHash: String
    var id: String { messageHash }
}

private struct InfoTarget: Identifiable {
    let id: UUID
}

struct MessageBubble: View {
    let message: Message
    var reactions: [ReactionSummary.Item] = []
    var replyPreview: ReplyPreview.Resolved? = nil
    var isHighlighted = false
    var onQuoteTap: ((Message.ID) -> Void)? = nil

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer() }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                BubbleText(message: message, replyPreview: replyPreview, onQuoteTap: onQuoteTap)
                    .overlay(
                        // Drawn 4 pt outside the bubble, so the accent ring shows on the blue
                        // outgoing bubble too.
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.accentColor, lineWidth: 3)
                            .padding(-4)
                            .opacity(isHighlighted ? 1 : 0)
                    )
                if !reactions.isEmpty {
                    ReactionBadge(items: reactions)
                        .padding(.top, -10)
                        .padding(.horizontal, 8)
                }
                if message.isOutgoing {
                    Text(message.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !message.isOutgoing { Spacer() }
        }
    }
}

/// The rounded bubble alone — also the context-menu preview, so the lifted view is just the bubble.
/// A reply shows its quote block above the text.
struct BubbleText: View {
    let message: Message
    var replyPreview: ReplyPreview.Resolved? = nil
    var onQuoteTap: ((Message.ID) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyPreview {
                QuoteBlock(preview: replyPreview, onOutgoingBubble: message.isOutgoing, onTap: onQuoteTap)
            }
            Text(message.body)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(message.isOutgoing ? Color.blue : Color(.systemGray5))
        .foregroundStyle(message.isOutgoing ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// Small capsule of reactions overlapping the bubble's bottom edge. Tinted border when one is mine.
struct ReactionBadge: View {
    let items: [ReactionSummary.Item]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.emoji) { item in
                HStack(spacing: 1) {
                    Text(item.emoji)
                    if item.count > 1 {
                        Text("\(item.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color(.systemBackground)))
        .overlay(
            Capsule().stroke(items.contains(where: \.includesMe) ? Color.accentColor : Color(.separator),
                             lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(items.map { "\($0.emoji) \($0.count)" }.joined(separator: ", "))
    }
}
```

The only changes from the current file are these:
- the `highlightedMessageID`, `highlightGeneration` and `draftFocused` properties;
- `peerName`, the `ScrollViewReader`, `replyPreview` and the new `MessageBubble` arguments, plus `.id(message.id)`;
- the Reply button;
- the preview's `replyPreview` argument;
- the composer bar and `.focused`;
- `showOriginal`;
- the new `MessageBubble` / `BubbleText` parameters, the highlight overlay and the `VStack` in `BubbleText`.

`ReactionBadge`, `PickerTarget` and `InfoTarget` are unchanged.

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build`
Expected: `** BUILD SUCCEEDED **`. If it fails in ReTiCA sources, stop and report it (ReTiCA drift). If it fails in these two files, fix it here.

- [ ] **Step 4: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore`
Expected: 230 tests pass, 0 known issues (unchanged, since this task touches only the app target).

- [ ] **Step 5: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies add ReTiCAMsgr/ReplyViews.swift ReTiCAMsgr/ChatView.swift
```

Write `/tmp/ReTiCAMsgr/msg-replies-task-6.txt` with the Write tool:

```
feat: reply from the message menu

A Reply row in the context menu of any message with a hash sets the reply
target and focuses the text field. A bar above the field shows who is
being replied to with a cancel button. Reply bubbles show a quote block
that scrolls to the original and briefly outlines it.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies commit -F /tmp/ReTiCAMsgr/msg-replies-task-6.txt`

---

### Task 7: Manual simulator verification

**Files:**
- Modify TEMPORARILY: `ReTiCAMsgr/ReTiCAMsgrApp.swift`. **This is reverted by hand before the task ends and is never committed.**

**Interfaces:**
- Consumes: everything above.
- Produces: a verification report, and no code or commit.

**Do NOT uninstall the app, and do NOT erase or reset the simulator.** The seeded rows are removed with a second scaffold run (Step 6) instead.

- [ ] **Step 1: Load the simulator skill**

Invoke the `xcodebuildmcp-cli` skill with the Skill tool. Follow its help-first discovery (`xcodebuildmcp --help`, `xcodebuildmcp tools`, `xcodebuildmcp <workflow> --help`) to find:
- the simulator build-and-run command for this project and scheme;
- the UI-automation commands for screenshot, tap, long-press, type text and describing the on-screen accessibility tree.

Check the session defaults before the first build, as the skill requires.

- [ ] **Step 2: Add the temporary seed scaffold**

In `ReTiCAMsgrApp.swift`, replace lines 20–21:

```swift
        prepareDependencies {
            $0.defaultDatabase = try! AppDatabase.makeOnDisk(path: dbPath)
```

with:

```swift
        let database = try! AppDatabase.makeOnDisk(path: dbPath)
        #if DEBUG
        ReplySeed.seed(database)   // TEMPORARY (message-replies Task 7). Revert before any commit.
        #endif
        prepareDependencies {
            $0.defaultDatabase = database
```

Replace line 38, `                .task { Self.store.send(.onLaunch) }`, with:

```swift
                .task {
                    Self.store.send(.onLaunch)
                    #if DEBUG
                    // TEMPORARY: make the seeded peer reachable (enables Send), then give it an
                    // announced display name. pathLearned goes first so no LearnedPeerRow is written.
                    Self.store.send(.node(.client(.endpoint(.delegate(.pathLearned(
                        destinationHash: ReplySeed.peerHash, hops: 1))))))
                    Self.store.send(.rehydrateLearnedPeers([ReplySeed.peerHash: LXMFNode.LearnedPeer(
                        displayName: "Sim Peer", stampCost: nil, supportsCompression: false, learnedAt: Date())]))
                    #endif
                }
```

Append at the end of the file:

```swift
#if DEBUG
/// TEMPORARY message-replies Task 7 scaffold. Revert before any commit.
enum ReplySeed {
    static let peer = String(repeating: "6c", count: 16)
    static let peerHash = Data(repeating: 0x6c, count: 16)
    static let originalHash = String(repeating: "6d", count: 32)

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-00000000f1" + String(format: "%02d", n))!
    }

    static func seed(_ db: any DatabaseWriter) {
        let now = Date()
        var rows: [Message] = [
            Message(id: id(1), peerHex: peer, isOutgoing: false, body: "Are we still on for dinner at 6?",
                    timestamp: now.addingTimeInterval(-3600), status: MessageStatus.received, validated: true,
                    messageHash: originalHash, fieldKeys: ""),
            Message(id: id(2), peerHex: peer, isOutgoing: false, body: "legacy hashless message",
                    timestamp: now.addingTimeInterval(-3500), status: MessageStatus.received, validated: false,
                    messageHash: ""),
        ]
        // Filler, so the original is scrolled well off screen when the thread opens at the bottom.
        for n in 0..<15 {
            rows.append(Message(id: id(10 + n), peerHex: peer, isOutgoing: n % 2 == 0, body: "filler \(n + 1)",
                                timestamp: now.addingTimeInterval(-3000 + Double(n) * 60),
                                status: n % 2 == 0 ? MessageStatus.delivered : MessageStatus.received,
                                validated: n % 2 != 0,
                                messageHash: String(repeating: "6e", count: 31) + String(format: "%02x", n)))
        }
        rows += [
            // A reply whose original is in the thread: tap-to-scroll.
            Message(id: id(30), peerHex: peer, isOutgoing: true, body: "Yes, see you there",
                    timestamp: now.addingTimeInterval(-600), status: MessageStatus.delivered, validated: false,
                    messageHash: String(repeating: "6f", count: 32), fieldKeys: "0x30,0x31",
                    replyToHash: originalHash, replyQuote: "Are we still on for dinner at 6?"),
            // Original missing, quote present: not tappable, labelled "You".
            Message(id: id(31), peerHex: peer, isOutgoing: false, body: "Replying to something you deleted",
                    timestamp: now.addingTimeInterval(-300), status: MessageStatus.received, validated: true,
                    messageHash: String(repeating: "70", count: 32), fieldKeys: "0x30,0x31",
                    replyToHash: String(repeating: "71", count: 32),
                    replyQuote: "An old message this phone never had"),
            // Original missing, no quote: "Original message not available".
            Message(id: id(32), peerHex: peer, isOutgoing: false, body: "Reply with no quote",
                    timestamp: now.addingTimeInterval(-120), status: MessageStatus.received, validated: true,
                    messageHash: String(repeating: "72", count: 32), fieldKeys: "0x30",
                    replyToHash: String(repeating: "73", count: 32)),
        ]
        for row in rows {
            try? db.write { try Message.insert { row }.execute($0) }   // fixed ids: a relaunch is a no-op
        }
    }

    /// Deletes every row in the seeded conversation, including replies sent during the check.
    static func remove(_ db: any DatabaseWriter) {
        let seededPeer = peer
        try? db.write { try Message.where { $0.peerHex.eq(seededPeer) }.delete().execute($0) }
    }
}
#endif
```

The file already imports `SQLiteData` (which re-exports `DatabaseWriter` and the query DSL), `ReTiCANode` (`LXMFNode.LearnedPeer`) and `ReTiCAMsgrCore`.

Before running, open Settings in the app once and note whether a propagation node is configured. Do not change it. If one is set, the reply sent in check 4 is also uploaded to that node, addressed to the fake peer `6c6c…`. That is harmless but should be mentioned in the report.

- [ ] **Step 3: Build and run on a simulator**

Use the skill's simulator build-and-run for `/Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgr.xcodeproj`, scheme `ReTiCAMsgr`. Open the conversation `6c6c…` from the Chats list.

- [ ] **Step 4: Verify, taking a screenshot for each check**

1. **Reply row.**
   - Long-press "Are we still on for dinner at 6?". The menu shows the reaction items, then **Reply**, then Info, then Copy.
   - Long-press "legacy hashless message". It shows only Info and Copy, with no Reply.
2. **Composer bar and ✕.**
   - Tap Reply on "Are we still on for dinner at 6?". The text field is focused (caret or keyboard).
   - A bar above it reads "Replying to Sim Peer", with the quote on one line.
   - Tap ✕, including its blank edge away from the glyph. The bar disappears.
   - Reply again, then long-press a filler outgoing message (for example "filler 1") and tap Reply. The bar now reads "Replying to You".
3. **The bar survives a rejected send.** With the bar showing and the draft empty, Send is disabled and the bar stays.
4. **Sending a reply.**
   - Reply to "Are we still on for dinner at 6?", type "on my way" and tap Send.
   - The new outgoing bubble shows a quote block, "Sim Peer" / "Are we still on for dinner at 6?", above "on my way".
   - The bar is gone and the draft is empty.
   - The bubble's status may later turn "failed", because the peer is fake. That is expected.
5. **Tap to scroll, with the highlight.**
   - Scroll to the bottom. Tap the quote block on "Yes, see you there", including its blank right edge.
   - The list scrolls so "Are we still on for dinner at 6?" is centred.
   - An accent ring appears around it and fades out over about a second.
   - Tap again quickly twice. The ring still fades once, after the last tap.
6. **Quote only, and missing.**
   - "Replying to something you deleted" shows "You" / "An old message this phone never had". Tapping it does nothing.
   - "Reply with no quote" shows "You" / "Original message not available". Tapping it does nothing.
7. **Info sheet.** Long-press "Yes, see you there" → Info. The Payload section lists `0x30 reply to` and `0x31 reply quote`. Do the same for the reply sent in check 4.
8. **Accessibility.** Describe the on-screen UI with the skill's accessibility command. The quote block on "Yes, see you there" has the label "Reply to Sim Peer: Are we still on for dinner at 6?" and the hint "Shows the original message". The one on "Reply with no quote" has no hint.

If check 2's focus does not move to the text field, the menu dismissal is swallowing it. In `ChatView.swift`, replace `draftFocused = true` in the Reply button with:

```swift
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(350))   // after the menu dismisses
                                    draftFocused = true
                                }
```

Rebuild, re-check, and commit it in a new commit, staging only `ReTiCAMsgr/ChatView.swift`, with the message in `/tmp/ReTiCAMsgr/msg-replies-task-7-fix.txt` ("fix: focus the text field after the Reply menu dismisses", plus the trailers). The scaffold must not be staged.

For any other failing check, stop. Diagnose it with superpowers:systematic-debugging, fix it in the owning task's files with a new commit (its own message file), and redo this task.

- [ ] **Step 5: Revert the scaffold by hand, keeping only `remove`**

With the Edit tool, restore the scaffold to a cleanup-only version:
- restore line 38 exactly: `                .task { Self.store.send(.onLaunch) }`;
- change `ReplySeed.seed(database)` to `ReplySeed.remove(database)`.

Then relaunch the app on the simulator with the skill's build-and-run. Confirm the `6c6c…` conversation is gone from Chats. Take a screenshot.

- [ ] **Step 6: Remove the scaffold entirely**

With the Edit tool:
- restore lines 20–21 exactly:
  ```swift
        prepareDependencies {
            $0.defaultDatabase = try! AppDatabase.makeOnDisk(path: dbPath)
  ```
  This deletes the `let database` line and the `#if DEBUG` block.
- delete the whole `#if DEBUG enum ReplySeed ... #endif` block at the end of the file.

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies diff -- ReTiCAMsgr/ReTiCAMsgrApp.swift`
Expected: empty output.

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-replies status --short`
Expected: no entry for `ReTiCAMsgrApp.swift`. Only pre-existing unrelated entries remain.

- [ ] **Step 7: Final checks**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build`
Expected: `** BUILD SUCCEEDED **` with the scaffold gone.

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-replies/ReTiCAMsgrCore`
Expected: 230 tests pass, 0 known issues.

Nothing is committed in this task, apart from a focus fix if Step 4 needed one. Report:
- the eight checks, each with pass or fail and its screenshot;
- the cleanup screenshot;
- whether a propagation node was configured.

---

## Self-Review

**Spec coverage**

| Spec requirement | Where |
|---|---|
| Reply row, only for rows with a hash | Task 6 (menu), Task 3 (`replyTapped` guard), Task 7 check 1 |
| `FIELD_REPLY_TO` 0x30 / `FIELD_REPLY_QUOTE` 0x31 on send, and no other fields | Task 3 `replyTargetSendCarriesReplyFieldsAndStoresColumns` (`fieldKeys == "0x30,0x31"`) |
| Reference byte check | Task 2 Step 1 + `replyWireEncodeMatchesReferenceUmsgpackBytes` |
| Round trip through real `LXMessage` | `replyWireRoundTripsThroughRealLXMessage` |
| Decode rules for 0x30 and 0x31, and 0x31 without 0x30 | `replyWireInvalidReplyToIsNotAReply`, `replyWireInvalidQuoteKeepsTheReply` |
| Trim: ≤ 100 unchanged, > 100 cut + "…", whitespace, ZWJ | `replyWireTrimLimitsTo100Characters`, `replyWireTrimStripsSurroundingWhitespace`, `replyWireTrimDoesNotSplitZWJEmojiAtBoundary` |
| Migration `addReplies`: legacy nil, round trip | Task 1 |
| `replyTapped` / `replyCancelled` / `closeConversation` | Task 3 |
| Send with target: fields, columns, target cleared | Task 3 |
| Send without target: unchanged | `replyTargetAbsentSendsNoReplyFields` |
| Incoming reply stores columns, and an invalid quote stores the hash only | Task 4 |
| Reaction + reply fields → reaction only | `replyReceiveReactionWithReplyFieldsIsOnlyAReaction` |
| `ReplyPreview` found / quote only / neither / not a reply | Task 5 |
| `peerName` source | Task 5 `openPeerDisplayName` |
| Composer bar, quote block, tap-to-scroll, highlight, accessibility | Task 6, Task 7 checks 2–8 |
| Info sheet shows 0x30 / 0x31 | Existing `MessageInfo.fieldNames`, Task 7 check 7 |

**Placeholder scan:** every code step has complete code, and every command has its expected output. `<model name>` in the commit trailers is intentional, filled in by whoever commits.

**Type consistency:** these names are the same in every task:
- `AppFeature.ReplyTarget(messageHash:body:isOutgoing:)`
- `state.replyTarget`
- `.replyTapped(Message.ID)`, `.replyCancelled`
- `ReplyWire.encode(replyTo:quote:)`, `ReplyWire.decode(_:)` (returning `(replyTo:quote:)?`), `ReplyWire.trimQuote(_:)`
- `ReplyPreview.resolve(for:in:peerName:)`, `ReplyPreview.Resolved(senderLabel:text:originalID:)`, `ReplyPreview.senderLabel(originalIsOutgoing:peerName:)`
- `state.openPeerDisplayName`
- `Message(... replyToHash:replyQuote:)`

**Review Focus:** all five items have a pinned test in their owning task.
