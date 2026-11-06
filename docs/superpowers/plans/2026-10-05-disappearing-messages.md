# Disappearing Messages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A shared per-conversation timer, carried in LXMF `FIELD_CUSTOM_META` (0xFD), after which each message's row, attachment file, export copies and reactions are deleted from this device.

**Architecture:** Three new pure types in the core package (`ExpiryWire` codec, `ExpiryPreset` labels and announcement text, `MessagePurge` for the delete work) plus a `ConversationSetting` table. `AppFeature` gains the glue: stamp `expiresAt` on send and on first view, purge-and-reschedule after every change, and one cancellable clock sleeper (`CancelID.expiry`). The SwiftUI app target adds a toolbar menu, a title indicator, a centred system line for timer changes and a timer glyph on bubbles.

**Tech Stack:** Swift 6, SwiftUI, TCA (`@Reducer`, `TestStore`, `TestClock`), SQLiteData/GRDB append-only migrations, ReTiCA (`LXMessage`, `MsgPackValue`).

**Spec:** `docs/superpowers/specs/2026-10-05-disappearing-messages-design.md` (app main, amendments A1–A9 at its end). The spec is the authority; this plan argues from it.

## Global Constraints

- **Where:** all work happens ONLY in the app worktree `/Users/ell/development/ios/apps/ReTiCAMsgr-disappearing` on branch `feat/disappearing-messages`, cut from app `main` in Task 0. `APP` below means that path; `CORE` means `APP/ReTiCAMsgrCore`. Never build, test or run git against the main checkout `/Users/ell/development/ios/apps/ReTiCAMsgr` after Task 0's `worktree add`, and never touch `/Users/ell/development/ios/pods/ReTiCA` (read-only path dependency; `CORE/Package.swift`'s `../../../pods/ReTiCA` resolves from the worktree unchanged).
- **Task 0 is a gate:** the baseline core suite `swift test --package-path CORE` must be green and `xcodebuild -project APP/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build` must succeed before Task 1. Record the baseline test count in `/tmp/ReTiCAMsgr/exp-baseline.txt`.
- **Commits** go on `feat/disappearing-messages` only. Stage explicit paths (`git -C APP add <path> ...`, never `-A`/`.`). Never stage `ReTiCAMsgr.xcodeproj/xcuserdata/**`, `ReTiCAMsgrCore/.swiftpm/**` or `Package.resolved`. Each task writes its message to its OWN file `/tmp/ReTiCAMsgr/msg-exp-task-N.txt` with the Write tool, then `git -C APP commit -F /tmp/ReTiCAMsgr/msg-exp-task-N.txt`. Message = `feat:`/`fix:`/`test:`/`docs:` subject, blank line, body, blank line, then exactly these two lines at column 0 (the first names the model that wrote the commit):
  `Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1`
  No semicolons anywhere in a commit message.
- **Shell:** one command per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreters (`python -c`, heredocs into an interpreter). Scripts go in files under `/tmp/ReTiCAMsgr/` (`mkdir -p /tmp/ReTiCAMsgr` if missing). Redirecting one command's output to a file (`cmd > /tmp/ReTiCAMsgr/x.log 2>&1`) is allowed.
- **Tests:** `swift test --package-path CORE --filter <prefix>` runs one task's tests; the full core suite is `swift test --package-path CORE`. Known flake: `deliveryFailedMarksFailedAndReloads` can fail when run ALONE via `--filter`; it passes in a full run. Never run `swift test` and `xcodebuild` at the same time on the same package. Filtering still compiles every target, so the whole package must compile at the end of every task. Every new test name starts with its task's prefix — `expiryTable` (T1), `expiryWire` (T2), `expiryPreset` (T3), `expiryPurge` (T4), `expirySend` (T5), `expiryReceive` (T6), `expiryTimer` (T7), `expiryInfo` (T8). None of these prefixes matches an existing test name (checked: the only existing names containing "expir" are `expiredLearnedDestinationsArePrunedAtLaunch` and `attachTransferInboundEntryExpiresAfterSilence`, neither of which contains `expiry`).
- **Mutation verification is mandatory** for every task with tests: (a) run the task's filter, all GREEN; (b) apply the task's listed mutation batch to production code, run the filter once, confirm EVERY listed test is RED — where the table says "sub-batch", run the sub-batches separately so no mutation masks another; (c) revert every mutation BY HAND with the Edit tool (never `git checkout -- <file>`), confirm `git -C APP diff` shows only the task's intended changes, run again, all GREEN. If a test survives its mutation, fix the test and restart at (a). Tests edited only mechanically to compile against a new shape are exempt.
- **TCA TestStore facts these tests rely on:** under `exhaustivity = .off`, `store.state` reflects effect-delivered actions only after `receive` or `await store.skipReceivedActions(strict: false)`; every `send` clears not-yet-received actions, so a `receive` for something an earlier `send` produced must come before the next `send`; absence claims go `.on` + an exhaustive no-op probe send; file-scope `let` constants of TCA `Action` types need `@MainActor`. `\.date` is frozen at 1700000000 (`infoT0`) in `makeStore`; move it mid-test with `store.dependencies.date = .constant(infoT0.addingTimeInterval(30))` BEFORE advancing the `TestClock`, or a purge will see nothing due. The reducer calls `UUID()` directly.
- **Test style** (match `AppFeatureTests.swift`): free `@MainActor @Test func` functions, `makeStore(db, identity:)` with `exhaustivity = .off`, `sendAndSettle` + `skipReceivedActions(strict: false)` before reading rows, `#expect` with literals. New AppFeature tests go in `AppFeatureTests.swift` so they can use its private helpers (`makeStore`, `seed`, `msg`, `uuid`, `peerA`, `peerB`, `infoT0`, `sendAndSettle`, `wireMessage`, `receiveAndFetch`, `pendingImage`, `attachTempStore`, `rowsByHashAndDirection`).
- **`Attachment` vs `Testing.Attachment`:** every TEST file that names the model type adds `import struct ReTiCAMsgrCore.Attachment` after its imports (as `AttachmentStoreTests.swift` does). Production code is unaffected.
- **Constants (from the spec and amendments):** `ExpiryWire.fieldCustomMeta = 0xFD`, `secondsKey = "reticamsgr.expiry"`, `changeKey = "reticamsgr.expiry.change"`, `maxSeconds = 2_419_200`; presets Off/30 s/5 min/1 h/8 h/1 day/1 week/4 weeks; announcement bodies `Disappearing messages set to <label>` / `Disappearing messages turned off`; peer line `<name> set disappearing messages to <label>` / `<name> turned disappearing messages off`, name falling back to `ReplyPreview.them` ("Them"); caveat `Only ReTiCAMsgr peers honour this. Other apps keep messages.`; migration name `addDisappearingMessages`; table `conversationSettings`.
- **App target:** new SwiftUI files go in `APP/ReTiCAMsgr/` (synchronized folders, no pbxproj edit). The app build must succeed at the end of Task 9; every core task must leave the package compiling, which the filtered test runs prove.

## Review Focus

Inputs the spec implies but its own examples don't exercise, most likely to bite first. Each is pinned by a named test in the owning task.

1. **A timer change from an unvalidated sender** must not flip the conversation timer or render as an announcement: it is stored as plain text and the setting is untouched. Test: T6 `expiryReceiveUnvalidatedChangeIsPlainText`.
2. **A 0xFD value from another app** (lxmf-group-hub writes a non-map; a map without our key) must neither drop the message nor set a timer. Tests: T2 `expiryWireDecodeIgnoresForeignCustomMeta`, T6 `expiryReceiveMalformedFieldIsPlainText`.
3. **An out-of-range duration from a hostile peer** (negative, over 4 weeks, a string) must be ignored, never stored as an absurd `expiresAt`. Test: T2 `expiryWireDecodeRejectsOutOfRangeValues`.
4. **A message that also carries an attachment or a reply** must keep the 0xFD field, after 0x05/0x06 and 0x30/0x31. Test: T5 `expirySendAttachmentCarriesFieldAfterAttachmentAndReply`.
5. **A row that fell due while the app was suspended** must be purged on the next launch, file and reactions included. Test: T7 `expiryTimerLaunchPurgesRowsDueWhileSuspended`.

---

### Task 0: Worktree and baseline

**Files:** none changed.

- [x] **Step 1: Create the worktree from app main**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr worktree add /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing -b feat/disappearing-messages main`
Expected: a new worktree at `APP` on `feat/disappearing-messages`, HEAD = app main (504bb42 or later).

- [x] **Step 2: Temp directory**

Run: `mkdir -p /tmp/ReTiCAMsgr`

- [x] **Step 3: Baseline core suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore > /tmp/ReTiCAMsgr/exp-t0-core.log 2>&1`
Expected: the log ends with `Test run with N tests in 0 suites passed`. Write `N` to `/tmp/ReTiCAMsgr/exp-baseline.txt` with the Write tool.

- [x] **Step 4: Baseline app build**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCAMsgr/exp-t0-xcodebuild.log 2>&1`
Expected: `** BUILD SUCCEEDED **` at the end of the log.

- [x] **Step 5: Restore any files Xcode rewrote**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing status --short`
Expected: empty. If the two `xcschememanagement.plist` files show as modified, restore them with `git -C APP checkout -- <path>` (the ONLY `git checkout --` allowed in this plan, only here and in Task 9 Step 8). Nothing to commit.

---

### Task 1: Schema, `Message` columns, `ConversationSetting`

**Files:**
- Modify: `CORE/Sources/ReTiCAMsgrCore/Database.swift` (new migration after `createAttachments`)
- Modify: `CORE/Sources/ReTiCAMsgrCore/Message.swift` (three properties after `propagationRefused`)
- Create: `CORE/Sources/ReTiCAMsgrCore/ConversationSetting.swift`
- Modify: `CORE/Tests/ReTiCAMsgrCoreTests/DatabaseTests.swift` (append)

**Interfaces:**
- Produces: `Message.expirySeconds: Int?`, `Message.expiresAt: Date?`, `Message.isTimerChange: Bool` (init parameters after `propagationRefused`, defaults `nil`, `nil`, `false`). `ConversationSetting` (`@Table`): `peerHex: String`, `expirySeconds: Int?`, `updatedAt: Date`; `static func expiry(for peerHex: String, _ db: GRDB.Database) throws -> Int?` (nil for no row, NULL or 0); `static func set(_ peerHex: String, seconds: Int, at now: Date, _ db: GRDB.Database) throws` (upsert; 0 stored as NULL). Migration `addDisappearingMessages`.

- [x] **Step 1: Write the failing tests**

Append to `CORE/Tests/ReTiCAMsgrCoreTests/DatabaseTests.swift`:

```swift

// MARK: - Disappearing messages (addDisappearingMessages)

private func expiryTableMessage(_ id: String, hash: String) -> Message {
    Message(
        id: UUID(uuidString: id)!,
        peerHex: String(repeating: "c", count: 32),
        isOutgoing: false,
        body: "soon gone",
        timestamp: Date(timeIntervalSince1970: 1700000000),
        status: MessageStatus.received,
        validated: true,
        messageHash: hash
    )
}

/// Literal expectations, not only `back == m`, so a model that drops a field on init cannot pass
/// by dropping it on both sides.
@Test func expiryTableMessageColumnsRoundTrip() throws {
    let db = try AppDatabase.makeInMemory()
    var m = expiryTableMessage("00000000-0000-0000-0000-000000000020", hash: String(repeating: "f", count: 64))
    m.expirySeconds = 86_400
    m.expiresAt = Date(timeIntervalSince1970: 1700086400)
    m.isTimerChange = true
    try db.write { try Message.insert { m }.execute($0) }
    let back = try #require(try db.read { try Message.all.fetchAll($0) }.first)
    #expect(back.expirySeconds == 86_400)
    #expect(back.expiresAt == Date(timeIntervalSince1970: 1700086400))
    #expect(back.isTimerChange == true)
    #expect(back == m)
}

/// Init defaults: a row built without the new parameters is an ordinary, never-expiring message.
@Test func expiryTableInitDefaultsAreNilNilFalse() {
    let m = expiryTableMessage("00000000-0000-0000-0000-000000000021", hash: "")
    #expect(m.expirySeconds == nil)
    #expect(m.expiresAt == nil)
    #expect(m.isTimerChange == false)
}

/// A row written before `addDisappearingMessages` reads back with no expiry and `isTimerChange`
/// false, so every message from before this feature is an ordinary bubble.
@Test func expiryTableLegacyRowReadsBackWithDefaults() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator().migrate(queue, upTo: "createAttachments")
    try queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO messages (id, peerHex, isOutgoing, body, timestamp, status, validated, messageHash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: ["00000000-0000-0000-0000-000000000022", String(repeating: "c", count: 32),
                        0, "old", "2023-11-14 22:13:20.000", MessageStatus.received, 1, ""]
        )
    }
    try AppDatabase.migrator().migrate(queue)
    let row = try #require(try queue.read { try Message.all.fetchAll($0) }.first)
    #expect(row.body == "old")
    #expect(row.expirySeconds == nil)
    #expect(row.expiresAt == nil)
    #expect(row.isTimerChange == false)
}

@Test func expiryTableConversationSettingUpsertsAndReadsOff() throws {
    let db = try AppDatabase.makeInMemory()
    let peer = String(repeating: "d", count: 32)
    let t1 = Date(timeIntervalSince1970: 1700000000)
    let t2 = Date(timeIntervalSince1970: 1700000100)
    try db.write { try ConversationSetting.set(peer, seconds: 600, at: t1, $0) }
    #expect(try db.read { try ConversationSetting.expiry(for: peer, $0) } == 600)
    try db.write { try ConversationSetting.set(peer, seconds: 0, at: t2, $0) }
    let rows = try db.read { try ConversationSetting.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.expirySeconds == nil)
    #expect(rows.first?.updatedAt == t2)
    #expect(try db.read { try ConversationSetting.expiry(for: peer, $0) } == nil)
}

@Test func expiryTableConversationSettingMissingPeerIsNil() throws {
    let db = try AppDatabase.makeInMemory()
    #expect(try db.read { try ConversationSetting.expiry(for: String(repeating: "e", count: 32), $0) } == nil)
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryTable > /tmp/ReTiCAMsgr/exp-t1-red.log 2>&1`
Expected: compile errors (`expirySeconds`, `ConversationSetting` unknown).

- [x] **Step 3: Add the migration**

In `CORE/Sources/ReTiCAMsgrCore/Database.swift`, after the `createAttachments` migration's closing `}` and before `return m`:

```swift
        m.registerMigration("addDisappearingMessages") { db in
            // Disappearing messages (spec 2026-10-05 §2). `expirySeconds` is the duration carried
            // on the wire, `expiresAt` the absolute deletion time the purge reads: NULL with a
            // duration means "received, not yet viewed". `isTimerChange` marks the announcement
            // rows that render as a system line and never expire. Rows from before this
            // migration read back NULL / NULL / false: ordinary, never-expiring bubbles.
            try db.alter(table: "messages") { t in
                t.add(column: "expirySeconds", .integer)
                t.add(column: "expiresAt", .datetime)
                t.add(column: "isTimerChange", .boolean).notNull().defaults(to: false)
            }
            // The shared per-conversation timer. Not in `learnedPeerRows`: that is an announce
            // cache, pruned after 45 days and replaced on every announce.
            try db.create(table: "conversationSettings") { t in
                t.primaryKey("peerHex", .text).notNull()
                t.column("expirySeconds", .integer)   // NULL = off
                t.column("updatedAt", .datetime).notNull()
            }
        }
```

- [x] **Step 4: Add the `Message` properties**

In `CORE/Sources/ReTiCAMsgrCore/Message.swift`, after `public var propagationRefused: String?`:

```swift
    /// Disappearing messages: the duration in seconds carried in FIELD_CUSTOM_META (0xFD).
    /// nil when this message never disappears.
    public var expirySeconds: Int?
    /// When the purge deletes this row. Outgoing: set at send. Incoming: set on first view in the
    /// open thread, so nil with a non-nil `expirySeconds` means "not viewed yet".
    public var expiresAt: Date?
    /// A timer-change announcement ("Disappearing messages set to 1 day"): rendered as a system
    /// line, never carries an attachment or reactions, never expires.
    public var isTimerChange: Bool
```

Add init parameters after `propagationRefused: String? = nil`:

```swift
        propagationRefused: String? = nil,
        expirySeconds: Int? = nil,
        expiresAt: Date? = nil,
        isTimerChange: Bool = false
```

and assignments after `self.propagationRefused = propagationRefused`:

```swift
        self.expirySeconds = expirySeconds
        self.expiresAt = expiresAt
        self.isTimerChange = isTimerChange
```

Update the type's doc comment's last sentence to mention `addDisappearingMessages` beside `addReplies`.

- [x] **Step 5: Create `ConversationSetting.swift`**

```swift
import Foundation
import GRDB
import SQLiteData

/// The shared disappearing-messages timer of one conversation (spec 2026-10-05 §2). `peerHex` is
/// the other party's lxmf.delivery hash (hex). `expirySeconds` NULL means off; the row is kept so
/// `updatedAt` records when the timer last changed.
@Table
public struct ConversationSetting: Equatable, Sendable {
    public var peerHex: String
    public var expirySeconds: Int?
    public var updatedAt: Date

    public init(peerHex: String, expirySeconds: Int?, updatedAt: Date) {
        self.peerHex = peerHex
        self.expirySeconds = expirySeconds
        self.updatedAt = updatedAt
    }

    /// The active timer for `peerHex` in seconds, or nil when there is none: no row, NULL, or 0.
    public static func expiry(for peerHex: String, _ db: GRDB.Database) throws -> Int? {
        guard let row = try ConversationSetting.where { $0.peerHex.eq(peerHex) }.fetchOne(db),
              let seconds = row.expirySeconds, seconds > 0
        else { return nil }
        return seconds
    }

    /// Upsert. 0 (and any negative value) is stored as NULL, meaning off.
    public static func set(_ peerHex: String, seconds: Int, at now: Date, _ db: GRDB.Database) throws {
        try ConversationSetting.where { $0.peerHex.eq(peerHex) }.delete().execute(db)
        try ConversationSetting.insert {
            ConversationSetting(peerHex: peerHex, expirySeconds: seconds > 0 ? seconds : nil, updatedAt: now)
        }.execute(db)
    }
}
```

- [x] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryTable > /tmp/ReTiCAMsgr/exp-t1-green.log 2>&1`
Expected: 5 tests passed.

- [x] **Step 7: Mutation verification**

| Mutation (production code) | Test that must go RED |
|---|---|
| In `Message.init`, replace `self.isTimerChange = isTimerChange` with `self.isTimerChange = false` | `expiryTableMessageColumnsRoundTrip` |
| In `Message.init`, replace `self.expirySeconds = expirySeconds` with `self.expirySeconds = 0` | `expiryTableInitDefaultsAreNilNilFalse` |
| In the migration, change `.defaults(to: false)` to `.defaults(to: true)` | `expiryTableLegacyRowReadsBackWithDefaults` |
| In `ConversationSetting.set`, delete the `.delete().execute(db)` line | `expiryTableConversationSettingUpsertsAndReadsOff` (two rows, or `expiry` still 600) |
| In `ConversationSetting.expiry`, change `else { return nil }` to `else { return 0 }` | `expiryTableConversationSettingMissingPeerIsNil` |

Apply all five, run the filter once, confirm all five RED. Revert by hand, run again, all GREEN.

- [x] **Step 8: Commit**

Write `/tmp/ReTiCAMsgr/msg-exp-task-1.txt`:

```
feat: disappearing-messages schema and conversation settings

Adds expirySeconds, expiresAt and isTimerChange to messages and the
conversationSettings table (migration addDisappearingMessages), the
Message properties with defaults, and ConversationSetting with expiry(for:)
and set(_:seconds:at:) where 0 is stored as NULL.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C APP add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Database.swift ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Message.swift ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ConversationSetting.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/DatabaseTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCAMsgr/msg-exp-task-1.txt`

---

### Task 2: `ExpiryWire` codec

**Files:**
- Create: `CORE/Sources/ReTiCAMsgrCore/ExpiryWire.swift`
- Create: `CORE/Tests/ReTiCAMsgrCoreTests/ExpiryWireTests.swift`

**Interfaces:**
- Produces: `ExpiryWire.fieldCustomMeta = 0xFD`, `secondsKey`, `changeKey`, `maxSeconds = 2_419_200`; `struct Decoded: Equatable, Sendable { seconds: Int; isChange: Bool }`; `static func clamp(_ seconds: Int) -> Int` (0...maxSeconds); `static func encode(seconds: Int) -> [MsgPackValue.IntPair]` (one 0xFD field, map with `secondsKey` only); `static func encodeChange(seconds: Int) -> [MsgPackValue.IntPair]` (adds `changeKey: true`); `static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded?` (nil = no expiry).

- [x] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCAMsgrCoreTests/ExpiryWireTests.swift`:

```swift
import Testing
import Foundation
import ReTiCA
@testable import ReTiCAMsgrCore

/// A 0xFD field built by hand, so these tests pin the wire shape rather than `encode`.
private func meta(_ value: MsgPackValue) -> [MsgPackValue.IntPair] { [.init(0xFD, value)] }

@Test func expiryWireConstantsMatchTheSpec() {
    #expect(ExpiryWire.fieldCustomMeta == 0xFD)
    #expect(ExpiryWire.secondsKey == "reticamsgr.expiry")
    #expect(ExpiryWire.changeKey == "reticamsgr.expiry.change")
    #expect(ExpiryWire.maxSeconds == 2_419_200)
}

/// Spec §1: one field, a string-keyed map, the duration as an unsigned integer.
@Test func expiryWireEncodeIsOneMetaFieldWithTheSecondsKey() {
    let fields = ExpiryWire.encode(seconds: 86_400)
    #expect(fields.count == 1)
    #expect(fields[0].key == 0xFD)
    #expect(fields[0].value == .map([.init("reticamsgr.expiry", .uint(86_400))]))
}

/// Amendment A1: a timer-change message adds a boolean flag beside the duration.
@Test func expiryWireEncodeChangeAddsTheFlag() {
    let fields = ExpiryWire.encodeChange(seconds: 0)
    #expect(fields[0].value == .map([
        .init("reticamsgr.expiry", .uint(0)),
        .init("reticamsgr.expiry.change", .bool(true)),
    ]))
    #expect(ExpiryWire.decode(fields) == ExpiryWire.Decoded(seconds: 0, isChange: true))
}

@Test func expiryWireRoundTripsThroughRealLXMessage() throws {
    let m = LXMessage.create(
        source: Identity(),
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data(),
        content: Data("gone soon".utf8),
        fields: ExpiryWire.encode(seconds: 300)
    )
    let back = try #require(LXMessage.unpack(m.packed))
    #expect(back.content == Data("gone soon".utf8))
    #expect(back.fields.map(\.key) == [0xFD])
    #expect(ExpiryWire.decode(back.fields) == ExpiryWire.Decoded(seconds: 300, isChange: false))
}

/// Review Focus 3: a hostile or buggy peer cannot plant an absurd duration.
@Test func expiryWireDecodeRejectsOutOfRangeValues() {
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .int(-5))]))) == nil)
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .uint(2_419_201))]))) == nil)
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .string("86400"))]))) == nil)
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .double(60))]))) == nil)
    // The cap itself is fine, and a non-negative `.int` tag is accepted like `.uint`.
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .uint(2_419_200))])))?.seconds == 2_419_200)
    #expect(ExpiryWire.decode(meta(.map([.init("reticamsgr.expiry", .int(60))])))?.seconds == 60)
}

/// Review Focus 2: another app's 0xFD (a non-map, or a map without our key) is not an expiry, and
/// extra keys beside ours are ignored. No field at all is nil too.
@Test func expiryWireDecodeIgnoresForeignCustomMeta() {
    #expect(ExpiryWire.decode([]) == nil)
    #expect(ExpiryWire.decode(meta(.bin(Data([1, 2, 3])))) == nil)
    #expect(ExpiryWire.decode(meta(.map([.init("somebody.else", .uint(9))]))) == nil)
    #expect(ExpiryWire.decode(meta(.intMap([.init(0, .uint(9))]))) == nil)
    let mixed = meta(.map([.init("somebody.else", .string("x")), .init("reticamsgr.expiry", .uint(30))]))
    #expect(ExpiryWire.decode(mixed) == ExpiryWire.Decoded(seconds: 30, isChange: false))
    // A change flag that is not literally `true` is not a change.
    let notFlag = meta(.map([.init("reticamsgr.expiry", .uint(30)), .init("reticamsgr.expiry.change", .uint(1))]))
    #expect(ExpiryWire.decode(notFlag) == ExpiryWire.Decoded(seconds: 30, isChange: false))
}

@Test func expiryWireClampBoundsToZeroAndTheCap() {
    #expect(ExpiryWire.clamp(-1) == 0)
    #expect(ExpiryWire.clamp(0) == 0)
    #expect(ExpiryWire.clamp(60) == 60)
    #expect(ExpiryWire.clamp(99_999_999) == 2_419_200)
    #expect(ExpiryWire.encode(seconds: 99_999_999)[0].value == .map([.init("reticamsgr.expiry", .uint(2_419_200))]))
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryWire > /tmp/ReTiCAMsgr/exp-t2-red.log 2>&1`
Expected: compile error, `ExpiryWire` unknown.

- [x] **Step 3: Create `ExpiryWire.swift`**

```swift
import Foundation
import ReTiCA

/// Wire codec for the disappearing-messages timer carried in LXMF `fields` (spec 2026-10-05 §1,
/// amendment A1). `FIELD_CUSTOM_META` (0xFD, "for custom data structures" per LXMF.py) holds a
/// string-keyed msgpack map: `reticamsgr.expiry` = duration in seconds (uint), and on a
/// timer-change message `reticamsgr.expiry.change` = true. 0xFB/0xFC are left alone: Retichat uses
/// that pair for key transfer, and a message has only one of it.
///
/// Received leniently: no 0xFD, a 0xFD that is not a map (lxmf-group-hub writes other data there), a
/// map without our key, a value that is not an integer, a negative value or one over the cap all
/// decode as `nil` ("no expiry"). A malformed field never drops the message. Reference LXMF has no
/// expiry field of its own (re-checked 2026-10-05).
public enum ExpiryWire {
    public static let fieldCustomMeta = 0xFD
    public static let secondsKey = "reticamsgr.expiry"
    public static let changeKey = "reticamsgr.expiry.change"
    /// Four weeks, the longest preset.
    public static let maxSeconds = 2_419_200

    public struct Decoded: Equatable, Sendable {
        public var seconds: Int
        /// The message announces a new conversation timer (0 = off) rather than carrying one.
        public var isChange: Bool

        public init(seconds: Int, isChange: Bool) {
            self.seconds = seconds
            self.isChange = isChange
        }
    }

    public static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, 0), maxSeconds)
    }

    /// The field on an ordinary message in a conversation whose timer is on.
    public static func encode(seconds: Int) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([.init(secondsKey, .uint(UInt64(clamp(seconds))))]))]
    }

    /// The field on a timer-change announcement. `seconds == 0` turns the timer off.
    public static func encodeChange(seconds: Int) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([
            .init(secondsKey, .uint(UInt64(clamp(seconds)))),
            .init(changeKey, .bool(true)),
        ]))]
    }

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded? {
        guard case let .map(pairs)? = fields.first(where: { $0.key == fieldCustomMeta })?.value,
              let value = pairs.first(where: { $0.key == secondsKey })?.value,
              let seconds = nonNegativeSeconds(value)
        else { return nil }
        let isChange: Bool
        if case .bool(true)? = pairs.first(where: { $0.key == changeKey })?.value {
            isChange = true
        } else {
            isChange = false
        }
        return Decoded(seconds: seconds, isChange: isChange)
    }

    /// `uint`, or a non-negative `int` tag, within 0...maxSeconds. Anything else is nil.
    static func nonNegativeSeconds(_ value: MsgPackValue) -> Int? {
        switch value {
        case let .uint(u):
            return u <= UInt64(maxSeconds) ? Int(u) : nil
        case let .int(i):
            return (0...Int64(maxSeconds)).contains(i) ? Int(i) : nil
        default:
            return nil
        }
    }
}
```

- [x] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryWire > /tmp/ReTiCAMsgr/exp-t2-green.log 2>&1`
Expected: 7 tests passed.

- [x] **Step 5: Mutation verification**

| Mutation | Test that must go RED |
|---|---|
| `maxSeconds = 2_419_201` | `expiryWireConstantsMatchTheSpec` |
| In `encode`, use `.int(Int64(...))` instead of `.uint` | `expiryWireEncodeIsOneMetaFieldWithTheSecondsKey` |
| In `encodeChange`, drop the `changeKey` pair | `expiryWireEncodeChangeAddsTheFlag` |
| In `decode`, return `Decoded(seconds: 0, isChange: false)` when the key is missing (replace the `else { return nil }` with that) | `expiryWireDecodeIgnoresForeignCustomMeta` |
| In `nonNegativeSeconds`, `.uint` branch: drop the cap check (`return Int(u)`) | `expiryWireDecodeRejectsOutOfRangeValues` |
| In `clamp`, remove `min(..., maxSeconds)` | `expiryWireClampBoundsToZeroAndTheCap` |
| In `decode`, after decoding, `return Decoded(seconds: seconds + 1, isChange: isChange)` (sub-batch B, alone) | `expiryWireRoundTripsThroughRealLXMessage` |

Run sub-batch A (first six) once, all six RED; revert; run sub-batch B, RED; revert; all GREEN.

- [x] **Step 6: Commit**

Write `/tmp/ReTiCAMsgr/msg-exp-task-2.txt` (subject `feat: ExpiryWire codec for FIELD_CUSTOM_META 0xFD`, body naming the keys, the cap, the change flag and the lenient decode, then the two trailer lines).

Run: `git -C APP add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ExpiryWire.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ExpiryWireTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCAMsgr/msg-exp-task-2.txt`

---

### Task 3: `ExpiryPreset` labels and announcement text

**Files:**
- Create: `CORE/Sources/ReTiCAMsgrCore/ExpiryPreset.swift`
- Create: `CORE/Tests/ReTiCAMsgrCoreTests/ExpiryPresetTests.swift`

**Interfaces:**
- Consumes: `ReplyPreview.them` ("Them", existing).
- Produces: `enum ExpiryPreset: Int, CaseIterable, Sendable` with cases `off = 0, thirtySeconds = 30, fiveMinutes = 300, oneHour = 3_600, eightHours = 28_800, oneDay = 86_400, oneWeek = 604_800, fourWeeks = 2_419_200`; `var seconds: Int`; `var label: String`; `static let offLabel = "Off"`; `static let caveat`; `static func label(forSeconds:) -> String`; `static func announcement(seconds:) -> String`; `static func peerAnnouncement(peerName: String?, seconds: Int) -> String`.

- [x] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCAMsgrCoreTests/ExpiryPresetTests.swift`:

```swift
import Testing
@testable import ReTiCAMsgrCore

@Test func expiryPresetCasesAreSignalsInOrder() {
    #expect(ExpiryPreset.allCases.map(\.seconds) == [0, 30, 300, 3_600, 28_800, 86_400, 604_800, 2_419_200])
    #expect(ExpiryPreset.allCases.map(\.label)
            == ["Off", "30 seconds", "5 minutes", "1 hour", "8 hours", "1 day", "1 week", "4 weeks"])
    #expect(ExpiryPreset.fourWeeks.seconds == ExpiryWire.maxSeconds)
}

/// A peer may send a value that is not a preset: the largest unit that divides it evenly.
@Test func expiryPresetLabelForArbitrarySeconds() {
    #expect(ExpiryPreset.label(forSeconds: 0) == "Off")
    #expect(ExpiryPreset.label(forSeconds: 1) == "1 second")
    #expect(ExpiryPreset.label(forSeconds: 90) == "90 seconds")
    #expect(ExpiryPreset.label(forSeconds: 120) == "2 minutes")
    #expect(ExpiryPreset.label(forSeconds: 7_200) == "2 hours")
    #expect(ExpiryPreset.label(forSeconds: 172_800) == "2 days")
    #expect(ExpiryPreset.label(forSeconds: 1_209_600) == "2 weeks")
    #expect(ExpiryPreset.label(forSeconds: 3_660) == "61 minutes")
}

@Test func expiryPresetAnnouncementBodies() {
    #expect(ExpiryPreset.announcement(seconds: 86_400) == "Disappearing messages set to 1 day")
    #expect(ExpiryPreset.announcement(seconds: 0) == "Disappearing messages turned off")
    #expect(ExpiryPreset.peerAnnouncement(peerName: "Ada", seconds: 300) == "Ada set disappearing messages to 5 minutes")
    #expect(ExpiryPreset.peerAnnouncement(peerName: "Ada", seconds: 0) == "Ada turned disappearing messages off")
    #expect(ExpiryPreset.peerAnnouncement(peerName: nil, seconds: 300) == "Them set disappearing messages to 5 minutes")
}

@Test func expiryPresetCaveatNamesOtherApps() {
    #expect(ExpiryPreset.caveat == "Only ReTiCAMsgr peers honour this. Other apps keep messages.")
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryPreset > /tmp/ReTiCAMsgr/exp-t3-red.log 2>&1`
Expected: compile error, `ExpiryPreset` unknown.

- [x] **Step 3: Create `ExpiryPreset.swift`**

```swift
import Foundation

/// The disappearing-messages durations the toolbar menu offers (Signal's presets, spec §4), their
/// labels, and the text of the announcement rows. Pure, so the strings are testable and the same
/// label serves the menu, the title indicator, the Info sheet and the announcements.
public enum ExpiryPreset: Int, CaseIterable, Sendable {
    case off = 0
    case thirtySeconds = 30
    case fiveMinutes = 300
    case oneHour = 3_600
    case eightHours = 28_800
    case oneDay = 86_400
    case oneWeek = 604_800
    case fourWeeks = 2_419_200

    public var seconds: Int { rawValue }
    public var label: String { Self.label(forSeconds: rawValue) }

    public static let offLabel = "Off"
    /// Shown with the menu: Sideband, NomadNet and Retichat ignore the field and keep the message.
    public static let caveat = "Only ReTiCAMsgr peers honour this. Other apps keep messages."

    /// "Off" for 0, otherwise the largest unit that divides the value evenly, so a peer's
    /// non-preset value still reads naturally ("90 seconds", "2 hours").
    public static func label(forSeconds seconds: Int) -> String {
        guard seconds > 0 else { return offLabel }
        let units: [(size: Int, name: String)] = [(604_800, "week"), (86_400, "day"), (3_600, "hour"), (60, "minute")]
        for unit in units where seconds % unit.size == 0 {
            return plural(seconds / unit.size, unit.name)
        }
        return plural(seconds, "second")
    }

    /// The body of the timer-change message this device sends (it is also what other LXMF clients
    /// display, since they ignore the field).
    public static func announcement(seconds: Int) -> String {
        seconds > 0
            ? "Disappearing messages set to \(label(forSeconds: seconds))"
            : "Disappearing messages turned off"
    }

    /// The local line for a change the peer made (a received change message with an empty body,
    /// or the convergence rule, spec §3). `peerName` nil falls back to "Them", as reply previews do.
    public static func peerAnnouncement(peerName: String?, seconds: Int) -> String {
        let who = peerName ?? ReplyPreview.them
        return seconds > 0
            ? "\(who) set disappearing messages to \(label(forSeconds: seconds))"
            : "\(who) turned disappearing messages off"
    }

    static func plural(_ n: Int, _ unit: String) -> String {
        n == 1 ? "1 \(unit)" : "\(n) \(unit)s"
    }
}
```

- [x] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryPreset > /tmp/ReTiCAMsgr/exp-t3-green.log 2>&1`
Expected: 4 tests passed.

- [x] **Step 5: Mutation verification**

| Mutation | Test that must go RED |
|---|---|
| Change `case eightHours = 28_800` to `= 28_000` | `expiryPresetCasesAreSignalsInOrder` |
| In `label(forSeconds:)`, remove the `(60, "minute")` unit | `expiryPresetLabelForArbitrarySeconds` |
| In `peerAnnouncement`, replace `peerName ?? ReplyPreview.them` with `peerName ?? ""` | `expiryPresetAnnouncementBodies` |
| Change `caveat` to end with "keep messages" (no full stop) | `expiryPresetCaveatNamesOtherApps` |

All four in one batch, all RED; revert; GREEN.

- [x] **Step 6: Commit**

Write `/tmp/ReTiCAMsgr/msg-exp-task-3.txt` (subject `feat: ExpiryPreset labels and announcement text`, body, trailers).

Run: `git -C APP add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ExpiryPreset.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ExpiryPresetTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCAMsgr/msg-exp-task-3.txt`

---

### Task 4: `MessagePurge` and `AttachmentStore.deleteExports`

**Files:**
- Create: `CORE/Sources/ReTiCAMsgrCore/MessagePurge.swift`
- Modify: `CORE/Sources/ReTiCAMsgrCore/AttachmentStore.swift` (new method after `exportURL`)
- Create: `CORE/Tests/ReTiCAMsgrCoreTests/MessagePurgeTests.swift`

**Interfaces:**
- Consumes: `Message.expiresAt`, `Attachment` (`messageId`, `path`, `hasBytes`, `id`), `Reaction`, `AttachmentStore.delete(_:)`, `AttachmentStore.exportURL(for:)`, `AttachmentStore.exportDirectory`.
- Produces: `MessagePurge.Result: Equatable, Sendable { purged: Int; nextDue: Date? }`; `static func run(_ database: any DatabaseWriter, attachmentStore: AttachmentStore, now: Date) async throws -> Result`. `AttachmentStore.deleteExports(for attachment: Attachment)` (non-throwing; missing directory is fine).

- [x] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCAMsgrCoreTests/MessagePurgeTests.swift`:

```swift
import Testing
import Foundation
import SQLiteData
import struct ReTiCAMsgrCore.Attachment
@testable import ReTiCAMsgrCore

private let purgeNow = Date(timeIntervalSince1970: 1700000000)
private let purgePeer = String(repeating: "7a", count: 16)

private func purgeStore() -> AttachmentStore {
    AttachmentStore(baseDirectory: FileManager.default.temporaryDirectory
        .appending(path: "expiryPurgeTests-\(UUID().uuidString)"))
}

private func purgeMessage(_ n: Int, expiresAt: Date?, expirySeconds: Int? = 60, hash: String? = nil) -> Message {
    Message(
        id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!,
        peerHex: purgePeer, isOutgoing: false, body: "m\(n)",
        timestamp: purgeNow.addingTimeInterval(TimeInterval(n)),
        status: MessageStatus.received, validated: true,
        messageHash: hash ?? String(repeating: String(format: "%02x", n), count: 32),
        expirySeconds: expirySeconds, expiresAt: expiresAt
    )
}

/// Spec §3 purge: the row, its attachment row (cascade), the attachment file, the export copy and
/// its reaction rows all go. `purged` counts the rows.
@Test func expiryPurgeDeletesDueRowWithFileExportAttachmentAndReactions() async throws {
    let db = try AppDatabase.makeInMemory()
    let files = purgeStore()
    let due = purgeMessage(1, expiresAt: purgeNow.addingTimeInterval(-1))
    let path = try files.store(Data([1, 2, 3]), messageHash: due.messageHash, outgoing: false, ext: "bin")
    let attachment = Attachment(id: UUID(), messageId: due.id, kind: AttachmentKind.file, name: "notes.bin",
                                format: "bin", size: 3, width: nil, height: nil, path: path)
    let export = try files.exportURL(for: attachment)
    #expect(FileManager.default.fileExists(atPath: export.path))
    try await db.write { d in
        try Message.insert { due }.execute(d)
        try Attachment.insert { attachment }.execute(d)
        try Reaction.insert { Reaction(messageHash: due.messageHash, reactorHex: purgePeer, emoji: "👍", sentAt: 1) }.execute(d)
    }

    let result = try await MessagePurge.run(db, attachmentStore: files, now: purgeNow)

    #expect(result == MessagePurge.Result(purged: 1, nextDue: nil))
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Reaction.all.fetchAll($0) }.isEmpty)
    #expect(!files.exists(path))
    #expect(!FileManager.default.fileExists(atPath: export.deletingLastPathComponent().path))
}

/// A row due exactly now is due. Later rows stay and the earliest of them is the next due time.
@Test func expiryPurgeKeepsLaterRowsAndReturnsTheirDueTime() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { d in
        try Message.insert { purgeMessage(1, expiresAt: purgeNow) }.execute(d)
        try Message.insert { purgeMessage(2, expiresAt: purgeNow.addingTimeInterval(50)) }.execute(d)
        try Message.insert { purgeMessage(3, expiresAt: purgeNow.addingTimeInterval(5)) }.execute(d)
    }
    let result = try await MessagePurge.run(db, attachmentStore: purgeStore(), now: purgeNow)
    #expect(result == MessagePurge.Result(purged: 1, nextDue: purgeNow.addingTimeInterval(5)))
    let bodies = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }.map(\.body)
    #expect(bodies == ["m2", "m3"])
}

/// A received row that has a duration but was never viewed has no `expiresAt` and is never touched.
/// An ordinary row (no duration) is never touched either, and with nothing stamped there is no
/// next due time.
@Test func expiryPurgeIgnoresUnstampedAndOrdinaryRows() async throws {
    let db = try AppDatabase.makeInMemory()
    try await db.write { d in
        try Message.insert { purgeMessage(1, expiresAt: nil) }.execute(d)
        try Message.insert { purgeMessage(2, expiresAt: nil, expirySeconds: nil) }.execute(d)
    }
    let result = try await MessagePurge.run(db, attachmentStore: purgeStore(), now: purgeNow.addingTimeInterval(1_000_000))
    #expect(result == MessagePurge.Result(purged: 0, nextDue: nil))
    #expect(try await db.read { try Message.all.fetchAll($0) }.count == 2)
}

/// Only the purged messages' reactions go; the seen-hash table is untouched so a late propagation
/// copy is not re-stored as a new message.
@Test func expiryPurgeKeepsOtherReactionsAndSeenHashes() async throws {
    let db = try AppDatabase.makeInMemory()
    let due = purgeMessage(1, expiresAt: purgeNow.addingTimeInterval(-1))
    let kept = purgeMessage(2, expiresAt: nil, expirySeconds: nil)
    try await db.write { d in
        try Message.insert { due }.execute(d)
        try Message.insert { kept }.execute(d)
        try Reaction.insert { Reaction(messageHash: due.messageHash, reactorHex: purgePeer, emoji: "👍", sentAt: 1) }.execute(d)
        try Reaction.insert { Reaction(messageHash: kept.messageHash, reactorHex: purgePeer, emoji: "❤️", sentAt: 1) }.execute(d)
        try SeenHashRow.insert { SeenHashRow(hashHex: due.messageHash, storedAt: purgeNow) }.execute(d)
    }
    _ = try await MessagePurge.run(db, attachmentStore: purgeStore(), now: purgeNow)
    let reactions = try await db.read { try Reaction.all.fetchAll($0) }
    #expect(reactions.map(\.messageHash) == [kept.messageHash])
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.map(\.hashHex) == [due.messageHash])
}

@Test func expiryPurgeDeleteExportsRemovesTheDirectoryAndToleratesAbsence() throws {
    let files = purgeStore()
    let attachment = Attachment(id: UUID(), messageId: UUID(), kind: AttachmentKind.file, name: "a.txt",
                                format: "txt", size: 1, width: nil, height: nil, path: "")
    files.deleteExports(for: attachment)   // nothing there: not an error
    var withBytes = attachment
    withBytes.path = try files.store(Data([9]), messageHash: String(repeating: "ab", count: 32), outgoing: true, ext: "txt")
    let export = try files.exportURL(for: withBytes)
    let directory = export.deletingLastPathComponent()
    #expect(FileManager.default.fileExists(atPath: directory.path))
    files.deleteExports(for: withBytes)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryPurge > /tmp/ReTiCAMsgr/exp-t4-red.log 2>&1`
Expected: compile error, `MessagePurge` and `deleteExports` unknown.

- [x] **Step 3: Add `deleteExports` to `AttachmentStore`**

In `CORE/Sources/ReTiCAMsgrCore/AttachmentStore.swift`, after `exportURL(for:)`:

```swift
    /// Removes the export copies of one attachment (`exportDirectory/<id>/`). Called by the purge:
    /// the system clears tmp on its own schedule, which is too late for a message that was meant to
    /// disappear. A missing directory is fine; a failed removal is swallowed (nothing to do about it
    /// here, and the row must still go).
    public func deleteExports(for attachment: Attachment) {
        let directory = exportDirectory.appending(path: attachment.id.uuidString)
        guard fileExists(directory) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
```

- [x] **Step 4: Create `MessagePurge.swift`**

```swift
import Foundation
import GRDB
import OSLog
import SQLiteData

/// Deletes every message whose `expiresAt` has passed (spec 2026-10-05 §3 "Purge", amendment A2).
/// The app's first message deletion, so it owns every on-disk consequence: the export copies and
/// the attachment file go first (a row that outlives its file shows "unavailable"; a file that
/// outlives its row is the leak this feature exists to prevent), then the reaction rows (no
/// foreign key on that table) and the message row, whose attachment row cascades. Seen hashes are
/// kept so a late propagation copy is not re-stored.
public enum MessagePurge {
    public struct Result: Equatable, Sendable {
        /// Rows deleted in this run.
        public var purged: Int
        /// The earliest `expiresAt` still in the table, for the reducer's sleeper. nil = nothing armed.
        public var nextDue: Date?

        public init(purged: Int, nextDue: Date?) {
            self.purged = purged
            self.nextDue = nextDue
        }
    }

    static let log = Logger(subsystem: "com.reticamsgr", category: "expiry")

    /// The comparison runs in Swift over the stamped rows (amendment A3): there are few of them,
    /// and it avoids depending on optional-column comparison in the query builder.
    public static func run(_ database: any DatabaseWriter, attachmentStore: AttachmentStore,
                           now: Date) async throws -> Result {
        let stamped = try await database.read { db in
            try Message.where { $0.expiresAt.isNot(nil) }.fetchAll(db)
        }
        let due = stamped.filter { ($0.expiresAt ?? .distantFuture) <= now }
        guard !due.isEmpty else {
            return Result(purged: 0, nextDue: stamped.compactMap(\.expiresAt).min())
        }
        let ids = due.map(\.id)
        let hashes = due.map(\.messageHash).filter { !$0.isEmpty }
        let attachments = try await database.read { db in
            try Attachment.where { $0.messageId.in(ids) }.fetchAll(db)
        }
        for attachment in attachments {
            attachmentStore.deleteExports(for: attachment)
            guard attachment.hasBytes else { continue }
            do {
                try attachmentStore.delete(attachment.path)
            } catch {
                log.error("purge: could not delete \(attachment.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        try await database.write { db in
            if !hashes.isEmpty {
                try Reaction.where { $0.messageHash.in(hashes) }.delete().execute(db)
            }
            try Message.where { $0.id.in(ids) }.delete().execute(db)
        }
        let remaining = try await database.read { db in
            try Message.where { $0.expiresAt.isNot(nil) }.fetchAll(db)
        }
        return Result(purged: due.count, nextDue: remaining.compactMap(\.expiresAt).min())
    }
}
```

- [x] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryPurge > /tmp/ReTiCAMsgr/exp-t4-green.log 2>&1`
Expected: 5 tests passed. If `expiryPurgeDeletesDueRowWithFileExportAttachmentAndReactions` fails on the attachments table not being empty, foreign keys are off for that queue: add `try db.execute(sql: "PRAGMA foreign_keys = ON")` is NOT the fix (GRDB enables them by default); instead check that `Attachment.insert` ran after `Message.insert` in the test and that the cascade clause exists in `createAttachments`.

- [x] **Step 6: Mutation verification**

| Mutation | Test that must go RED |
|---|---|
| In `run`, delete the `try attachmentStore.delete(attachment.path)` line (keep the do/catch shape by replacing it with `_ = attachment.path`) | `expiryPurgeDeletesDueRowWithFileExportAttachmentAndReactions` (file still exists) |
| In `run`, change `<= now` to `< now` | `expiryPurgeKeepsLaterRowsAndReturnsTheirDueTime` (purged 0, nextDue purgeNow) |
| In `run`, change `($0.expiresAt ?? .distantFuture)` to `($0.expiresAt ?? .distantPast)` AND the first read to `Message.all.fetchAll(db)` | `expiryPurgeIgnoresUnstampedAndOrdinaryRows` |
| In `run`, replace `Reaction.where { $0.messageHash.in(hashes) }.delete()` with `Reaction.all.delete()` | `expiryPurgeKeepsOtherReactionsAndSeenHashes` |
| In `deleteExports`, replace the body with `return` | `expiryPurgeDeleteExportsRemovesTheDirectoryAndToleratesAbsence` |

All five in one batch, all RED; revert; GREEN.

- [x] **Step 7: Commit**

Write `/tmp/ReTiCAMsgr/msg-exp-task-4.txt` (subject `feat: MessagePurge deletes due rows, files, exports and reactions`, body, trailers).

Run: `git -C APP add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/MessagePurge.swift ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AttachmentStore.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/MessagePurgeTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCAMsgr/msg-exp-task-4.txt`

---

### Task 5: AppFeature — setting the timer and sending with it

**Files:**
- Modify: `CORE/Sources/ReTiCAMsgrCore/AppFeature.swift` (State, Action, CancelID, `sendTapped`, `closeConversation`, `outgoing`, `reloadThread`, new cases, new file-scope helpers)
- Modify: `CORE/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` (append)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces (used by Tasks 6, 7, 9): `State.openConversationExpiry: Int?`, `State.isForeground: Bool` (default true), `Action.expirySelected(seconds: Int)`, `Action.conversationExpiryLoaded(peerHex: String, seconds: Int?)`, `Action.expiryPurgeCompleted(purged: Int, nextDue: Date?)`, `Action.expiryDue`, `CancelID.expiry`; file-scope `stampViewed(_:_:now:) async throws -> Int` and `purgeAndReschedule(_:_:now:_:) async throws`; `outgoing(...)` gains `expirySeconds: Int? = nil, expiresAt: Date? = nil, isTimerChange: Bool = false`. `reloadThread` also sends `.conversationExpiryLoaded`.

This task wires the setting, the send path and the sleeper plumbing (`expiryPurgeCompleted` / `expiryDue`), because a send with a timer must arm the sleeper. Task 7 adds the stamping and lifecycle call sites and tests the sleeper end to end.

- [x] **Step 1: Write the failing tests**

Append to `CORE/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift`:

```swift

// MARK: - Disappearing messages: setting the timer and sending (spec 2026-10-05 §3)

/// Send the current draft from a store whose conversation timer is `expiry`, returning the
/// LXMessage handed to the node and the stored row.
@MainActor
private func expirySendAndFetch(_ db: any DatabaseWriter, draft: String, expiry: Int?,
                                attachmentStore: AttachmentStore? = nil,
                                configure: ((inout AppFeature.State) -> Void)? = nil)
    async -> (sent: LXMessage?, row: Message?, store: TestStoreOf<AppFeature>) {
    let store = makeStore(db, identity: Identity(), attachmentStore: attachmentStore) { s in
        s.openPeerHex = peerA
        s.draft = draft
        s.openConversationExpiry = expiry
        configure?(&s)
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let row = try! await db.read { try Message.where { $0.peerHex.eq(peerA) && !$0.isTimerChange }.fetchAll($0) }.first
    return (sent, row, store)
}

@MainActor @Test func expirySendSelectingTimerWritesSettingAnnouncementAndSendsChange() async throws {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.expirySelected(seconds: 86_400))
    #expect(store.state.openConversationExpiry == 86_400)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let wire = try #require(sent)
    #expect(wire.content == Data("Disappearing messages set to 1 day".utf8))
    #expect(ExpiryWire.decode(wire.fields) == ExpiryWire.Decoded(seconds: 86_400, isChange: true))
    #expect(try await db.read { try ConversationSetting.expiry(for: peerA, $0) } == 86_400)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.isTimerChange == true)
    #expect(row.isOutgoing == true)
    #expect(row.body == "Disappearing messages set to 1 day")
    #expect(row.expirySeconds == nil)
    #expect(row.expiresAt == nil)
    #expect(row.messageHash == wire.hash.hexString)
    #expect(row.status == MessageStatus.sending)
    #expect(store.state.conversations.first?.lastBody == "Disappearing messages set to 1 day")
}

@MainActor @Test func expirySendTurningOffStoresNullAndAnnounces() async throws {
    let db = try! AppDatabase.makeInMemory()
    try await db.write { try ConversationSetting.set(peerA, seconds: 3_600, at: infoT0, $0) }
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.openConversationExpiry = 3_600
    }
    await store.send(.expirySelected(seconds: 0))
    #expect(store.state.openConversationExpiry == nil)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let wire = try #require(sent)
    #expect(wire.content == Data("Disappearing messages turned off".utf8))
    #expect(ExpiryWire.decode(wire.fields) == ExpiryWire.Decoded(seconds: 0, isChange: true))
    let settings = try await db.read { try ConversationSetting.all.fetchAll($0) }
    #expect(settings.count == 1)
    #expect(settings.first?.expirySeconds == nil)
}

@MainActor @Test func expirySendSelectedIgnoredWithoutOpenConversation() async throws {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    store.exhaustivity = .on
    await store.send(.expirySelected(seconds: 60))
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try ConversationSetting.all.fetchAll($0) }.isEmpty)
}

/// Spec §3 "Sending": the field goes on the wire and the sender's copy is stamped at send.
@MainActor @Test func expirySendMessageCarriesFieldAndStampsSenderCopy() async throws {
    let db = try! AppDatabase.makeInMemory()
    let (sent, row, store) = await expirySendAndFetch(db, draft: "hi", expiry: 300)
    let wire = try #require(sent)
    #expect(wire.fields.map(\.key) == [0xFD])
    #expect(ExpiryWire.decode(wire.fields) == ExpiryWire.Decoded(seconds: 300, isChange: false))
    let stored = try #require(row)
    #expect(stored.expirySeconds == 300)
    #expect(stored.expiresAt == infoT0.addingTimeInterval(300))
    #expect(stored.isTimerChange == false)
    #expect(stored.fieldKeys == "0xfd")
    // The send armed the sleeper for this row.
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 \&\& nextDue == infoT0.addingTimeInterval(300) }
        return false
    }
}

@MainActor @Test func expirySendWithoutTimerCarriesNoFieldAndNoStamp() async throws {
    let db = try! AppDatabase.makeInMemory()
    let (sent, row, _) = await expirySendAndFetch(db, draft: "plain", expiry: nil)
    let wire = try #require(sent)
    #expect(wire.fields.isEmpty)
    let stored = try #require(row)
    #expect(stored.expirySeconds == nil)
    #expect(stored.expiresAt == nil)
}

/// Review Focus 4: the attachment field comes first, then the reply fields, then 0xFD.
@MainActor @Test func expirySendAttachmentCarriesFieldAfterAttachmentAndReply() async throws {
    let db = try! AppDatabase.makeInMemory()
    let files = attachTempStore()
    let jpeg = TestImages.jpeg(width: 40, height: 30)
    let (sent, row, _) = await expirySendAndFetch(db, draft: "cap", expiry: 3_600, attachmentStore: files) { s in
        s.pendingAttachment = pendingImage(jpeg)
        s.replyTarget = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "orig", isOutgoing: false)
    }
    let wire = try #require(sent)
    #expect(wire.fields.map(\.key) == [0x06, 0x30, 0x31, 0xFD])
    #expect(ExpiryWire.decode(wire.fields) == ExpiryWire.Decoded(seconds: 3_600, isChange: false))
    let stored = try #require(row)
    #expect(stored.expirySeconds == 3_600)
    #expect(stored.expiresAt == infoT0.addingTimeInterval(3_600))
    #expect(stored.fieldKeys == "0x06,0x30,0x31,0xfd")
}

@MainActor @Test func expirySendCloseConversationClearsOpenExpiry() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.openConversationExpiry = 60
    }
    await store.send(.closeConversation)
    #expect(store.state.openConversationExpiry == nil)
}

/// `reloadThread` carries the conversation's stored timer into state, and only for the open peer.
@MainActor @Test func expirySendThreadLoadCarriesConversationSetting() async throws {
    let db = try! AppDatabase.makeInMemory()
    try await db.write { try ConversationSetting.set(peerA, seconds: 600, at: infoT0, $0) }
    try! await seed(db, [msg(1, peerA, "a1", 1000)])
    let store = makeStore(db, identity: Identity())
    await store.send(.openConversation(peerA))
    await store.receive { if case let .conversationExpiryLoaded(peerHex, seconds) = $0 { return peerHex == peerA && seconds == 600 }; return false }
    #expect(store.state.openConversationExpiry == 600)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    // A late load for a conversation that is no longer open changes nothing.
    await store.send(.closeConversation)
    await store.send(.conversationExpiryLoaded(peerHex: peerA, seconds: 600))
    #expect(store.state.openConversationExpiry == nil)
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expirySend > /tmp/ReTiCAMsgr/exp-t5-red.log 2>&1`
Expected: compile errors (`openConversationExpiry`, `expirySelected` unknown).

- [x] **Step 3: State, actions, cancel ID**

In `AppFeature.State`, after `public var attachmentsByMessageId: [UUID: Attachment] = [:]`:

```swift
        /// The open conversation's disappearing-messages timer in seconds, nil when off. Loaded with
        /// the thread (`conversationExpiryLoaded`), set by `expirySelected`. Session-only.
        public var openConversationExpiry: Int? = nil
        /// Whether the scene is active (amendment A5). A message arriving into the open thread is
        /// "viewed" only while this is true. Starts true: a launch is a foreground launch unless
        /// `.backgrounded` says otherwise, and a push-wake launch has no open thread anyway.
        public var isForeground = true
```

In `Action`, after `case threadLoaded(...)`:

```swift
        /// The user picked a disappearing-messages duration (0 = off) from the chat toolbar menu.
        case expirySelected(seconds: Int)
        /// The open conversation's stored timer, sent by `reloadThread` beside `threadLoaded`.
        case conversationExpiryLoaded(peerHex: String, seconds: Int?)
        /// A purge finished: reload if it deleted anything, and arm the sleeper for `nextDue`. Internal.
        case expiryPurgeCompleted(purged: Int, nextDue: Date?)
        /// The expiry sleeper fired. Internal.
        case expiryDue
```

In `CancelID`, after `case pushRegistration`:

```swift
        /// The one sleeper waiting for the earliest `expiresAt` (spec §3). Re-armed with
        /// `cancelInFlight` after every purge, so it always waits for the current earliest row.
        case expiry
```

- [x] **Step 4: New cases in the reducer**

Add after the `case let .threadLoaded(...)` case:

```swift
            case let .conversationExpiryLoaded(peerHex, seconds):
                // Guarded like reactions and attachments: a late load for a thread the user has
                // left must not label the next conversation with the previous one's timer.
                guard peerHex == state.openPeerHex else { return .none }
                state.openConversationExpiry = seconds
                return .none

            case let .expirySelected(seconds):
                guard let peerHex = state.openPeerHex, let peer = Data(hexString: peerHex) else { return .none }
                let seconds = ExpiryWire.clamp(seconds)
                state.openConversationExpiry = seconds > 0 ? seconds : nil
                let now = date.now
                let alsoViaPropagation = !state.propagationNodeHex.isEmpty
                // The change goes out as a message with a readable body (spec §1): other LXMF
                // clients show the sentence, ReTiCAMsgr peers adopt the timer from the field.
                let (msg, row) = Self.outgoing(
                    identity: state.identity, peer: peer, peerHex: peerHex,
                    text: ExpiryPreset.announcement(seconds: seconds), now: now,
                    fields: ExpiryWire.encodeChange(seconds: seconds), alsoViaPropagation: alsoViaPropagation,
                    replyToHash: nil, replyQuote: nil, isTimerChange: true)
                return .merge(
                    .send(.node(.client(.sendMessage(message: msg, alsoViaPropagation: alsoViaPropagation)))),
                    .run { [database] send in
                        try await database.write { db in
                            try ConversationSetting.set(peerHex, seconds: seconds, at: now, db)
                            try Message.insert { row }.execute(db)
                        }
                        try await reloadThread(database, peerHex, send)
                        try await reloadConversations(database, send)
                    }
                )

            case let .expiryPurgeCompleted(purged, nextDue):
                // Reload only when something went (amendment A2): every caller already reloaded
                // after its own write, so a no-op purge must not reload twice.
                let openPeer = state.openPeerHex
                let reload: Effect<Action> = purged > 0
                    ? .run { [database] send in
                        try await reloadConversations(database, send)
                        if let openPeer { try await reloadThread(database, openPeer, send) }
                    }
                    : .none
                guard let nextDue else { return .merge(.cancel(id: CancelID.expiry), reload) }
                let delay = max(0, nextDue.timeIntervalSince(date.now))
                let sleeper: Effect<Action> = .run { [clock] send in
                    try await clock.sleep(for: .seconds(delay))
                    await send(.expiryDue)
                }
                .cancellable(id: CancelID.expiry, cancelInFlight: true)
                return .merge(reload, sleeper)

            case .expiryDue:
                return .run { [database, attachmentStore, now = date.now] send in
                    try await purgeAndReschedule(database, attachmentStore, now: now, send)
                }
```

- [x] **Step 5: `closeConversation`, `sendTapped`, `outgoing`**

In `case .closeConversation:` add `state.openConversationExpiry = nil` after `state.attachmentsByMessageId = [:]`.

In `case .sendTapped:`, after the reply-fields block (after `replyQuote = quote.isEmpty ? nil : quote` and its closing `}`), add:

```swift
                // Disappearing messages (spec §3 "Sending"): the field rides last, and the sender's
                // copy is stamped at send. The receiving side stamps on first view instead.
                let expiry = state.openConversationExpiry
                let expiryFields = expiry.map { ExpiryWire.encode(seconds: $0) } ?? []
```

In the text path (`guard let pending else { ... }`), change the `Self.outgoing(...)` call to pass `fields: replyFields + expiryFields` and add after `replyQuote: replyQuote`:

```swift
                        expirySeconds: expiry,
                        expiresAt: expiry.map { now.addingTimeInterval(TimeInterval($0)) })
```

and change its `.run` to:

```swift
                        .run { [database, attachmentStore] send in
                            try await database.write { try Message.insert { row }.execute($0) }
                            try await reloadThread(database, peerHex, send)
                            try await reloadConversations(database, send)
                            if expiry != nil {
                                try await purgeAndReschedule(database, attachmentStore, now: now, send)
                            }
                        }
```

In the attachment path, change the `.run` capture list to `[database, replyFields, replyToHash, replyQuote, expiryFields, expiry]`, the `Self.outgoing` call to `fields: attachmentFields + replyFields + expiryFields` with the same two new arguments, and after the final `reloadConversations` add:

```swift
                        if expiry != nil {
                            try await purgeAndReschedule(database, attachmentStore, now: now, send)
                        }
```

Change `static func outgoing(...)`'s signature to end with:

```swift
                         replyToHash: String?, replyQuote: String?,
                         expirySeconds: Int? = nil, expiresAt: Date? = nil,
                         isTimerChange: Bool = false) -> (LXMessage, Message) {
```

and the `Message(` literal inside it to end with:

```swift
            replyToHash: replyToHash,
            replyQuote: replyQuote,
            expirySeconds: expirySeconds,
            expiresAt: expiresAt,
            isTimerChange: isTimerChange
        )
```

- [x] **Step 6: `reloadThread` and the file-scope helpers**

Change `reloadThread` to read the setting too:

```swift
private func reloadThread(_ database: any DatabaseWriter, _ peerHex: String, _ send: Send<AppFeature.Action>) async throws {
    let (rows, reactions, attachments, expiry) = try await database.read { db -> ([Message], [Reaction], [Attachment], Int?) in
        let rows = try Message.where { $0.peerHex.eq(peerHex) }.order(by: \.timestamp).fetchAll(db)
        let hashes = rows.map(\.messageHash).filter { !$0.isEmpty }
        let reactions = hashes.isEmpty ? [] : try Reaction.where { $0.messageHash.in(hashes) }.fetchAll(db)
        let ids = rows.map(\.id)
        let attachments = ids.isEmpty ? [] : try Attachment.where { $0.messageId.in(ids) }.fetchAll(db)
        let expiry = try ConversationSetting.expiry(for: peerHex, db)
        return (rows, reactions, attachments, expiry)
    }
    await send(.threadLoaded(rows, reactions: reactions, attachments: attachments))
    await send(.conversationExpiryLoaded(peerHex: peerHex, seconds: expiry))
}
```

Add after `reloadThread`:

```swift
/// First view (spec §3): every row of `peerHex` that carries a duration and has no `expiresAt`
/// yet is stamped `now + expirySeconds`. Outgoing rows are stamped at send, so in practice this
/// touches received rows. Returns how many rows changed, so the caller knows whether to reload.
private func stampViewed(_ database: any DatabaseWriter, _ peerHex: String, now: Date) async throws -> Int {
    try await database.write { db in
        let unstamped = try Message
            .where { $0.peerHex.eq(peerHex) && $0.expirySeconds.isNot(nil) && $0.expiresAt.is(nil) }
            .fetchAll(db)
        for row in unstamped {
            guard let seconds = row.expirySeconds else { continue }
            let due = now.addingTimeInterval(TimeInterval(seconds))
            try Message.where { $0.id.eq(row.id) }.update { $0.expiresAt = due }.execute(db)
        }
        return unstamped.count
    }
}

/// Purge what is due, then tell the reducer what is left so it can arm the sleeper (spec §3
/// "Purge"). Called on launch, foreground, thread open, after every stamp, after every send with a
/// timer, and when the sleeper fires.
private func purgeAndReschedule(_ database: any DatabaseWriter, _ attachmentStore: AttachmentStore,
                                now: Date, _ send: Send<AppFeature.Action>) async throws {
    let result = try await MessagePurge.run(database, attachmentStore: attachmentStore, now: now)
    await send(.expiryPurgeCompleted(purged: result.purged, nextDue: result.nextDue))
}
```

If `.update { $0.expiresAt = due }` does not compile for an optional `Date` column, follow the shape `markUndeliverable` uses for `failedAt` (`$0.failedAt = milestoneAt` where `milestoneAt: Date?`): declare `let due: Date? = now.addingTimeInterval(...)`.

- [x] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expirySend > /tmp/ReTiCAMsgr/exp-t5-green.log 2>&1`
Expected: 8 tests passed. Then the full suite: `swift test --package-path CORE > /tmp/ReTiCAMsgr/exp-t5-full.log 2>&1` — expected baseline + 29 passed (T1 5, T2 7, T3 4, T4 5, T5 8), no failures. The new `conversationExpiryLoaded` action after every `threadLoaded` is delivered under `exhaustivity = .off` in existing tests; if an existing exhaustive test (`exhaustivity = .on`) now fails on an unexpected `conversationExpiryLoaded`, add a `receive` for it in that test (mechanical edit, exempt from mutation).

- [x] **Step 8: Mutation verification**

| Mutation | Test that must go RED |
|---|---|
| In `.expirySelected`, remove the `ConversationSetting.set` line | `expirySendSelectingTimerWritesSettingAnnouncementAndSendsChange` |
| In `.expirySelected`, pass `isTimerChange: false` | `expirySendSelectingTimerWritesSettingAnnouncementAndSendsChange` (sub-batch B, alone — the first mutation also fails this test) |
| In `.expirySelected`, replace `ExpiryWire.encodeChange(seconds: seconds)` with `ExpiryWire.encode(seconds: seconds)` | `expirySendTurningOffStoresNullAndAnnounces` (isChange false) |
| In `.expirySelected`, replace `guard let peerHex = state.openPeerHex, ...` with `let peerHex = state.openPeerHex ?? peerA`-style fallback: concretely `let peerHex = state.openPeerHex ?? String(repeating: "a", count: 32), let peer = Data(hexString: peerHex)!` | `expirySendSelectedIgnoredWithoutOpenConversation` |
| In `sendTapped` text path, pass `expiresAt: nil` | `expirySendMessageCarriesFieldAndStampsSenderCopy` |
| In `sendTapped`, `let expiryFields: [MsgPackValue.IntPair] = []` | `expirySendAttachmentCarriesFieldAfterAttachmentAndReply` (sub-batch B) |
| In `sendTapped`, `let expiry: Int? = state.openConversationExpiry ?? 60` | `expirySendWithoutTimerCarriesNoFieldAndNoStamp` |
| In `.closeConversation`, drop `state.openConversationExpiry = nil` | `expirySendCloseConversationClearsOpenExpiry` |
| In `reloadThread`, drop the `conversationExpiryLoaded` send | `expirySendThreadLoadCarriesConversationSetting` |

Sub-batch A = all rows not marked B; run once, each listed test RED. Revert. Sub-batch B = the two marked rows; run once, both RED. Revert. GREEN.

- [x] **Step 9: Commit**

Write `/tmp/ReTiCAMsgr/msg-exp-task-5.txt` (subject `feat: set the conversation timer and send messages that carry it`, body naming expirySelected, the announcement row, the 0xFD field order, the sender-side stamp and the expiryPurgeCompleted/expiryDue sleeper plumbing, trailers).

Run: `git -C APP add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCAMsgr/msg-exp-task-5.txt`

---

### Task 6: AppFeature — receiving

**Files:**
- Modify: `CORE/Sources/ReTiCAMsgrCore/AppFeature.swift` (`State.peerDisplayName(_:)`, `.messageReceived`)
- Modify: `CORE/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` (append)

**Interfaces:**
- Consumes: Task 5's state and helpers; `ExpiryWire.decode`; `ExpiryPreset.peerAnnouncement`; `ConversationSetting`.
- Produces: `State.peerDisplayName(_:) -> String?` (public; `openPeerDisplayName` delegates to it).

- [x] **Step 1: Write the failing tests**

Append to `AppFeatureTests.swift`:

```swift

// MARK: - Disappearing messages: receive path (spec 2026-10-05 §3)

private func expiryHex(_ identity: Identity) -> String {
    LXMessage.deliveryHash(identityHash: identity.hash).hexString
}

/// Spec §3 "Receiving": the duration is stored, the row is NOT stamped (not viewed), and since no
/// setting existed the convergence rule writes one and inserts a line above the message.
@MainActor @Test func expiryReceiveStoresDurationUnstampedAndConvergesSetting() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me)
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "hi", fields: ExpiryWire.encode(seconds: 600))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }
    #expect(rows.count == 2)
    let line = try #require(rows.first)
    let message = try #require(rows.last)
    #expect(line.isTimerChange == true)
    #expect(line.isOutgoing == false)
    #expect(line.body == "Them set disappearing messages to 10 minutes")
    #expect(line.messageHash == "")
    #expect(line.expirySeconds == nil)
    #expect(line.timestamp < message.timestamp)
    #expect(message.body == "hi")
    #expect(message.expirySeconds == 600)
    #expect(message.expiresAt == nil)
    #expect(message.isTimerChange == false)
    #expect(message.fieldKeys == "0xfd")
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 600)
}

@MainActor @Test func expiryReceiveEqualSettingAddsNoLine() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "hi", fields: ExpiryWire.encode(seconds: 600))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.expirySeconds == 600)
}

/// A timer-change message updates the setting and is stored only as the announcement row, body as
/// received. Turning off stores NULL.
@MainActor @Test func expiryReceiveTimerChangeUpdatesSettingAndStoresOnlyAnnouncement() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me)
    let on = wireMessage(from: sender, to: me, at: 1699999999, content: "Disappearing messages set to 1 hour",
                         fields: ExpiryWire.encodeChange(seconds: 3_600))
    await store.send(.node(.client(.delegate(.messageReceived(message: on, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    var rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.isTimerChange == true)
    #expect(rows.first?.body == "Disappearing messages set to 1 hour")
    #expect(rows.first?.expirySeconds == nil)
    #expect(rows.first?.expiresAt == nil)
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 3_600)

    let off = wireMessage(from: sender, to: me, at: 1700000001, content: "Disappearing messages turned off",
                          fields: ExpiryWire.encodeChange(seconds: 0))
    await store.send(.node(.client(.delegate(.messageReceived(message: off, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    rows = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }
    #expect(rows.count == 2)
    #expect(rows.last?.isTimerChange == true)
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == nil)
    #expect(try await db.read { try ConversationSetting.all.fetchAll($0) }.count == 1)
}

/// A change message with an empty body (a future client might send none) gets the local line text.
@MainActor @Test func expiryReceiveTimerChangeWithEmptyBodyGetsLocalText() async throws {
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me, at: 1699999999, content: "", fields: ExpiryWire.encodeChange(seconds: 86_400))
    let rows = try await receiveAndFetch(m, me: me)
    #expect(rows.count == 1)
    #expect(rows.first?.isTimerChange == true)
    #expect(rows.first?.body == "Them set disappearing messages to 1 day")
}

/// Spec §3: a message without the field never touches the setting (a non-honouring peer must not
/// keep switching it off), and amendment A4: an explicit 0 on an ordinary message does converge.
@MainActor @Test func expiryReceiveWithoutFieldLeavesSettingAloneButZeroConverges() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    let plain = wireMessage(from: sender, to: me, at: 1699999999, content: "no field")
    await store.send(.node(.client(.delegate(.messageReceived(message: plain, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 600)
    #expect(try await db.read { try Message.all.fetchAll($0) }.count == 1)

    // Move the frozen clock so the second message (and its convergence line, 1 ms before it)
    // sorts after the first by timestamp.
    store.dependencies.date = .constant(infoT0.addingTimeInterval(5))
    let zero = wireMessage(from: sender, to: me, at: 1700000001, content: "off now", fields: ExpiryWire.encode(seconds: 0))
    await store.send(.node(.client(.delegate(.messageReceived(message: zero, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == nil)
    let rows = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }
    #expect(rows.count == 3)
    #expect(rows[1].isTimerChange == true)
    #expect(rows[1].body == "Them turned disappearing messages off")
    #expect(rows[2].body == "off now")
    #expect(rows[2].expirySeconds == nil)
}

/// Spec §3 "First view": a message arriving into the open thread while the app is active is
/// viewed at once, so it is stamped on insert and the sleeper is armed.
@MainActor @Test func expiryReceiveIntoOpenForegroundThreadStampsAtOnce() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me) { $0.openPeerHex = expiryHex(sender) }
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "hi", fields: ExpiryWire.encode(seconds: 600))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 \&\& nextDue == infoT0.addingTimeInterval(600) }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.expiresAt == infoT0.addingTimeInterval(600))
    #expect(store.state.threadMessages.first?.expiresAt == infoT0.addingTimeInterval(600))
}

/// Amendment A5: the open thread is not being looked at while the app is in the background.
@MainActor @Test func expiryReceiveIntoOpenThreadWhileBackgroundedDoesNotStamp() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me) { $0.openPeerHex = expiryHex(sender) }
    await store.send(.backgrounded)
    #expect(store.state.isForeground == false)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "hi", fields: ExpiryWire.encode(seconds: 600))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.expirySeconds == 600)
    #expect(row.expiresAt == nil)
}

/// Review Focus 2: a 0xFD that is not ours leaves an ordinary text message and the setting alone.
@MainActor @Test func expiryReceiveMalformedFieldIsPlainText() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "hub data",
                        fields: [.init(0xFD, .bin(Data([1, 2, 3])))])
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.body == "hub data")
    #expect(rows.first?.expirySeconds == nil)
    #expect(rows.first?.isTimerChange == false)
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 600)
}

/// Review Focus 1: an unvalidated sender cannot change the timer. The message is kept as text.
@MainActor @Test func expiryReceiveUnvalidatedChangeIsPlainText() async throws {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    try await db.write { try ConversationSetting.set(expiryHex(sender), seconds: 600, at: infoT0, $0) }
    let store = makeStore(db, identity: me)
    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "Disappearing messages turned off",
                        fields: ExpiryWire.encodeChange(seconds: 0))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: false, method: .opportunistic)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.isTimerChange == false)
    #expect(rows.first?.body == "Disappearing messages turned off")
    #expect(try await db.read { try ConversationSetting.expiry(for: expiryHex(sender), $0) } == 600)
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryReceive > /tmp/ReTiCAMsgr/exp-t6-red.log 2>&1`
Expected: compiles (everything referenced exists) and the tests FAIL on counts, `expirySeconds == nil`, or the setting.

- [x] **Step 3: `peerDisplayName(_:)`**

In `AppFeature.State`, replace `openPeerDisplayName`'s body so it delegates, and add the general form:

```swift
        public var openPeerDisplayName: String? {
            openPeerHex.flatMap(peerDisplayName)
        }

        /// `peerHex`'s display name from its LXMF delivery announce (`learnedPeers`), trimmed; nil
        /// when no announce was heard or the name is blank, so labels fall back to "Them".
        public func peerDisplayName(_ hex: String) -> String? {
            guard let hash = Data(hexString: hex),
                  let name = node.client.learnedPeers[hash]?.displayName?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            return name
        }
```

- [x] **Step 4: Decode and store in `.messageReceived`**

After `let decodedAttachment = AttachmentWire.decode(m.fields)` block (after the dropped-file-count log), add:

```swift
                // Disappearing messages (spec §3 "Receiving", amendments A1, A4, A5). Only a
                // validated sender may set or carry a timer: an unsigned message is plain text.
                let decodedExpiry = validated ? ExpiryWire.decode(m.fields) : nil
                let isTimerChange = decodedExpiry?.isChange == true
                let incomingSeconds: Int? = {
                    guard let decoded = decodedExpiry, !decoded.isChange, decoded.seconds > 0 else { return nil }
                    return decoded.seconds
                }()
                // Arriving into the open thread while the app is active is "viewed" at once.
                let viewedNow: Date? = (incomingPeer == openPeer && state.isForeground) ? date.now : nil
                let peerName = state.peerDisplayName(incomingPeer)
                let receivedBody = String(decoding: m.content, as: UTF8.self)
```

Change the `Message(` literal's `body:` to:

```swift
                    body: isTimerChange && receivedBody.isEmpty
                        ? ExpiryPreset.peerAnnouncement(peerName: peerName, seconds: decodedExpiry?.seconds ?? 0)
                        : receivedBody,
```

and add after `replyQuote: reply?.quote`:

```swift
                    expirySeconds: incomingSeconds,
                    expiresAt: incomingSeconds.flatMap { seconds in
                        viewedNow.map { $0.addingTimeInterval(TimeInterval(seconds)) }
                    },
                    isTimerChange: isTimerChange
```

Inside `storeMessage`'s `database.write { db in` block, BEFORE `try Message.insert { row }.execute(db)`, add:

```swift
                        if let decoded = decodedExpiry {
                            let current = try ConversationSetting.expiry(for: incomingPeer, db) ?? 0
                            if decoded.isChange {
                                try ConversationSetting.set(incomingPeer, seconds: decoded.seconds, at: seenNow, db)
                            } else if decoded.seconds != current {
                                // Convergence after a missed change message: adopt the peer's timer
                                // and say so, 1 ms before the message so the line sorts above it.
                                try ConversationSetting.set(incomingPeer, seconds: decoded.seconds, at: seenNow, db)
                                try Message.insert {
                                    Message(id: UUID(), peerHex: incomingPeer, isOutgoing: false,
                                            body: ExpiryPreset.peerAnnouncement(peerName: peerName, seconds: decoded.seconds),
                                            timestamp: row.timestamp.addingTimeInterval(-0.001),
                                            status: MessageStatus.received, validated: validated,
                                            messageHash: "", fieldKeys: "", isTimerChange: true)
                                }.execute(db)
                            }
                        }
```

After the `if incomingPeer == openPeer { try await reloadThread(...) }` block at the end of `storeMessage`, add:

```swift
                    if row.expiresAt != nil {
                        try await purgeAndReschedule(database, attachmentStore, now: seenNow, send)
                    }
```

`attachmentStore` is already a local in this case (`let attachmentStore = self.attachmentStore`).

- [x] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryReceive > /tmp/ReTiCAMsgr/exp-t6-green.log 2>&1`
Expected: 9 tests passed.

- [x] **Step 6: Mutation verification**

| Mutation | Test that must go RED |
|---|---|
| Remove the convergence `Message.insert { ... }` (keep the `set`) | `expiryReceiveStoresDurationUnstampedAndConvergesSetting` |
| Change `else if decoded.seconds != current` to `else` | `expiryReceiveEqualSettingAddsNoLine` |
| `let isTimerChange = false` | `expiryReceiveTimerChangeUpdatesSettingAndStoresOnlyAnnouncement` |
| In `body:`, drop the `receivedBody.isEmpty` branch (always `receivedBody`) | `expiryReceiveTimerChangeWithEmptyBodyGetsLocalText` |
| `let decodedExpiry = validated ? (ExpiryWire.decode(m.fields) ?? ExpiryWire.Decoded(seconds: 0, isChange: false)) : nil` | `expiryReceiveWithoutFieldLeavesSettingAloneButZeroConverges` (the plain message converges to off) and `expiryReceiveMalformedFieldIsPlainText` |
| `let viewedNow: Date? = nil` | `expiryReceiveIntoOpenForegroundThreadStampsAtOnce` |
| `let viewedNow: Date? = incomingPeer == openPeer ? date.now : nil` (drop `isForeground`) (sub-batch B) | `expiryReceiveIntoOpenThreadWhileBackgroundedDoesNotStamp` |
| `let decodedExpiry = ExpiryWire.decode(m.fields)` (drop `validated ?`) (sub-batch B) | `expiryReceiveUnvalidatedChangeIsPlainText` |

Sub-batch A: all rows not marked B, run once, each RED. Revert. Sub-batch B: the two marked rows, run once, both RED. Revert. GREEN.

- [x] **Step 7: Commit**

Write `/tmp/ReTiCAMsgr/msg-exp-task-6.txt` (subject `feat: honour the disappearing-messages field on receive`, body, trailers).

Run: `git -C APP add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCAMsgr/msg-exp-task-6.txt`

---

### Task 7: AppFeature — first view, lifecycle and the sleeper

**Files:**
- Modify: `CORE/Sources/ReTiCAMsgrCore/AppFeature.swift` (`.onLaunch`, `.foregrounded`, `.backgrounded`, `.openConversation`, `.startConversation`)
- Modify: `CORE/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` (append)

**Interfaces:**
- Consumes: Task 5's `stampViewed`, `purgeAndReschedule`, `CancelID.expiry`, `.expiryDue`, `.expiryPurgeCompleted`; `State.isForeground`.

- [x] **Step 1: Write the failing tests**

Append to `AppFeatureTests.swift`:

```swift

// MARK: - Disappearing messages: first view, lifecycle, sleeper (spec 2026-10-05 §3)

private func expiryTimerRow(_ id: Int, _ peer: String, seconds: Int?, expiresAt: Date?, outgoing: Bool = false,
                            hash: String? = nil) -> Message {
    Message(id: uuid(id), peerHex: peer, isOutgoing: outgoing, body: "r\(id)",
            timestamp: infoT0.addingTimeInterval(TimeInterval(id)),
            status: outgoing ? MessageStatus.delivered : MessageStatus.received, validated: !outgoing,
            messageHash: hash ?? String(repeating: String(format: "%02x", 0x50 + id), count: 32),
            expirySeconds: seconds, expiresAt: expiresAt)
}

/// Opening a thread is the first view of every unstamped row in it. A row already stamped keeps
/// its time, an ordinary row stays nil, and the sleeper is armed for the earliest stamp.
@MainActor @Test func expiryTimerOpeningThreadStampsUnstampedRowsOnly() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [
        expiryTimerRow(1, peerA, seconds: 60, expiresAt: nil),
        expiryTimerRow(2, peerA, seconds: 60, expiresAt: infoT0.addingTimeInterval(10)),
        expiryTimerRow(3, peerA, seconds: nil, expiresAt: nil),
        expiryTimerRow(4, peerB, seconds: 60, expiresAt: nil),   // another conversation: not viewed
    ])
    let store = makeStore(db, identity: Identity())
    await store.send(.openConversation(peerA))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 \&\& nextDue == infoT0.addingTimeInterval(10) }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.order(by: \.timestamp).fetchAll($0) }
    #expect(rows[0].expiresAt == infoT0.addingTimeInterval(60))
    #expect(rows[1].expiresAt == infoT0.addingTimeInterval(10))
    #expect(rows[2].expiresAt == nil)
    #expect(rows[3].expiresAt == nil)
    #expect(store.state.threadMessages.map(\.expiresAt) == [infoT0.addingTimeInterval(60), infoT0.addingTimeInterval(10), nil])
}

/// `startConversation` is the other way into a thread and stamps too.
@MainActor @Test func expiryTimerStartConversationStampsToo() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [expiryTimerRow(1, peerA, seconds: 30, expiresAt: nil)])
    let store = makeStore(db, identity: Identity())
    await store.send(.startConversation(peerA))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.expiresAt == infoT0.addingTimeInterval(30))
}

/// The sleeper fires at the earliest `expiresAt`, the row is purged and the thread reloads. A
/// 30-second preset with the thread open therefore disappears on time.
@MainActor @Test func expiryTimerDueRowIsPurgedAndThreadReloads() async throws {
    let db = try! AppDatabase.makeInMemory()
    let clock = TestClock()
    try! await seed(db, [expiryTimerRow(1, peerA, seconds: 30, expiresAt: infoT0.addingTimeInterval(30))])
    let store = makeStore(db, identity: Identity(), clock: clock)
    await store.send(.openConversation(peerA))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 \&\& nextDue == infoT0.addingTimeInterval(30) }
        return false
    }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.threadMessages.count == 1)

    store.dependencies.date = .constant(infoT0.addingTimeInterval(30))
    await clock.advance(by: .seconds(30))
    await store.receive { if case .expiryDue = $0 { return true }; return false }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 \&\& nextDue == nil }
        return false
    }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadMessages.isEmpty)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    await store.finish()
    await store.skipReceivedActions(strict: false)
}

/// A nearer expiry re-arms the sleeper: after a 60 s row is armed, a message stamped for 10 s
/// arrives, and the sleeper fires at 10 s, not 60.
@MainActor @Test func expiryTimerNearerExpiryReschedulesSleeper() async throws {
    let db = try! AppDatabase.makeInMemory()
    let clock = TestClock()
    let me = Identity()
    let sender = Identity()
    let senderHex = expiryHex(sender)
    try! await seed(db, [expiryTimerRow(1, senderHex, seconds: 60, expiresAt: infoT0.addingTimeInterval(60))])
    try await db.write { try ConversationSetting.set(senderHex, seconds: 10, at: infoT0, $0) }
    let store = makeStore(db, identity: me, clock: clock)
    await store.send(.openConversation(senderHex))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 \&\& nextDue == infoT0.addingTimeInterval(60) }
        return false
    }
    await store.skipReceivedActions(strict: false)

    let m = wireMessage(from: sender, to: me, at: 1699999999, content: "quick", fields: ExpiryWire.encode(seconds: 10))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 0 \&\& nextDue == infoT0.addingTimeInterval(10) }
        return false
    }
    await store.skipReceivedActions(strict: false)

    store.dependencies.date = .constant(infoT0.addingTimeInterval(10))
    await clock.advance(by: .seconds(10))
    await store.receive { if case .expiryDue = $0 { return true }; return false }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 \&\& nextDue == infoT0.addingTimeInterval(60) }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let bodies = try await db.read { try Message.all.fetchAll($0) }.map(\.body)
    #expect(bodies == ["r1"])
}

/// Review Focus 5: nothing runs while suspended, so launch catches up on rows that fell due,
/// including the attachment file and reactions.
@MainActor @Test func expiryTimerLaunchPurgesRowsDueWhileSuspended() async throws {
    let db = try! AppDatabase.makeInMemory()
    let files = attachTempStore()
    let due = expiryTimerRow(1, peerA, seconds: 60, expiresAt: infoT0.addingTimeInterval(-1))
    let path = try files.store(Data([1]), messageHash: due.messageHash, outgoing: false, ext: "bin")
    let attachment = Attachment(id: UUID(), messageId: due.id, kind: AttachmentKind.file, name: "a.bin",
                                format: "bin", size: 1, width: nil, height: nil, path: path)
    try! await seed(db, [due, expiryTimerRow(2, peerA, seconds: nil, expiresAt: nil)])
    try await db.write { d in
        try Attachment.insert { attachment }.execute(d)
        try Reaction.insert { Reaction(messageHash: due.messageHash, reactorHex: peerA, emoji: "👍", sentAt: 1) }.execute(d)
    }
    let store = makeStore(db, identity: Identity(), attachmentStore: files)
    await store.send(.onLaunch)
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 \&\& nextDue == nil }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Message.all.fetchAll($0) }.map(\.body) == ["r2"])
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Reaction.all.fetchAll($0) }.isEmpty)
    #expect(!files.exists(path))
    #expect(store.state.conversations.first?.lastBody == "r2")
}

/// Returning to the foreground with a thread open is a view of its unstamped rows, and a purge.
@MainActor @Test func expiryTimerForegroundStampsOpenThreadAndPurges() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [
        expiryTimerRow(1, peerA, seconds: 60, expiresAt: nil),
        expiryTimerRow(2, peerA, seconds: 5, expiresAt: infoT0.addingTimeInterval(-1)),
    ])
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.isForeground = false
    }
    await store.send(.foregrounded) {
        $0.connection = .connecting
        $0.isForeground = true
    }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 \&\& nextDue == infoT0.addingTimeInterval(60) }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.body) == ["r1"])
    #expect(rows.first?.expiresAt == infoT0.addingTimeInterval(60))
    #expect(store.state.threadMessages.map(\.body) == ["r1"])
}

/// Foreground with no thread open still purges, and stamps nothing.
@MainActor @Test func expiryTimerForegroundWithoutThreadOnlyPurges() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [
        expiryTimerRow(1, peerA, seconds: 60, expiresAt: nil),
        expiryTimerRow(2, peerA, seconds: 5, expiresAt: infoT0.addingTimeInterval(-1)),
    ])
    let store = makeStore(db, identity: Identity())
    await store.send(.foregrounded) { $0.connection = .connecting }
    await store.receive { action in
        if case let .expiryPurgeCompleted(purged, nextDue) = action { return purged == 1 \&\& nextDue == nil }
        return false
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.body) == ["r1"])
    #expect(rows.first?.expiresAt == nil)
}

@MainActor @Test func expiryTimerBackgroundedClearsForegroundFlagAndStampsNothing() async throws {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [expiryTimerRow(1, peerA, seconds: 60, expiresAt: nil)])
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    #expect(store.state.isForeground == true)
    await store.send(.backgrounded) { $0.isForeground = false }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.expiresAt == nil)
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryTimer > /tmp/ReTiCAMsgr/exp-t7-red.log 2>&1`
Expected: compiles; the tests FAIL (no `expiryPurgeCompleted` received, rows unstamped, `isForeground` unchanged).

- [x] **Step 3: Launch, foreground, background**

In `case .onLaunch:`, add to the `.merge(` list (after the `reloadConversations` `.run`):

```swift
                    .run { [database, attachmentStore, now = date.now] send in
                        // Nothing ran while suspended or dead: purge what fell due and arm the sleeper.
                        try await purgeAndReschedule(database, attachmentStore, now: now, send)
                    },
```

Replace `case .foregrounded:`'s body with:

```swift
            case .foregrounded:
                // Only re-dial when the TCP socket specifically is down. iOS tears the TCP socket
                // down while suspended, so foreground is when we rebuild it — but a live BLE peer
                // must NOT suppress that: keying on the whole-app `.connected` bool would skip the
                // re-dial whenever any BLE peer held the app "connected", leaving the dead socket
                // unrebuilt (A4). A HEALTHY tcp interface still short-circuits, because re-dialling
                // it would tear down its live links on every app switch.
                // Either way, drain the push inbox: packets may have been stashed while suspended.
                // Disappearing messages: the open thread is being looked at again (first view for
                // rows that arrived while suspended), and rows that fell due meanwhile go now.
                state.isForeground = true
                let openPeer = state.openPeerHex
                let expiryCatchUp: Effect<Action> = .run { [database, attachmentStore, now = date.now] send in
                    if let openPeer, try await stampViewed(database, openPeer, now: now) > 0 {
                        try await reloadThread(database, openPeer, send)
                    }
                    try await purgeAndReschedule(database, attachmentStore, now: now, send)
                }
                return .merge(redialIfTCPDown(&state), .send(.push(.drainInbox)), expiryCatchUp)
```

In `case .backgrounded:`, add as the first line of the case body:

```swift
                // Amendment A5: a message arriving into the open thread from now on is not viewed.
                state.isForeground = false
```

- [x] **Step 4: Thread open**

In `case let .openConversation(peerHex):`, replace `.run { [database] send in try await reloadThread(database, peerHex, send) },` with:

```swift
                    .run { [database, attachmentStore, now = date.now] send in
                        // First view (spec §3): stamp before the load so the rows arrive stamped.
                        _ = try await stampViewed(database, peerHex, now: now)
                        try await reloadThread(database, peerHex, send)
                        try await purgeAndReschedule(database, attachmentStore, now: now, send)
                    },
```

Make the same replacement in `case let .startConversation(hex):` (its variable is `hex`).

- [x] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryTimer > /tmp/ReTiCAMsgr/exp-t7-green.log 2>&1`
Expected: 8 tests passed. Then the full suite: `swift test --package-path CORE > /tmp/ReTiCAMsgr/exp-t7-full.log 2>&1`, expected baseline + 46 passed. Existing `.foregrounded` tests (`foregroundReDialsWhenTCPDownEvenWithBLEPeerUp`, `foregroundDoesNotReDialWhenTCPIsUp`, the push drain tests) run with exhaustivity off and finish with `store.finish()`; the extra `expiryPurgeCompleted` is skipped. If one asserts exhaustively, add a `receive` for `.expiryPurgeCompleted` (mechanical, exempt).

- [x] **Step 6: Mutation verification**

| Mutation | Test that must go RED |
|---|---|
| In `.openConversation`, delete the `stampViewed` line | `expiryTimerOpeningThreadStampsUnstampedRowsOnly` |
| In `.startConversation`, delete the `stampViewed` line | `expiryTimerStartConversationStampsToo` |
| In `stampViewed`, drop `&& $0.expiresAt.is(nil)` from the where clause (sub-batch B) | `expiryTimerOpeningThreadStampsUnstampedRowsOnly` (row 2 restamped to +60) |
| In `.expiryDue`, `return .none` | `expiryTimerDueRowIsPurgedAndThreadReloads` |
| In `.expiryPurgeCompleted`, `let delay: TimeInterval = 60` | `expiryTimerNearerExpiryReschedulesSleeper` |
| In `.onLaunch`, remove the new `purgeAndReschedule` `.run` | `expiryTimerLaunchPurgesRowsDueWhileSuspended` |
| In `.foregrounded`, remove the `if let openPeer, ... stampViewed ...` block | `expiryTimerForegroundStampsOpenThreadAndPurges` |
| In `.foregrounded`, replace `expiryCatchUp` in the merge with `.none` (sub-batch B) | `expiryTimerForegroundWithoutThreadOnlyPurges` |
| In `.backgrounded`, drop `state.isForeground = false` | `expiryTimerBackgroundedClearsForegroundFlagAndStampsNothing` |

Sub-batch A: all rows not marked B, each RED. Revert. Sub-batch B: the two marked rows, both RED. Revert. GREEN.

- [x] **Step 7: Commit**

Write `/tmp/ReTiCAMsgr/msg-exp-task-7.txt` (subject `feat: stamp first view, purge on launch and foreground, run the expiry sleeper`, body, trailers).

Run: `git -C APP add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCAMsgr/msg-exp-task-7.txt`

---

### Task 8: Info sheet rows

**Files:**
- Modify: `CORE/Sources/ReTiCAMsgrCore/MessageInfo.swift` (`timeline`)
- Modify: `CORE/Tests/ReTiCAMsgrCoreTests/MessageInfoTests.swift` (append)

**Interfaces:**
- Consumes: `Message.expirySeconds`, `Message.expiresAt`, `ExpiryPreset.label(forSeconds:)`, existing `timeRow`, `Row`.

- [x] **Step 1: Write the failing tests**

Read the top of `MessageInfoTests.swift` for its message-building helper; if there is none usable, use the literal below. Append:

```swift

// MARK: - Disappearing messages (spec 2026-10-05 §4 Info sheet)

private func expiryInfoMessage(expirySeconds: Int?, expiresAt: Date?) -> Message {
    Message(id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            peerHex: String(repeating: "a", count: 32), isOutgoing: true, body: "x",
            timestamp: Date(timeIntervalSince1970: 1700000000), status: MessageStatus.sent, validated: false,
            messageHash: String(repeating: "ab", count: 32), fieldKeys: "0xfd",
            expirySeconds: expirySeconds, expiresAt: expiresAt)
}

private func expiryInfoTimeline(_ m: Message) -> [MessageInfo.Row] {
    MessageInfo.sections(for: m, timeZone: TimeZone(identifier: "UTC")!).first { $0.title == "Timeline" }!.rows
}

/// A stamped row shows when it expires (same-day short form, ISO copy). The 0xFD field is named.
@Test func expiryInfoStampedRowShowsExpiresTime() {
    let rows = expiryInfoTimeline(expiryInfoMessage(expirySeconds: 300, expiresAt: Date(timeIntervalSince1970: 1700000300)))
    let expires = rows.first { $0.label == "Expires" }
    #expect(expires?.display == "22:18:20")
    #expect(expires?.copy == "2023-11-14T22:18:20.000Z")
    #expect(rows.contains { $0.label == "Disappears after" } == false)
    let payload = MessageInfo.sections(for: expiryInfoMessage(expirySeconds: 300, expiresAt: nil)).first { $0.title == "Payload" }!
    #expect(payload.rows.contains(MessageInfo.Row("Field", "0xFD custom meta")))
}

/// A received row that carries a duration but was not viewed yet shows the duration instead.
@Test func expiryInfoUnstampedRowShowsDuration() {
    let rows = expiryInfoTimeline(expiryInfoMessage(expirySeconds: 86_400, expiresAt: nil))
    #expect(rows.contains(MessageInfo.Row("Disappears after", "1 day")))
    #expect(rows.contains { $0.label == "Expires" } == false)
}

@Test func expiryInfoOrdinaryRowHasNeitherRow() {
    let rows = expiryInfoTimeline(expiryInfoMessage(expirySeconds: nil, expiresAt: nil))
    #expect(rows.contains { $0.label == "Expires" || $0.label == "Disappears after" } == false)
}
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryInfo > /tmp/ReTiCAMsgr/exp-t8-red.log 2>&1`
Expected: compiles; `expiryInfoStampedRowShowsExpiresTime` and `expiryInfoUnstampedRowShowsDuration` FAIL (no such rows).

- [x] **Step 3: Add the rows**

In `MessageInfo.timeline`, after the `if let reason = m.failureReason { ... }` block and before `return Section(...)`:

```swift
        // Disappearing messages (spec §4): when the purge will take this row, or, for a received
        // row not viewed yet, how long after the first view.
        if let at = m.expiresAt {
            rows.append(timeRow("Expires", at, sameDayAs: m.timestamp, tz))
        } else if let seconds = m.expirySeconds {
            rows.append(Row("Disappears after", ExpiryPreset.label(forSeconds: seconds)))
        }
```

- [x] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore --filter expiryInfo > /tmp/ReTiCAMsgr/exp-t8-green.log 2>&1`
Expected: 3 tests passed.

- [x] **Step 5: Mutation verification**

| Mutation | Test that must go RED |
|---|---|
| Change `timeRow("Expires", at, ...)` to `timeRow("Expires", m.timestamp, ...)` | `expiryInfoStampedRowShowsExpiresTime` |
| Change `else if let seconds = m.expirySeconds` to `if let seconds = m.expirySeconds` (both rows for a stamped message) (sub-batch B) | `expiryInfoStampedRowShowsExpiresTime` |
| Change `Row("Disappears after", ...)` label to `"Disappears in"` | `expiryInfoUnstampedRowShowsDuration` |
| Append `rows.append(Row("Expires", "never"))` unconditionally before the return | `expiryInfoOrdinaryRowHasNeitherRow` |

Sub-batch A: rows 1, 3, 4. Sub-batch B: row 2. Revert. GREEN.

- [x] **Step 6: Commit**

Write `/tmp/ReTiCAMsgr/msg-exp-task-8.txt` (subject `feat: Info sheet shows when a message expires`, body, trailers).

Run: `git -C APP add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/MessageInfo.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/MessageInfoTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCAMsgr/msg-exp-task-8.txt`

---

### Task 9: UI — toolbar menu, title, system line, bubble glyph

**Files:**
- Create: `APP/ReTiCAMsgr/ExpiryViews.swift`
- Modify: `APP/ReTiCAMsgr/ChatView.swift` (list rows, toolbar, `MessageBubble` status area)

**Interfaces:**
- Consumes: `store.openConversationExpiry`, `Action.expirySelected(seconds:)`, `Message.isTimerChange`, `Message.expirySeconds`, `ExpiryPreset`.

No unit tests in the app target (none exist today); the deliverable is a successful build and a manual check in the Simulator.

- [x] **Step 1: Create `ExpiryViews.swift`**

```swift
//
//  ExpiryViews.swift
//  ReTiCAMsgr
//

import SwiftUI
import ReTiCAMsgrCore

/// The disappearing-messages picker in the chat toolbar (spec 2026-10-05 §4): Signal's presets
/// with a checkmark on the current one, and the caveat that only ReTiCAMsgr peers honour it.
struct ExpiryMenu: View {
    let current: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        Menu {
            Section {
                ForEach(ExpiryPreset.allCases, id: \.rawValue) { preset in
                    Button {
                        onSelect(preset.seconds)
                    } label: {
                        if (current ?? 0) == preset.seconds {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
            } header: {
                Text(ExpiryPreset.caveat)
            }
        } label: {
            Image(systemName: current == nil ? "timer" : "timer.circle.fill")
        }
        .accessibilityLabel("Disappearing messages")
    }
}

/// The chat title with the active timer beneath the peer's name.
struct ChatTitle: View {
    let title: String
    let expiry: Int?

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
            if let expiry {
                Label(ExpiryPreset.label(forSeconds: expiry), systemImage: "timer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A timer-change announcement: a centred, secondary single line instead of a bubble. No context
/// menu, no reactions, no reply.
struct TimerChangeLine: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
```

- [x] **Step 2: Rows in `ChatView`**

In `ChatView.body`, change `List(store.threadMessages) { message in` so the closure begins:

```swift
                List(store.threadMessages) { message in
                    if message.isTimerChange {
                        TimerChangeLine(text: message.body)
                            .id(message.id)
                            .listRowSeparator(.hidden)
                    } else {
```

and close the `else {` with a `}` right after the existing `.contextMenu { ... } preview: { ... }` chain (before `}` that closes the `List` closure). Indent the existing body one level.

- [x] **Step 3: Toolbar and title**

Replace `.navigationTitle(store.openPeerHex.map(shortHex) ?? "Chat")` with:

```swift
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatTitle(title: store.openPeerHex.map(shortHex) ?? "Chat", expiry: store.openConversationExpiry)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ExpiryMenu(current: store.openConversationExpiry) { store.send(.expirySelected(seconds: $0)) }
                    // The change has to reach the peer, so it is gated like the reaction palette.
                    .disabled(!peerReachable)
            }
        }
```

Keep `.navigationBarTitleDisplayMode(.inline)`.

- [x] **Step 4: Bubble glyph**

In `MessageBubble.body`, replace

```swift
                if message.isOutgoing {
                    Text(message.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
```

with

```swift
                if message.isOutgoing || message.expirySeconds != nil {
                    HStack(spacing: 4) {
                        if message.expirySeconds != nil {
                            // Spec §4: a static glyph, no live countdown.
                            Image(systemName: "timer")
                                .accessibilityLabel("Disappearing message")
                        }
                        if message.isOutgoing {
                            Text(message.status)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
```

- [x] **Step 5: Build the app**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCAMsgr/exp-t9-xcodebuild.log 2>&1`
Expected: `** BUILD SUCCEEDED **`. Fix any compile error in the two app files only.

- [x] **Step 6: Full core suite once more**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-disappearing/ReTiCAMsgrCore > /tmp/ReTiCAMsgr/exp-t9-core.log 2>&1`
Expected: baseline + 49 passed, no failures.

- [x] **Step 7: Manual check (Simulator)**

Use the `xcodebuildmcp-cli` skill to boot a simulator, install and launch the app, open a conversation, and confirm: the timer glyph in the toolbar opens the menu with eight entries and the caveat header; selecting "1 day" inserts a centred "Disappearing messages set to 1 day" line and shows "1 day" under the title; sending a message shows a small timer glyph beside its status. Record what was seen in the task's commit body. If no Simulator is available, say so in the commit body instead of claiming the check.

- [x] **Step 8: Restore Xcode's scheme files, commit**

Run: `git -C APP status --short`. If only the two `xcschememanagement.plist` files are modified beside the intended changes, restore them with `git -C APP checkout -- <path>`.

Write `/tmp/ReTiCAMsgr/msg-exp-task-9.txt` (subject `feat: disappearing-messages menu, title indicator, system lines and bubble glyph`, body including the manual-check result, trailers).

Run: `git -C APP add ReTiCAMsgr/ExpiryViews.swift ReTiCAMsgr/ChatView.swift`
Run: `git -C APP commit -F /tmp/ReTiCAMsgr/msg-exp-task-9.txt`

---

### Task 10: Docs and hand-off

**Files:**
- Modify: `APP/docs/superpowers/backlog-retica-followups.md` (append a "Disappearing messages" section)
- Modify: this plan (tick boxes as tasks complete)

- [x] **Step 1: Backlog entry**

Append to `docs/superpowers/backlog-retica-followups.md`:

```markdown

## Disappearing messages (2026-10-05)

Left out by design (spec "Out of scope"): read receipts, a live countdown on bubbles, manual
delete-message and delete-conversation (the `MessagePurge` primitives make both small), groups.
Follow-ups noticed while implementing:

- A timer change selected while the peer is unreachable is blocked in the UI only; the reducer
  would send it and let it fail, as reactions do.
- The convergence line uses the peer's announce display name at receive time; a later announce
  with a new name does not rewrite earlier lines.
- `isForeground` starts true, so a push-wake launch counts as foreground until the first
  `.backgrounded`; harmless today because no thread can be open then.
```

- [x] **Step 2: Commit**

Write `/tmp/ReTiCAMsgr/msg-exp-task-10.txt` (subject `docs: disappearing-messages follow-ups`, body, trailers).

Run: `git -C APP add docs/superpowers/backlog-retica-followups.md docs/superpowers/plans/2026-10-05-disappearing-messages.md`
Run: `git -C APP commit -F /tmp/ReTiCAMsgr/msg-exp-task-10.txt`

- [ ] **Step 3: Hand off**

Use `superpowers:finishing-a-development-branch` from the main checkout's session to merge `feat/disappearing-messages` into `main` and remove the worktree.
