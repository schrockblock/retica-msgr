# Message Info Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Long-pressing any message offers an **Info** row that opens a sheet of copyable debugging metadata (timeline, delivery method, hashes, signature, stamp, sizes, LXMF field keys). As part of the same branch, reactions move to the standard LXMF `FIELD_REACTION` (0x40).

**Architecture:** One GRDB migration (`addMessageInfo`) adds nullable metadata columns to `messages`. `AppFeature` fills them in the existing insert on the receive and send paths. Each status handler also records its first milestone time. A pure `MessageInfo` builder in ReTiCAMsgrCore turns a `Message` into titled sections of `(label, display, copy)` rows. It is unit-tested and holds all formatting. The SwiftUI `MessageInfoSheet` only lays the rows out. `ReactionWire` switches its encoder to 0x40 and still decodes the legacy 0xFB/0xFC format.

**Tech Stack:** Swift 6, TCA (ComposableArchitecture), SQLiteData/StructuredQueries on GRDB, Swift Testing, SwiftUI (iOS 26.4), ReTiCA (`LXMessage`, `MsgPackValue`, `LXMFRouter.DeliveryMethod`).

**Spec:** `/Users/ell/development/ios/apps/ReTiCAMsgr-message-info/docs/superpowers/specs/2026-09-26-message-info-design.md`, including its "Addendum: reactions move to the standard `FIELD_REACTION` (0x40)". Read it before starting. It is binding.

## Global Constraints

**Where you work**
- All work happens ONLY in the worktree `/Users/ell/development/ios/apps/ReTiCAMsgr-message-info`, on branch `feat/message-info`.
- Never commit in `/Users/ell/development/ios/apps/ReTiCAMsgr`.
- Never touch `/Users/ell/development/ios/pods/ReTiCA`: no edits, no git, no builds. Another agent works there.

**Shell**
- One command per Bash call. No `|`, `&&`, `||`, `;`, `$(...)` or `xargs`.
- No inline interpreters (`python -c`, heredocs into interpreters, and so on). Scripts go in files under `/tmp/ReTiCAMsgr/`. Create that directory once with `mkdir -p /tmp/ReTiCAMsgr`.

**Commits**
- Stage explicit paths only: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info add <path> <path> ...`. Never use `git add -A` or `git add .`. The worktree has unrelated untracked or modified files, such as xcuserdata and other plans, that must not be staged.
- Write the message with the **Write** tool to `/tmp/ReTiCAMsgr/commit-msg.txt`, then run `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info commit -F /tmp/ReTiCAMsgr/commit-msg.txt`.
  - **That file may hold a stale message from earlier work. Always overwrite it with Write immediately before each commit.**
- No semicolons anywhere in a commit message.
- End every commit message with these two trailer lines, at column 0, after a blank line. Put the name of the model that actually wrote the commit in the first line (for example `Claude Opus 5.5`):
  ```
  Co-Authored-By: <model name> <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
  ```

**Tests**
- Command: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore [--filter X]`.
- The baseline is 166 tests green.
- The whole package must compile at the end of every task.
- Each task's new tests share a unique name prefix, so one `--filter` selects all of them:

  | Task | Prefix |
  |---|---|
  | 1 | `infoMigration` |
  | 2 | `stdReaction` |
  | 3 | `infoReceive` |
  | 4 | `infoSend` |
  | 5 | `infoMilestone` |
  | 6 | `infoSections` |

**Mutation verification (mandatory for every task with tests)**
1. The new tests go green.
2. Apply the task's listed batch of production mutations, all at once. Run the filter and confirm that EVERY new test is red.
3. Revert every mutation BY HAND with the Edit tool. Never use `git checkout -- <file>`, `git restore` or `git stash`. Then run `git -C <worktree> diff` and confirm that only the intended task changes remain.
4. The new tests are green again, then the full suite is green.
- Each task's batch has been checked so that no mutation masks another and none crashes the process.
- If any new test survives the batch, that test is not testing what it claims. Fix the test and restart from step 1.
- Edits that only change shape, with no tests, are exempt (Task 7's SwiftUI).

**Test style**
- Keep `store.exhaustivity = .off` in the shared `makeStore` helper. Do not change the helper.
- None of this plan's tests asserts the *absence of a store action*. The absence claims (for example "no `Message` row") are database reads made after `await store.finish()`, when every effect has completed.
  - If you add a store-action absence claim, turn exhaustivity `.on` for that window, or use an exhaustive no-op send probe.
  - Never call `skipInFlightEffects` while exhaustivity is `.on`, because it records a known issue.
- The suite must end with zero known issues.

**UI rule**
- Tappable custom rows get `.frame(maxWidth: .infinity, alignment: .leading)` + `.contentShape(Rectangle())`.

**App build check:** `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build`

**Values from the spec, copied verbatim**
- Migration and columns:
  - The migration is named `addMessageInfo` and is registered after `createReactions`.
  - Columns: `senderTimestamp`, `arrivalMethod`, `sentViaPropagation`, `storedAt`, `deliveredAt`, `failedAt`, `wireSize`, `titleSize`, `contentSize`, `fieldKeys`, `stampState`.
- String constants:
  - `ArrivalMethod` values: `"opportunistic"` / `"direct"` / `"propagated"`.
  - `StampState` values: `"none"`, `"unchecked"`, `"valid"`, `"invalid"`.
- Reaction wire format:
  - `ReactionWire.fieldReaction = 0x40`, `reactionTo = 0x00`, `reactionContent = 0x01`.
  - `maxEmojiBytes` is 64. The target length is 16–32.
  - Removal is empty `REACTION_CONTENT` bytes.
- UI strings and modifiers:
  - Menu row: `Button("Info", systemImage: "info.circle")`, between the reaction items and "Copy".
  - Sheet: `.presentationDetents([.medium, .large])`, title "Info", a Done button.
  - Legacy footer text: "Some details weren't recorded for messages from before this feature."

## Review Focus

These are five inputs the spec does not mention that are most likely to bite a real user. Each one is pinned by a test in the task that owns the code.

1. **A peer with a broken clock.** The sender's timestamp is `0`, negative, `1e18`, NaN or infinite. The message must still be stored and the thread must still load. Only the Info row degrades, to "—".
   - Why it matters: an unrepresentable `Date` written as ISO text could make every later `Message.fetchAll` of that thread throw.
   - Pinned by `infoReceiveSenderTimestampRejectsUnrepresentableValues` and `infoReceiveOutOfRangeSenderTimestampStillStoresTheMessage` (Task 3). Huge skews format in hours, pinned by `infoSectionsGapFormats` (Task 6).
2. **A mixed-version sender** puts a malformed 0x40 field and a valid legacy 0xFB/0xFC reaction in the same message. The expected result is the legacy reaction, not a dropped message.
   - Pinned by `stdReactionMalformedStandardFallsBackToValidLegacy` (Task 2).
3. **A failure report after the message was delivered.** The bubble must keep "delivered", while Info still records when the failure was reported. The spec states this for a late `propagationAccepted`; the same rule applies to `deliveryFailed`.
   - Pinned by `infoMilestoneFailureAfterDeliveredKeepsStatusButRecordsTime` (Task 5).
4. **A legacy incoming bubble with no hash.** Info must still open. The hash row shows "—" and a tap copies nothing, rather than putting "—" on the pasteboard.
   - Pinned by `infoSectionsLegacyIncoming` (Task 6), which asserts `copy == ""`. The empty-copy tap guard is in Task 7 and checked manually in Task 8.
5. **Unusual field keys**: a key the app has no name for (`0x2A`), a key above 0xFF (`0x100`), or a corrupt stored token (`junk`). Each must show as-is and must not crash or vanish.
   - Pinned by `infoSectionsFieldKeyNaming` (Task 6).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Message.swift` | Modify | New nullable properties, init parameters defaulting to nil, `ArrivalMethod` and `StampState` namespaces |
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Database.swift` | Modify | `addMessageInfo` migration |
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReactionWire.swift` | Modify | Standard 0x40 encode, dual-format decode |
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/MessageMetadata.swift` | Create | Pure mapping from ReTiCA values (`LXMessage`, `DeliveryMethod`, fields) to the stored strings |
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift` | Modify | Receive and send inserts carry metadata, and the three status handlers record milestones |
| `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/MessageInfo.swift` | Create | Pure `Message` to `[Section]` builder and all formatting |
| `ReTiCAMsgr/MessageInfoSheet.swift` | Create | SwiftUI sheet: inset-grouped list, tap to copy, "Copied" overlay |
| `ReTiCAMsgr/ChatView.swift` | Modify | Info menu row and `sheet(item:)` |
| `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DatabaseTests.swift` | Modify | Migration tests |
| `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReactionWireTests.swift` | Modify | Standard codec tests |
| `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/MessageMetadataTests.swift` | Create | Pure sender-timestamp range test |
| `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` | Modify | Reducer tests for reactions, receive, send and milestones |
| `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/MessageInfoTests.swift` | Create | Builder and formatting tests |

The app target uses file-system-synchronized groups, so a new file in `ReTiCAMsgr/` joins the target automatically. The test target picks up new files in `Tests/ReTiCAMsgrCoreTests/` automatically as well.

**`Message(` construction sites:** these are all of them, found by grep. The new init parameters default to `nil`, so each keeps compiling unchanged.
- `Sources/.../AppFeature.swift:500` (sendTapped) and `:657` (messageReceived). Tasks 4 and 3 add arguments to these two.
- `Tests/.../DatabaseTests.swift:10`
- `Tests/.../AppFeatureTests.swift:72` (the `msg` helper)
- `Tests/.../ConversationTests.swift:10`
- There are none in `ReTiCAMsgr/`.

**Before Task 1:**
- Confirm the branch: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info branch --show-current` should print `feat/message-info`.
- Run `mkdir -p /tmp/ReTiCAMsgr`.
- Run the full suite once to confirm the 166-test baseline.

**Date storage note, which affects test values:**
- StructuredQueries stores `Date` as ISO-8601 text with **millisecond** precision (`"yyyy-MM-dd HH:mm:ss.SSS"`, UTC).
- Test timestamps therefore use whole seconds or `.5`. A value like `1700000000.123456` would not round-trip exactly.
- `makeStore` freezes `\.date` at `1700000000`, which is `2023-11-14 22:13:20 UTC`.

---

### Task 1: Migration and model columns

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Message.swift` (whole file)
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Database.swift:75-87` (after the `createReactions` migration)
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DatabaseTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Message` gains these properties:
    ```swift
    public var senderTimestamp: Date?
    public var arrivalMethod: String?
    public var sentViaPropagation: Bool?
    public var storedAt: Date?
    public var deliveredAt: Date?
    public var failedAt: Date?
    public var wireSize: Int?
    public var titleSize: Int?
    public var contentSize: Int?
    public var fieldKeys: String?
    public var stampState: String?
    ```
  - `Message.init` gains the matching labelled parameters, each `= nil`, after `messageHash:`, in exactly that order.
  - `public enum ArrivalMethod { static let opportunistic, direct, propagated }` (String constants).
  - `public enum StampState { static let none, unchecked, valid, invalid }` (String constants).

- [ ] **Step 1: Write the failing tests**

Append to `DatabaseTests.swift`:

```swift
// MARK: - Message Info metadata (addMessageInfo)

/// A row written before `addMessageInfo` existed must read back through the new `Message` shape
/// with every metadata field nil. Nil is what the Info sheet shows as "—".
@Test func infoMigrationLegacyRowReadsBackWithNilMetadata() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator().migrate(queue, upTo: "createReactions")
    // Raw SQL: the Swift `Message` type already has the new columns, so it cannot insert into the
    // old schema. Values use the encodings SQLiteData writes: lowercase UUID text, ISO-8601 ms text.
    try queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO messages (id, peerHex, isOutgoing, body, timestamp, status, validated, messageHash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: ["00000000-0000-0000-0000-000000000001", String(repeating: "a", count: 32),
                        0, "old", "2023-11-14 22:13:20.000", MessageStatus.received, 1, ""]
        )
    }
    try AppDatabase.migrator().migrate(queue)
    let rows = try queue.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.body == "old")
    #expect(row.timestamp == Date(timeIntervalSince1970: 1700000000))
    #expect(row.validated == true)
    #expect(row.senderTimestamp == nil)
    #expect(row.arrivalMethod == nil)
    #expect(row.sentViaPropagation == nil)
    #expect(row.storedAt == nil)
    #expect(row.deliveredAt == nil)
    #expect(row.failedAt == nil)
    #expect(row.wireSize == nil)
    #expect(row.titleSize == nil)
    #expect(row.contentSize == nil)
    #expect(row.fieldKeys == nil)
    #expect(row.stampState == nil)
}

/// Every new column round-trips. The expectations use literals, not `back == m`, so a model that
/// silently drops a field on init cannot pass by dropping it on both sides.
@Test func infoMigrationRoundTripsEveryMetadataColumn() throws {
    let db = try AppDatabase.makeInMemory()
    let m = Message(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        peerHex: String(repeating: "b", count: 32),
        isOutgoing: true,
        body: "hi",
        timestamp: Date(timeIntervalSince1970: 1700000000),
        status: MessageStatus.delivered,
        validated: false,
        messageHash: "abcd",
        senderTimestamp: Date(timeIntervalSince1970: 1699999999.5),
        arrivalMethod: ArrivalMethod.direct,
        sentViaPropagation: true,
        storedAt: Date(timeIntervalSince1970: 1700000005),
        deliveredAt: Date(timeIntervalSince1970: 1700000010),
        failedAt: Date(timeIntervalSince1970: 1700000003),
        wireSize: 412,
        titleSize: 3,
        contentSize: 17,
        fieldKeys: "0xfb,0xfc",
        stampState: StampState.valid
    )
    try db.write { try Message.insert { m }.execute($0) }
    let back = try #require(try db.read { try Message.all.fetchAll($0) }.first)
    #expect(back.senderTimestamp == Date(timeIntervalSince1970: 1699999999.5))
    #expect(back.arrivalMethod == "direct")
    #expect(back.sentViaPropagation == true)
    #expect(back.storedAt == Date(timeIntervalSince1970: 1700000005))
    #expect(back.deliveredAt == Date(timeIntervalSince1970: 1700000010))
    #expect(back.failedAt == Date(timeIntervalSince1970: 1700000003))
    #expect(back.wireSize == 412)
    #expect(back.titleSize == 3)
    #expect(back.contentSize == 17)
    #expect(back.fieldKeys == "0xfb,0xfc")
    #expect(back.stampState == "valid")
    #expect(back == m)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter infoMigration`
Expected: a compile failure. `Message` has no `senderTimestamp` (and so on), and `ArrivalMethod` / `StampState` are undefined.

- [ ] **Step 3: Implement the model**

Replace the whole of `Message.swift` with:

```swift
import Foundation
import SQLiteData

/// A single chat message row. `peerHex` is the other party's lxmf.delivery hash (hex);
/// `messageHash` is the LXMessage.hash (hex) — correlates deliveryFailed for outgoing rows and is
/// the reaction target for all rows.
///
/// The optional fields after `messageHash` are debugging metadata for the Info sheet, added by the
/// `addMessageInfo` migration. Rows stored before it read back `nil` for all of them.
@Table
public struct Message: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var peerHex: String
    public var isOutgoing: Bool
    public var body: String
    public var timestamp: Date
    public var status: String        // MessageStatus.*
    public var validated: Bool       // incoming: signature validated
    public var messageHash: String   // LXMessage.hash hex ("" for incoming rows stored before reactions shipped)

    /// The LXMF timestamp: the sender's clock for incoming rows, the send time for outgoing rows.
    public var senderTimestamp: Date?
    /// Incoming only: ArrivalMethod.*
    public var arrivalMethod: String?
    /// Outgoing only: a propagation node was configured at send, so a PN copy was also sent.
    public var sentViaPropagation: Bool?
    /// Outgoing only: the FIRST time each milestone happened. Never overwritten.
    public var storedAt: Date?
    public var deliveredAt: Date?
    public var failedAt: Date?
    /// Bytes on the wire (incoming: as received; outgoing: as packed before stamping).
    public var wireSize: Int?
    public var titleSize: Int?
    public var contentSize: Int?
    /// Lowercase two-digit hex LXMF field keys in wire order, e.g. "0x02,0xfb". "" when none.
    public var fieldKeys: String?
    /// Incoming only: StampState.*
    public var stampState: String?

    public init(
        id: UUID,
        peerHex: String,
        isOutgoing: Bool,
        body: String,
        timestamp: Date,
        status: String,
        validated: Bool,
        messageHash: String,
        senderTimestamp: Date? = nil,
        arrivalMethod: String? = nil,
        sentViaPropagation: Bool? = nil,
        storedAt: Date? = nil,
        deliveredAt: Date? = nil,
        failedAt: Date? = nil,
        wireSize: Int? = nil,
        titleSize: Int? = nil,
        contentSize: Int? = nil,
        fieldKeys: String? = nil,
        stampState: String? = nil
    ) {
        self.id = id
        self.peerHex = peerHex
        self.isOutgoing = isOutgoing
        self.body = body
        self.timestamp = timestamp
        self.status = status
        self.validated = validated
        self.messageHash = messageHash
        self.senderTimestamp = senderTimestamp
        self.arrivalMethod = arrivalMethod
        self.sentViaPropagation = sentViaPropagation
        self.storedAt = storedAt
        self.deliveredAt = deliveredAt
        self.failedAt = failedAt
        self.wireSize = wireSize
        self.titleSize = titleSize
        self.contentSize = contentSize
        self.fieldKeys = fieldKeys
        self.stampState = stampState
    }
}

public enum MessageStatus {
    public static let sending = "sending"
    public static let sent = "sent"
    public static let failed = "failed"
    public static let received = "received"
    public static let propagated = "stored"
    /// The recipient proved receipt (`deliveryConfirmed`). Beats "stored": a delivered row is
    /// never downgraded by a later `propagationAccepted` or `deliveryFailed`.
    public static let delivered = "delivered"
}

/// How an incoming message reached us (`Message.arrivalMethod`), from ReTiCA's
/// `LXMFRouter.DeliveryMethod`.
public enum ArrivalMethod {
    public static let opportunistic = "opportunistic"
    public static let direct = "direct"
    public static let propagated = "propagated"
}

/// The delivery-stamp state of an incoming message (`Message.stampState`), from `LXMessage`'s
/// `stamp` / `stampChecked` / `stampValid`.
public enum StampState {
    /// No stamp was attached.
    public static let none = "none"
    /// A stamp was attached but no stamp cost is configured, so it was never checked.
    public static let unchecked = "unchecked"
    public static let valid = "valid"
    public static let invalid = "invalid"
}
```

- [ ] **Step 4: Add the migration**

In `Database.swift`, insert this between the closing `}` of the `createReactions` migration (line 86) and `return m` (line 87):

```swift
        m.registerMigration("addMessageInfo") { db in
            // Debugging metadata for the message Info sheet. Every column is nullable: rows stored
            // before this migration read back NULL, which the sheet shows as "—".
            try db.alter(table: "messages") { t in
                t.add(column: "senderTimestamp", .datetime)
                t.add(column: "arrivalMethod", .text)
                t.add(column: "sentViaPropagation", .boolean)
                t.add(column: "storedAt", .datetime)
                t.add(column: "deliveredAt", .datetime)
                t.add(column: "failedAt", .datetime)
                t.add(column: "wireSize", .integer)
                t.add(column: "titleSize", .integer)
                t.add(column: "contentSize", .integer)
                t.add(column: "fieldKeys", .text)
                t.add(column: "stampState", .text)
            }
        }
```

Also update the doc comment on `migrator()` (line 6) to: `/// GRDB migrator for the app's tables. Migrations are append-only: never edit a shipped one.`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter infoMigration`
Expected: 2 tests pass.

- [ ] **Step 6: Mutation check**

Apply both mutations together:
- **M1** (`Database.swift`, the migration): `t.add(column: "wireSize", .integer)` becomes `t.add(column: "wireSize", .integer).defaults(to: 0)`. This reddens `infoMigrationLegacyRowReadsBackWithNilMetadata`, because the legacy row reads `wireSize == 0`.
- **M2** (`Message.swift`, the init): `self.wireSize = wireSize` becomes `self.wireSize = nil`. This reddens `infoMigrationRoundTripsEveryMetadataColumn`, because `back.wireSize == 412` fails.

The two don't mask each other:
- M1 does not affect the round trip, which inserts 412 explicitly.
- M2 does not affect the legacy test, which expects nil anyway.

Run the filter and confirm both tests are red. Revert both by hand. Run `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info diff` and confirm that no mutation text remains.

- [ ] **Step 7: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore`
Expected: 168 tests pass (166 + 2), with 0 known issues.

- [ ] **Step 8: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Message.swift ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Database.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DatabaseTests.swift
```

Write `/tmp/ReTiCAMsgr/commit-msg.txt` with the Write tool (overwrite it):

```
feat: add message Info metadata columns

The addMessageInfo migration adds nullable columns to messages for the Info
sheet: sender timestamp, arrival method, propagation copy, milestone times,
sizes, field keys and stamp state. Legacy rows read back nil.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Then run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info commit -F /tmp/ReTiCAMsgr/commit-msg.txt`

---

### Task 2: Standard-format reaction codec (`FIELD_REACTION` 0x40)

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReactionWire.swift:1-50` (the `ReactionWire` enum. Leave `QuickReactions` unchanged.)
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReactionWireTests.swift`
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` (append after the last test, `closeConversationClearsReactions`, at line 2226)

**Interfaces:**
- Consumes: `MsgPackValue` (`.intMap`, `.bin`, `.map`, `.string`) and `MsgPackValue.IntPair(_ key: Int, _ value:)`.
- Produces:
  - Constants: `ReactionWire.fieldReaction = 0x40`, `ReactionWire.reactionTo = 0x00`, `ReactionWire.reactionContent = 0x01`.
  - `ReactionWire.encode(target: Data, emoji: String) -> [MsgPackValue.IntPair]`. The signature is unchanged; it now emits `[.init(0x40, .intMap([.init(0x00, .bin(target)), .init(0x01, .bin(Data(emoji.utf8)))]))]`.
  - `ReactionWire.decode(_:) -> Decoded`. The signature is unchanged and the cases are the same (`.notReaction`, `.reaction(target:emoji:)`, `.malformed`). It accepts both formats.
  - The reducer (`AppFeature` `reactionSelected` / `messageReceived`) is not changed. It already calls `encode`/`decode`.

**How the decoder resolves the formats.** The spec says "A well-formed 0x40 is tried first, then the legacy 0xFB format" and also "a 0x40 present but malformed is dropped". Together they mean:
1. A well-formed 0x40 gives `.reaction`.
2. Otherwise the legacy decoder runs. A legacy `.reaction` or `.malformed` is returned as is.
3. If the legacy result is `.notReaction` but a 0x40 field was present, the result is `.malformed` (dropped, never a bubble).
4. If neither format is present, the result is `.notReaction`.

- [ ] **Step 1: Write the failing codec tests**

Append to `ReactionWireTests.swift`:

```swift
// MARK: - Standard FIELD_REACTION (0x40), spec addendum 2026-09-27

/// The shipped-on-2026-09-25 legacy format, built by hand now that `encode` no longer emits it.
private func legacyFields(target: Data, emoji: String) -> [MsgPackValue.IntPair] {
    [
        .init(0xFB, .string("reticamsgr.reaction")),
        .init(0xFC, .map([.init("target", .bin(target)), .init("emoji", .string(emoji))])),
    ]
}

private func standardField(_ payload: MsgPackValue) -> [MsgPackValue.IntPair] {
    [.init(0x40, payload)]
}

private func standardPayload(target: Data, content: Data) -> MsgPackValue {
    .intMap([.init(0x00, .bin(target)), .init(0x01, .bin(content))])
}

@Test func stdReactionEncodeEmitsOnlyTheStandardField() {
    #expect(ReactionWire.fieldReaction == 0x40)
    #expect(ReactionWire.reactionTo == 0x00)
    #expect(ReactionWire.reactionContent == 0x01)
    #expect(ReactionWire.encode(target: target32, emoji: "❤️")
            == standardField(standardPayload(target: target32, content: Data("❤️".utf8))))
}

@Test func stdReactionRoundTripsThroughRealLXMessageIncludingRemoval() throws {
    for emoji in ["❤️", ""] {
        let m = LXMessage.create(
            source: Identity(),
            destinationHash: Data(repeating: 0x11, count: 16),
            timestamp: 1700000000.25,
            title: Data(),
            content: Data(),
            fields: ReactionWire.encode(target: target32, emoji: emoji)
        )
        let back = try #require(LXMessage.unpack(m.packed))
        #expect(back.fields.map(\.key) == [0x40], "emoji \(emoji.isEmpty ? "<removal>" : emoji)")
        #expect(ReactionWire.decode(back.fields) == .reaction(target: target32, emoji: emoji))
    }
}

@Test func stdReactionLegacyFormatStillDecodes() {
    #expect(ReactionWire.decode(legacyFields(target: target32, emoji: "👍"))
            == .reaction(target: target32, emoji: "👍"))
}

@Test func stdReactionStandardWinsWhenBothFormatsPresent() {
    // Legacy first in wire order, so "first field wins" would pick the wrong one.
    let fields = legacyFields(target: target32, emoji: "👍")
        + standardField(standardPayload(target: target32, content: Data("❤️".utf8)))
    #expect(ReactionWire.decode(fields) == .reaction(target: target32, emoji: "❤️"))
}

/// Every malformed shape listed in the spec addendum is dropped (`.malformed`), never a bubble.
@Test func stdReactionMalformedStandardCasesAreDropped() {
    let heart = Data("❤️".utf8)
    let cases: [(String, MsgPackValue)] = [
        ("string-keyed map", .map([.init("to", .bin(target32)), .init("content", .bin(heart))])),
        ("empty map", .map([])),
        ("not a map", .bin(target32)),
        ("0x00 missing", .intMap([.init(0x01, .bin(heart))])),
        ("0x00 not bin", .intMap([.init(0x00, .string("abc")), .init(0x01, .bin(heart))])),
        ("0x00 empty", standardPayload(target: Data(), content: heart)),
        ("0x00 15 bytes", standardPayload(target: Data(repeating: 1, count: 15), content: heart)),
        ("0x00 33 bytes", standardPayload(target: Data(repeating: 1, count: 33), content: heart)),
        ("0x01 missing", .intMap([.init(0x00, .bin(target32))])),
        ("0x01 not bin", .intMap([.init(0x00, .bin(target32)), .init(0x01, .string("❤️"))])),
        ("0x01 over 64 bytes", standardPayload(target: target32,
                                               content: Data(repeating: 0x61, count: ReactionWire.maxEmojiBytes + 1))),
        ("0x01 invalid UTF-8", standardPayload(target: target32, content: Data([0xFF, 0xFE, 0xFD]))),
    ]
    for (name, payload) in cases {
        #expect(ReactionWire.decode(standardField(payload)) == .malformed, "\(name)")
    }
}

@Test func stdReactionBoundaryValuesAreAccepted() {
    for n in [16, 32] {
        let target = Data(repeating: 7, count: n)
        #expect(ReactionWire.decode(standardField(standardPayload(target: target, content: Data("👍".utf8))))
                == .reaction(target: target, emoji: "👍"), "target length \(n)")
    }
    let atLimit = String(repeating: "a", count: ReactionWire.maxEmojiBytes)
    #expect(ReactionWire.decode(standardField(standardPayload(target: target32, content: Data(atLimit.utf8))))
            == .reaction(target: target32, emoji: atLimit))
    #expect(ReactionWire.decode(standardField(standardPayload(target: target32, content: Data())))
            == .reaction(target: target32, emoji: ""))
}

/// Review Focus 2: a mixed-version sender with a broken 0x40 beside a good legacy reaction.
@Test func stdReactionMalformedStandardFallsBackToValidLegacy() {
    let fields = standardField(.intMap([.init(0x00, .bin(Data(repeating: 1, count: 3)))]))
        + legacyFields(target: target32, emoji: "😮")
    #expect(ReactionWire.decode(fields) == .reaction(target: target32, emoji: "😮"))
}
```

- [ ] **Step 2: Write the failing reducer tests**

Append to the end of `AppFeatureTests.swift`:

```swift
// MARK: - Reactions: standard FIELD_REACTION (0x40)

@MainActor @Test func stdReactionWithFallbackContentIsNotABubble() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let target = Data(repeating: 0x43, count: 32)
    let store = makeStore(db, identity: me)
    // Built by hand, not via ReactionWire.encode, so this pins the wire shape a foreign client sends.
    let m = LXMessage.create(
        source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1700000001, title: Data(), content: Data("Reacted ❤️ to a message".utf8),
        fields: [.init(0x40, .intMap([.init(0x00, .bin(target)), .init(0x01, .bin(Data("❤️".utf8)))]))]
    )
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions == [Reaction(messageHash: target.hexString, reactorHex: senderHex, emoji: "❤️", sentAt: 1700000001)])
}

@MainActor @Test func stdReactionMalformedIsDroppedNotABubble() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me)
    let m = LXMessage.create(
        source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1, title: Data(), content: Data("fallback text".utf8),
        fields: [.init(0x40, .intMap([.init(0x00, .bin(Data(repeating: 1, count: 8))),
                                      .init(0x01, .bin(Data("❤️".utf8)))]))]
    )
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    let seen = try! await db.read { try SeenHashRow.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions.isEmpty)
    #expect(seen.count == 1)
}

@MainActor @Test func stdReactionSelectedSendsTheStandardFormat() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    var fields: [MsgPackValue.IntPair]?
    await store.receive { action in
        if case let .node(.client(.sendMessage(sent, _))) = action { fields = sent.fields; return true }
        return false
    }
    #expect(fields == [.init(0x40, .intMap([.init(0x00, .bin(Data(hexString: hash)!)),
                                            .init(0x01, .bin(Data("❤️".utf8)))]))])
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter stdReaction`
Expected: a compile failure, because `ReactionWire.fieldReaction` is undefined. If you temporarily comment out the constant checks, the remaining tests run red: encode still emits 0xFB/0xFC and decode ignores 0x40.

- [ ] **Step 4: Implement the codec**

Replace lines 1–50 of `ReactionWire.swift` (everything above `public enum QuickReactions`) with:

```swift
import Foundation
import ReTiCA

/// Wire codec for an emoji reaction carried in LXMF `fields`.
///
/// **Sent** in the standard LXMF 1.1.0 format (`LXMF/LXMF.py:25,109-110`): `FIELD_REACTION` (0x40)
/// holds an int-keyed map with `REACTION_TO` (0x00) = the target's full `LXMessage.hash` as bin,
/// and `REACTION_CONTENT` (0x01) = the reaction as UTF-8 bin. The standard defines no removal, so
/// by our convention **empty `REACTION_CONTENT` means "I removed my reaction"**.
///
/// **Received** in either format. A well-formed 0x40 wins. Otherwise the legacy format this app
/// shipped on 2026-09-25 is tried: `FIELD_CUSTOM_TYPE` (0xFB) = "reticamsgr.reaction" and
/// `FIELD_CUSTOM_DATA` (0xFC) = `{ "target": bin, "emoji": str }`. A 0x40 field that is present
/// but unusable, with no usable legacy reaction beside it, is `.malformed` and dropped.
///
/// A message that decodes as a reaction is a reaction whatever its `content`, so a human-readable
/// fallback in `content` never renders as a bubble in this app.
public enum ReactionWire {
    public static let fieldReaction = 0x40
    public static let reactionTo = 0x00
    public static let reactionContent = 0x01
    public static let fieldCustomType = 0xFB
    public static let fieldCustomData = 0xFC
    public static let customType = "reticamsgr.reaction"
    /// Upper bound on the emoji's UTF-8 size. Generous enough for any ZWJ sequence with skin
    /// tones; small enough that a peer can't stuff a paragraph into a badge.
    public static let maxEmojiBytes = 64
    public static let targetLengths = 16...32

    public enum Decoded: Equatable, Sendable {
        /// Neither reaction format — handle as an ordinary message.
        case notReaction
        case reaction(target: Data, emoji: String)
        /// Claims to be a reaction but the payload is unusable — drop it.
        case malformed
    }

    public static func encode(target: Data, emoji: String) -> [MsgPackValue.IntPair] {
        [
            .init(fieldReaction, .intMap([
                .init(reactionTo, .bin(target)),
                .init(reactionContent, .bin(Data(emoji.utf8))),
            ])),
        ]
    }

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded {
        let standard = fields.first(where: { $0.key == fieldReaction })?.value
        if let standard, let reaction = decodeStandard(standard) {
            return .reaction(target: reaction.target, emoji: reaction.emoji)
        }
        let legacy = decodeLegacy(fields)
        if case .notReaction = legacy, standard != nil { return .malformed }
        return legacy
    }

    /// `nil` when the 0x40 payload is unusable.
    private static func decodeStandard(_ value: MsgPackValue) -> (target: Data, emoji: String)? {
        guard case let .intMap(pairs) = value,
              case let .bin(target)? = pairs.first(where: { $0.key == reactionTo })?.value,
              targetLengths.contains(target.count),
              case let .bin(content)? = pairs.first(where: { $0.key == reactionContent })?.value,
              content.count <= maxEmojiBytes
        else { return nil }
        // Strict UTF-8: `String(decoding:)` repairs invalid bytes with U+FFFD, so the bytes are
        // valid exactly when they survive a round trip unchanged.
        let emoji = String(decoding: content, as: UTF8.self)
        guard Data(emoji.utf8) == content else { return nil }
        return (target, emoji)
    }

    /// The 2026-09-25 format. Kept so reactions from builds that predate the addendum still work.
    private static func decodeLegacy(_ fields: [MsgPackValue.IntPair]) -> Decoded {
        guard case .string(customType)? = fields.first(where: { $0.key == fieldCustomType })?.value else {
            return .notReaction
        }
        guard case let .map(pairs)? = fields.first(where: { $0.key == fieldCustomData })?.value,
              case let .bin(target)? = pairs.first(where: { $0.key == "target" })?.value,
              targetLengths.contains(target.count),
              case let .string(emoji)? = pairs.first(where: { $0.key == "emoji" })?.value,
              emoji.utf8.count <= maxEmojiBytes
        else { return .malformed }
        return .reaction(target: target, emoji: emoji)
    }
}
```

The existing tests need no code change. Those that build fields with `ReactionWire.encode` now exercise the standard format:
- `reactionRoundTripsThroughRealLXMessagePackUnpack`
- `emptyEmojiRoundTripsAsRemoval`
- `badTargetLengthsAreMalformed`
- `oversizedEmojiIsMalformed`
- `unpackedHashEqualsSenderHashWithReactionFields`
- In `AppFeatureTests`, everything that goes through `reactionMessage` / `sentReaction`

Those that build 0xFB by hand keep covering the legacy path:
- `missingDataIsMalformed`
- `missingTargetIsMalformed`
- `nonStringEmojiIsMalformed`
- `otherCustomTypeIsNotAReaction`
- `malformedReactionIsDroppedNotABubble`

The one required edit: change the comment line above `reactionMessage` in `AppFeatureTests.swift` (line 1994, `// MARK: - Reactions: receive path`) to `// MARK: - Reactions: receive path (ReactionWire.encode = standard 0x40 format)`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter stdReaction`
Expected: 10 tests pass.

- [ ] **Step 6: Mutation check**

Apply all four mutations to `ReactionWire.swift` together:
- **M1** (`encode`): `.init(reactionContent, .bin(Data(emoji.utf8)))` becomes `.init(reactionContent, .string(emoji))`.
- **M2** (`decode`): `let legacy = decodeLegacy(fields)` becomes `let legacy: Decoded = .notReaction`.
- **M3** (`decodeStandard`): `targetLengths.contains(target.count),` becomes `!targetLengths.contains(target.count),`.
- **M4** (`decode`): `if case .notReaction = legacy, standard != nil { return .malformed }` becomes `if case .notReaction = legacy, standard != nil { return .notReaction }`.

Expected reds, all 10:

| Test | Reddened by | What happens |
|---|---|---|
| `stdReactionEncodeEmitsOnlyTheStandardField` | M1 | Literal mismatch |
| `stdReactionRoundTripsThroughRealLXMessageIncludingRemoval` | M1, M3 | The content is not bin, or the target length is rejected |
| `stdReactionLegacyFormatStillDecodes` | M2 | Result is `.notReaction` |
| `stdReactionStandardWinsWhenBothFormatsPresent` | M3 | The standard is rejected and the answer is not ❤️ |
| `stdReactionMalformedStandardCasesAreDropped` | M4 | Results are `.notReaction`, and M3 turns the bad-length cases into reactions |
| `stdReactionBoundaryValuesAreAccepted` | M3 | The 16- and 32-byte targets are rejected |
| `stdReactionMalformedStandardFallsBackToValidLegacy` | M2 | The legacy reaction is not found |
| `stdReactionWithFallbackContentIsNotABubble` | M3 + M4 | The message becomes a bubble |
| `stdReactionMalformedIsDroppedNotABubble` | M4, M3 | M4 makes it a bubble. M3 makes the 8-byte target valid, so a Reaction row appears. `reactions.isEmpty` is asserted precisely so that M3 cannot mask M4 here |
| `stdReactionSelectedSendsTheStandardFormat` | M1 | The field literal does not match |

Several pre-existing reaction tests also go red under this batch, which is expected. None of the mutations crashes.

Run the filter and confirm all 10 are red. Revert by hand. Run `git diff` and confirm no mutation text remains.

- [ ] **Step 7: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore`
Expected: 178 tests pass, with 0 known issues.

- [ ] **Step 8: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReactionWire.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReactionWireTests.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift
```

Write `/tmp/ReTiCAMsgr/commit-msg.txt` (overwrite it):

```
feat: send reactions as standard LXMF FIELD_REACTION

Reactions are now sent as field 0x40 with REACTION_TO and REACTION_CONTENT
bins, and removal is empty content. The legacy 0xFB/0xFC format still
decodes. A well-formed 0x40 wins, and a malformed one is dropped unless a
valid legacy reaction sits beside it.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Then run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info commit -F /tmp/ReTiCAMsgr/commit-msg.txt`

---

### Task 3: Receive-path metadata

**Files:**
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/MessageMetadata.swift`
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift:605` (the `messageReceived` case pattern) and `:657-666` (the `Message(` insert)
- Create: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/MessageMetadataTests.swift`
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` (append at the end)

**Interfaces:**
- Consumes: the `Message` init parameters from Task 1, `ArrivalMethod.*` and `StampState.*`.
- Produces (internal, visible to tests through `@testable`): `enum MessageMetadata` with:
  - `static let maxSenderTimestamp: Double = 253_402_300_799`
  - `static func senderTimestamp(_ t: Double) -> Date?`
  - `static func arrivalMethod(_ method: LXMFRouter.DeliveryMethod) -> String`
  - `static func stampState(_ message: LXMessage) -> String`
  - `static func fieldKeys(_ fields: [MsgPackValue.IntPair]) -> String`
- Task 4 uses `MessageMetadata.fieldKeys`.

**Ambiguities this task resolves:**
- **`stampState` when `stamp == nil`.** The result is always `"none"`, even if validation ran. ReTiCA reports a missing stamp under a configured cost as checked-and-invalid, but "there was no stamp" is the more useful debugging statement.
- **`fieldKeys` padding.** Keys are two-digit lowercase hex, so key 2 is stored as `0x02`, not `0x2`. The existing DIAGNOSTIC log line at `AppFeature.swift:620` uses the unpadded form. Leave that log line alone.
- **Unrepresentable sender timestamps** (Review Focus 1) are stored as `nil`. That covers non-finite values, negative values, and anything after 9999-12-31T23:59:59Z. The message itself is still stored.

- [ ] **Step 1: Write the failing tests**

Create `MessageMetadataTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCAMsgrCore

/// Review Focus 1: a peer's clock can say anything. Only values that store and read back as a
/// Date are kept. Everything else becomes nil ("—" in Info) instead of poisoning the row.
@Test func infoReceiveSenderTimestampRejectsUnrepresentableValues() {
    #expect(MessageMetadata.senderTimestamp(1700000000.5) == Date(timeIntervalSince1970: 1700000000.5))
    #expect(MessageMetadata.senderTimestamp(0) == Date(timeIntervalSince1970: 0))
    #expect(MessageMetadata.senderTimestamp(253_402_300_799) == Date(timeIntervalSince1970: 253_402_300_799))
    #expect(MessageMetadata.senderTimestamp(253_402_300_800) == nil)
    #expect(MessageMetadata.senderTimestamp(1e18) == nil)
    #expect(MessageMetadata.senderTimestamp(-1) == nil)
    #expect(MessageMetadata.senderTimestamp(.nan) == nil)
    #expect(MessageMetadata.senderTimestamp(.infinity) == nil)
}
```

Append to the end of `AppFeatureTests.swift`:

```swift
// MARK: - Message Info: receive path

/// An incoming message exactly as it arrives off the wire. It is packed then unpacked, so
/// `receivedBytes` is set as in production.
private func wireMessage(from sender: Identity, to me: Identity, at ts: Double, title: String = "",
                         content: String = "hi", fields: [MsgPackValue.IntPair] = []) -> LXMessage {
    let built = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                 timestamp: ts, title: Data(title.utf8), content: Data(content.utf8),
                                 fields: fields)
    return LXMessage.unpack(built.packed)!
}

/// Deliver one message to a fresh store and database, and return every stored row once all
/// effects have finished. The read uses `try?` so that a broken row fails an expectation instead
/// of trapping the test process.
@MainActor
private func receiveAndFetch(_ m: LXMessage, me: Identity,
                             method: LXMFRouter.DeliveryMethod = .opportunistic) async -> [Message] {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: me)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: method)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    return (try? await db.read { try Message.all.fetchAll($0) }) ?? []
}

@MainActor @Test func infoReceiveStoresSenderTimestampSizesAndEmptyFieldKeys() async throws {
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me, at: 1699999900.5, title: "T", content: "hello")
    let rows = await receiveAndFetch(m, me: me)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.senderTimestamp == Date(timeIntervalSince1970: 1699999900.5))
    #expect(row.timestamp == Date(timeIntervalSince1970: 1700000000))   // still our clock
    #expect(row.wireSize != nil)
    #expect(row.wireSize == m.receivedBytes?.count)
    #expect(row.titleSize == 1)
    #expect(row.contentSize == 5)
    #expect(row.fieldKeys == "")
    #expect(row.stampState == StampState.none)
    #expect(row.sentViaPropagation == nil)
    #expect(row.storedAt == nil)
    #expect(row.deliveredAt == nil)
    #expect(row.failedAt == nil)
}

@MainActor @Test func infoReceiveRecordsEachArrivalMethod() async {
    let me = Identity()
    let cases: [(LXMFRouter.DeliveryMethod, String)] = [
        (.opportunistic, ArrivalMethod.opportunistic),
        (.direct, ArrivalMethod.direct),
        (.propagated, ArrivalMethod.propagated),
    ]
    for (method, expected) in cases {
        let rows = await receiveAndFetch(wireMessage(from: Identity(), to: me, at: 1699999999), me: me, method: method)
        #expect(rows.map(\.arrivalMethod) == [expected], "\(method)")
    }
}

@MainActor @Test func infoReceiveRecordsFieldKeysInWireOrder() async {
    let me = Identity()
    // 0xFB first, so a sorted encoding would differ. A foreign custom type is not a reaction.
    let m = wireMessage(from: Identity(), to: me, at: 1699999999, fields: [
        .init(0xFB, .string("someone.else")),
        .init(0x02, .bin(Data([1]))),
    ])
    let rows = await receiveAndFetch(m, me: me)
    #expect(rows.map(\.fieldKeys) == ["0xfb,0x02"])
}

@MainActor @Test func infoReceiveRecordsStampState() async {
    let me = Identity()
    let sender = Identity()
    let stamp = Data(repeating: 0xFF, count: LXStamper.stampSize)
    let plain = wireMessage(from: sender, to: me, at: 1699999999, content: "none")
    let stampedBuilt = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                        timestamp: 1699999999, title: Data(), content: Data("stamped".utf8))
    let stamped = LXMessage.unpack(stampedBuilt.withStamp(stamp).packed)!
    let cases: [(LXMessage, String)] = [
        (plain, StampState.none),
        (stamped, StampState.unchecked),
        (stamped.withStampValidation(valid: true), StampState.valid),
        (stamped.withStampValidation(valid: false), StampState.invalid),
    ]
    for (m, expected) in cases {
        let rows = await receiveAndFetch(m, me: me)
        #expect(rows.map(\.stampState) == [expected], "\(expected)")
    }
}

@MainActor @Test func infoReceiveReactionStillCreatesNoRow() async {
    let me = Identity()
    let m = reactionMessage(from: Identity(), to: me, target: Data(repeating: 9, count: 32), emoji: "👍",
                            at: 1700000001)
    let rows = await receiveAndFetch(LXMessage.unpack(m.packed)!, me: me)
    #expect(rows.isEmpty)
}

/// Review Focus 1, end to end: a broken sender clock still produces a bubble that loads.
@MainActor @Test func infoReceiveOutOfRangeSenderTimestampStillStoresTheMessage() async {
    let me = Identity()
    let rows = await receiveAndFetch(wireMessage(from: Identity(), to: me, at: 1e18, content: "broken clock"), me: me)
    #expect(rows.map(\.body) == ["broken clock"])
    #expect(rows.first?.senderTimestamp == nil)
}
```

`reactionMessage` is the existing private helper at `AppFeatureTests.swift:1996`. Since Task 2 it builds the standard format.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter infoReceive`
Expected: a compile failure, because `MessageMetadata` is undefined.

- [ ] **Step 3: Create `MessageMetadata.swift`**

```swift
import Foundation
import ReTiCA
import ReTiCANode

/// Maps ReTiCA's view of a message onto the strings stored in `messages` for the Info sheet.
/// Pure. `AppFeature` calls these while building the row it inserts.
enum MessageMetadata {
    /// 9999-12-31T23:59:59Z, the last instant the ISO-8601 text column can hold.
    static let maxSenderTimestamp: Double = 253_402_300_799

    /// The sender's LXMF timestamp as a Date, or nil when a peer's clock produced a value that
    /// cannot be stored and read back (non-finite, before 1970, or after year 9999).
    static func senderTimestamp(_ t: Double) -> Date? {
        guard t.isFinite, (0...maxSenderTimestamp).contains(t) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func arrivalMethod(_ method: LXMFRouter.DeliveryMethod) -> String {
        switch method {
        case .opportunistic: return ArrivalMethod.opportunistic
        case .direct: return ArrivalMethod.direct
        case .propagated: return ArrivalMethod.propagated
        }
    }

    /// No stamp is "none" even when validation ran. ReTiCA reports a missing stamp under a
    /// configured cost as checked-and-invalid, but "there was no stamp" says more when debugging.
    static func stampState(_ message: LXMessage) -> String {
        guard message.stamp != nil else { return StampState.none }
        guard message.stampChecked else { return StampState.unchecked }
        return message.stampValid ? StampState.valid : StampState.invalid
    }

    /// Lowercase two-digit hex keys in wire order, e.g. "0x02,0xfb". "" when there are none.
    static func fieldKeys(_ fields: [MsgPackValue.IntPair]) -> String {
        fields.map { pair in
            let hex = String(pair.key, radix: 16)
            return "0x" + (hex.count < 2 ? "0" + hex : hex)
        }.joined(separator: ",")
    }
}
```

- [ ] **Step 4: Fill the receive insert in `AppFeature.swift`**

Line 605. Replace

```swift
            case let .node(.client(.delegate(.messageReceived(m, validated, _)))):   // arrival method unused for now
```

with

```swift
            case let .node(.client(.delegate(.messageReceived(m, validated, method)))):
```

Lines 657–666. Replace the `let row = Message(...)` block with:

```swift
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
                    stampState: MessageMetadata.stampState(m)
                )
```

Do not touch the DIAGNOSTIC block (lines 607–629) or its local `fieldKeys` constant. The new code calls `MessageMetadata.fieldKeys(...)` explicitly, so the names don't clash. Reaction messages still `return` from the `switch ReactionWire.decode(m.fields)` above this point, so they never reach the insert.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter infoReceive`
Expected: 7 tests pass.

- [ ] **Step 6: Mutation check**

Apply all six mutations together:
- **M1** (`AppFeature.swift` insert): `senderTimestamp: MessageMetadata.senderTimestamp(m.timestamp),` becomes `senderTimestamp: seenNow,`. This reddens `infoReceiveStoresSenderTimestampSizesAndEmptyFieldKeys` and `infoReceiveOutOfRangeSenderTimestampStillStoresTheMessage`.
- **M2** (`MessageMetadata.arrivalMethod`): `case .direct: return ArrivalMethod.direct` becomes `case .direct: return ArrivalMethod.propagated`. This reddens `infoReceiveRecordsEachArrivalMethod`.
- **M3** (`MessageMetadata.fieldKeys`): `fields.map { pair in` becomes `fields.sorted { $0.key < $1.key }.map { pair in`. This reddens `infoReceiveRecordsFieldKeysInWireOrder` (`"0x02,0xfb"`).
- **M4** (`MessageMetadata.stampState`): `guard message.stampChecked else` becomes `guard !message.stampChecked else`. This reddens `infoReceiveRecordsStampState`.
- **M5** (`AppFeature.swift`): `switch ReactionWire.decode(m.fields) {` becomes `switch ReactionWire.Decoded.notReaction {`. Every message becomes a bubble, which reddens `infoReceiveReactionStillCreatesNoRow`.
- **M6** (`MessageMetadata.senderTimestamp`): `guard t.isFinite, (0...maxSenderTimestamp).contains(t) else` becomes `guard t.isFinite else`. This reddens `infoReceiveSenderTimestampRejectsUnrepresentableValues`, because `1e18` and `-1` become non-nil.

No masking and no crash:
- M5 does not change the other tests, which send non-reaction messages.
- M1 bypasses M6 on the receive path, so no out-of-range Date is ever written to the database.
- M6 only affects the pure test, which never formats the Date.

Run the filter and confirm all 7 are red. Revert by hand. Run `git diff` and confirm no mutation text remains.

- [ ] **Step 7: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore`
Expected: 185 tests pass, with 0 known issues.

- [ ] **Step 8: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/MessageMetadata.swift ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/MessageMetadataTests.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift
```

Write `/tmp/ReTiCAMsgr/commit-msg.txt` (overwrite it):

```
feat: record Info metadata for incoming messages

Incoming text rows now store the sender timestamp, arrival method, wire,
title and content sizes, field keys in wire order and the stamp state. A
sender timestamp that cannot be stored becomes nil so the row still loads.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Then run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info commit -F /tmp/ReTiCAMsgr/commit-msg.txt`

---

### Task 4: Send-path metadata

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift` in the `case .sendTapped:` body, lines 486–519 before Task 3. Task 3 did not touch this region, but search for `case .sendTapped:` rather than trusting the line numbers.
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` (append at the end)

**Interfaces:**
- Consumes: `MessageMetadata.fieldKeys(_:)` (Task 3) and the `Message` init parameters (Task 1).
- Produces: outgoing rows with these values:
  - `senderTimestamp == timestamp`
  - `sentViaPropagation = !propagationNodeHex.isEmpty`
  - `wireSize = msg.packed.count`
  - `titleSize`, `contentSize`
  - `fieldKeys = ""` for text sends
  - `arrivalMethod` and `stampState` stay nil

- [ ] **Step 1: Write the failing tests**

Append to `AppFeatureTests.swift`:

```swift
// MARK: - Message Info: send path

/// Send "hello" and return the LXMessage handed to the node plus the stored row. The test waits for
/// `conversationsLoaded`, the last action of the send saga, so the insert has happened. It does not
/// call `finish()`: `sendMessage` starts node effects that are not this test's business.
@MainActor
private func sendAndFetch(propagationNode: String) async -> (LXMessage?, Message?) {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "hello"
        s.$propagationNodeHex.withLock { $0 = propagationNode }
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let row = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }.first
    return (sent, row)
}

@MainActor @Test func infoSendStoresSizesFieldKeysAndSendTime() async throws {
    let (sent, row) = await sendAndFetch(propagationNode: "")
    let wire = try #require(sent)
    let stored = try #require(row)
    #expect(stored.senderTimestamp == Date(timeIntervalSince1970: 1700000000))
    #expect(stored.senderTimestamp == stored.timestamp)
    #expect(stored.wireSize == wire.packed.count)
    #expect(stored.titleSize == 0)
    #expect(stored.contentSize == 5)
    #expect(stored.fieldKeys == "")
    #expect(stored.sentViaPropagation == false)
    #expect(stored.arrivalMethod == nil)
    #expect(stored.stampState == nil)
}

@MainActor @Test func infoSendRecordsPropagationNodeCopy() async throws {
    let (_, row) = await sendAndFetch(propagationNode: String(repeating: "c", count: 32))
    #expect(try #require(row).sentViaPropagation == true)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter infoSend`
Expected: both tests FAIL. `senderTimestamp`, `wireSize` and the other metadata fields are nil.

- [ ] **Step 3: Implement**

In `case .sendTapped:`, replace everything from `let title = Data()` down to and including `state.draft = ""` with:

```swift
                let title = Data()
                let content = Data(text.utf8)
                let now = date.now
                let msg = LXMessage.create(
                    source: state.identity,
                    destinationHash: peer,
                    timestamp: now.timeIntervalSince1970,
                    title: title,
                    content: content
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
                    fieldKeys: MessageMetadata.fieldKeys(msg.fields)
                )
                state.draft = ""
```

The following `return .merge(...)` is unchanged. It still uses `alsoViaPropagation`, which is now declared above the row.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter infoSend`
Expected: 2 tests pass.

- [ ] **Step 5: Mutation check**

Apply both mutations together:
- **M1**: `sentViaPropagation: alsoViaPropagation,` becomes `sentViaPropagation: false,`. This reddens `infoSendRecordsPropagationNodeCopy`.
- **M2**: `wireSize: msg.packed.count,` becomes `wireSize: msg.content.count,`. This reddens `infoSendStoresSizesFieldKeysAndSendTime`.

Neither masks the other: M1 leaves the first test's expected `false` intact, and M2 is not asserted by the second test. Neither crashes.

Run the filter and confirm both are red. Revert by hand. Run `git diff` and confirm no mutation text remains.

- [ ] **Step 6: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore`
Expected: 187 tests pass, with 0 known issues.

- [ ] **Step 7: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift
```

Write `/tmp/ReTiCAMsgr/commit-msg.txt` (overwrite it):

```
feat: record Info metadata for outgoing messages

Outgoing rows now store the send time as sender timestamp, whether a
propagation node copy was sent, the packed wire size, title and content
sizes and the field keys.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Then run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info commit -F /tmp/ReTiCAMsgr/commit-msg.txt`

---

### Task 5: Milestone timestamps

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift`, in three handlers:
  - `case let .node(.client(.delegate(.deliveryFailed(hash)))):` (originally line 683)
  - `case let .node(.client(.delegate(.propagationAccepted(hash)))):` (originally line 797)
  - `case let .node(.client(.delegate(.deliveryConfirmed(hash)))):` (originally line 818)

  Tasks 3 and 4 shifted the line numbers, so search for the case patterns.
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` (append at the end)

**Interfaces:**
- Consumes: the `storedAt`, `deliveredAt` and `failedAt` columns (Task 1), and the `\.date` dependency (`date.now`).
- Produces: each handler sets its column on outgoing rows with the hash, only where the column is still NULL. It does this in the same write transaction as the status update, and regardless of the status guards.

**Column typing note:**
- The milestone value is declared `let milestoneAt: Date? = date.now`.
- StructuredQueries' `update` setter takes `any QueryExpression<Date?>` for an optional column. A non-optional `Date` does not type-check.
- If the compiler still objects, write `$0.storedAt = #bind(milestoneAt)`.

- [ ] **Step 1: Write the failing tests**

Append to `AppFeatureTests.swift`:

```swift
// MARK: - Message Info: milestone timestamps

private let infoT0 = Date(timeIntervalSince1970: 1700000000)   // makeStore's frozen \.date

@MainActor
private func sendAndSettle(_ store: TestStoreOf<AppFeature>, _ action: AppFeature.Action) async {
    await store.send(action)
    await store.finish()
}

private func hashData(_ hex: String) -> Data { Data(hexString: hex)! }

private func rowsByHashAndDirection(_ db: any DatabaseWriter) async -> [String: Message] {
    let rows = try! await db.read { try Message.all.fetchAll($0) }
    return Dictionary(uniqueKeysWithValues: rows.map { ("\($0.messageHash)/\($0.isOutgoing ? "out" : "in")", $0) })
}

@MainActor @Test func infoMilestoneFirstEventsSetTheirColumns() async {
    let db = try! AppDatabase.makeInMemory()
    let hD = String(repeating: "31", count: 16)
    let hS = String(repeating: "32", count: 16)
    let hF = String(repeating: "33", count: 16)
    try! await seed(db, [
        msg(1, peerA, "d", 1000, status: MessageStatus.sending, hash: hD),
        msg(2, peerA, "s", 1000, status: MessageStatus.sending, hash: hS),
        msg(3, peerA, "f", 1000, status: MessageStatus.sending, hash: hF),
    ])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(hD))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(hS))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(hF))))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(hD)/out"]?.deliveredAt == infoT0)
    #expect(rows["\(hD)/out"]?.storedAt == nil)
    #expect(rows["\(hD)/out"]?.failedAt == nil)
    #expect(rows["\(hS)/out"]?.storedAt == infoT0)
    #expect(rows["\(hS)/out"]?.deliveredAt == nil)
    #expect(rows["\(hS)/out"]?.failedAt == nil)
    #expect(rows["\(hF)/out"]?.failedAt == infoT0)
    #expect(rows["\(hF)/out"]?.storedAt == nil)
    #expect(rows["\(hF)/out"]?.deliveredAt == nil)
}

@MainActor @Test func infoMilestoneRepeatEventDoesNotMoveTheTime() async {
    let db = try! AppDatabase.makeInMemory()
    let hD = String(repeating: "41", count: 16)
    let hS = String(repeating: "42", count: 16)
    let hF = String(repeating: "43", count: 16)
    try! await seed(db, [
        msg(1, peerA, "d", 1000, status: MessageStatus.sending, hash: hD),
        msg(2, peerA, "s", 1000, status: MessageStatus.sending, hash: hS),
        msg(3, peerA, "f", 1000, status: MessageStatus.sending, hash: hF),
    ])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(hD))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(hS))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(hF))))))
    store.dependencies.date = .constant(infoT0.addingTimeInterval(60))   // the clock moves on
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(hD))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(hS))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(hF))))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(hD)/out"]?.deliveredAt == infoT0)
    #expect(rows["\(hS)/out"]?.storedAt == infoT0)
    #expect(rows["\(hF)/out"]?.failedAt == infoT0)
}

@MainActor @Test func infoMilestoneLateStoredAfterDeliveredIsStillRecorded() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "51", count: 16)
    try! await seed(db, [msg(1, peerA, "x", 1000, status: MessageStatus.delivered, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.delivered)
    #expect(row?.storedAt == infoT0)
}

/// Review Focus 3: the status guard keeps "delivered", but Info still learns the failure time.
@MainActor @Test func infoMilestoneFailureAfterDeliveredKeepsStatusButRecordsTime() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "52", count: 16)
    try! await seed(db, [msg(1, peerA, "x", 1000, status: MessageStatus.delivered, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.delivered)
    #expect(row?.failedAt == infoT0)
}

@MainActor @Test func infoMilestoneFalseFailureThenStoredRecordsBoth() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "53", count: 16)
    try! await seed(db, [msg(1, peerA, "x", 1000, status: MessageStatus.sending, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(h))))))
    store.dependencies.date = .constant(infoT0.addingTimeInterval(45))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.propagated)
    #expect(row?.failedAt == infoT0)
    #expect(row?.storedAt == infoT0.addingTimeInterval(45))
}

@MainActor @Test func infoMilestoneIncomingRowsSharingTheHashAreUntouched() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "54", count: 16)
    try! await seed(db, [
        msg(1, peerA, "out", 1000, outgoing: true, status: MessageStatus.sending, hash: h),
        msg(2, peerA, "in", 1000, outgoing: false, status: MessageStatus.received, hash: h),
    ])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(h))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(h))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(h)/out"]?.failedAt == infoT0)
    #expect(rows["\(h)/out"]?.storedAt == infoT0)
    #expect(rows["\(h)/out"]?.deliveredAt == infoT0)
    #expect(rows["\(h)/in"]?.failedAt == nil)
    #expect(rows["\(h)/in"]?.storedAt == nil)
    #expect(rows["\(h)/in"]?.deliveredAt == nil)
    #expect(rows["\(h)/in"]?.status == MessageStatus.received)
}
```

`msg(...)` is the existing helper at `AppFeatureTests.swift:69`. Its `outgoing` defaults to `true`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter infoMilestone`
Expected: all 6 FAIL, because every milestone column stays nil.

- [ ] **Step 3: Implement the three handlers**

Replace the `deliveryFailed` case body (from `let hex = hash.hexString` through the closing `}` of its `.run`) with:

```swift
                let hex = hash.hexString
                let openPeer = state.openPeerHex
                let milestoneAt: Date? = date.now
                return .run { [database] send in
                    try await database.write { db in
                        // With a PN configured, one message.hash gets two copies: the propagated
                        // copy (`propagationAccepted` → "stored") and the delivery copy
                        // (`deliveryConfirmed` → "delivered"). ReTiCA now proves opportunistic
                        // sends and never reports `deliveryFailed` after either copy succeeded, so
                        // a failure should not reach a stored or delivered row. The status guards
                        // below remain as a defensive check so a success is never clobbered (F5.5).
                        // `messageHash` alone is not unique: an incoming row and an outgoing row can
                        // share a hash (a conversation with your own address), so scope to outgoing
                        // rows only or this would also rewrite the incoming row's status.
                        try Message.where {
                            $0.messageHash.eq(hex)
                                && $0.status.neq(MessageStatus.propagated)
                                && $0.status.neq(MessageStatus.delivered)
                                && $0.isOutgoing
                        }
                            .update { $0.status = MessageStatus.failed }
                            .execute(db)
                        // Info milestone: the FIRST failure time. Recorded even when the guard above
                        // kept the status, and never overwritten by a repeat.
                        try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing && $0.failedAt.is(nil) }
                            .update { $0.failedAt = milestoneAt }
                            .execute(db)
                    }
                    try await reloadConversations(database, send)
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                }
```

Replace the `propagationAccepted` case body with:

```swift
                let hex = hash.hexString
                let openPeer = state.openPeerHex
                let milestoneAt: Date? = date.now
                return .run { [database] send in
                    try await database.write { db in
                        // Same hash-collision hazard as `deliveryFailed` above: scope to outgoing
                        // rows only so an incoming row sharing this hash isn't rewritten.
                        // Delivered beats stored: the propagated copy can be accepted after the
                        // delivery copy was already proved, so leave delivered rows alone.
                        try Message.where {
                            $0.messageHash.eq(hex) && $0.status.neq(MessageStatus.delivered) && $0.isOutgoing
                        }
                            .update { $0.status = MessageStatus.propagated }
                            .execute(db)
                        // Info milestone: the FIRST acceptance time, including a late acceptance
                        // after "delivered" (the status stays delivered, the time is still news).
                        try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing && $0.storedAt.is(nil) }
                            .update { $0.storedAt = milestoneAt }
                            .execute(db)
                    }
                    try await reloadConversations(database, send)
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                }
```

Replace the `deliveryConfirmed` case body, keeping the leading comment lines, with:

```swift
                let hex = hash.hexString
                let openPeer = state.openPeerHex
                let milestoneAt: Date? = date.now
                return .run { [database] send in
                    try await database.write { db in
                        // Same hash-collision hazard as `deliveryFailed` above: scope to outgoing
                        // rows only so an incoming row sharing this hash isn't rewritten.
                        try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing }
                            .update { $0.status = MessageStatus.delivered }
                            .execute(db)
                        // Info milestone: the FIRST proof time. A repeat proof never moves it.
                        try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing && $0.deliveredAt.is(nil) }
                            .update { $0.deliveredAt = milestoneAt }
                            .execute(db)
                    }
                    try await reloadConversations(database, send)
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter infoMilestone`
Expected: 6 tests pass. Then run the existing status tests to confirm the rewrites kept them green:
- `--filter deliveryFailed`
- `--filter propagationAccepted`
- `--filter deliveryConfirmed`

- [ ] **Step 5: Mutation check**

Apply all four mutations together:
- **M1** (`deliveryConfirmed` milestone): `$0.messageHash.eq(hex) && $0.isOutgoing && $0.deliveredAt.is(nil)` becomes `$0.messageHash.eq(hex) && $0.isOutgoing`. This reddens `infoMilestoneRepeatEventDoesNotMoveTheTime`, because `deliveredAt` moves to T0+60.
- **M2** (`propagationAccepted` milestone): `$0.messageHash.eq(hex) && $0.isOutgoing && $0.storedAt.is(nil)` becomes `$0.messageHash.eq(hex) && $0.isOutgoing && $0.storedAt.is(nil) && $0.status.neq(MessageStatus.delivered)`. This reddens `infoMilestoneLateStoredAfterDeliveredIsStillRecorded`. It does not affect the other tests, because none of them has a delivered row when `propagationAccepted` arrives.
- **M3** (`deliveryFailed` milestone): `$0.messageHash.eq(hex) && $0.isOutgoing && $0.failedAt.is(nil)` becomes `$0.messageHash.eq(hex) && $0.failedAt.is(nil)`. This reddens `infoMilestoneIncomingRowsSharingTheHashAreUntouched`, because the incoming row gets a time.
- **M4** (`deliveryFailed` milestone): `.update { $0.failedAt = milestoneAt }` becomes `.update { $0.storedAt = milestoneAt }`. This reddens:
  - `infoMilestoneFirstEventsSetTheirColumns` (`failedAt` stays nil)
  - `infoMilestoneFailureAfterDeliveredKeepsStatusButRecordsTime`
  - `infoMilestoneFalseFailureThenStoredRecordsBoth`

M3 and M4 edit the same statement, and together they still leave the incoming row with a non-nil `storedAt`, so that test stays red. None of the mutations crashes.

Run the filter and confirm all 6 are red. Revert by hand. Run `git diff` and confirm no mutation text remains.

- [ ] **Step 6: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore`
Expected: 193 tests pass, with 0 known issues.

- [ ] **Step 7: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift
```

Write `/tmp/ReTiCAMsgr/commit-msg.txt` (overwrite it):

```
feat: record first stored, delivered and failed times

Each status handler now also stamps its milestone column on outgoing rows
with the hash, only while it is still NULL. The time is recorded even when
the status guard keeps a delivered row delivered.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Then run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info commit -F /tmp/ReTiCAMsgr/commit-msg.txt`

---

### Task 6: The `MessageInfo` builder

**Files:**
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/MessageInfo.swift`
- Create: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/MessageInfoTests.swift`

**Interfaces:**
- Consumes: `Message` with its metadata (Task 1), `ArrivalMethod.*`, `StampState.*` and `MessageStatus.*`.
- Produces (public, used by the app in Task 7):
  - `MessageInfo.sections(for message: Message, timeZone: TimeZone = .current) -> [MessageInfo.Section]`
  - `MessageInfo.Section { title: String, rows: [Row], footer: String? }`, `Equatable`, `Sendable`
  - `MessageInfo.Row { label: String, display: String, copy: String }`, `Equatable`, `Sendable`
    - `init(label:display:copy:)`
    - `init(_ label: String, _ display: String)`, where copy equals display
  - `MessageInfo.missing = "—"`
  - `MessageInfo.legacyFooter`
- Internal helpers, tested through `@testable`:
  - `gap(_:)`
  - `time(_:sameDayAs:timeZone:)`
  - `iso(_:)`
  - `shortHash(_:)`
  - `hashRow(_:_:)`
  - `fieldRows(_:)`
  - `fieldDisplay(_:)`

**Formatting decisions**

The spec leaves these open. They are decided here:

- **Time zone.** `sections(for:)` takes a `timeZone:` parameter that defaults to `.current`, so the spec's call shape still works. Tests pass UTC.
- **Cross-day times** get an ISO date prefix: `2023-11-15 00:00:30`.
- **Gaps** truncate toward zero to whole seconds:
  - Under 1 minute: `+4s`.
  - Under 1 hour: `+1m 21s` (seconds padded to two digits).
  - Otherwise: `+2h 03m`, with no seconds and hours unbounded (`+26h 00m`).
  - Negative: `-3s`. Anything that rounds to zero is `+0s`.
  - Skew uses the same format.
- **Copy values**
  - Hash rows copy the full hex.
  - Time rows copy full ISO-8601 UTC with milliseconds (`2023-11-14T22:13:20.000Z`).
  - Missing ("—") rows copy `""`, and the sheet treats `""` as "nothing to copy".
  - Every other row copies its display text.
- **Milestone order** is fixed as in the spec: Stored on node, Delivered, Failed. It is not re-sorted by time.
- **Hash shortening** applies to both "Message hash" and "Peer" (`peerHex` is a hash too). `first4…last4`, and only when the hex is longer than 9 characters.
- **Field rows.** `fieldKeys == nil` gives one row "Fields: —". `""` gives one row "Fields: None". Otherwise there is one row per key, each labelled "Field".
  - The display is the uppercase code plus the known name, for example `0xFB custom type`.
  - A key with no name, including keys above 0xFF, shows as its code alone (`0x2A`, `0x100`).
  - A token that doesn't parse (`junk`) shows as-is.
- **Delivery values.** An unknown `arrivalMethod` string shows raw. An unknown `stampState` shows raw.

**Fixture reference:** `1700000000` is `2023-11-14 22:13:20 UTC`.

- [ ] **Step 1: Write the failing tests**

Create `MessageInfoTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCAMsgrCore

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1700000000)          // 2023-11-14 22:13:20 UTC
private let hash64 = "a1b2" + String(repeating: "0", count: 56) + "c3d4"
private let peer32 = "0123456789abcdef0123456789abcdef"

private func info(_ m: Message) -> [MessageInfo.Section] { MessageInfo.sections(for: m, timeZone: utc) }

private func missingRow(_ label: String) -> MessageInfo.Row {
    MessageInfo.Row(label: label, display: "—", copy: "")
}

@Test func infoSectionsOutgoingWithAllMilestones() {
    let m = Message(
        id: UUID(), peerHex: peer32, isOutgoing: true, body: "hi", timestamp: t0,
        status: MessageStatus.delivered, validated: false, messageHash: hash64,
        senderTimestamp: t0, sentViaPropagation: true,
        storedAt: t0.addingTimeInterval(4), deliveredAt: t0.addingTimeInterval(81),
        failedAt: t0.addingTimeInterval(3780),
        wireSize: 412, titleSize: 0, contentSize: 2, fieldKeys: ""
    )
    #expect(info(m) == [
        MessageInfo.Section(title: "Timeline", rows: [
            MessageInfo.Row(label: "Sent", display: "22:13:20", copy: "2023-11-14T22:13:20.000Z"),
            MessageInfo.Row(label: "Stored on node", display: "22:13:24 (+4s)", copy: "2023-11-14T22:13:24.000Z"),
            MessageInfo.Row(label: "Delivered", display: "22:14:41 (+1m 21s)", copy: "2023-11-14T22:14:41.000Z"),
            MessageInfo.Row(label: "Failed", display: "23:16:20 (+1h 03m)", copy: "2023-11-14T23:16:20.000Z"),
            MessageInfo.Row("Status", "delivered"),
        ]),
        MessageInfo.Section(title: "Delivery", rows: [MessageInfo.Row("Propagation node copy", "Yes")]),
        MessageInfo.Section(title: "Identity", rows: [
            MessageInfo.Row(label: "Message hash", display: "a1b2…c3d4", copy: hash64),
            MessageInfo.Row(label: "Peer", display: "0123…cdef", copy: peer32),
            MessageInfo.Row("Signature", "n/a"),
        ]),
        MessageInfo.Section(title: "Payload", rows: [
            MessageInfo.Row("Wire size", "412 B"),
            MessageInfo.Row("Title size", "0 B"),
            MessageInfo.Row("Content size", "2 B"),
            MessageInfo.Row("Fields", "None"),
            missingRow("Stamp"),
        ]),
    ])
}

@Test func infoSectionsOutgoingWithOnlySent() {
    let m = Message(
        id: UUID(), peerHex: peer32, isOutgoing: true, body: "hi", timestamp: t0,
        status: MessageStatus.sending, validated: false, messageHash: hash64,
        senderTimestamp: t0, sentViaPropagation: false,
        wireSize: 100, titleSize: 0, contentSize: 2, fieldKeys: ""
    )
    let sections = info(m)
    #expect(sections.map(\.title) == ["Timeline", "Delivery", "Identity", "Payload"])
    #expect(sections[0].rows == [
        MessageInfo.Row(label: "Sent", display: "22:13:20", copy: "2023-11-14T22:13:20.000Z"),
        MessageInfo.Row("Status", "sending"),
    ])
    #expect(sections[1].rows == [MessageInfo.Row("Propagation node copy", "No")])
    #expect(sections[2].footer == nil)
}

@Test func infoSectionsIncomingPositiveAndNegativeSkew() {
    let base = Message(
        id: UUID(), peerHex: peer32, isOutgoing: false, body: "yo", timestamp: t0,
        status: MessageStatus.received, validated: true, messageHash: hash64,
        senderTimestamp: t0.addingTimeInterval(-81), arrivalMethod: ArrivalMethod.direct,
        wireSize: 300, titleSize: 0, contentSize: 5, fieldKeys: "0x02,0xfb", stampState: StampState.unchecked
    )
    #expect(info(base) == [
        MessageInfo.Section(title: "Timeline", rows: [
            MessageInfo.Row(label: "Written", display: "22:11:59", copy: "2023-11-14T22:11:59.000Z"),
            MessageInfo.Row(label: "Received", display: "22:13:20", copy: "2023-11-14T22:13:20.000Z"),
            MessageInfo.Row("Skew", "+1m 21s"),
            MessageInfo.Row("Status", "received"),
        ]),
        MessageInfo.Section(title: "Delivery", rows: [MessageInfo.Row("Arrival", "Direct link")]),
        MessageInfo.Section(title: "Identity", rows: [
            MessageInfo.Row(label: "Message hash", display: "a1b2…c3d4", copy: hash64),
            MessageInfo.Row(label: "Peer", display: "0123…cdef", copy: peer32),
            MessageInfo.Row("Signature", "Validated"),
        ]),
        MessageInfo.Section(title: "Payload", rows: [
            MessageInfo.Row("Wire size", "300 B"),
            MessageInfo.Row("Title size", "0 B"),
            MessageInfo.Row("Content size", "5 B"),
            MessageInfo.Row("Field", "0x02 telemetry"),
            MessageInfo.Row("Field", "0xFB custom type"),
            MessageInfo.Row("Stamp", "Not checked"),
        ]),
    ])
    var ahead = base   // the sender's clock runs 3 s ahead of ours
    ahead.senderTimestamp = t0.addingTimeInterval(3)
    #expect(info(ahead)[0].rows[2] == MessageInfo.Row("Skew", "-3s"))
    #expect(info(ahead)[0].rows[0].display == "22:13:23")
}

/// Review Focus 4: a pre-reactions, pre-Info incoming row with no hash and all metadata nil.
@Test func infoSectionsLegacyIncoming() {
    let m = Message(id: UUID(), peerHex: peer32, isOutgoing: false, body: "old", timestamp: t0,
                    status: MessageStatus.received, validated: false, messageHash: "")
    #expect(info(m) == [
        MessageInfo.Section(title: "Timeline", rows: [
            missingRow("Written"),
            MessageInfo.Row(label: "Received", display: "22:13:20", copy: "2023-11-14T22:13:20.000Z"),
            missingRow("Skew"),
            MessageInfo.Row("Status", "received"),
        ]),
        MessageInfo.Section(title: "Delivery", rows: [missingRow("Arrival")]),
        MessageInfo.Section(title: "Identity", rows: [
            missingRow("Message hash"),
            MessageInfo.Row(label: "Peer", display: "0123…cdef", copy: peer32),
            MessageInfo.Row("Signature", "Not validated"),
        ], footer: "Some details weren't recorded for messages from before this feature."),
        MessageInfo.Section(title: "Payload", rows: [
            missingRow("Wire size"), missingRow("Title size"), missingRow("Content size"),
            missingRow("Fields"), missingRow("Stamp"),
        ]),
    ])
}

@Test func infoSectionsGapFormats() {
    #expect(MessageInfo.gap(4) == "+4s")
    #expect(MessageInfo.gap(4.9) == "+4s")
    #expect(MessageInfo.gap(0) == "+0s")
    #expect(MessageInfo.gap(-0.4) == "+0s")
    #expect(MessageInfo.gap(-3) == "-3s")
    #expect(MessageInfo.gap(65) == "+1m 05s")
    #expect(MessageInfo.gap(81) == "+1m 21s")
    #expect(MessageInfo.gap(7380) == "+2h 03m")
    #expect(MessageInfo.gap(-7380) == "-2h 03m")
    #expect(MessageInfo.gap(93_600) == "+26h 00m")        // Review Focus 1: big skews stay readable
}

@Test func infoSectionsCrossDayTime() {
    let lateSend = Date(timeIntervalSince1970: 1700006390)   // 2023-11-14 23:59:50 UTC
    let m = Message(id: UUID(), peerHex: peer32, isOutgoing: true, body: "hi", timestamp: lateSend,
                    status: MessageStatus.delivered, validated: false, messageHash: hash64,
                    senderTimestamp: lateSend, deliveredAt: lateSend.addingTimeInterval(40))
    #expect(info(m)[0].rows[1].display == "2023-11-15 00:00:30 (+40s)")
    #expect(info(m)[0].rows[0].display == "23:59:50")
    // The local time zone decides the day and the clock face, not UTC.
    let plus3 = TimeZone(secondsFromGMT: 3 * 3600)!
    #expect(MessageInfo.time(t0, sameDayAs: t0, timeZone: plus3) == "01:13:20")
    #expect(MessageInfo.time(t0, sameDayAs: lateSend.addingTimeInterval(40), timeZone: utc) == "2023-11-14 22:13:20")
}

/// Review Focus 5 plus the spec's full name table (LXMF 1.1.0 `LXMF/LXMF.py`).
@Test func infoSectionsFieldKeyNaming() {
    let names: [(String, String)] = [
        ("0x01", "0x01 embedded LXMs"), ("0x02", "0x02 telemetry"), ("0x03", "0x03 telemetry stream"),
        ("0x04", "0x04 icon appearance"), ("0x05", "0x05 file attachments"), ("0x06", "0x06 image"),
        ("0x07", "0x07 audio"), ("0x08", "0x08 thread"), ("0x09", "0x09 commands"),
        ("0x0a", "0x0A results"), ("0x0b", "0x0B group"), ("0x0c", "0x0C ticket"),
        ("0x0d", "0x0D event"), ("0x0e", "0x0E RNR refs"), ("0x0f", "0x0F renderer"),
        ("0x30", "0x30 reply to"), ("0x31", "0x31 reply quote"), ("0x40", "0x40 reaction"),
        ("0x41", "0x41 comment"), ("0x42", "0x42 continuation"), ("0xfb", "0xFB custom type"),
        ("0xfc", "0xFC custom data"), ("0xfd", "0xFD custom meta"), ("0xfe", "0xFE non-specific"),
        ("0xff", "0xFF debug"),
    ]
    for (token, expected) in names {
        #expect(MessageInfo.fieldDisplay(token) == expected)
    }
    #expect(MessageInfo.fieldRows("0x40,0x2a,0x100,junk") == [
        MessageInfo.Row("Field", "0x40 reaction"),
        MessageInfo.Row("Field", "0x2A"),
        MessageInfo.Row("Field", "0x100"),
        MessageInfo.Row("Field", "junk"),
    ])
    #expect(MessageInfo.fieldRows("") == [MessageInfo.Row("Fields", "None")])
    #expect(MessageInfo.fieldRows(nil) == [missingRow("Fields")])
}

@Test func infoSectionsHashTruncationAndCopy() {
    #expect(MessageInfo.hashRow("Peer", peer32) == MessageInfo.Row(label: "Peer", display: "0123…cdef", copy: peer32))
    #expect(MessageInfo.shortHash(hash64) == "a1b2…c3d4")
    #expect(MessageInfo.shortHash("abcdefghi") == "abcdefghi")       // 9 chars: nothing to hide
    #expect(MessageInfo.shortHash("abcdefghij") == "abcd…ghij")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter infoSections`
Expected: a compile failure, because `MessageInfo` is undefined.

- [ ] **Step 3: Implement `MessageInfo.swift`**

```swift
import Foundation

/// The message Info sheet as data: titled sections of (label, display, copy) rows. Pure — all
/// formatting happens here so it can be unit-tested. The SwiftUI sheet only lays rows out.
public enum MessageInfo {
    public struct Section: Equatable, Sendable {
        public var title: String
        public var rows: [Row]
        public var footer: String?

        public init(title: String, rows: [Row], footer: String? = nil) {
            self.title = title
            self.rows = rows
            self.footer = footer
        }
    }

    public struct Row: Equatable, Sendable {
        public var label: String
        public var display: String
        /// What a tap puts on the pasteboard. "" means there is nothing to copy.
        public var copy: String

        public init(label: String, display: String, copy: String) {
            self.label = label
            self.display = display
            self.copy = copy
        }

        /// A row whose copy value is its display text.
        public init(_ label: String, _ display: String) {
            self.init(label: label, display: display, copy: display)
        }
    }

    public static let missing = "—"
    public static let legacyFooter = "Some details weren't recorded for messages from before this feature."

    public static func sections(for message: Message, timeZone: TimeZone = .current) -> [Section] {
        [timeline(message, timeZone), delivery(message), identity(message), payload(message)]
    }

    // MARK: - Sections

    static func timeline(_ m: Message, _ tz: TimeZone) -> Section {
        var rows: [Row] = []
        if m.isOutgoing {
            rows.append(timeRow("Sent", m.timestamp, sameDayAs: m.timestamp, tz))
            let milestones: [(String, Date?)] = [
                ("Stored on node", m.storedAt),
                ("Delivered", m.deliveredAt),
                ("Failed", m.failedAt),
            ]
            for (label, at) in milestones {
                guard let at else { continue }   // a milestone that never happened is hidden
                let shown = time(at, sameDayAs: m.timestamp, timeZone: tz)
                rows.append(Row(label: label,
                                display: "\(shown) (\(gap(at.timeIntervalSince(m.timestamp))))",
                                copy: iso(at)))
            }
        } else {
            if let written = m.senderTimestamp {
                rows.append(timeRow("Written", written, sameDayAs: m.timestamp, tz))
            } else {
                rows.append(missingRow("Written"))
            }
            rows.append(timeRow("Received", m.timestamp, sameDayAs: m.timestamp, tz))
            if let written = m.senderTimestamp {
                rows.append(Row("Skew", gap(m.timestamp.timeIntervalSince(written))))
            } else {
                rows.append(missingRow("Skew"))
            }
        }
        rows.append(Row("Status", m.status))
        return Section(title: "Timeline", rows: rows)
    }

    static func delivery(_ m: Message) -> Section {
        let row = m.isOutgoing
            ? optionalRow("Propagation node copy", m.sentViaPropagation.map { $0 ? "Yes" : "No" })
            : optionalRow("Arrival", m.arrivalMethod.map(arrivalName))
        return Section(title: "Delivery", rows: [row])
    }

    static func identity(_ m: Message) -> Section {
        let hash = m.messageHash.isEmpty ? missingRow("Message hash") : hashRow("Message hash", m.messageHash)
        let signature = m.isOutgoing ? "n/a" : (m.validated ? "Validated" : "Not validated")
        return Section(title: "Identity",
                       rows: [hash, hashRow("Peer", m.peerHex), Row("Signature", signature)],
                       footer: m.senderTimestamp == nil ? legacyFooter : nil)
    }

    static func payload(_ m: Message) -> Section {
        var rows = [
            optionalRow("Wire size", m.wireSize.map(bytes)),
            optionalRow("Title size", m.titleSize.map(bytes)),
            optionalRow("Content size", m.contentSize.map(bytes)),
        ]
        rows += fieldRows(m.fieldKeys)
        rows.append(m.isOutgoing ? missingRow("Stamp") : optionalRow("Stamp", m.stampState.map(stampName)))
        return Section(title: "Payload", rows: rows)
    }

    // MARK: - Rows

    static func missingRow(_ label: String) -> Row {
        Row(label: label, display: missing, copy: "")
    }

    static func optionalRow(_ label: String, _ value: String?) -> Row {
        value.map { Row(label, $0) } ?? missingRow(label)
    }

    static func timeRow(_ label: String, _ date: Date, sameDayAs reference: Date, _ tz: TimeZone) -> Row {
        Row(label: label, display: time(date, sameDayAs: reference, timeZone: tz), copy: iso(date))
    }

    static func hashRow(_ label: String, _ hex: String) -> Row {
        Row(label: label, display: shortHash(hex), copy: hex)
    }

    static func fieldRows(_ keys: String?) -> [Row] {
        guard let keys else { return [missingRow("Fields")] }
        let tokens = keys.split(separator: ",").map(String.init)
        guard !tokens.isEmpty else { return [Row("Fields", "None")] }
        return tokens.map { Row("Field", fieldDisplay($0)) }
    }

    // MARK: - Formatting

    /// `HH:mm:ss` in `timeZone`, prefixed with `yyyy-MM-dd` when not on `reference`'s calendar day.
    static func time(_ date: Date, sameDayAs reference: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: reference) ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Unambiguous copy value for a time: ISO-8601 UTC with milliseconds.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Signed duration, truncated to whole seconds: `+4s`, `+1m 21s`, `+2h 03m`, `-3s`.
    static func gap(_ seconds: TimeInterval) -> String {
        let total = Int(abs(seconds).rounded(.down))
        let sign = seconds < 0 && total > 0 ? "-" : "+"
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(sign)\(h)h \(twoDigits(m))m" }
        if m > 0 { return "\(sign)\(m)m \(twoDigits(s))s" }
        return "\(sign)\(s)s"
    }

    static func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    static func bytes(_ n: Int) -> String { "\(n) B" }

    /// `first4…last4`, or the whole string when shortening would hide nothing.
    static func shortHash(_ hex: String) -> String {
        guard hex.count > 9 else { return hex }
        return "\(hex.prefix(4))…\(hex.suffix(4))"
    }

    static func arrivalName(_ raw: String) -> String {
        switch raw {
        case ArrivalMethod.opportunistic: return "Opportunistic"
        case ArrivalMethod.direct: return "Direct link"
        case ArrivalMethod.propagated: return "Propagation node"
        default: return raw
        }
    }

    static func stampName(_ raw: String) -> String {
        switch raw {
        case StampState.none: return "None"
        case StampState.unchecked: return "Not checked"
        case StampState.valid: return "Valid"
        case StampState.invalid: return "Invalid"
        default: return raw
        }
    }

    /// A stored token ("0xfb") → "0xFB custom type". An unnamed key → its code alone ("0x2A").
    /// A token that is not `0x<hex>` is shown as-is rather than dropped.
    static func fieldDisplay(_ token: String) -> String {
        guard token.hasPrefix("0x"), let key = Int(token.dropFirst(2), radix: 16), key >= 0 else { return token }
        var hex = String(key, radix: 16, uppercase: true)
        if hex.count < 2 { hex = "0" + hex }
        let code = "0x" + hex
        guard let name = fieldNames[key] else { return code }
        return "\(code) \(name)"
    }

    /// FIELD_* names from reference LXMF 1.1.0 (`LXMF/LXMF.py:8-51`).
    static let fieldNames: [Int: String] = [
        0x01: "embedded LXMs", 0x02: "telemetry", 0x03: "telemetry stream", 0x04: "icon appearance",
        0x05: "file attachments", 0x06: "image", 0x07: "audio", 0x08: "thread", 0x09: "commands",
        0x0A: "results", 0x0B: "group", 0x0C: "ticket", 0x0D: "event", 0x0E: "RNR refs",
        0x0F: "renderer", 0x30: "reply to", 0x31: "reply quote", 0x40: "reaction", 0x41: "comment",
        0x42: "continuation", 0xFB: "custom type", 0xFC: "custom data", 0xFD: "custom meta",
        0xFE: "non-specific", 0xFF: "debug",
    ]
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore --filter infoSections`
Expected: 8 tests pass.

- [ ] **Step 5: Mutation check**

Apply all six mutations to `MessageInfo.swift` together:
- **M1** (`gap`): `let sign = seconds < 0 && total > 0 ? "-" : "+"` becomes `let sign = seconds < 0 && total > 0 ? "+" : "-"`. This reddens `GapFormats`, `OutgoingWithAllMilestones`, `IncomingPositiveAndNegativeSkew` and `CrossDayTime`.
- **M2** (`timeline`): `guard let at else { continue }` becomes `guard let at else { rows.append(missingRow(label)); continue }`. This reddens `OutgoingWithOnlySent`.
- **M3** (`identity`): `footer: m.senderTimestamp == nil ? legacyFooter : nil` becomes `footer: m.senderTimestamp != nil ? legacyFooter : nil`. This reddens `LegacyIncoming`, and also the full-section tests.
- **M4** (`shortHash`): `"\(hex.prefix(4))…\(hex.suffix(4))"` becomes `"\(hex.prefix(6))…\(hex.suffix(4))"`. This reddens `HashTruncationAndCopy`.
- **M5** (`fieldDisplay`): `String(key, radix: 16, uppercase: true)` becomes `String(key, radix: 16, uppercase: false)`. This reddens `FieldKeyNaming`.
- **M6** (`time`): `calendar.isDate(date, inSameDayAs: reference) ? "HH:mm:ss"` becomes `true ? "HH:mm:ss"`. This reddens `CrossDayTime`.

Every test has at least one mutation aimed at it. The overlaps (for example M1 also reddening `CrossDayTime`) are redundant, not masking. None crashes.

Run the filter and confirm all 8 are red. Revert by hand. Run `git diff` and confirm no mutation text remains.

- [ ] **Step 6: Run the full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore`
Expected: 201 tests pass, with 0 known issues.

- [ ] **Step 7: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/MessageInfo.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/MessageInfoTests.swift
```

Write `/tmp/ReTiCAMsgr/commit-msg.txt` (overwrite it):

```
feat: build message Info sections

MessageInfo turns a Message into Timeline, Delivery, Identity and Payload
sections of label, display and copy rows. It formats local times with
cross-day dates, signed gaps and skew, shortened hashes with full-hex copy,
named LXMF field keys and a legacy footer.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Then run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info commit -F /tmp/ReTiCAMsgr/commit-msg.txt`

---

### Task 7: The Info sheet and menu row

**Files:**
- Create: `ReTiCAMsgr/MessageInfoSheet.swift`
- Modify: `ReTiCAMsgr/ChatView.swift`:
  - `:15` (state)
  - `:28-49` (the list and context menu)
  - `:71-74` (the `PickerTarget` neighbour)

**Interfaces:**
- Consumes: `MessageInfo.sections(for:)`, `MessageInfo.Section`, `MessageInfo.Row` (Task 6), `StoreOf<AppFeature>.threadMessages` and `Message.id`.
- Produces: `struct MessageInfoSheet: View { init(store: StoreOf<AppFeature>, messageID: UUID) }`.

This task is SwiftUI only and has no unit tests, so it is exempt from mutation checks. It is verified by the app build here and manually in Task 8.

- [ ] **Step 1: Create `MessageInfoSheet.swift`**

```swift
import SwiftUI
import UIKit
import ComposableArchitecture
import ReTiCAMsgrCore

/// Debugging metadata for one message. It reads the message from `store.threadMessages` by id, so
/// a milestone that lands while the sheet is open (the thread reloads) shows up live.
struct MessageInfoSheet: View {
    let store: StoreOf<AppFeature>
    let messageID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var showCopied = false
    @State private var copyGeneration = 0

    private var message: Message? {
        store.threadMessages.first { $0.id == messageID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let message {
                    List {
                        ForEach(Array(MessageInfo.sections(for: message).enumerated()), id: \.offset) { _, section in
                            Section {
                                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                    InfoRow(row: row) { copy(row.copy) }
                                }
                            } header: {
                                Text(section.title)
                            } footer: {
                                if let footer = section.footer { Text(footer) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    ContentUnavailableView("Message unavailable", systemImage: "questionmark.bubble")
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if showCopied {
                    Text("Copied")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else { return }   // "—" rows have nothing to copy
        UIPasteboard.general.string = value
        copyGeneration += 1
        let generation = copyGeneration
        withAnimation { showCopied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            // A newer copy restarts the timer: only the latest tap hides the overlay.
            if generation == copyGeneration {
                withAnimation { showCopied = false }
            }
        }
    }
}

/// Label left, monospaced value right. The whole row is the tap target (see the UI rule: a plain
/// Button otherwise only hit-tests its glyphs).
private struct InfoRow: View {
    let row: MessageInfo.Row
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.label)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(row.display)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.copy.isEmpty)
        .accessibilityHint(row.copy.isEmpty ? "" : "Copies the value")
    }
}
```

- [ ] **Step 2: Wire it into `ChatView.swift`**

After line 15 (`@State private var pickerTarget: PickerTarget?`), add:

```swift
    @State private var infoTarget: InfoTarget?
```

In the `.contextMenu { ... }` builder, insert the Info button between the closing `}` of `if !message.messageHash.isEmpty { ... }` (line 40) and `Button("Copy", ...)` (line 41). It sits outside the `if`, so legacy bubbles with no hash get it too:

```swift
                        Button("Info", systemImage: "info.circle") {
                            infoTarget = InfoTarget(id: message.id)
                        }
```

After `.listStyle(.plain)` (line 49), add the sheet. It goes on the `List`, not the outer `VStack`, so it doesn't share a view with the emoji `sheet(item:)`:

```swift
            .sheet(item: $infoTarget) { target in
                MessageInfoSheet(store: store, messageID: target.id)
            }
```

After the `PickerTarget` struct (lines 71–74), add:

```swift
private struct InfoTarget: Identifiable {
    let id: UUID
}
```

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full core suite (unchanged, sanity check)**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore`
Expected: 201 tests pass, with 0 known issues.

- [ ] **Step 5: Commit**

```
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info add ReTiCAMsgr/MessageInfoSheet.swift ReTiCAMsgr/ChatView.swift
```

Write `/tmp/ReTiCAMsgr/commit-msg.txt` (overwrite it):

```
feat: add Info sheet to the message menu

Every bubble's context menu gets an Info row that opens a sheet of the
MessageInfo sections. Tapping a row copies its value and shows a brief
Copied overlay. The sheet reads the message from the live thread so
milestones update while it is open.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Then run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info commit -F /tmp/ReTiCAMsgr/commit-msg.txt`

---

### Task 8: Manual simulator verification

**Files:**
- Modify TEMPORARILY: `ReTiCAMsgr/ReTiCAMsgrApp.swift`. **This is reverted by hand before the task ends and is never committed.**

**Interfaces:**
- Consumes: everything above.
- Produces: a verification report, and no code.

- [ ] **Step 1: Load the simulator skill**

Invoke the `xcodebuildmcp-cli` skill with the Skill tool. Follow its help-first discovery (`xcodebuildmcp --help`, `xcodebuildmcp tools`, `xcodebuildmcp <workflow> --help`) to find:
- the simulator build-and-run command for this project and scheme;
- the UI-automation commands for screenshot, tap, long-press, type and paste;
- how to describe the on-screen accessibility tree.

Check the session defaults before the first build, as the skill requires.

- [ ] **Step 2: Add the temporary seed scaffold**

In `ReTiCAMsgrApp.swift`, replace the `prepareDependencies { ... }` block (lines 20–29) with:

```swift
        let database = try! AppDatabase.makeOnDisk(path: dbPath)
        #if DEBUG
        InfoSeed.seed(database)   // TEMPORARY (message-info Task 8). Revert before any commit.
        #endif
        prepareDependencies {
            $0.defaultDatabase = database
            // Answer peers' /publicKey requests with our own 64-byte public key. The link the
            // request arrives on is already authenticated, and the key is public (every announce
            // carries it), so answering unconditionally is safe.
            $0.requestResponder = RequestResponder { path, _, _ in
                guard path == AppFeature.publicKeyRequestPath else { return nil }
                return identity.publicKey
            }
        }
```

Replace `.task { Self.store.send(.onLaunch) }` (line 38) with:

```swift
                .task {
                    Self.store.send(.onLaunch)
                    #if DEBUG
                    // TEMPORARY: a delivery proof for the seeded pending message, 45 s after launch,
                    // so the open Info sheet can be watched updating live.
                    try? await Task.sleep(for: .seconds(45))
                    Self.store.send(.node(.client(.delegate(.deliveryConfirmed(
                        messageHash: Data(repeating: 0x5E, count: 32))))))
                    #endif
                }
```

Append at the end of the file:

```swift
#if DEBUG
/// TEMPORARY message-info Task 8 scaffold. Revert before any commit.
enum InfoSeed {
    static let peer = String(repeating: "5a", count: 16)

    static func seed(_ db: any DatabaseWriter) {
        let now = Date()
        let rows: [Message] = [
            Message(id: UUID(uuidString: "00000000-0000-0000-0000-00000000f001")!, peerHex: peer,
                    isOutgoing: false, body: "incoming with metadata", timestamp: now.addingTimeInterval(-300),
                    status: MessageStatus.received, validated: true,
                    messageHash: String(repeating: "5b", count: 32),
                    senderTimestamp: now.addingTimeInterval(-381), arrivalMethod: ArrivalMethod.direct,
                    wireSize: 312, titleSize: 0, contentSize: 22, fieldKeys: "0x02,0xfb,0x2a",
                    stampState: StampState.valid),
            Message(id: UUID(uuidString: "00000000-0000-0000-0000-00000000f002")!, peerHex: peer,
                    isOutgoing: false, body: "legacy incoming", timestamp: now.addingTimeInterval(-240),
                    status: MessageStatus.received, validated: false, messageHash: ""),
            Message(id: UUID(uuidString: "00000000-0000-0000-0000-00000000f003")!, peerHex: peer,
                    isOutgoing: true, body: "outgoing stored", timestamp: now.addingTimeInterval(-180),
                    status: MessageStatus.propagated, validated: false,
                    messageHash: String(repeating: "5c", count: 32),
                    senderTimestamp: now.addingTimeInterval(-180), sentViaPropagation: true,
                    storedAt: now.addingTimeInterval(-176),
                    wireSize: 150, titleSize: 0, contentSize: 15, fieldKeys: ""),
            Message(id: UUID(uuidString: "00000000-0000-0000-0000-00000000f004")!, peerHex: peer,
                    isOutgoing: true, body: "outgoing pending", timestamp: now.addingTimeInterval(-60),
                    status: MessageStatus.sending, validated: false,
                    messageHash: String(repeating: "5e", count: 32),
                    senderTimestamp: now.addingTimeInterval(-60), sentViaPropagation: false,
                    wireSize: 152, titleSize: 0, contentSize: 16, fieldKeys: ""),
        ]
        for row in rows {
            try? db.write { try Message.insert { row }.execute($0) }   // fixed ids: a relaunch is a no-op
        }
    }
}
#endif
```

The file already imports `SQLiteData`, which re-exports `DatabaseWriter`.

- [ ] **Step 3: Build and run on a simulator**

Use the skill's simulator build-and-run for `/Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgr.xcodeproj`, scheme `ReTiCAMsgr`. Open the conversation `5a5a…` from the Chats list. Start the next steps promptly, because the 45-second proof timer starts at launch.

- [ ] **Step 4: Verify, taking a screenshot for each check**

1. **Info row in the menu.** Long-press "incoming with metadata". The menu shows the reaction palette, More Reactions, **Info** and Copy, in that order. Long-press "legacy incoming": it shows **Info** and Copy, with no reaction items because it has no hash.
2. **Incoming sheet.** Tap Info on "incoming with metadata" and check each section:
   - Timeline: Written, Received, Skew `+1m 21s`, Status `received`.
   - Delivery: Arrival `Direct link`.
   - Identity: hash `5b5b…5b5b`, peer `5a5a…5a5a`, Signature `Validated`.
   - Payload: `312 B` / `0 B` / `22 B`, then the fields `0x02 telemetry`, `0xFB custom type` and `0x2A`, then Stamp `Valid`.
   - There is no footer. The detents allow medium and large, and Done dismisses the sheet.
3. **Legacy sheet.** Tap Info on "legacy incoming":
   - Every metadata row shows "—".
   - Message hash shows "—".
   - Signature shows `Not validated`.
   - The Identity footer reads "Some details weren't recorded for messages from before this feature."
   - Tapping a "—" row shows no "Copied" overlay.
4. **Outgoing sheet.** Tap Info on "outgoing stored":
   - Timeline: Sent, Stored on node with `(+4s)`, Status `stored`.
   - Delivery: `Propagation node copy: Yes`.
   - Signature: `n/a`. Stamp: "—".
5. **Tap to copy.** In the "incoming with metadata" sheet, tap the Message hash row. "Copied" appears briefly. Dismiss the sheet, paste into the Message draft field, and confirm it contains the full 64-hex-character hash `5b5b…` (not the shortened form). Clear the draft.
6. **Live milestone.** Before the 45-second mark, open Info on "outgoing pending" and keep the sheet open. It shows Sent and Status `sending`. When the timer fires, the Timeline gains a **Delivered** row with a `(+…)` gap and Status changes to `delivered`, without reopening the sheet.
   - If you missed the window, terminate and relaunch the app. The seed insert is a no-op on relaunch, and the timer fires again.
7. **Whole-row tap.** Tap the blank middle of a row, between the label and the value. It still copies.

If any check fails, stop. Diagnose it with superpowers:systematic-debugging, fix it in the owning task's files with a new commit, and redo this task.

- [ ] **Step 5: Revert the scaffold by hand**

With the Edit tool, restore the `prepareDependencies` block and the `.task { Self.store.send(.onLaunch) }` line exactly as they were, and delete the `InfoSeed` enum. Then:

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info diff -- ReTiCAMsgr/ReTiCAMsgrApp.swift`
Expected: empty output.

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-message-info status --short`
Expected: no change to `ReTiCAMsgrApp.swift`. Only the pre-existing unrelated entries remain.

Remove the seeded rows from the simulator by uninstalling the app with the skill's simulator uninstall tool (find it with `--help`), so the fake conversation doesn't linger.

- [ ] **Step 6: Final checks**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build`
Expected: `** BUILD SUCCEEDED **` with the scaffold gone.

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-message-info/ReTiCAMsgrCore`
Expected: 201 tests pass, with 0 known issues.

Nothing is committed in this task. Report the seven checks, each with pass or fail and its screenshot.
