# Attachments (images and files) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send one photo or one file per message and receive both, inline, with progress and cancel, using LXMF's standard `FIELD_IMAGE` (0x06) and `FIELD_FILE_ATTACHMENTS` (0x05).

**Architecture:** A normalised `attachments` table (one row per message today) plus bytes on disk under Application Support, written and read only through `AttachmentStore`. `AttachmentWire` is the codec beside `ReplyWire`/`ReactionWire`; `ImageEncoder` (ImageIO, in the core package so `swift test` covers it on macOS) downscales to JPEG. `AppFeature` gains the send/receive/transfer state; SwiftUI views in the app target render bubbles, the composer bar, a viewer, QuickLook and progress.

**Tech Stack:** Swift 6, SwiftUI, TCA (`@Reducer`, `TestStore`), SQLiteData/GRDB migrations, ImageIO/CoreGraphics, PhotosUI, QuickLook, ReTiCA (`LXMFNode` delegates `deliveryProgress`, `inboundTransferProgress`, `propagationRefused`, `deliveryRejected`, `deliveryCancelled`, action `cancelOutbound`).

**Spec:** `docs/superpowers/specs/2026-09-28-attachments-design.md` (app main c6156ff). The spec is the authority; this plan argues from it.

## Global Constraints

- **Where:** all work happens ONLY in the app worktree `/Users/ell/development/ios/apps/ReTiCaMsgr-attachments` on branch `feat/attachments`, cut from app `main` in Task 0. `APP` below means that path; `CORE` means `APP/ReTiCaMsgrCore`. Never build, test or run git against the main checkout `/Users/ell/development/ios/apps/ReTiCaMsgr` after Task 0's `worktree add`, and never touch `/Users/ell/development/ios/pods/ReTiCA` (another agent may own it; it is only a read-only path dependency here — `CORE/Package.swift`'s `../../../pods/ReTiCA` resolves from the worktree unchanged).
- **Task 0 is a gate:** the baseline core suite `swift test --package-path CORE` must be green (currently **238 tests**) and `xcodebuild -project APP/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build` must succeed before Task 1.
- **Commits** go on `feat/attachments` only. Stage explicit paths (`git -C APP add <path> ...`, never `-A`/`.`). Never stage `ReTiCaMsgr.xcodeproj/xcuserdata/**`, `ReTiCaMsgrCore/.swiftpm/**`, `Package.resolved` or anything under `docs/superpowers/plans/2026-08-16-display-name.md` (pre-existing drift). Each task writes its message to its OWN file `/tmp/ReTiCaMsgr/msg-att-task-N.txt` with the Write tool, then `git -C APP commit -F /tmp/ReTiCaMsgr/msg-att-task-N.txt`. Message = `feat:`/`fix:`/`test:`/`docs:` subject, blank line, body, blank line, then exactly these two lines at column 0 (the first names the model that wrote the commit):
  `Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1`
  No semicolons anywhere in a commit message.
- **Shell:** one command per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreters (`python -c`, heredocs into an interpreter). Scripts and sed scripts go in files under `/tmp/ReTiCaMsgr/` (`mkdir -p /tmp/ReTiCaMsgr` if missing). Redirecting one command's output to a file (`cmd > /tmp/ReTiCaMsgr/x.log 2>&1`) is allowed.
- **Tests:** `swift test --package-path CORE --filter <prefix>` (`--filter` is repeatable) runs one task's tests; the full core suite is `swift test --package-path CORE` (no `--no-parallel` needed here). Known flake: `deliveryFailedMarksFailedAndReloads` can fail when run ALONE via `--filter`; it passes in a full run. Filtering still compiles every target, so the whole package must compile at the end of every task. Every new test name starts with its task's prefix — `attachTable` (T1), `attachStore` (T2), `attachWire` (T3), `imageEncoder` (T4), `attachInfo` (T5), `attachReceive` (T6), `attachSend` (T7), `attachTransfer` (T8) — so `--filter <prefix>` selects exactly that task's tests. None of these prefixes matches an existing test name (checked: no test contains "attach" or "imageEncoder" today).
- **Mutation verification is mandatory** for every task with tests: (a) run the task's filter, all GREEN; (b) apply the task's listed mutation batch to production code, run the filter once, confirm EVERY listed test is RED — where the batch says "sub-batch", run the sub-batches separately so no mutation masks another; (c) revert every mutation BY HAND with the Edit tool (never `git checkout -- <file>`), confirm `git -C APP diff` shows only the task's intended changes, run again, all GREEN. If a test survives its mutation, fix the test and restart at (a). Tests edited only mechanically to compile against a new shape are exempt.
- **TCA TestStore facts these tests rely on** (learned in the transfer-aware delivery run): under `exhaustivity = .off`, `store.state` reflects effect-delivered actions only after `receive` or `await store.skipReceivedActions(strict: false)`; every `send` clears not-yet-received actions, so a `receive` for something an earlier `send` produced must come before the next `send`; absence claims go `.on` + an exhaustive no-op probe send (never `skipInFlightEffects` while `.on`); a state closure on a pure `RingSet` insert asserts nothing; file-scope `let` constants of TCA `Action` types need `@MainActor`. The full suite must end with no new "Skipped assertions" or other known issues (today: none in this package).
- **Test style** (match `AppFeatureTests.swift`): free `@MainActor @Test func` functions, `makeStore(db, identity:)` with `exhaustivity = .off`, `sendAndSettle` + `skipReceivedActions(strict: false)` before reading rows, `rowsByHashAndDirection(db)` for outgoing/incoming disambiguation, `#expect` with literals. No tuple comparisons inside `#expect` (compare `.width` and `.height`, or bind to locals).
- **`Attachment` vs `Testing.Attachment`:** Swift Testing exports `public struct Attachment<AttachableValue>`, so a bare `Attachment` in a test file that imports `Testing` is ambiguous. The model keeps its name; every TEST file that names the type adds `private typealias Attachment = ReTiCaMsgrCore.Attachment` right after its imports — `DatabaseTests.swift` (Task 1), `AttachmentStoreTests.swift` (Task 2), `AttachmentInfoTests.swift` (Task 5), `AppFeatureTests.swift` (Task 6, once, at the top). Production code is unaffected (it does not import `Testing`).
- **Dependencies:** the attachment store is a TCA dependency `\.attachmentStore` (live: Application Support; test: a fresh temp directory per `AttachmentStore.testValue` access — tests that need to read files back must build ONE store, inject it, and keep it). `\.date` is frozen at 1700000000 in `makeStore` (2023-11-14 22:13:20 UTC), which fixes generated image names to `IMG_20231114_221320.jpg`.
- **Image bytes in tests** come from `TestImages` (Task 4 creates it in the test target): CoreGraphics-drawn PNG/JPEG data with known pixel sizes, EXIF orientation and a GPS tag. No fixture files.
- **Constants (from the spec):** `ImageEncoder.standardMaxPixels = 1280`, `standardQuality = 0.75`, `originalQuality = 0.92`; `AttachmentSizeNote.propagationLimitBytes = 256_000`, `deliveryLimitBytes = 1_000_000`; `AttachmentWire.sentImageFormat = "jpeg"`; `MessageStatus.cancelled = "cancelled"`; `FailureReason.rejected = "rejected"`, `.cancelled = "cancelled"`; `PropagationRefusal.tooLargeForNode = "too large for node"`; inbound-transfer silence timeout 60 s.
- **App target:** new SwiftUI files go in `APP/ReTiCaMsgr/` (the Xcode project uses synchronized folders, so no pbxproj edit). No `Info.plist` privacy keys are needed (`PhotosPicker` and `fileImporter` run out of process). The app-target build must succeed at the end of the one task that touches the app target (Task 9); every core task must leave the package compiling, which the filtered test runs prove.

## Review Focus

Inputs the spec implies but its own examples don't exercise, most likely to bite first. Each is pinned by a named test in the owning task.

1. **A Sideband image whose format string is `jpg`, upper-case, or a `bin`** must still render as an image; an unknown format must not drop the message — it becomes a file row. Tests: T3 `attachWireDecodesSidebandFormatVariants`, `attachWireUnknownImageFormatBecomesAFile`.
2. **A file name with path separators or hundreds of bytes** from a hostile peer must never escape the attachments directory or break the row. Tests: T3 `attachWireSanitisesFileNames`, T2 `attachStoreNamesFilesByHashAndDirection` (the store never uses the peer's name in a path).
3. **A message with `0x05`/`0x06` present but malformed** must still be stored as a text message (never lost). Test: T6 `attachReceiveMalformedFieldKeepsTheText`.
4. **A store write failure on receive** (disk full, directory unwritable) must keep the message and mark the attachment unavailable, not crash or drop it. Test: T6 `attachReceiveStoreFailureKeepsTheMessageWithoutBytes`.
5. **Progress must never go backwards and must be cleared by every terminal outcome**, including `deliveryRejected` and `deliveryCancelled`, or a bubble keeps a stale bar. Test: T8 `attachTransferProgressIsMonotonicAndClearedByEveryTerminal`.
6. **A cancel on a message that is not `sending`** (already delivered, or incoming) must send nothing to the node. Test: T8 `attachTransferCancelIsIgnoredUnlessSending` (exhaustive window).
7. **An inbound transfer that stops reporting** (link died without `linkClosed`, or the peer vanished) must not show "Receiving…" forever. Test: T8 `attachTransferInboundEntryExpiresAfterSilence` (TestClock, 60 s).
8. **The EXIF orientation of a phone photo** must be baked into the sent JPEG (Sideband ignores orientation tags) and GPS must be gone. Tests: T4 `imageEncoderBakesOrientationIntoPixels`, `imageEncoderStripsMetadata`.

---

### Task 0: Worktree and baseline

**Files:** none changed.

- [ ] **Step 1: Create the worktree from app main**

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr worktree add /Users/ell/development/ios/apps/ReTiCaMsgr-attachments -b feat/attachments main`
Expected: a new worktree at `APP` on `feat/attachments`, HEAD = app main (c6156ff or later).

- [ ] **Step 2: Baseline core suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/att-t0-core.log 2>&1`
Expected: `Test run with 238 tests in 0 suites passed` (count may be higher if main moved — record it as the baseline).

- [ ] **Step 3: Baseline app build**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCaMsgr/att-t0-xcodebuild.log 2>&1`
Expected: `** BUILD SUCCEEDED **` at the end of the log.

- [ ] **Step 4: Restore any files Xcode rewrote**

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments status --short`
Expected: empty. If `xcschememanagement.plist` files show as modified, restore them: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments checkout -- ReTiCaMsgr.xcodeproj/xcuserdata/ell.xcuserdatad/xcschemes/xcschememanagement.plist` and the same for `ReTiCaMsgrCore/.swiftpm/xcode/xcuserdata/ell.xcuserdatad/xcschemes/xcschememanagement.plist` (these two files are the ONLY `git checkout --` allowed in this plan, and only in Task 0 and Task 9 Step 9, where nothing else is modified). Nothing to commit.

---

### Task 1: `Attachment` table, message columns, `cancelled` status

**Files:**
- Create: `CORE/Sources/ReTiCaMsgrCore/Attachment.swift`
- Modify: `CORE/Sources/ReTiCaMsgrCore/Message.swift` (columns after `replyQuote`, `MessageStatus`, new enums)
- Modify: `CORE/Sources/ReTiCaMsgrCore/Database.swift` (new migration after `addReplies`)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/DatabaseTests.swift` (append)

**Interfaces:**
- Produces: `Attachment` (`@Table`, `Identifiable`): `id: UUID`, `messageId: UUID`, `kind: String`, `name: String`, `format: String`, `size: Int`, `width: Int?`, `height: Int?`, `path: String` (relative; `""` = bytes unavailable); `static func byMessageId(_ rows: [Attachment]) -> [UUID: Attachment]` (first row per message wins; used by Task 6's thread and conversation loads). `AttachmentKind.image = "image"`, `.file = "file"`. `Message.failureReason: String?`, `Message.propagationRefused: String?` (init parameters with `nil` defaults, after `replyQuote`). `MessageStatus.cancelled = "cancelled"`. `FailureReason.rejected = "rejected"`, `.cancelled = "cancelled"`. `PropagationRefusal.tooLargeForNode = "too large for node"`. Migration name `createAttachments` (table + index + the two `messages` columns).

- [ ] **Step 1: Write the failing tests**

In `CORE/Tests/ReTiCaMsgrCoreTests/DatabaseTests.swift`, add right after the imports (after `@testable import ReTiCaMsgrCore`):

```swift

/// `Testing` exports its own `Attachment`; this file means the model.
private typealias Attachment = ReTiCaMsgrCore.Attachment
```

Then append to the end of the file:

```swift

// MARK: - Attachments (createAttachments)

private func attachTableMessage(_ id: String, hash: String) -> Message {
    Message(
        id: UUID(uuidString: id)!,
        peerHex: String(repeating: "b", count: 32),
        isOutgoing: true,
        body: "",
        timestamp: Date(timeIntervalSince1970: 1700000000),
        status: MessageStatus.sending,
        validated: false,
        messageHash: hash
    )
}

/// Every column round-trips. Literal expectations, not only `back == a`, so a model that drops a
/// field on init cannot pass by dropping it on both sides.
@Test func attachTableRoundTripsEveryColumn() throws {
    let db = try AppDatabase.makeInMemory()
    let m = attachTableMessage("00000000-0000-0000-0000-000000000010", hash: String(repeating: "e", count: 64))
    let a = Attachment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        messageId: m.id,
        kind: AttachmentKind.image,
        name: "IMG_20231114_221320.jpg",
        format: "jpeg",
        size: 34_211,
        width: 1280,
        height: 853,
        path: "eeee-out.jpg"
    )
    try db.write { d in
        try Message.insert { m }.execute(d)
        try Attachment.insert { a }.execute(d)
    }
    let back = try #require(try db.read { try Attachment.all.fetchAll($0) }.first)
    #expect(back.messageId == m.id)
    #expect(back.kind == "image")
    #expect(back.name == "IMG_20231114_221320.jpg")
    #expect(back.format == "jpeg")
    #expect(back.size == 34_211)
    #expect(back.width == 1280)
    #expect(back.height == 853)
    #expect(back.path == "eeee-out.jpg")
    #expect(back == a)
}

/// A file attachment has no dimensions, and an empty path means "bytes unavailable".
@Test func attachTableFileRowHasNilDimensions() throws {
    let db = try AppDatabase.makeInMemory()
    let m = attachTableMessage("00000000-0000-0000-0000-000000000012", hash: String(repeating: "f", count: 64))
    let a = Attachment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
        messageId: m.id, kind: AttachmentKind.file, name: "notes.pdf", format: "pdf",
        size: 12, width: nil, height: nil, path: ""
    )
    try db.write { d in
        try Message.insert { m }.execute(d)
        try Attachment.insert { a }.execute(d)
    }
    let back = try #require(try db.read { try Attachment.all.fetchAll($0) }.first)
    #expect(back.kind == "file")
    #expect(back.width == nil)
    #expect(back.height == nil)
    #expect(back.path == "")
}

/// Deleting a message deletes its attachment row (ON DELETE CASCADE), so a future "delete
/// conversation" cannot leave orphan rows pointing at files.
@Test func attachTableRowIsDeletedWithItsMessage() throws {
    let db = try AppDatabase.makeInMemory()
    let m = attachTableMessage("00000000-0000-0000-0000-000000000014", hash: String(repeating: "1", count: 64))
    let a = Attachment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!,
        messageId: m.id, kind: AttachmentKind.file, name: "a.bin", format: "bin",
        size: 1, width: nil, height: nil, path: "1111-in.bin"
    )
    try db.write { d in
        try Message.insert { m }.execute(d)
        try Attachment.insert { a }.execute(d)
    }
    try db.write { d in try Message.where { $0.id.eq(m.id) }.delete().execute(d) }
    let remaining = try db.read { try Attachment.all.fetchAll($0) }
    #expect(remaining.isEmpty)
}

/// An attachment row must point at an existing message: the foreign key is enforced.
@Test func attachTableRejectsAnOrphanRow() throws {
    let db = try AppDatabase.makeInMemory()
    let orphan = Attachment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000016")!,
        messageId: UUID(uuidString: "00000000-0000-0000-0000-0000000000ff")!,
        kind: AttachmentKind.file, name: "x", format: "", size: 0, width: nil, height: nil, path: ""
    )
    #expect(throws: (any Error).self) {
        try db.write { d in try Attachment.insert { orphan }.execute(d) }
    }
}

/// A row written before `createAttachments` reads back with nil for the two new message columns.
@Test func attachTableLegacyMessageReadsBackWithNilNewColumns() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator().migrate(queue, upTo: "addReplies")
    try queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO messages (id, peerHex, isOutgoing, body, timestamp, status, validated, messageHash, fieldKeys)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: ["00000000-0000-0000-0000-000000000017", String(repeating: "a", count: 32),
                        1, "before attachments", "2023-11-14 22:13:20.000", MessageStatus.failed, 0,
                        String(repeating: "c", count: 64), ""]
        )
    }
    try AppDatabase.migrator().migrate(queue)
    let row = try #require(try queue.read { try Message.all.fetchAll($0) }.first)
    #expect(row.body == "before attachments")
    #expect(row.failureReason == nil)
    #expect(row.propagationRefused == nil)
    let attachments = try queue.read { try Attachment.all.fetchAll($0) }
    #expect(attachments.isEmpty)
}

/// The two new message columns round-trip, and the new status/reason constants are the strings
/// the spec names.
@Test func attachTableMessageColumnsRoundTripAndConstantsMatchSpec() throws {
    let db = try AppDatabase.makeInMemory()
    var m = attachTableMessage("00000000-0000-0000-0000-000000000018", hash: String(repeating: "2", count: 64))
    m.status = MessageStatus.cancelled
    m.failureReason = FailureReason.cancelled
    m.propagationRefused = PropagationRefusal.tooLargeForNode
    try db.write { try Message.insert { m }.execute($0) }
    let back = try #require(try db.read { try Message.all.fetchAll($0) }.first)
    #expect(back.status == "cancelled")
    #expect(back.failureReason == "cancelled")
    #expect(back.propagationRefused == "too large for node")
    #expect(FailureReason.rejected == "rejected")
    #expect(AttachmentKind.image == "image")
    #expect(AttachmentKind.file == "file")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachTable`
Expected: compile errors (`Attachment`, `AttachmentKind`, `failureReason` unknown).

- [ ] **Step 3: `Attachment.swift`**

Create `CORE/Sources/ReTiCaMsgrCore/Attachment.swift`:

```swift
import Foundation
import SQLiteData

/// One attachment of one message (spec 2026-09-28 §1): the bytes live on disk under
/// `AttachmentStore`, this row is what the thread and the Info sheet read. Today a message carries
/// at most one attachment; the schema does not assume it (the app does).
///
/// `path` is relative to the attachments directory, `""` when the bytes could not be written
/// (the bubble then says the attachment is unavailable). `width`/`height` are set for images only.
@Table
public struct Attachment: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var messageId: UUID
    public var kind: String        // AttachmentKind.*
    /// The file name: the sender's for files, `IMG_<yyyyMMdd_HHmmss>.jpg` for photos we send,
    /// `image.<format>` for images we receive (LXMF FIELD_IMAGE carries no name).
    public var name: String
    /// Images: `jpeg`/`webp`/`png`/`heic`. Files: the extension without the dot, `""` if none.
    public var format: String
    /// Bytes as sent or received.
    public var size: Int
    public var width: Int?
    public var height: Int?
    public var path: String

    public init(id: UUID, messageId: UUID, kind: String, name: String, format: String, size: Int,
                width: Int?, height: Int?, path: String) {
        self.id = id
        self.messageId = messageId
        self.kind = kind
        self.name = name
        self.format = format
        self.size = size
        self.width = width
        self.height = height
        self.path = path
    }

    public var isImage: Bool { kind == AttachmentKind.image }
    /// The bytes are on disk (an empty path means the write failed or the file is gone).
    public var hasBytes: Bool { !path.isEmpty }

    /// Rows keyed by their message. The app keeps one attachment per message today; should a
    /// message ever carry more, the first row wins.
    public static func byMessageId(_ rows: [Attachment]) -> [UUID: Attachment] {
        Dictionary(rows.map { ($0.messageId, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

public enum AttachmentKind {
    public static let image = "image"
    public static let file = "file"
}
```

- [ ] **Step 4: `Message.swift` — columns, status, reasons**

In `CORE/Sources/ReTiCaMsgrCore/Message.swift`, after the `replyQuote` property (line 45) add:

```swift
    /// Outgoing only: why the message will not go out, beside `status` — `FailureReason.*`.
    /// nil for an ordinary failure (retries exhausted) and for every non-failed row.
    public var failureReason: String?
    /// Outgoing only: the propagated copy was refused up front — `PropagationRefusal.*`.
    /// nil when it was not refused (or no propagation node was configured).
    public var propagationRefused: String?
```

Add two init parameters after `replyQuote: String? = nil`:

```swift
        replyQuote: String? = nil,
        failureReason: String? = nil,
        propagationRefused: String? = nil
```

and two assignments after `self.replyQuote = replyQuote`:

```swift
        self.failureReason = failureReason
        self.propagationRefused = propagationRefused
```

In `MessageStatus`, after `delivered`, add:

```swift
    /// The user stopped the send (`deliveryCancelled`). Terminal, like `failed`; a cancelled
    /// message is never retried (ReTiCA forbids re-sending a hash — re-attach and send again).
    public static let cancelled = "cancelled"
```

After the `StampState` enum, append:

```swift

/// Why an outgoing message ended as `failed`/`cancelled` (`Message.failureReason`).
public enum FailureReason {
    /// The recipient refused the transfer (`deliveryRejected`).
    public static let rejected = "rejected"
    /// The user cancelled the send (`deliveryCancelled`).
    public static let cancelled = "cancelled"
}

/// Why the propagated copy was never sent (`Message.propagationRefused`), from ReTiCA's
/// `LXMFRouter.RefusalReason`.
public enum PropagationRefusal {
    public static let tooLargeForNode = "too large for node"
}
```

- [ ] **Step 5: Migration**

In `CORE/Sources/ReTiCaMsgrCore/Database.swift`, after the `addReplies` migration (before `return m`) add:

```swift
        m.registerMigration("createAttachments") { db in
            // One row per attachment (spec 2026-09-28 §1). `messageId` cascades so a deleted
            // message can never leave a row pointing at a file. Indexed, not unique: the app
            // enforces one attachment per message today, the schema does not assume it.
            try db.create(table: "attachments") { t in
                t.primaryKey("id", .text).notNull()
                t.column("messageId", .text).notNull().references("messages", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("format", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("path", .text).notNull()
            }
            try db.create(indexOn: "attachments", columns: ["messageId"])
            // Outgoing-only reasons for the Info sheet. Nullable: rows from before this migration
            // and every ordinary row read back NULL.
            try db.alter(table: "messages") { t in
                t.add(column: "failureReason", .text)
                t.add(column: "propagationRefused", .text)
            }
        }
```

- [ ] **Step 6: Run the new tests**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachTable`
Expected: 6 tests PASS. If `attachTableRejectsAnOrphanRow` fails because foreign keys are off, GRDB's default `Configuration` enables them — check `AppDatabase.makeInMemory` uses a plain `DatabaseQueue()` (it does) and that the `references` call is present.

- [ ] **Step 7: Mutation batch (two sub-batches)**

Sub-batch A (apply together):
1. `Database.swift`: remove `.references("messages", onDelete: .cascade)` → RED `attachTableRowIsDeletedWithItsMessage` (the row survives), `attachTableRejectsAnOrphanRow` (the insert succeeds).
2. `Attachment.swift`: in `init`, `self.height = height` → `self.height = width` → RED `attachTableRoundTripsEveryColumn` (853 ≠ 1280).
3. `Message.swift`: `public static let cancelled = "cancelled"` → `"canceled"` → RED `attachTableMessageColumnsRoundTripAndConstantsMatchSpec`.
5. `Attachment.swift`: in `init`, `self.path = path` → `self.path = path.isEmpty ? "x" : path` → RED `attachTableFileRowHasNilDimensions` (`back.path == "x"`). No other test in A reads an empty path.

Sub-batch B (alone, after A is reverted and green):
4. `Database.swift`: delete the `t.add(column: "propagationRefused", .text)` line → RED `attachTableMessageColumnsRoundTripAndConstantsMatchSpec` (insert fails: no such column), `attachTableLegacyMessageReadsBackWithNilNewColumns` (decode fails). Alone because mutation 3 also reddens the constants test.

Every mutation names its test. Run the Step 6 command per sub-batch: listed tests FAIL. Revert by hand, `git -C APP diff` shows only this task's changes, run again: all PASS.

- [ ] **Step 8: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/att-t1-full.log 2>&1`
Expected: all pass; count = baseline + 6.

- [ ] **Step 9: Commit**

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Attachment.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Message.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Database.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/DatabaseTests.swift`

Write `/tmp/ReTiCaMsgr/msg-att-task-1.txt`:

```
feat: attachments table, cancelled status and failure columns

Adds the attachments table (one row per message, cascading on delete)
and two nullable message columns, failureReason and propagationRefused,
plus the cancelled status and the reason constants the Info sheet and
the bubbles will show.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments commit -F /tmp/ReTiCaMsgr/msg-att-task-1.txt`

---

### Task 2: `AttachmentStore` — bytes on disk

**Files:**
- Create: `CORE/Sources/ReTiCaMsgrCore/AttachmentStore.swift`
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/AttachmentStoreTests.swift`

**Interfaces:**
- Produces: `public struct AttachmentStore: Sendable { public var baseDirectory: URL; public init(baseDirectory: URL) }`; `static func fileName(messageHash: String, outgoing: Bool, ext: String) -> String` (`<hash>-<in|out>[.<ext>]`); `static func sanitizedExtension(_ ext: String) -> String` (lowercase, dot stripped, `[a-z0-9]{1,8}` else `""`); `func store(_ bytes: Data, messageHash: String, outgoing: Bool, ext: String) throws -> String` (creates the directory, marks it excluded from backup, writes atomically with `.completeFileProtectionUntilFirstUserAuthentication` on iOS — the same class as the SQLite file, so an attachment received over BLE while the phone is locked can still be written — returns the RELATIVE path = file name); `func url(forRelativePath:) -> URL`; `func url(for: Attachment) -> URL?` (nil when `path` is empty); `func exists(_ relativePath: String) -> Bool`; `func delete(_ relativePath: String) throws`; `enum ExportError: Error, Equatable { case noBytes }`; `var exportDirectory: URL` (`<temporaryDirectory>/AttachmentExports`); `func exportURL(for attachment: Attachment) throws -> URL` (copies the bytes to `<exportDirectory>/<attachment.id>/<attachment.name>`, creating the directory and replacing an earlier copy, and returns that URL; throws `ExportError.noBytes` when `path` is empty — Task 9's share sheet and QuickLook use it so the recipient sees the real file name, not `<hash>-in.pdf`). The spec's `url(for:) -> URL` / `delete(_ attachment:)` become `url(for:) -> URL?` / `delete(_ relativePath:)` (see Self-review departures). TCA dependency `\.attachmentStore` (`DependencyKey` live = `<Application Support>/Attachments`, test = a unique temp directory).

- [ ] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/AttachmentStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCaMsgrCore

/// `Testing` exports its own `Attachment`; this file means the model.
private typealias Attachment = ReTiCaMsgrCore.Attachment

private func tempStore() -> AttachmentStore {
    AttachmentStore(baseDirectory: FileManager.default.temporaryDirectory
        .appending(path: "attachStoreTests-\(UUID().uuidString)"))
}

private let hash64 = String(repeating: "ab", count: 32)

/// Review Focus 2: the file name is the message hash plus the direction, never the peer's name,
/// so a hostile name cannot pick the path. An incoming and an outgoing row can share a hash.
@Test func attachStoreNamesFilesByHashAndDirection() {
    #expect(AttachmentStore.fileName(messageHash: hash64, outgoing: true, ext: "jpeg") == "\(hash64)-out.jpeg")
    #expect(AttachmentStore.fileName(messageHash: hash64, outgoing: false, ext: "pdf") == "\(hash64)-in.pdf")
    #expect(AttachmentStore.fileName(messageHash: hash64, outgoing: false, ext: "") == "\(hash64)-in")
    // The extension is sanitised on the way in: no dots, no separators, no case, at most 8 chars.
    #expect(AttachmentStore.fileName(messageHash: hash64, outgoing: true, ext: "../etc") == "\(hash64)-out")
    #expect(AttachmentStore.fileName(messageHash: hash64, outgoing: true, ext: ".JPG") == "\(hash64)-out.jpg")
}

@Test func attachStoreSanitisesExtensions() {
    #expect(AttachmentStore.sanitizedExtension("jpeg") == "jpeg")
    #expect(AttachmentStore.sanitizedExtension(".PNG") == "png")
    #expect(AttachmentStore.sanitizedExtension("tar.gz") == "")
    #expect(AttachmentStore.sanitizedExtension("a/b") == "")
    #expect(AttachmentStore.sanitizedExtension("") == "")
    #expect(AttachmentStore.sanitizedExtension("toolongext") == "")   // 10 chars
    #expect(AttachmentStore.sanitizedExtension("mp4") == "mp4")
}

@Test func attachStoreWritesReadsAndDeletes() throws {
    let store = tempStore()
    let bytes = Data([1, 2, 3, 4])
    let path = try store.store(bytes, messageHash: hash64, outgoing: false, ext: "bin")
    #expect(path == "\(hash64)-in.bin")
    #expect(store.exists(path))
    #expect(try Data(contentsOf: store.url(forRelativePath: path)) == bytes)
    try store.delete(path)
    #expect(!store.exists(path))
    // Deleting again is not an error (idempotent cleanup).
    try store.delete(path)
}

@Test func attachStoreOverwritesTheSameNameAtomically() throws {
    let store = tempStore()
    _ = try store.store(Data([9]), messageHash: hash64, outgoing: true, ext: "jpeg")
    let path = try store.store(Data([7, 7]), messageHash: hash64, outgoing: true, ext: "jpeg")
    #expect(try Data(contentsOf: store.url(forRelativePath: path)) == Data([7, 7]))
    let listing = try FileManager.default.contentsOfDirectory(atPath: store.baseDirectory.path())
    #expect(listing == ["\(hash64)-out.jpeg"])   // no temp files left behind
}

@Test func attachStoreCreatesTheDirectoryAndExcludesItFromBackup() throws {
    let store = tempStore()
    #expect(!FileManager.default.fileExists(atPath: store.baseDirectory.path()))
    _ = try store.store(Data([1]), messageHash: hash64, outgoing: true, ext: "")
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: store.baseDirectory.path(), isDirectory: &isDir))
    #expect(isDir.boolValue)
    let values = try store.baseDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
}

@Test func attachStoreURLForAttachmentIsNilWhenPathIsEmpty() {
    let store = tempStore()
    let withBytes = Attachment(id: UUID(), messageId: UUID(), kind: AttachmentKind.file, name: "a", format: "",
                               size: 1, width: nil, height: nil, path: "\(hash64)-in")
    let without = Attachment(id: UUID(), messageId: UUID(), kind: AttachmentKind.file, name: "a", format: "",
                             size: 1, width: nil, height: nil, path: "")
    #expect(store.url(for: withBytes) == store.baseDirectory.appending(path: "\(hash64)-in"))
    #expect(store.url(for: without) == nil)
}

/// Review Focus 4: a base directory that cannot be created (its parent is a regular file)
/// surfaces as a thrown error, which `AppFeature` turns into "attachment unavailable".
@Test func attachStoreWriteFailureThrows() throws {
    let blocker = FileManager.default.temporaryDirectory.appending(path: "attachStoreBlocker-\(UUID().uuidString)")
    try Data([0]).write(to: blocker)
    let store = AttachmentStore(baseDirectory: blocker.appending(path: "Attachments"))
    #expect(throws: (any Error).self) {
        try store.store(Data([1]), messageHash: hash64, outgoing: false, ext: "")
    }
}

/// Each access to the test dependency is a fresh, isolated directory.
@Test func attachStoreTestValueIsIsolated() {
    let a = AttachmentStore.testValue
    let b = AttachmentStore.testValue
    #expect(a.baseDirectory != b.baseDirectory)
    #expect(a.baseDirectory.path().contains("ReTiCaMsgrTests-Attachments"))
}

/// The share sheet and QuickLook get the attachment's real name, not the hash-named stored file,
/// and a second export replaces the first copy instead of failing.
@Test func attachStoreExportURLUsesTheRealName() throws {
    let store = tempStore()
    let path = try store.store(Data([5, 6]), messageHash: hash64, outgoing: false, ext: "pdf")
    let a = Attachment(id: UUID(), messageId: UUID(), kind: AttachmentKind.file, name: "Trail map.pdf",
                       format: "pdf", size: 2, width: nil, height: nil, path: path)
    let url = try store.exportURL(for: a)
    #expect(url.lastPathComponent == "Trail map.pdf")
    #expect(url.deletingLastPathComponent().lastPathComponent == a.id.uuidString)
    #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "AttachmentExports")
    #expect(try Data(contentsOf: url) == Data([5, 6]))
    // The stored file stays where it was.
    #expect(store.exists(path))
    let again = try store.exportURL(for: a)
    #expect(again == url)
    #expect(try Data(contentsOf: again) == Data([5, 6]))
}

/// A row with no bytes has nothing to export.
@Test func attachStoreExportURLThrowsWithoutBytes() {
    let store = tempStore()
    let without = Attachment(id: UUID(), messageId: UUID(), kind: AttachmentKind.file, name: "a.pdf", format: "pdf",
                             size: 1, width: nil, height: nil, path: "")
    #expect(throws: AttachmentStore.ExportError.noBytes) {
        try store.exportURL(for: without)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachStore`
Expected: compile errors (`AttachmentStore` unknown).

- [ ] **Step 3: `AttachmentStore.swift`**

Create `CORE/Sources/ReTiCaMsgrCore/AttachmentStore.swift`:

```swift
import Foundation
import ComposableArchitecture

/// The bytes of every attachment (spec 2026-09-28 §1). One directory, one file per attachment,
/// named by the message hash and the direction — never by anything a peer sent — so a hostile
/// file name cannot choose a path. Everything else in the app goes through this type; nothing
/// else touches `FileManager` for attachments.
public struct AttachmentStore: Sendable {
    public var baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// `<hash>-<in|out>[.<ext>]`. The extension is sanitised (`sanitizedExtension`) so a
    /// separator or a dot in it cannot turn the name into a path.
    public static func fileName(messageHash: String, outgoing: Bool, ext: String) -> String {
        let clean = sanitizedExtension(ext)
        let stem = "\(messageHash)-\(outgoing ? "out" : "in")"
        return clean.isEmpty ? stem : "\(stem).\(clean)"
    }

    /// Lowercase, without a leading dot, `[a-z0-9]{1,8}`; anything else is `""` (no extension).
    public static func sanitizedExtension(_ ext: String) -> String {
        var s = ext.lowercased()
        if s.hasPrefix(".") { s.removeFirst() }
        guard (1...8).contains(s.count),
              s.allSatisfy({ ($0.isASCII && $0.isLetter) || ($0.isASCII && $0.isNumber) })
        else { return "" }
        return s
    }

    /// Writes the bytes and returns the RELATIVE path (the file name) to store in the row.
    /// Creates the directory on first use, marks it excluded from backup, writes atomically, and
    /// on iOS with the same file protection class as the SQLite file
    /// (`completeUntilFirstUserAuthentication`): BLE runs in the background, and an attachment
    /// received while the phone is locked must still be writable.
    public func store(_ bytes: Data, messageHash: String, outgoing: Bool, ext: String) throws -> String {
        try ensureDirectory()
        let name = Self.fileName(messageHash: messageHash, outgoing: outgoing, ext: ext)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try bytes.write(to: baseDirectory.appending(path: name), options: options)
        return name
    }

    public func url(forRelativePath path: String) -> URL {
        baseDirectory.appending(path: path)
    }

    /// nil when the row has no bytes (`path == ""`).
    public func url(for attachment: Attachment) -> URL? {
        attachment.hasBytes ? url(forRelativePath: attachment.path) : nil
    }

    public func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forRelativePath: relativePath).path())
    }

    /// Removes the file; a missing file is not an error.
    public func delete(_ relativePath: String) throws {
        let url = url(forRelativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path()) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public enum ExportError: Error, Equatable {
        /// The row has no bytes (`path == ""`).
        case noBytes
    }

    /// Where shareable copies go. The system purges the temporary directory on its own.
    public var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "AttachmentExports")
    }

    /// A copy of the bytes under the attachment's own name, for the share sheet and QuickLook:
    /// the stored file is named by hash, so sharing it directly would hand the recipient
    /// `<hash>-in.pdf` (and a file with no extension would preview as unknown). The name is safe
    /// to use as a path component: `AttachmentWire` and `AttachmentPreparation` sanitise every
    /// name before a row exists. An earlier copy is replaced.
    public func exportURL(for attachment: Attachment) throws -> URL {
        guard let source = url(for: attachment) else { throw ExportError.noBytes }
        let directory = exportDirectory.appending(path: attachment.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: attachment.name)
        if FileManager.default.fileExists(atPath: destination.path()) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func ensureDirectory() throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: baseDirectory.path(), isDirectory: &isDir), isDir.boolValue {
            return
        }
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = baseDirectory
        try dir.setResourceValues(values)
    }
}

extension AttachmentStore: DependencyKey {
    /// `<Application Support>/Attachments`, beside nothing else the app writes there today.
    public static var liveValue: AttachmentStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AttachmentStore(baseDirectory: support.appending(path: "Attachments"))
    }

    /// A fresh temporary directory on every access, so tests never share files. A test that must
    /// read back what a reducer wrote builds one store, injects it, and keeps the reference.
    public static var testValue: AttachmentStore {
        AttachmentStore(baseDirectory: FileManager.default.temporaryDirectory
            .appending(path: "ReTiCaMsgrTests-Attachments-\(UUID().uuidString)"))
    }
}

extension DependencyValues {
    public var attachmentStore: AttachmentStore {
        get { self[AttachmentStore.self] }
        set { self[AttachmentStore.self] = newValue }
    }
}
```

- [ ] **Step 4: Run the new tests**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachStore`
Expected: 10 tests PASS. If `attachStoreCreatesTheDirectoryAndExcludesItFromBackup` fails on `isExcludedFromBackup` (macOS temp dirs can report nil), read the value with `try store.baseDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup` right after creation in the test and report; do not weaken the production code.

- [ ] **Step 5: Mutation batch (three sub-batches)**

Sub-batch A (apply together):
1. `fileName`: `outgoing ? "out" : "in"` → `outgoing ? "in" : "out"` → RED `attachStoreNamesFilesByHashAndDirection`, `attachStoreWritesReadsAndDeletes` (path mismatch), `attachStoreOverwritesTheSameNameAtomically` (the listing is `-in.jpeg`).
2. `sanitizedExtension`: `(1...8)` → `(1...10)` → RED `attachStoreSanitisesExtensions` (`toolongext` accepted).
3. `ensureDirectory`: delete the three `isExcludedFromBackup` lines → RED `attachStoreCreatesTheDirectoryAndExcludesItFromBackup`.
5. `url(for:)`: `attachment.hasBytes ? ... : nil` → always the URL → RED `attachStoreURLForAttachmentIsNilWhenPathIsEmpty`.
6. `testValue`: replace the UUID suffix with a constant → RED `attachStoreTestValueIsIsolated`.
9. `exportURL`: `directory.appending(path: attachment.name)` → `directory.appending(path: attachment.path)` → RED `attachStoreExportURLUsesTheRealName` (the copy is hash-named).

Sub-batch B (apply together, after A is reverted and green):
4. `delete`: remove the `guard ... else { return }` → RED `attachStoreWritesReadsAndDeletes` (second delete throws). Not in A: mutation 1 reddens the same test.
11. `exportURL`: `guard let source = url(for: attachment) else { throw ExportError.noBytes }` → `let source = url(forRelativePath: attachment.path)` → RED `attachStoreExportURLThrowsWithoutBytes` (the copy fails with a Cocoa error, not `.noBytes`). Not in A: mutation 5 reddens the same test.

Sub-batch C (apply together, after B is reverted and green):
7. `store`: `let name = Self.fileName(...)` → `let name = Self.fileName(...) + "-\(UUID().uuidString)"` → RED `attachStoreOverwritesTheSameNameAtomically` (two files in the listing), `attachStoreWritesReadsAndDeletes` (path mismatch). Not in A: mutation 1 reddens the overwrite test.
8. `store`: `try ensureDirectory()` → `try? ensureDirectory()` AND `try bytes.write(...)` → `try? bytes.write(...)` → RED `attachStoreWriteFailureThrows` (nothing throws). Both lines: with only `ensureDirectory` swallowed, the write into the missing directory still throws and the test stays green.
10. `exportURL`: delete the `if FileManager.default.fileExists(atPath: destination.path()) { ... }` block → RED `attachStoreExportURLUsesTheRealName` (the second export's copy fails on the existing file). Not in A: mutation 9 reddens the same test.

Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 6: Full suite, commit**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/att-t2-full.log 2>&1`
Expected: all pass; count = Task 1 count + 10.

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AttachmentStore.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AttachmentStoreTests.swift`

Write `/tmp/ReTiCaMsgr/msg-att-task-2.txt`:

```
feat: attachment bytes live on disk behind AttachmentStore

One directory under Application Support, excluded from backup, one
file per attachment named by message hash and direction, written
atomically with the same file protection class as the database so a
locked phone can still receive. exportURL copies the bytes under the
real file name for sharing. A TCA dependency with an isolated test
value.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments commit -F /tmp/ReTiCaMsgr/msg-att-task-2.txt`

---
### Task 3: `AttachmentWire` — the LXMF 0x05 / 0x06 codec

**Files:**
- Create: `CORE/Sources/ReTiCaMsgrCore/AttachmentWire.swift`
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/AttachmentWireTests.swift`

**Interfaces:**
- Consumes (Task 1–2): `AttachmentKind`, `AttachmentStore.sanitizedExtension`.
- Produces: `public enum AttachmentWire` with `fieldFileAttachments = 0x05`, `fieldImage = 0x06`, `sentImageFormat = "jpeg"`, `imageFormats: Set<String> = ["jpeg", "png", "webp", "heic"]`, `maxNameBytes = 255`, `fallbackFileName = "file"`; `struct Decoded: Equatable, Sendable { kind: String, name: String, format: String, data: Data, droppedFileCount: Int }` (`init(kind:name:format:data:droppedFileCount: = 0)`; `droppedFileCount` = the 0x05 entries left out: those beyond the first, or all of them when an image wins — Task 6 logs it); `encodeImage(_ data: Data) -> [MsgPackValue.IntPair]`; `encodeFile(name: String, data: Data) -> [MsgPackValue.IntPair]`; `decode(_ fields:) -> Decoded?`; helpers `normalizedImageFormat(_:)`, `sanitizedFileName(_:)`, `fileExtension(_:)`.
- Semantics (spec §2): image wins over files; the first file entry wins (both count what they drop); a format not in `imageFormats` becomes a FILE named `image.<ext>`; malformed shapes → nil; an image with empty bytes → nil; names are sanitised (separators and NUL → `_`, leading dots stripped, at most 255 UTF-8 bytes, `"file"` when empty).

- [ ] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/AttachmentWireTests.swift`:

```swift
import Testing
import Foundation
import ReTiCA
@testable import ReTiCaMsgrCore

private let imageBytes = Data([0x01, 0x02])
private let fileBytes = Data("hi".utf8)

private func imageField(_ format: MsgPackValue, _ data: MsgPackValue = .bin(imageBytes)) -> [MsgPackValue.IntPair] {
    [.init(0x06, .array([format, data]))]
}

private func fileField(_ entries: [MsgPackValue]) -> [MsgPackValue.IntPair] {
    [.init(0x05, .array(entries))]
}

@Test func attachWireConstantsMatchReferenceLXMF() {
    #expect(AttachmentWire.fieldFileAttachments == 0x05)
    #expect(AttachmentWire.fieldImage == 0x06)
    #expect(AttachmentWire.sentImageFormat == "jpeg")
    #expect(AttachmentWire.imageFormats == ["jpeg", "png", "webp", "heic"])
    #expect(AttachmentWire.maxNameBytes == 255)
}

/// umsgpack `packb({0x06: ["jpeg", b"\x01\x02"]})`: fixmap(1), 0x06, fixarray(2), fixstr "jpeg", bin8 2 bytes.
@Test func attachWireEncodeImageMatchesReferenceUmsgpackBytes() throws {
    let expected = try #require(Data(hexString: "810692a46a706567c4020102"))
    #expect(MsgPack.encode(.intMap(AttachmentWire.encodeImage(imageBytes))) == expected)
}

/// umsgpack `packb({0x05: [["a.txt", b"hi"]]})`: fixmap(1), 0x05, fixarray(1), fixarray(2), fixstr "a.txt", bin8 "hi".
@Test func attachWireEncodeFileMatchesReferenceUmsgpackBytes() throws {
    let expected = try #require(Data(hexString: "810591 92a5612e747874c4026869".replacingOccurrences(of: " ", with: "")))
    #expect(MsgPack.encode(.intMap(AttachmentWire.encodeFile(name: "a.txt", data: fileBytes))) == expected)
}

@Test func attachWireRoundTripsThroughRealLXMessage() throws {
    let replyTo = Data((0..<32).map { UInt8($0) })
    let m = LXMessage.create(
        source: Identity(),
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data(),
        content: Data("caption".utf8),
        fields: AttachmentWire.encodeImage(imageBytes) + ReplyWire.encode(replyTo: replyTo, quote: "q")
    )
    let back = try #require(LXMessage.unpack(m.packed))
    #expect(back.fields.map(\.key) == [0x06, 0x30, 0x31])
    let decoded = try #require(AttachmentWire.decode(back.fields))
    #expect(decoded == AttachmentWire.Decoded(kind: "image", name: "image.jpeg", format: "jpeg", data: imageBytes))
    #expect(ReplyWire.decode(back.fields)?.replyTo == replyTo)

    let file = LXMessage.create(
        source: Identity(), destinationHash: Data(repeating: 0x11, count: 16), timestamp: 1700000001,
        title: Data(), content: Data(), fields: AttachmentWire.encodeFile(name: "notes.pdf", data: fileBytes))
    let fileBack = try #require(LXMessage.unpack(file.packed))
    #expect(AttachmentWire.decode(fileBack.fields)
            == AttachmentWire.Decoded(kind: "file", name: "notes.pdf", format: "pdf", data: fileBytes))
}

/// Review Focus 1: Sideband writes the format as the file extension it had (`jpg`, `webp`, `png`),
/// other clients may upper-case it, add a dot, say `heif`, or send it as bin.
@Test func attachWireDecodesSidebandFormatVariants() {
    let cases: [(MsgPackValue, String)] = [
        (.string("jpg"), "jpeg"), (.string("JPEG"), "jpeg"), (.string("webp"), "webp"),
        (.string(".png"), "png"), (.string("heif"), "heic"), (.string(" HEIC "), "heic"),
        (.bin(Data("webp".utf8)), "webp"),
    ]
    for (format, expected) in cases {
        let decoded = AttachmentWire.decode(imageField(format))
        #expect(decoded?.kind == "image", "\(format)")
        #expect(decoded?.format == expected, "\(format)")
        #expect(decoded?.name == "image.\(expected)", "\(format)")
        #expect(decoded?.data == imageBytes, "\(format)")
    }
}

/// A bin name for a file entry is accepted too (strict UTF-8); invalid UTF-8 is malformed.
@Test func attachWireAcceptsBinNamesAndRejectsInvalidUTF8() {
    let asBin = AttachmentWire.decode(fileField([.array([.bin(Data("r.txt".utf8)), .bin(fileBytes)])]))
    #expect(asBin == AttachmentWire.Decoded(kind: "file", name: "r.txt", format: "txt", data: fileBytes))
    #expect(AttachmentWire.decode(fileField([.array([.bin(Data([0xFF, 0xFE])), .bin(fileBytes)])])) == nil)
    #expect(AttachmentWire.decode(imageField(.bin(Data([0xFF, 0xFE])))) == nil)
}

/// Review Focus 1: an image we cannot name is kept as a file, never dropped.
@Test func attachWireUnknownImageFormatBecomesAFile() {
    let tiff = AttachmentWire.decode(imageField(.string("tiff")))
    #expect(tiff == AttachmentWire.Decoded(kind: "file", name: "image.tiff", format: "tiff", data: imageBytes))
    let hostile = AttachmentWire.decode(imageField(.string("../x")))
    #expect(hostile == AttachmentWire.Decoded(kind: "file", name: "image", format: "", data: imageBytes))
}

@Test func attachWireImageWinsOverFiles() {
    let fields = fileField([.array([.string("a.txt"), .bin(fileBytes)])]) + imageField(.string("png"))
    #expect(AttachmentWire.decode(fields)?.kind == "image")
    #expect(AttachmentWire.decode(fields)?.format == "png")
    // The file beside it is dropped, and counted so the receiver can log it.
    #expect(AttachmentWire.decode(fields)?.droppedFileCount == 1)
    #expect(AttachmentWire.decode(imageField(.string("png")))?.droppedFileCount == 0)
}

@Test func attachWireFirstFileEntryWins() {
    let fields = fileField([
        .array([.string("first.txt"), .bin(Data("1".utf8))]),
        .array([.string("second.txt"), .bin(Data("2".utf8))]),
    ])
    #expect(AttachmentWire.decode(fields)?.name == "first.txt")
    #expect(AttachmentWire.decode(fields)?.data == Data("1".utf8))
    #expect(AttachmentWire.decode(fields)?.droppedFileCount == 1)
}

/// Review Focus 2: a peer's file name never becomes a path and never breaks the row.
@Test func attachWireSanitisesFileNames() {
    #expect(AttachmentWire.sanitizedFileName("../../etc/passwd") == "_.._etc_passwd")
    #expect(AttachmentWire.sanitizedFileName("C:\\Users\\me\\a.doc") == "C__Users_me_a.doc")
    #expect(AttachmentWire.sanitizedFileName(".hidden") == "hidden")
    #expect(AttachmentWire.sanitizedFileName("   ") == "file")
    #expect(AttachmentWire.sanitizedFileName("") == "file")
    #expect(AttachmentWire.sanitizedFileName("nul\u{0}byte.txt") == "nul_byte.txt")
    let long = String(repeating: "a", count: 300) + ".pdf"
    let cut = AttachmentWire.sanitizedFileName(long)
    #expect(cut.utf8.count == 255)
    #expect(cut == String(repeating: "a", count: 255))
    // The extension comes from the SANITISED name: the cut one has none.
    #expect(AttachmentWire.fileExtension(cut) == "")
    #expect(AttachmentWire.fileExtension("notes.PDF") == "pdf")
    #expect(AttachmentWire.fileExtension("archive.tar.gz") == "gz")
    #expect(AttachmentWire.fileExtension("noext") == "")
    #expect(AttachmentWire.fileExtension(".bashrc") == "")
    // A wide-character name is cut on a Character boundary, under 255 bytes.
    let families = String(repeating: "👨‍👩‍👧‍👦", count: 12)   // 12 × 25 = 300 bytes
    let cutWide = AttachmentWire.sanitizedFileName(families)
    #expect(cutWide.utf8.count <= 255)
    #expect(cutWide == String(repeating: "👨‍👩‍👧‍👦", count: 10))
    // Decoding applies it.
    let decoded = AttachmentWire.decode(fileField([.array([.string("../evil.sh"), .bin(fileBytes)])]))
    #expect(decoded?.name == "_evil.sh")
    #expect(decoded?.format == "sh")
}

/// Review Focus 3 (codec half): every malformed shape is nil, so the message is stored as text.
@Test func attachWireMalformedShapesAreNil() {
    let cases: [(String, [MsgPackValue.IntPair])] = [
        ("no fields", []),
        ("0x06 not an array", [.init(0x06, .bin(imageBytes))]),
        ("0x06 one element", [.init(0x06, .array([.string("jpeg")]))]),
        ("0x06 three elements", [.init(0x06, .array([.string("jpeg"), .bin(imageBytes), .uint(1)]))]),
        ("0x06 data not bin", imageField(.string("jpeg"), .string("nope"))),
        ("0x06 format not text", imageField(.uint(6))),
        ("0x06 empty bytes", imageField(.string("jpeg"), .bin(Data()))),
        ("0x05 not an array", [.init(0x05, .bin(fileBytes))]),
        ("0x05 empty list", fileField([])),
        ("0x05 entry not a pair", fileField([.string("a.txt")])),
        ("0x05 pair of one", fileField([.array([.string("a.txt")])])),
        ("0x05 data not bin", fileField([.array([.string("a.txt"), .string("x")])])),
        ("0x05 name not text", fileField([.array([.uint(1), .bin(fileBytes)])])),
    ]
    for (name, fields) in cases {
        #expect(AttachmentWire.decode(fields) == nil, "\(name)")
    }
    // An empty FILE is allowed (a zero-byte document is a document).
    let empty = AttachmentWire.decode(fileField([.array([.string("empty.txt"), .bin(Data())])]))
    #expect(empty?.name == "empty.txt")
    #expect(empty?.data.isEmpty == true)
    // A malformed 0x06 beside a good 0x05 falls through to the file.
    let mixed = [MsgPackValue.IntPair(0x06, .bin(imageBytes))] + fileField([.array([.string("ok.txt"), .bin(fileBytes)])])
    #expect(AttachmentWire.decode(mixed)?.name == "ok.txt")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachWire`
Expected: compile errors (`AttachmentWire` unknown).

- [ ] **Step 3: `AttachmentWire.swift`**

Create `CORE/Sources/ReTiCaMsgrCore/AttachmentWire.swift`:

```swift
import Foundation
import ReTiCA

/// Wire codec for one attachment carried in LXMF `fields`, in the standard format
/// (`LXMF/LXMF.py:12-13`, as Sideband writes it): `FIELD_IMAGE` (0x06) is `[format, bytes]` and
/// `FIELD_FILE_ATTACHMENTS` (0x05) is `[[name, bytes], ...]`.
///
/// Sent: one field, `0x06 = ["jpeg", <jpeg>]` or `0x05 = [[name, <bytes>]]`. Received: lenient.
/// The image wins when both are present, the first file entry wins, an image format we cannot
/// decode is kept as a file, and a malformed field is `nil` — `AppFeature` then stores the
/// message as plain text (a message is never lost over a bad field).
public enum AttachmentWire {
    public static let fieldFileAttachments = 0x05
    public static let fieldImage = 0x06
    /// The format string we send. Sideband/Kivy accept "jpeg" and "jpg" alike.
    public static let sentImageFormat = "jpeg"
    /// Formats ImageIO decodes on iOS and that render inline. Anything else is a file row.
    public static let imageFormats: Set<String> = ["jpeg", "png", "webp", "heic"]
    public static let maxNameBytes = 255
    public static let fallbackFileName = "file"

    public struct Decoded: Equatable, Sendable {
        public var kind: String      // AttachmentKind.*
        public var name: String
        public var format: String
        public var data: Data
        /// 0x05 entries left out: those after the first, or all of them when an image won.
        /// `AppFeature` logs it (spec §2: one attachment per message is kept, the rest noted).
        public var droppedFileCount: Int

        public init(kind: String, name: String, format: String, data: Data, droppedFileCount: Int = 0) {
            self.kind = kind
            self.name = name
            self.format = format
            self.data = data
            self.droppedFileCount = droppedFileCount
        }
    }

    public static func encodeImage(_ data: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldImage, .array([.string(sentImageFormat), .bin(data)]))]
    }

    public static func encodeFile(name: String, data: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldFileAttachments, .array([.array([.string(name), .bin(data)])]))]
    }

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded? {
        let fileValue = fields.first(where: { $0.key == fieldFileAttachments })?.value
        if let value = fields.first(where: { $0.key == fieldImage })?.value,
           var image = decodeImage(value) {
            // The image wins: every file entry beside it is dropped.
            image.droppedFileCount = fileEntryCount(fileValue)
            return image
        }
        if let fileValue, let file = decodeFile(fileValue) {
            return file
        }
        return nil
    }

    /// How many entries a 0x05 value lists (0 when absent or not a list).
    static func fileEntryCount(_ value: MsgPackValue?) -> Int {
        guard case let .array(entries)? = value else { return 0 }
        return entries.count
    }

    /// `[format, bin]`. An unknown format is a file named `image.<ext>` (ext sanitised).
    static func decodeImage(_ value: MsgPackValue) -> Decoded? {
        guard case let .array(parts) = value, parts.count == 2,
              let raw = text(parts[0]),
              case let .bin(data) = parts[1], !data.isEmpty
        else { return nil }
        let format = normalizedImageFormat(raw)
        if imageFormats.contains(format) {
            return Decoded(kind: AttachmentKind.image, name: "image.\(format)", format: format, data: data)
        }
        let ext = AttachmentStore.sanitizedExtension(raw)
        return Decoded(kind: AttachmentKind.file, name: ext.isEmpty ? "image" : "image.\(ext)", format: ext, data: data)
    }

    /// `[[name, bin], ...]` — the first entry only (known limit, spec §2).
    static func decodeFile(_ value: MsgPackValue) -> Decoded? {
        guard case let .array(entries) = value,
              case let .array(pair)? = entries.first, pair.count == 2,
              let rawName = text(pair[0]),
              case let .bin(data) = pair[1]
        else { return nil }
        let name = sanitizedFileName(rawName)
        return Decoded(kind: AttachmentKind.file, name: name, format: fileExtension(name), data: data,
                       droppedFileCount: entries.count - 1)
    }

    /// A `str`, or a `bin` that is strictly valid UTF-8 (`String(decoding:)` repairs invalid bytes,
    /// so the bytes are valid exactly when they survive a round trip unchanged).
    static func text(_ value: MsgPackValue) -> String? {
        switch value {
        case let .string(s):
            return s
        case let .bin(b):
            let s = String(decoding: b, as: UTF8.self)
            return Data(s.utf8) == b ? s : nil
        default:
            return nil
        }
    }

    /// Trimmed, lowercased, no leading dot; `jpg` → `jpeg`, `heif` → `heic`.
    public static func normalizedImageFormat(_ raw: String) -> String {
        var f = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if f.hasPrefix(".") { f.removeFirst() }
        switch f {
        case "jpg", "jpeg": return "jpeg"
        case "heif", "heic": return "heic"
        default: return f
        }
    }

    /// Review Focus 2: separators, colons and NUL become `_`, leading dots are stripped (no hidden
    /// or `..` names), the result is cut to `maxNameBytes` on a Character boundary, and an empty
    /// result is `fallbackFileName`. The store never uses this name in a path anyway.
    public static func sanitizedFileName(_ raw: String) -> String {
        var name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).map { ch -> Character in
            (ch == "/" || ch == "\\" || ch == ":" || ch == "\u{0}" || ch.isNewline) ? "_" : ch
        })
        while name.hasPrefix(".") { name.removeFirst() }
        if name.utf8.count > maxNameBytes {
            var kept = Substring(name)
            while !kept.isEmpty, kept.utf8.count > maxNameBytes { kept = kept.dropLast() }
            name = String(kept)
        }
        return name.isEmpty ? fallbackFileName : name
    }

    /// The sanitised extension after the last dot, `""` when there is none or the dot leads.
    public static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return AttachmentStore.sanitizedExtension(String(name[name.index(after: dot)...]))
    }
}
```

- [ ] **Step 4: Run the new tests**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachWire`
Expected: 11 tests PASS. If `attachWireEncodeFileMatchesReferenceUmsgpackBytes` fails, compare against the reference: write `/tmp/ReTiCaMsgr/attach_fields_reference.py` containing `import umsgpack; print(umsgpack.packb({0x05: [["a.txt", b"hi"]]}).hex()); print(umsgpack.packb({0x06: ["jpeg", b"\x01\x02"]}).hex())` and run it with `/Users/ell/opt/anaconda3/envs/rns/bin/python /tmp/ReTiCaMsgr/attach_fields_reference.py`; fix the TEST's hex if the reference differs, never the encoder (ReTiCA's `MsgPack.encode` follows umsgpack).

- [ ] **Step 5: Mutation batch**

Sub-batch A (apply together):
1. `decode`: move the `if let fileValue, let file = decodeFile(fileValue) { return file }` block above the image block → RED `attachWireImageWinsOverFiles`.
2. `normalizedImageFormat`: delete the `case "jpg", "jpeg": return "jpeg"` line → RED `attachWireDecodesSidebandFormatVariants` (`jpg` becomes a file).
3. `decodeImage`: drop `!data.isEmpty` → RED `attachWireMalformedShapesAreNil`.
4. `sanitizedFileName`: delete the `while name.hasPrefix(".")` loop → RED `attachWireSanitisesFileNames`.
5. `encodeImage`: `.string(sentImageFormat)` → `.bin(Data(sentImageFormat.utf8))` → RED `attachWireEncodeImageMatchesReferenceUmsgpackBytes`.
6. `decodeFile`: `entries.first` → `entries.last` → RED `attachWireFirstFileEntryWins`.
9. `encodeFile`: wrap the pair in one more array — `.array([.array([.array([.string(name), .bin(data)])])])` → RED `attachWireEncodeFileMatchesReferenceUmsgpackBytes` (bytes differ), `attachWireRoundTripsThroughRealLXMessage` (the file half decodes to nil: its first entry is a one-element list).
11. `decodeImage`: the unknown-format branch `return Decoded(kind: AttachmentKind.file, ...)` → `return nil` → RED `attachWireUnknownImageFormatBecomesAFile` (Review Focus 1).

Sub-batch B (apply together, after A is reverted and green):
7. `text`: make the `.bin` branch `return nil` → RED `attachWireAcceptsBinNamesAndRejectsInvalidUTF8` (the bin name is rejected) and `attachWireDecodesSidebandFormatVariants` (the bin format).
13. `decode`: delete `image.droppedFileCount = fileEntryCount(fileValue)` → RED `attachWireImageWinsOverFiles` (count 0). Not in A: mutation 1 reddens the same test.

Sub-batch C (alone, after B is reverted and green):
8. `fieldImage = 0x06` → `0x07` → RED `attachWireConstantsMatchReferenceLXMF` (and, as a side effect, most image tests — which is why it runs alone).

Sub-batch D (apply together, after C is reverted and green):
10. `decodeFile`: `format: fileExtension(name)` → `format: ""` → RED `attachWireRoundTripsThroughRealLXMessage` (file format "pdf"), `attachWireAcceptsBinNamesAndRejectsInvalidUTF8` ("txt"), `attachWireSanitisesFileNames` ("sh"). Not in A or B: 9, 4 and 7 redden those tests.
12. `decodeFile`: `droppedFileCount: entries.count - 1` → `droppedFileCount: 0` → RED `attachWireFirstFileEntryWins`. Not in A: mutation 6 reddens the same test.

Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 6: Full suite, commit**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/att-t3-full.log 2>&1`
Expected: all pass; count = Task 2 count + 11.

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AttachmentWire.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AttachmentWireTests.swift`

Write `/tmp/ReTiCaMsgr/msg-att-task-3.txt`:

```
feat: LXMF image and file attachment fields codec

Encodes one image as FIELD_IMAGE 0x06 ["jpeg", bytes] or one file as
FIELD_FILE_ATTACHMENTS 0x05 [[name, bytes]] the way Sideband writes
them, and decodes both leniently: format variants, bin or str names,
unknown formats kept as files, hostile names sanitised, malformed
fields ignored so the message is still stored as text.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments commit -F /tmp/ReTiCaMsgr/msg-att-task-3.txt`

---

### Task 4: `ImageEncoder` — JPEG out, orientation baked, metadata stripped

**Files:**
- Create: `CORE/Sources/ReTiCaMsgrCore/ImageEncoder.swift`
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/TestImages.swift` (test helper, shared with Tasks 6–7)
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/ImageEncoderTests.swift`

**Interfaces:**
- Produces: `public enum ImageEncoder` with `Preset { standard, original }`, `standardMaxPixels = 1280`, `standardQuality = 0.75`, `originalQuality = 0.92`, `struct Encoded { data, width, height }`, `enum Failure: Error { undecodable, encodingFailed }`, `encodeJPEG(_ source: Data, preset:) throws -> Encoded`, `dimensions(of: Data) -> (width: Int, height: Int)?` (oriented, no pixel decode), `isDecodable(_:)`, `containerType(of:) -> String?` (UTType identifier), `hasLocationOrOrientationMetadata(_:) -> Bool`.
- Test helper `TestImages` (test target): `png(width:height:) -> Data` (left half red, right half blue, each a vertical gradient from bright at the top to half brightness at the bottom, so JPEG size depends on quality), `jpeg(width:height:orientation:withGPS:) -> Data`, `pixel(in data: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)?`.
- Runs on macOS under `swift test` (ImageIO/CoreGraphics are available; no UIKit).

- [ ] **Step 1: Test helper**

Create `CORE/Tests/ReTiCaMsgrCoreTests/TestImages.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Images drawn in-test, so no fixture files: the left half is red, the right half blue, which
/// makes an orientation change visible in the pixels. Each half is a vertical gradient (bright at
/// the top, half brightness at the bottom), so a JPEG's size depends on its quality — a flat image
/// is almost all DC and encodes to nearly the same size at 0.75 and 0.92. Pixel checks read the
/// bright top rows of the SOURCE image.
enum TestImages {
    static func cgImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CG's origin is the bottom-left, so y = height is the TOP of the image.
        let top = CGPoint(x: 0, y: CGFloat(height))
        let bottom = CGPoint(x: 0, y: 0)
        let halves: [(CGRect, [CGFloat])] = [
            // RGBA bright, then RGBA half brightness.
            (CGRect(x: 0, y: 0, width: width / 2, height: height), [1, 0, 0, 1, 0.5, 0, 0, 1]),
            (CGRect(x: width / 2, y: 0, width: width - width / 2, height: height), [0, 0, 1, 1, 0, 0, 0.5, 1]),
        ]
        for (rect, components) in halves {
            let gradient = CGGradient(colorSpace: space, colorComponents: components, locations: [0, 1], count: 2)!
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(gradient, start: top, end: bottom, options: [])
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    static func png(width: Int, height: Int) -> Data {
        encode(cgImage(width: width, height: height), type: UTType.png, properties: [:])
    }

    /// `orientation` is the EXIF/TIFF value (1 = up, 6 = rotate 90° CW to display).
    static func jpeg(width: Int, height: Int, orientation: UInt32? = nil, withGPS: Bool = false) -> Data {
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if withGPS {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any]
        }
        return encode(cgImage(width: width, height: height), type: UTType.jpeg, properties: properties)
    }

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// The colour at (x, y) of the DISPLAYED image (orientation applied by ImageIO's transform).
    static func pixel(in data: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 100_000,
              ] as CFDictionary)
        else { return nil }
        let w = image.width, h = image.height
        guard x < w, y < h else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // A bitmap context's MEMORY row 0 is the TOP of the drawn image (CG's y axis points up,
        // but the backing buffer is stored top row first), so y indexes the buffer directly.
        let i = (y * w + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2])
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/ImageEncoderTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCaMsgrCore

private func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8)?) -> Bool { (p?.r ?? 0) > 200 && (p?.b ?? 255) < 60 }
private func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8)?) -> Bool { (p?.b ?? 0) > 200 && (p?.r ?? 255) < 60 }

@Test func imageEncoderConstantsMatchSpec() {
    #expect(ImageEncoder.standardMaxPixels == 1280)
    #expect(ImageEncoder.standardQuality == 0.75)
    #expect(ImageEncoder.originalQuality == 0.92)
}

@Test func imageEncoderStandardDownscalesTo1280LongEdge() throws {
    let out = try ImageEncoder.encodeJPEG(TestImages.png(width: 3000, height: 2000), preset: .standard)
    #expect(out.width == 1280)
    #expect(out.height == 853)
    #expect(ImageEncoder.containerType(of: out.data) == "public.jpeg")
    let d = try #require(ImageEncoder.dimensions(of: out.data))
    #expect(d.width == 1280)
    #expect(d.height == 853)
    // Portrait sources scale on the long edge too.
    let tall = try ImageEncoder.encodeJPEG(TestImages.png(width: 1000, height: 4000), preset: .standard)
    #expect(tall.width == 320)
    #expect(tall.height == 1280)
}

@Test func imageEncoderNeverUpscales() throws {
    let small = try ImageEncoder.encodeJPEG(TestImages.png(width: 100, height: 80), preset: .standard)
    #expect(small.width == 100)
    #expect(small.height == 80)
    let exact = try ImageEncoder.encodeJPEG(TestImages.png(width: 1280, height: 720), preset: .standard)
    #expect(exact.width == 1280)
    #expect(exact.height == 720)
}

@Test func imageEncoderOriginalKeepsDimensions() throws {
    let out = try ImageEncoder.encodeJPEG(TestImages.png(width: 3000, height: 2000), preset: .original)
    #expect(out.width == 3000)
    #expect(out.height == 2000)
    #expect(ImageEncoder.containerType(of: out.data) == "public.jpeg")
    // Original is the higher quality: same image, more bytes than the standard preset at the
    // same size would give — compare against a standard encode forced to full size by a source
    // that is already ≤ 1280 on its long edge. The gradients in `TestImages` give the quantiser
    // something to drop, so the two sizes differ by more than header noise.
    let source = TestImages.png(width: 1200, height: 800)
    let standard = try ImageEncoder.encodeJPEG(source, preset: .standard)
    let original = try ImageEncoder.encodeJPEG(source, preset: .original)
    #expect(original.width == standard.width && original.height == standard.height)
    #expect(original.data.count > standard.data.count)
}

/// Review Focus 8: a phone photo stored landscape with orientation 6 displays as portrait. The
/// sent JPEG must have those pixels rotated, because Sideband ignores orientation tags.
@Test func imageEncoderBakesOrientationIntoPixels() throws {
    // Stored 3000×2000, left half red, bright at the stored top. Orientation 6 = rotate 90° CW to
    // display: 2000×3000 with the RED half on TOP and the stored top rows (bright) on the RIGHT.
    let source = TestImages.jpeg(width: 3000, height: 2000, orientation: 6)
    // Self-check of the helper, independent of the encoder: `pixel` applies the orientation, so
    // the source itself reads red on top and blue below. If this fails, `TestImages.pixel`'s row
    // arithmetic is wrong — not `ImageEncoder`.
    #expect(isRed(TestImages.pixel(in: source, x: 1900, y: 300)))
    #expect(isBlue(TestImages.pixel(in: source, x: 1900, y: 2700)))
    let out = try ImageEncoder.encodeJPEG(source, preset: .standard)
    #expect(out.width == 853)
    #expect(out.height == 1280)
    // The output carries no orientation tag (or 1), and the raw pixels are already rotated, so
    // they read red on top with no transform to apply.
    #expect(!ImageEncoder.hasLocationOrOrientationMetadata(out.data))
    #expect(isRed(TestImages.pixel(in: out.data, x: 800, y: 300)))
    #expect(isBlue(TestImages.pixel(in: out.data, x: 800, y: 980)))
    // Sanity: an untagged source keeps left = red (read in the bright top rows).
    let plain = try ImageEncoder.encodeJPEG(TestImages.png(width: 400, height: 200), preset: .standard)
    #expect(isRed(TestImages.pixel(in: plain.data, x: 100, y: 20)))
    #expect(isBlue(TestImages.pixel(in: plain.data, x: 300, y: 20)))
}

/// Review Focus 8: GPS never leaves the phone, in either preset.
@Test func imageEncoderStripsMetadata() throws {
    let source = TestImages.jpeg(width: 800, height: 600, orientation: 3, withGPS: true)
    #expect(ImageEncoder.hasLocationOrOrientationMetadata(source))
    let standard = try ImageEncoder.encodeJPEG(source, preset: .standard)
    let original = try ImageEncoder.encodeJPEG(source, preset: .original)
    #expect(!ImageEncoder.hasLocationOrOrientationMetadata(standard.data))
    #expect(!ImageEncoder.hasLocationOrOrientationMetadata(original.data))
}

@Test func imageEncoderPNGBecomesJPEG() throws {
    let source = TestImages.png(width: 640, height: 480)
    #expect(ImageEncoder.containerType(of: source) == "public.png")
    let out = try ImageEncoder.encodeJPEG(source, preset: .original)
    #expect(ImageEncoder.containerType(of: out.data) == "public.jpeg")
    #expect(out.width == 640 && out.height == 480)
}

@Test func imageEncoderRejectsUndecodableData() {
    let junk = Data("not an image at all".utf8)
    #expect(ImageEncoder.dimensions(of: junk) == nil)
    #expect(!ImageEncoder.isDecodable(junk))
    #expect(ImageEncoder.containerType(of: junk) == nil)
    #expect(throws: ImageEncoder.Failure.undecodable) {
        try ImageEncoder.encodeJPEG(junk, preset: .standard)
    }
    #expect(throws: ImageEncoder.Failure.undecodable) {
        try ImageEncoder.encodeJPEG(Data(), preset: .original)
    }
}

/// `dimensions(of:)` reports the DISPLAYED size: orientation 5–8 swap width and height.
@Test func imageEncoderDimensionsHonourOrientation() throws {
    let up = try #require(ImageEncoder.dimensions(of: TestImages.jpeg(width: 3000, height: 2000)))
    #expect(up.width == 3000)
    #expect(up.height == 2000)
    let rotated = try #require(ImageEncoder.dimensions(of: TestImages.jpeg(width: 3000, height: 2000, orientation: 6)))
    #expect(rotated.width == 2000)
    #expect(rotated.height == 3000)
    let upsideDown = try #require(ImageEncoder.dimensions(of: TestImages.jpeg(width: 3000, height: 2000, orientation: 3)))
    #expect(upsideDown.width == 3000)
    #expect(upsideDown.height == 2000)
    let png = try #require(ImageEncoder.dimensions(of: TestImages.png(width: 10, height: 20)))
    #expect(png.width == 10)
    #expect(png.height == 20)
    #expect(ImageEncoder.isDecodable(TestImages.png(width: 10, height: 20)))
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter imageEncoder`
Expected: compile errors (`ImageEncoder` unknown).

- [ ] **Step 4: `ImageEncoder.swift`**

Create `CORE/Sources/ReTiCaMsgrCore/ImageEncoder.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns picked image bytes into the JPEG we send (spec 2026-09-28 §2). ImageIO only — no UIKit —
/// so it lives in the core package and `swift test` covers it on macOS.
///
/// Both presets bake the EXIF orientation into the pixels (Sideband ignores orientation tags) and
/// write NO metadata (no GPS leaves the phone). `standard` scales the long edge to at most
/// `standardMaxPixels`, never upscaling; `original` keeps the source size.
public enum ImageEncoder {
    public enum Preset: Equatable, Sendable {
        case standard
        case original
    }

    public static let standardMaxPixels = 1280
    public static let standardQuality = 0.75
    public static let originalQuality = 0.92

    public struct Encoded: Equatable, Sendable {
        public var data: Data
        public var width: Int
        public var height: Int

        public init(data: Data, width: Int, height: Int) {
            self.data = data
            self.width = width
            self.height = height
        }
    }

    public enum Failure: Error, Equatable {
        /// ImageIO could not read the bytes as an image.
        case undecodable
        case encodingFailed
    }

    public static func encodeJPEG(_ source: Data, preset: Preset) throws -> Encoded {
        guard let src = CGImageSourceCreateWithData(source as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let dims = dimensions(of: source)
        else { throw Failure.undecodable }
        let longEdge = max(dims.width, dims.height)
        let maxPixels: Int
        switch preset {
        case .standard: maxPixels = min(standardMaxPixels, longEdge)
        case .original: maxPixels = longEdge
        }
        // "Thumbnail" here is ImageIO's scaled, orientation-applied decode of the full image; with
        // a max size equal to the long edge it is the full image, oriented.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw Failure.undecodable
        }
        let quality = preset == .standard ? standardQuality : originalQuality
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        // Only the quality: no properties dictionary is copied from the source, so EXIF/GPS/TIFF
        // are gone and the orientation is 1 (the pixels are already transformed).
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encodingFailed }
        return Encoded(data: out as Data, width: image.width, height: image.height)
    }

    /// The displayed pixel size from the container's properties (no pixel decode): orientation
    /// values 5–8 swap width and height. nil when the bytes are not an image.
    public static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    public static func isDecodable(_ data: Data) -> Bool {
        dimensions(of: data) != nil
    }

    /// The container's UTType identifier, e.g. `public.jpeg`, `public.png`, `org.webmproject.webp`.
    public static func containerType(of data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src)
        else { return nil }
        return type as String
    }

    /// True when the container carries a GPS dictionary or an orientation other than 1.
    public static func hasLocationOrOrientationMetadata(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return false }
        if props[kCGImagePropertyGPSDictionary] != nil { return true }
        if let orientation = props[kCGImagePropertyOrientation] as? UInt32, orientation != 1 { return true }
        return false
    }
}
```

- [ ] **Step 5: Run the new tests**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter imageEncoder`
Expected: 9 tests PASS. If ImageIO rounds 2000/3000×1280 to 854 rather than 853 on this macOS, change the `853` expectations (downscale and orientation tests) to the observed value and note it in the report (the rounding is ImageIO's, not ours). If `imageEncoderBakesOrientationIntoPixels` fails on its first two expectations (the SOURCE self-check), the helper is wrong, not the encoder: `TestImages.pixel` indexes `(y * w + x) * 4` because a bitmap context's memory row 0 is the top of the image — check that first. If `imageEncoderOriginalKeepsDimensions`'s byte comparison fails, report the two sizes; do not weaken the check.

- [ ] **Step 6: Mutation batch (six sub-batches — run each alone, revert and re-green between them)**

Sub-batch A (alone):
1. `standardMaxPixels = 1280` → `640` → RED `imageEncoderConstantsMatchSpec`, `imageEncoderStandardDownscalesTo1280LongEdge`, `imageEncoderNeverUpscales` (1280 exact becomes 640), `imageEncoderBakesOrientationIntoPixels` (640 tall), `imageEncoderOriginalKeepsDimensions` (the standard encode of the 1200×800 source shrinks). Alone because it reddens the tests mutations 2 and 3 target.

Sub-batch B (alone):
2. `kCGImageSourceCreateThumbnailWithTransform: true` → `false` in `encodeJPEG` → RED `imageEncoderBakesOrientationIntoPixels` (1280×853, red on the left). The test's source self-check stays green (the helper applies its own transform).

Sub-batch C (alone):
3. `.original: maxPixels = longEdge` → `= standardMaxPixels` → RED `imageEncoderOriginalKeepsDimensions` (3000 becomes 1280).

Sub-batch D (apply together):
4. `dimensions`: `orientation >= 5 ? (h, w) : (w, h)` → `(w, h)` → RED `imageEncoderDimensionsHonourOrientation`.
6. `encodeJPEG`: change the FIRST `throw Failure.undecodable` (the guard on the source and its dimensions) to `throw Failure.encodingFailed` → RED `imageEncoderRejectsUndecodableData` (junk now throws `encodingFailed`). Neither mutation touches the other's test.

Sub-batch E (alone):
5. `UTType.jpeg` → `UTType.png` in `encodeJPEG`'s `CGImageDestinationCreateWithData` → RED `imageEncoderPNGBecomesJPEG`, `imageEncoderStandardDownscalesTo1280LongEdge`, `imageEncoderOriginalKeepsDimensions` (their container checks). Alone because it reddens the test mutation 3 targets.

Sub-batch F (alone):
7. `CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0]] as CFDictionary)` → RED `imageEncoderStripsMetadata`, `imageEncoderBakesOrientationIntoPixels` (its no-metadata check).

Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 7: Full suite, commit**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/att-t4-full.log 2>&1`
Expected: all pass; count = Task 3 count + 9.

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/ImageEncoder.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/TestImages.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/ImageEncoderTests.swift`

Write `/tmp/ReTiCaMsgr/msg-att-task-4.txt`:

```
feat: ImageEncoder scales photos to JPEG with orientation baked in

ImageIO only, so the core package tests it on macOS: the standard
preset scales the long edge to 1280 px at quality 0.75 and never
upscales, the original preset keeps the size at 0.92, both apply the
EXIF orientation to the pixels and write no metadata.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments commit -F /tmp/ReTiCaMsgr/msg-att-task-4.txt`

---
### Task 5: Info sheet section, placeholders, conversation preview

**Files:**
- Create: `CORE/Sources/ReTiCaMsgrCore/AttachmentPlaceholder.swift`
- Modify: `CORE/Sources/ReTiCaMsgrCore/MessageInfo.swift` (`sections(for:attachment:timeZone:)`, timeline reason row, delivery refusal row, new `attachment` section, name helpers)
- Modify: `CORE/Sources/ReTiCaMsgrCore/Conversation.swift` (`list(from:attachments:)`)
- Modify: `CORE/Sources/ReTiCaMsgrCore/ReplyPreview.swift` (`resolve(for:in:peerName:attachments:)`)
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/AttachmentInfoTests.swift`

**Interfaces:**
- Produces: `public enum AttachmentPlaceholder { static let photo = "📷 Photo"; static func text(for: Attachment) -> String; static func preview(body: String, attachment: Attachment?) -> String }`. `MessageInfo.sections(for message: Message, attachment: Attachment? = nil, timeZone: TimeZone = .current)` — existing callers keep compiling. `Conversation.list(from messages: [Message], attachments: [UUID: Attachment] = [:])`. `ReplyPreview.resolve(for message: Message, in thread: [Message], peerName: String?, attachments: [UUID: Attachment] = [:])` — a reply to a caption-less photo or file IN the thread quotes its placeholder instead of "Original message not available" (spec §4); existing callers keep compiling, Task 9's `ChatView` passes `store.attachmentsByMessageId`.
- Semantics: an image's placeholder is `📷 Photo`, a file's is `📎 <name>`; `preview` returns the body when it has non-whitespace text, else the placeholder, else the body as is. Info: a "Reason" row after "Status" only when `failureReason` is set (`Rejected by recipient` / `Cancelled`); a "Propagation refusal" row in Delivery only when `propagationRefused` is set (`Refused: too large for node`); a fifth section "Attachment" only when an attachment is passed: Kind (`Image`/`File`), Name, Format (upper-cased, `—` when empty), Size (`<n> B`), Dimensions (`W × H`, `—` for files), Stored (`Yes`/`No` from `hasBytes`).

- [ ] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/AttachmentInfoTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCaMsgrCore

/// `Testing` exports its own `Attachment`; this file means the model.
private typealias Attachment = ReTiCaMsgrCore.Attachment

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1700000000)
private let hash64 = "a1b2" + String(repeating: "0", count: 56) + "c3d4"
private let peer32 = "0123456789abcdef0123456789abcdef"
private let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!

private func outgoing(status: String = MessageStatus.sending, body: String = "", failureReason: String? = nil,
                      propagationRefused: String? = nil) -> Message {
    Message(id: messageID, peerHex: peer32, isOutgoing: true, body: body, timestamp: t0, status: status,
            validated: false, messageHash: hash64, senderTimestamp: t0, sentViaPropagation: true,
            wireSize: 500, titleSize: 0, contentSize: body.utf8.count, fieldKeys: "0x06",
            failureReason: failureReason, propagationRefused: propagationRefused)
}

private func image(path: String = "\(hash64)-out.jpeg") -> Attachment {
    Attachment(id: UUID(), messageId: messageID, kind: AttachmentKind.image, name: "IMG_20231114_221320.jpg",
               format: "jpeg", size: 34_211, width: 1280, height: 853, path: path)
}

private func file(name: String = "notes.pdf", format: String = "pdf") -> Attachment {
    Attachment(id: UUID(), messageId: messageID, kind: AttachmentKind.file, name: name, format: format,
               size: 12_000, width: nil, height: nil, path: "\(hash64)-in.pdf")
}

@Test func attachInfoSectionAppearsForAnImage() {
    let sections = MessageInfo.sections(for: outgoing(), attachment: image(), timeZone: utc)
    #expect(sections.map(\.title) == ["Timeline", "Delivery", "Identity", "Payload", "Attachment"])
    #expect(sections[4] == MessageInfo.Section(title: "Attachment", rows: [
        MessageInfo.Row("Kind", "Image"),
        MessageInfo.Row("Name", "IMG_20231114_221320.jpg"),
        MessageInfo.Row("Format", "JPEG"),
        MessageInfo.Row("Size", "34211 B"),
        MessageInfo.Row("Dimensions", "1280 × 853"),
        MessageInfo.Row("Stored", "Yes"),
    ]))
}

@Test func attachInfoSectionForAFileHasNoDimensionsAndShowsUnavailableBytes() {
    var f = file()
    f.path = ""
    let sections = MessageInfo.sections(for: outgoing(), attachment: f, timeZone: utc)
    #expect(sections[4] == MessageInfo.Section(title: "Attachment", rows: [
        MessageInfo.Row("Kind", "File"),
        MessageInfo.Row("Name", "notes.pdf"),
        MessageInfo.Row("Format", "PDF"),
        MessageInfo.Row("Size", "12000 B"),
        MessageInfo.Row(label: "Dimensions", display: "—", copy: ""),
        MessageInfo.Row("Stored", "No"),
    ]))
    // A file without an extension shows "—" for the format.
    let bare = MessageInfo.sections(for: outgoing(), attachment: file(name: "README", format: ""), timeZone: utc)
    #expect(bare[4].rows[2] == MessageInfo.Row(label: "Format", display: "—", copy: ""))
}

@Test func attachInfoNoAttachmentNoSectionAndNoReasonRows() {
    let sections = MessageInfo.sections(for: outgoing(), timeZone: utc)
    #expect(sections.map(\.title) == ["Timeline", "Delivery", "Identity", "Payload"])
    #expect(sections[0].rows.last == MessageInfo.Row("Status", "sending"))
    #expect(sections[1].rows == [MessageInfo.Row("Propagation node copy", "Yes")])
}

@Test func attachInfoFailureReasonAndRefusalRows() {
    let cancelled = MessageInfo.sections(
        for: outgoing(status: MessageStatus.cancelled, failureReason: FailureReason.cancelled,
                      propagationRefused: PropagationRefusal.tooLargeForNode),
        timeZone: utc)
    #expect(Array(cancelled[0].rows.suffix(2)) == [MessageInfo.Row("Status", "cancelled"), MessageInfo.Row("Reason", "Cancelled")])
    #expect(cancelled[1].rows == [
        MessageInfo.Row("Propagation node copy", "Yes"),
        MessageInfo.Row("Propagation refusal", "Refused: too large for node"),
    ])
    let rejected = MessageInfo.sections(
        for: outgoing(status: MessageStatus.failed, failureReason: FailureReason.rejected), timeZone: utc)
    #expect(rejected[0].rows.last == MessageInfo.Row("Reason", "Rejected by recipient"))
    // An unknown stored reason is shown as-is rather than dropped.
    let odd = MessageInfo.sections(for: outgoing(status: MessageStatus.failed, failureReason: "weird"), timeZone: utc)
    #expect(odd[0].rows.last == MessageInfo.Row("Reason", "weird"))
}

@Test func attachInfoPlaceholderTextAndPreview() {
    #expect(AttachmentPlaceholder.text(for: image()) == "📷 Photo")
    #expect(AttachmentPlaceholder.text(for: file(name: "notes.pdf")) == "📎 notes.pdf")
    #expect(AttachmentPlaceholder.preview(body: "look at this", attachment: image()) == "look at this")
    #expect(AttachmentPlaceholder.preview(body: "", attachment: image()) == "📷 Photo")
    #expect(AttachmentPlaceholder.preview(body: " \n", attachment: file()) == "📎 notes.pdf")
    #expect(AttachmentPlaceholder.preview(body: "", attachment: nil) == "")
    #expect(AttachmentPlaceholder.preview(body: "text", attachment: nil) == "text")
}

@Test func attachInfoConversationPreviewUsesPlaceholder() {
    let withPhoto = outgoing(body: "")
    let older = Message(id: UUID(), peerHex: peer32, isOutgoing: false, body: "earlier", timestamp: t0.addingTimeInterval(-10),
                        status: MessageStatus.received, validated: true, messageHash: "")
    let list = Conversation.list(from: [older, withPhoto], attachments: [withPhoto.id: image()])
    #expect(list.map(\.lastBody) == ["📷 Photo"])
    // Without the attachment map the preview is the (empty) body, as before.
    #expect(Conversation.list(from: [older, withPhoto]).map(\.lastBody) == [""])
    // A file placeholder carries the name.
    let withFile = outgoing(body: "")
    #expect(Conversation.list(from: [withFile], attachments: [withFile.id: file(name: "map.gpx", format: "gpx")])
            .map(\.lastBody) == ["📎 map.gpx"])
}

/// Spec §4: a reply to a photo that is in the thread quotes `📷 Photo`, not "Original message not
/// available" (the photo's body is empty). A file quotes its name. Without the map, as before.
@Test func attachInfoReplyPreviewQuotesAPhotoInTheThread() {
    let photoMessage = Message(id: messageID, peerHex: peer32, isOutgoing: false, body: "", timestamp: t0,
                               status: MessageStatus.received, validated: true, messageHash: hash64)
    // No carried quote, so the text can only come from the original in the thread.
    let reply = Message(id: UUID(uuidString: "00000000-0000-0000-0000-000000000051")!, peerHex: peer32,
                        isOutgoing: true, body: "nice", timestamp: t0.addingTimeInterval(5),
                        status: MessageStatus.sending, validated: false, messageHash: "",
                        replyToHash: hash64)
    let thread = [photoMessage, reply]
    let resolved = ReplyPreview.resolve(for: reply, in: thread, peerName: "Ann",
                                        attachments: [photoMessage.id: image()])
    #expect(resolved == ReplyPreview.Resolved(senderLabel: "Ann", text: "📷 Photo", originalID: photoMessage.id))
    let asFile = ReplyPreview.resolve(for: reply, in: thread, peerName: "Ann",
                                      attachments: [photoMessage.id: file()])
    #expect(asFile?.text == "📎 notes.pdf")
    #expect(ReplyPreview.resolve(for: reply, in: thread, peerName: "Ann")?.text == ReplyPreview.unavailable)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachInfo`
Expected: compile errors (`AttachmentPlaceholder` unknown, `sections(for:attachment:timeZone:)` unknown).

- [ ] **Step 3: `AttachmentPlaceholder.swift`**

Create `CORE/Sources/ReTiCaMsgrCore/AttachmentPlaceholder.swift`:

```swift
import Foundation

/// What stands in for an attachment where only text fits: reply quotes and the conversation
/// list's preview (spec 2026-09-28 §4).
public enum AttachmentPlaceholder {
    public static let photo = "📷 Photo"

    public static func text(for attachment: Attachment) -> String {
        attachment.isImage ? photo : "📎 \(attachment.name)"
    }

    /// The body when it says something, else the attachment's placeholder, else the body as is.
    public static func preview(body: String, attachment: Attachment?) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return body }
        guard let attachment else { return body }
        return text(for: attachment)
    }
}
```

- [ ] **Step 4: `Conversation.swift`**

Replace `list(from:)` with:

```swift
    /// Build the conversation list from all messages: keep the newest row per
    /// `peerHex`, sorted most-recent-first. `attachments` (by message id) supplies the preview
    /// for a message whose body is empty because it carried a photo or a file.
    static func list(from messages: [Message], attachments: [UUID: Attachment] = [:]) -> [Conversation] {
        var latest: [String: Message] = [:]
        for m in messages {
            if let existing = latest[m.peerHex] {
                if m.timestamp > existing.timestamp { latest[m.peerHex] = m }
            } else {
                latest[m.peerHex] = m
            }
        }
        return latest.values
            .map {
                Conversation(peerHex: $0.peerHex,
                             lastBody: AttachmentPlaceholder.preview(body: $0.body, attachment: attachments[$0.id]),
                             lastTimestamp: $0.timestamp)
            }
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
    }
```

- [ ] **Step 5: `MessageInfo.swift`**

Replace `sections(for:timeZone:)` with:

```swift
    public static func sections(for message: Message, attachment: Attachment? = nil,
                                timeZone: TimeZone = .current) -> [Section] {
        var sections = [timeline(message, timeZone), delivery(message), identity(message), payload(message)]
        if let attachment {
            sections.append(attachmentSection(attachment))
        }
        return sections
    }
```

In `timeline`, replace `rows.append(Row("Status", m.status))` with:

```swift
        rows.append(Row("Status", m.status))
        if let reason = m.failureReason {
            rows.append(Row("Reason", failureReasonName(reason)))
        }
```

Replace `delivery` with:

```swift
    static func delivery(_ m: Message) -> Section {
        var rows = [m.isOutgoing
            ? optionalRow("Propagation node copy", m.sentViaPropagation.map { $0 ? "Yes" : "No" })
            : optionalRow("Arrival", m.arrivalMethod.map(arrivalName))]
        if m.isOutgoing, let refusal = m.propagationRefused {
            rows.append(Row("Propagation refusal", "Refused: \(refusal)"))
        }
        return Section(title: "Delivery", rows: rows)
    }
```

After `payload`, add:

```swift
    static func attachmentSection(_ a: Attachment) -> Section {
        let dimensions: String? = (a.width != nil && a.height != nil) ? "\(a.width!) × \(a.height!)" : nil
        return Section(title: "Attachment", rows: [
            Row("Kind", a.isImage ? "Image" : "File"),
            Row("Name", a.name),
            optionalRow("Format", a.format.isEmpty ? nil : a.format.uppercased()),
            Row("Size", bytes(a.size)),
            optionalRow("Dimensions", dimensions),
            Row("Stored", a.hasBytes ? "Yes" : "No"),
        ])
    }
```

In the Formatting section, after `stampName`, add:

```swift
    static func failureReasonName(_ raw: String) -> String {
        switch raw {
        case FailureReason.rejected: return "Rejected by recipient"
        case FailureReason.cancelled: return "Cancelled"
        default: return raw
        }
    }
```

- [ ] **Step 6: `ReplyPreview.swift`**

Replace `resolve(for:in:peerName:)` with:

```swift
    /// nil when `message` is not a reply. Otherwise the original from `thread` when present (its
    /// body, trimmed like a quote — or, when the body is empty and the original carries a photo or
    /// a file, its placeholder from `attachments`, keyed by message id), else the carried quote,
    /// else "Original message not available".
    ///
    /// When the original IS found but its trimmed text is empty (a whitespace-only body with no
    /// attachment), `text` still falls back to `unavailable` — but `originalID` stays set, so the
    /// quote block still scrolls to that (blank) original.
    public static func resolve(for message: Message, in thread: [Message], peerName: String?,
                               attachments: [UUID: Attachment] = [:]) -> Resolved? {
        guard let hash = message.replyToHash else { return nil }
        if let original = thread.first(where: { $0.messageHash == hash }) {
            // Spec 2026-09-28 §4: a caption-less photo or file quotes its placeholder.
            let body = AttachmentPlaceholder.preview(body: original.body, attachment: attachments[original.id])
            let trimmedBody = ReplyWire.trimQuote(body)
            return Resolved(
                senderLabel: senderLabel(originalIsOutgoing: original.isOutgoing, peerName: peerName),
                text: trimmedBody.isEmpty ? unavailable : trimmedBody,
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
```

- [ ] **Step 7: Run the new tests**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachInfo --filter infoSections --filter conversation --filter replyPreview`
Expected: the 7 new tests PASS and every existing `infoSections*` / conversation / `replyPreview*` test still passes (their expectations are untouched: no reason/refusal/attachment rows appear for messages without those fields, and `resolve` without `attachments:` behaves as before).

- [ ] **Step 8: Mutation batch (three sub-batches)**

Sub-batch A (apply together):
1. `AttachmentPlaceholder.text`: `attachment.isImage ? photo : ...` → always `photo` → RED `attachInfoPlaceholderTextAndPreview` (the file case), `attachInfoReplyPreviewQuotesAPhotoInTheThread` (the file quote), `attachInfoConversationPreviewUsesPlaceholder` (the `📎 map.gpx` case).
2. `attachmentSection`: delete the `optionalRow("Dimensions", dimensions)` line → RED `attachInfoSectionAppearsForAnImage`, `attachInfoSectionForAFileHasNoDimensionsAndShowsUnavailableBytes`.
3. `failureReasonName`: `case FailureReason.rejected: return "Rejected by recipient"` → `return "Cancelled"` → RED `attachInfoFailureReasonAndRefusalRows`.
4. `sections`: `if let attachment` → always append `attachmentSection(attachment ?? Attachment(id: UUID(), messageId: message.id, kind: "file", name: "", format: "", size: 0, width: nil, height: nil, path: ""))` → RED `attachInfoNoAttachmentNoSectionAndNoReasonRows`.

Sub-batch B (apply together, after A is reverted and green):
6. `AttachmentPlaceholder.preview`: delete the `if !trimmed.isEmpty { return body }` line → RED `attachInfoPlaceholderTextAndPreview` (body no longer wins). `attachInfoConversationPreviewUsesPlaceholder` and `attachInfoReplyPreviewQuotesAPhotoInTheThread` are unaffected (their bodies are empty). Not in A: mutation 1 reddens the same test.
7. `ReplyPreview.resolve`: `attachment: attachments[original.id]` → `attachment: nil` → RED `attachInfoReplyPreviewQuotesAPhotoInTheThread` (the photo quotes "Original message not available"). Not in A: mutation 1 reddens the same test.

Sub-batch C (alone, after B is reverted and green):
5. `Conversation.list`: `attachments[$0.id]` → `nil` → RED `attachInfoConversationPreviewUsesPlaceholder`. Alone: mutation 1 reddens the same test through its `📎 map.gpx` case.

Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 9: Full suite, commit**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/att-t5-full.log 2>&1`
Expected: all pass; count = Task 4 count + 7.

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AttachmentPlaceholder.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/MessageInfo.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Conversation.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/ReplyPreview.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AttachmentInfoTests.swift`

Write `/tmp/ReTiCaMsgr/msg-att-task-5.txt`:

```
feat: attachment section, failure reason and refusal in the Info sheet

Adds the Attachment section (kind, name, format, size, dimensions,
stored), a Reason row for rejected and cancelled messages, a
propagation refusal row, and the photo/file placeholders the
conversation list and reply quotes show for a message with no text,
including the quote block of a reply to a photo in the thread.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments commit -F /tmp/ReTiCaMsgr/msg-att-task-5.txt`

---

### Task 6: Receiving an attachment

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` (dependency; `State.attachmentsByMessageId`; `threadLoaded` shape; `openConversation`/`closeConversation`; `messageReceived`; `reloadThread`; `reloadConversations`; `replyTapped` quote text)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (`makeStore` gains an `attachmentStore:` parameter; tests appended at the end)

**Interfaces:**
- Consumes: T1 `Attachment.byMessageId(_:)`, T2 `\.attachmentStore`, T3 `AttachmentWire.decode` (and `Decoded.droppedFileCount`, logged as `inbound.notice` when > 0), T4 `ImageEncoder.dimensions(of:)`/`isDecodable`, T5 `AttachmentPlaceholder`, `Conversation.list(from:attachments:)`.
- Produces: `AppFeature.State.attachmentsByMessageId: [UUID: Attachment]` (the open thread's attachments), `Action.threadLoaded([Message], reactions: [Reaction] = [], attachments: [Attachment] = [])`; `@Dependency(\.attachmentStore) var attachmentStore` on the reducer. `reloadThread` fetches the thread's attachments; `reloadConversations` fetches attachments for empty-body messages so previews get placeholders.
- Semantics (spec §4): after the reaction and reply decoders, `AttachmentWire.decode`; bytes → `attachmentStore.store(…, outgoing: false, ext: format)`; on a throw the row is still inserted with `path == ""` (bubble: "Attachment could not be saved"); an image ImageIO cannot decode is stored as a FILE; dimensions from `ImageEncoder.dimensions(of:)`; `Message` and `Attachment` rows in one write transaction; `body` is the caption. `replyTapped` uses `AttachmentPlaceholder.preview` for the target's body so a photo reply quotes `📷 Photo`.

- [ ] **Step 1: `makeStore` accepts a store; the `Attachment` alias**

In `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`, add right after the imports (after `@testable import ReTiCaMsgrCore`), once for Tasks 6–8:

```swift

/// `Testing` exports its own `Attachment`; this file means the model.
private typealias Attachment = ReTiCaMsgrCore.Attachment
```

Then change the `makeStore` signature and body:

```swift
@MainActor
private func makeStore(_ db: any DatabaseWriter, identity: Identity,
                       attachmentStore: AttachmentStore? = nil,
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
```

and inside `withDependencies`, after `$0.defaultDatabase = db`:

```swift
        $0.attachmentStore = attachmentStore ?? AttachmentStore.testValue
```

Every existing call site (`makeStore(db, identity: x)` and `makeStore(db, identity: x) { state in … }`) keeps compiling.

- [ ] **Step 2: Write the failing tests**

Append to `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`:

```swift

// MARK: - Attachments: receiving (spec 2026-09-28 §4)

private func attachTempStore() -> AttachmentStore {
    AttachmentStore(baseDirectory: FileManager.default.temporaryDirectory
        .appending(path: "attachReceive-\(UUID().uuidString)"))
}

/// Deliver one message and return the stored message rows and attachment rows.
@MainActor
private func attachReceiveAndFetch(_ m: LXMessage, me: Identity, store attachmentStore: AttachmentStore)
    async throws -> (messages: [Message], attachments: [Attachment], state: AppFeature.State) {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: me, attachmentStore: attachmentStore) { s in
        s.openPeerHex = nil
    }
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .direct)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try await db.read { try Message.all.fetchAll($0) }
    let attachments = try await db.read { try Attachment.all.fetchAll($0) }
    return (messages, attachments, store.state)
}

@MainActor @Test func attachReceiveStoresAnImageOnDiskAndInTheTable() async throws {
    let me = Identity()
    let files = attachTempStore()
    let png = TestImages.png(width: 640, height: 480)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "look",
                        fields: [.init(0x06, .array([.string("png"), .bin(png)]))])
    let (messages, attachments, _) = try await attachReceiveAndFetch(m, me: me, store: files)
    let row = try #require(messages.first)
    #expect(row.body == "look")
    #expect(row.fieldKeys == "0x06")
    let a = try #require(attachments.first)
    #expect(a.messageId == row.id)
    #expect(a.kind == "image")
    #expect(a.name == "image.png")
    #expect(a.format == "png")
    #expect(a.size == png.count)
    #expect(a.width == 640)
    #expect(a.height == 480)
    #expect(a.path == "\(m.hash.hexString)-in.png")
    #expect(try Data(contentsOf: files.url(forRelativePath: a.path)) == png)
}

@MainActor @Test func attachReceiveStoresAFileWithAnEmptyCaption() async throws {
    let me = Identity()
    let files = attachTempStore()
    let pdf = Data("%PDF-1.4 fake".utf8)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "",
                        fields: [.init(0x05, .array([.array([.string("Trail map.pdf"), .bin(pdf)])]))])
    let (messages, attachments, _) = try await attachReceiveAndFetch(m, me: me, store: files)
    #expect(messages.first?.body == "")
    let a = try #require(attachments.first)
    #expect(a.kind == "file")
    #expect(a.name == "Trail map.pdf")
    #expect(a.format == "pdf")
    #expect(a.width == nil && a.height == nil)
    #expect(a.path == "\(m.hash.hexString)-in.pdf")
    #expect(try Data(contentsOf: files.url(forRelativePath: a.path)) == pdf)
}

/// Review Focus 3: a bad field never loses the message.
@MainActor @Test func attachReceiveMalformedFieldKeepsTheText() async throws {
    let me = Identity()
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "still here",
                        fields: [.init(0x06, .array([.string("jpeg")]))])   // one element: malformed
    let (messages, attachments, _) = try await attachReceiveAndFetch(m, me: me, store: attachTempStore())
    #expect(messages.count == 1)
    #expect(messages.first?.body == "still here")
    #expect(messages.first?.fieldKeys == "0x06")
    #expect(attachments.isEmpty)
}

/// An image the decoder cannot read (a jpeg field carrying junk) is kept as a file row, so the
/// bytes can still be opened or shared.
@MainActor @Test func attachReceiveUndecodableImageBecomesAFile() async throws {
    let me = Identity()
    let junk = Data("not really a jpeg".utf8)
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "",
                        fields: [.init(0x06, .array([.string("jpeg"), .bin(junk)]))])
    let (_, attachments, _) = try await attachReceiveAndFetch(m, me: me, store: attachTempStore())
    let a = try #require(attachments.first)
    #expect(a.kind == "file")
    #expect(a.name == "image.jpeg")
    #expect(a.format == "jpeg")
    #expect(a.width == nil)
}

/// Review Focus 4: a store that cannot write keeps the message and marks the bytes unavailable.
@MainActor @Test func attachReceiveStoreFailureKeepsTheMessageWithoutBytes() async throws {
    let me = Identity()
    let blocker = FileManager.default.temporaryDirectory.appending(path: "attachReceiveBlocker-\(UUID().uuidString)")
    try Data([0]).write(to: blocker)
    let broken = AttachmentStore(baseDirectory: blocker.appending(path: "Attachments"))
    let m = wireMessage(from: Identity(), to: me, at: 1699999900, content: "photo!",
                        fields: [.init(0x06, .array([.string("png"), .bin(TestImages.png(width: 8, height: 8))]))])
    let (messages, attachments, _) = try await attachReceiveAndFetch(m, me: me, store: broken)
    #expect(messages.first?.body == "photo!")
    let a = try #require(attachments.first)
    #expect(a.kind == "image")
    #expect(a.path == "")
    #expect(!a.hasBytes)
    #expect(a.width == 8)
}

@MainActor @Test func attachReceiveThreadLoadExposesAttachmentsByMessageId() async throws {
    let me = Identity()
    let sender = Identity()
    let files = attachTempStore()
    let db = try! AppDatabase.makeInMemory()
    let peerHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let store = makeStore(db, identity: me, attachmentStore: files) { s in s.openPeerHex = peerHex }
    let m = wireMessage(from: sender, to: me, at: 1699999900, content: "",
                        fields: [.init(0x05, .array([.array([.string("a.txt"), .bin(Data("x".utf8))])]))])
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .direct)))))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    let row = try #require(store.state.threadMessages.first)
    let a = try #require(store.state.attachmentsByMessageId[row.id])
    #expect(a.name == "a.txt")
    // The conversation preview shows the placeholder for the empty caption.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.conversations.first?.lastBody == "📎 a.txt")
    // Closing the conversation clears the map.
    await store.send(.closeConversation)
    #expect(store.state.attachmentsByMessageId.isEmpty)
}

/// A reply to a photo quotes the placeholder, not an empty line.
@MainActor @Test func attachReceiveReplyToAPhotoQuotesThePlaceholder() async {
    let hash = String(repeating: "7a", count: 32)
    let original = msg(1, peerA, "", 1000, outgoing: false, status: MessageStatus.received, hash: hash)
    let photo = Attachment(id: UUID(), messageId: original.id, kind: AttachmentKind.image, name: "image.jpeg",
                           format: "jpeg", size: 10, width: 4, height: 4, path: "x")
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.threadMessages = [original]
        s.attachmentsByMessageId = [original.id: photo]
    }
    await store.send(.replyTapped(uuid(1)))
    #expect(store.state.replyTarget == AppFeature.ReplyTarget(messageHash: hash, body: "📷 Photo", isOutgoing: false))
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachReceive`
Expected: compile errors (`attachmentsByMessageId` unknown, `makeStore(attachmentStore:)` unknown until Step 1 — do Step 1 first, then the tests fail on the state property).

- [ ] **Step 4: `AppFeature.swift` — state, action, dependency**

In `State`, after `threadReactions` (line 83) add:

```swift
        /// The open thread's attachments by message id, loaded with the thread. Session-only.
        public var attachmentsByMessageId: [UUID: Attachment] = [:]
```

Change the action case:

```swift
        case threadLoaded([Message], reactions: [Reaction] = [], attachments: [Attachment] = [])
```

After `@Dependency(\.continuousClock) var clock` add:

```swift
    @Dependency(\.attachmentStore) var attachmentStore
```

In `.closeConversation`, after `state.setThreadReactionRows([])` add `state.attachmentsByMessageId = [:]`.

In `.threadLoaded`:

```swift
            case let .threadLoaded(rows, reactions, attachments):
                state.threadMessages = rows
                let allowed: Set<String> = [state.myAddressHex, state.openPeerHex ?? ""]
                state.setThreadReactionRows(reactions.filter { allowed.contains($0.reactorHex) })
                state.attachmentsByMessageId = Attachment.byMessageId(attachments)
                return .none
```

In `.replyTapped`, build the target with the placeholder:

```swift
                state.replyTarget = ReplyTarget(
                    messageHash: message.messageHash,
                    body: AttachmentPlaceholder.preview(body: message.body,
                                                        attachment: state.attachmentsByMessageId[message.id]),
                    isOutgoing: message.isOutgoing)
```

- [ ] **Step 5: `messageReceived`**

After `let reply = ReplyWire.decode(m.fields)` add:

```swift
                // Standard LXMF attachment fields (0x05 / 0x06). Decoded here, written inside the
                // effect: the bytes go to disk first, then the message and attachment rows land in
                // one transaction. A field that does not decode leaves an ordinary text message.
                let decodedAttachment = AttachmentWire.decode(m.fields)
                if let dropped = decodedAttachment?.droppedFileCount, dropped > 0 {
                    // Spec §2: one attachment per message is kept; say what was left out.
                    AppFeature.inbound.notice("attachment: kept one, dropped \(dropped, privacy: .public) other file entries from \(String(m.hash.hexString.prefix(8)), privacy: .public)")
                }
                let attachmentStore = self.attachmentStore
```

Replace the effect at the end of the case with:

```swift
                return .run { [database] send in
                    var attachmentRow: Attachment? = nil
                    if let decoded = decodedAttachment {
                        // An image ImageIO cannot read is kept as a file so it can still be shared.
                        let dims = decoded.kind == AttachmentKind.image ? ImageEncoder.dimensions(of: decoded.data) : nil
                        let kind = (decoded.kind == AttachmentKind.image && dims == nil) ? AttachmentKind.file : decoded.kind
                        // Review Focus 4: a failed write keeps the row with no bytes (path "").
                        let path: String
                        do {
                            path = try attachmentStore.store(decoded.data, messageHash: seenHashHex,
                                                             outgoing: false, ext: decoded.format)
                        } catch {
                            AppFeature.inbound.error("attachment write failed for \(seenHashHex.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
                            path = ""
                        }
                        attachmentRow = Attachment(
                            id: UUID(), messageId: row.id, kind: kind, name: decoded.name,
                            format: decoded.format, size: decoded.data.count,
                            width: dims?.width, height: dims?.height, path: path)
                    }
                    try await database.write { db in
                        try Message.insert { row }.execute(db)
                        if let attachmentRow {
                            try Attachment.insert { attachmentRow }.execute(db)
                        }
                        // Persist the seen hash so a cold start doesn't re-deliver this message.
                        // Upsert: replace any existing row for the same hash (a duplicate from a
                        // previous session should already be in seen, but a re-deliver would be
                        // wrong regardless). Then prune to RingSet.capacity so the table mirrors
                        // the in-memory ring and doesn't grow without bound.
                        try recordSeenHash(seenHashHex, at: seenNow, db)
                    }
                    try await reloadConversations(database, send)
                    if incomingPeer == openPeer {
                        try await reloadThread(database, incomingPeer, send)
                    }
                }
```

Note the test `attachReceiveStoreFailureKeepsTheMessageWithoutBytes` expects `width == 8` with `kind == "image"` even though the bytes were not stored: dimensions are read from the received bytes before the write, so keep the `dims` computation before the `store` call as written.

- [ ] **Step 6: Reload helpers**

Replace `reloadConversations` and `reloadThread` (file scope) with:

```swift
private func reloadConversations(_ database: any DatabaseWriter, _ send: Send<AppFeature.Action>) async throws {
    let (all, attachments) = try await database.read { db -> ([Message], [Attachment]) in
        let all = try Message.fetchAll(db)
        // Only a message with no text needs its attachment for the preview placeholder.
        let ids = all.filter { $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id)
        let attachments = ids.isEmpty ? [] : try Attachment.where { $0.messageId.in(ids) }.fetchAll(db)
        return (all, attachments)
    }
    let byMessage = Attachment.byMessageId(attachments)
    await send(.conversationsLoaded(Conversation.list(from: all, attachments: byMessage)))
}

private func reloadThread(_ database: any DatabaseWriter, _ peerHex: String, _ send: Send<AppFeature.Action>) async throws {
    let (rows, reactions, attachments) = try await database.read { db -> ([Message], [Reaction], [Attachment]) in
        let rows = try Message.where { $0.peerHex.eq(peerHex) }.order(by: \.timestamp).fetchAll(db)
        let hashes = rows.map(\.messageHash).filter { !$0.isEmpty }
        let reactions = hashes.isEmpty ? [] : try Reaction.where { $0.messageHash.in(hashes) }.fetchAll(db)
        let ids = rows.map(\.id)
        let attachments = ids.isEmpty ? [] : try Attachment.where { $0.messageId.in(ids) }.fetchAll(db)
        return (rows, reactions, attachments)
    }
    await send(.threadLoaded(rows, reactions: reactions, attachments: attachments))
}
```

- [ ] **Step 7: Run the new tests**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachReceive`
Expected: 7 tests PASS.

- [ ] **Step 8: Mutation batch**

Sub-batch A (apply together, `AppFeature.swift`):
1. `messageReceived` effect: `path = try attachmentStore.store(...)` → `path = ""` (never store) → RED `attachReceiveStoresAnImageOnDiskAndInTheTable`, `attachReceiveStoresAFileWithAnEmptyCaption` (path mismatch, no file).
2. `let kind = (... && dims == nil) ? AttachmentKind.file : decoded.kind` → `let kind = decoded.kind` → RED `attachReceiveUndecodableImageBecomesAFile`.
3. `.threadLoaded`: `state.attachmentsByMessageId = Attachment.byMessageId(attachments)` → `= [:]` → RED `attachReceiveThreadLoadExposesAttachmentsByMessageId`.
4. `.replyTapped`: `AttachmentPlaceholder.preview(...)` → `message.body` → RED `attachReceiveReplyToAPhotoQuotesThePlaceholder`.
8. `messageReceived`: before the effect add `let hasAttachmentField = m.fields.contains { $0.key == 0x05 || $0.key == 0x06 }`, and in the transaction wrap `try Message.insert { row }.execute(db)` in `if decodedAttachment != nil || !hasAttachmentField { ... }` (a malformed attachment field drops the message) → RED `attachReceiveMalformedFieldKeepsTheText` (Review Focus 3: no message row). The other tests' fields all decode, so only this one turns red.

Sub-batch B (alone):
5. `messageReceived` effect: in the `catch`, `path = ""` → rethrow (`throw error`) → RED `attachReceiveStoreFailureKeepsTheMessageWithoutBytes` (no rows at all).

Sub-batch C (alone):
6. `messageReceived` effect: `if let decoded = decodedAttachment` → `if let decoded = decodedAttachment, decoded.data.count > 100_000` → RED `attachReceiveStoresAnImageOnDiskAndInTheTable`, `attachReceiveStoresAFileWithAnEmptyCaption`, `attachReceiveUndecodableImageBecomesAFile`, `attachReceiveThreadLoadExposesAttachmentsByMessageId` (no attachment rows) — while `attachReceiveMalformedFieldKeepsTheText` stays GREEN, which proves that test asserts the message survives rather than merely "no attachment".

Sub-batch D (alone):
7. `reloadConversations`: `attachments: byMessage` → `attachments: [:]` → RED `attachReceiveThreadLoadExposesAttachmentsByMessageId` (preview is ""). Alone: mutation 6 reddens the same test (no rows means no preview).

Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 9: Full suite, commit**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/att-t6-full.log 2>&1`
Expected: all pass; count = Task 5 count + 7. Existing `threadLoaded` receives (`if case .threadLoaded = $0`) still match.

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`

Write `/tmp/ReTiCaMsgr/msg-att-task-6.txt`:

```
feat: store received image and file attachments

messageReceived decodes the standard 0x05/0x06 fields, writes the
bytes through AttachmentStore and inserts the attachment row with the
message in one transaction. A write failure keeps the message with an
unavailable attachment, an undecodable image is kept as a file, the
thread and conversation loads carry attachments, and a reply to a
photo quotes its placeholder.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments commit -F /tmp/ReTiCaMsgr/msg-att-task-6.txt`

---
### Task 7: Sending an attachment — picking, preparing, the send

**Files:**
- Create: `CORE/Sources/ReTiCaMsgrCore/PendingAttachment.swift`
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` (state, actions, `CancelID.attachmentPreparation`, `prepareEffect`, `openConversation`/`startConversation`/`closeConversation`, `sendTapped`, new cases)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (append)

**Interfaces:**
- Consumes: T2 `\.attachmentStore`, T3 `AttachmentWire.encodeImage/encodeFile`, T4 `ImageEncoder`.
- Produces: `public struct PickedItem { kind: String, name: String, data: Data }` (what the view hands over after reading the picker's bytes); `public struct PendingAttachment { kind, name, format, data, width: Int?, height: Int?, originalSource: Data?, isOriginal: Bool; var size: Int }`; `public enum AttachmentSizeNote { propagationLimitBytes = 256_000, deliveryLimitBytes = 1_000_000, overDelivery, overPropagation, note(for size: Int) -> String?, formattedSize(_:) -> String }`; `public enum AttachmentPreparation { undecodableImage, encodingFailed, storeFailed, prepare(_:original:now:) -> Result<PendingAttachment, PreparationError>, imageName(at:) -> String }`. `AppFeature.State.pendingAttachment: PendingAttachment?`, `attachmentPreparing: Bool`, `attachmentError: String?`; actions `attachmentPicked(PickedItem)`, `attachmentPrepared(PendingAttachment)`, `attachmentFailed(String)`, `attachmentRemoved`, `attachmentOriginalToggled(Bool)`, `attachmentSendFailed(draft: String)`; `CancelID.attachmentPreparation`; private reducer helper `prepareEffect(_ item: PickedItem, original: Bool) -> Effect<Action>`.
- Semantics (spec §3): picking replaces any pending attachment and prepares asynchronously (images → `ImageEncoder` standard; Original toggle re-encodes from `originalSource`; files pass through); ONE preparation at a time — `prepareEffect` is `.cancellable(id: CancelID.attachmentPreparation, cancelInFlight: true)`, and `attachmentRemoved`, `openConversation`, `startConversation`, `closeConversation` and a proceeding `sendTapped` cancel it, so a late `attachmentPrepared` can never replace or resurrect the pending attachment; `sendTapped` allows an empty draft when an attachment is pending, refuses while preparing, orders fields `[0x05|0x06] + reply`, writes the bytes BEFORE inserting the message + attachment rows in one transaction and only then sends; a store failure sends nothing, logs the error, and sends `attachmentSendFailed(draft:)`, which shows `storeFailed` inline in the attachment bar and puts the caption back in the draft (the attachment must be picked again); `draft`/`replyTarget`/`pendingAttachment` clear synchronously; generated photo names are `IMG_<yyyyMMdd_HHmmss>.jpg` in UTC; an `ImageEncoder.Failure.encodingFailed` shows `encodingFailed` ("Couldn't encode that image"), anything else `undecodableImage`.

- [ ] **Step 1: Write the failing tests**

Append to `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`:

```swift

// MARK: - Attachments: sending (spec 2026-09-28 §3)

/// 1600×1200: above the 1280 standard edge (so the standard preset scales it to 1280×960) but
/// small enough that the PNG decode + JPEG encode inside `store.receive` stays well under the
/// TestStore's 1 s receive timeout in a parallel full suite.
private let attachPNG = TestImages.png(width: 1600, height: 1200)

private func pendingImage(_ data: Data = TestImages.jpeg(width: 40, height: 30)) -> PendingAttachment {
    PendingAttachment(kind: AttachmentKind.image, name: "IMG_20231114_221320.jpg", format: "jpeg", data: data,
                      width: 40, height: 30, originalSource: data, isOriginal: false)
}

private func pendingFile(name: String = "Trail map.pdf", data: Data = Data("%PDF fake".utf8)) -> PendingAttachment {
    PendingAttachment(kind: AttachmentKind.file, name: name, format: "pdf", data: data,
                      width: nil, height: nil, originalSource: nil, isOriginal: false)
}

@MainActor @Test func attachSendPickingAnImagePreparesAStandardJPEG() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity())
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: attachPNG)))
    #expect(store.state.attachmentPreparing)
    await store.receive { if case .attachmentPrepared = $0 { return true }; return false }
    let p = try! #require(store.state.pendingAttachment)
    #expect(p.kind == "image")
    #expect(p.format == "jpeg")
    #expect(p.name == "IMG_20231114_221320.jpg")   // the frozen \.date, UTC
    #expect(p.width == 1280)
    #expect(p.height == 960)
    #expect(p.originalSource == attachPNG)
    #expect(p.isOriginal == false)
    #expect(ImageEncoder.containerType(of: p.data) == "public.jpeg")
    #expect(!store.state.attachmentPreparing)
    #expect(store.state.attachmentError == nil)
}

@MainActor @Test func attachSendOriginalToggleReencodesFromTheSource() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity())
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: attachPNG)))
    await store.receive { if case .attachmentPrepared = $0 { return true }; return false }
    await store.send(.attachmentOriginalToggled(true))
    #expect(store.state.attachmentPreparing)
    await store.receive { if case .attachmentPrepared = $0 { return true }; return false }
    #expect(store.state.pendingAttachment?.width == 1600)
    #expect(store.state.pendingAttachment?.height == 1200)
    #expect(store.state.pendingAttachment?.isOriginal == true)
    #expect(store.state.pendingAttachment?.name == "IMG_20231114_221320.jpg")   // the name is kept
    await store.send(.attachmentOriginalToggled(false))
    await store.receive { if case .attachmentPrepared = $0 { return true }; return false }
    #expect(store.state.pendingAttachment?.width == 1280)
    #expect(store.state.pendingAttachment?.height == 960)
    // Toggling to the state it is already in, or with a file pending, does nothing.
    store.exhaustivity = .on
    await store.send(.attachmentOriginalToggled(false))
    await store.send(.attachmentRemoved) {
        $0.pendingAttachment = nil
        $0.attachmentPreparing = false
        $0.attachmentError = nil
    }
    store.exhaustivity = .off
}

@MainActor @Test func attachSendPickingAFilePassesThrough() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity())
    let bytes = Data("%PDF fake".utf8)
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.file, name: "Trail map.pdf", data: bytes)))
    await store.receive { if case .attachmentPrepared = $0 { return true }; return false }
    let p = try! #require(store.state.pendingAttachment)
    #expect(p.kind == "file")
    #expect(p.name == "Trail map.pdf")
    #expect(p.format == "pdf")
    #expect(p.data == bytes)
    #expect(p.width == nil && p.height == nil)
    #expect(p.originalSource == nil)
    #expect(p.size == bytes.count)
}

/// A late preparation result must not resurrect an attachment the user removed: Remove cancels
/// the encode in flight.
@MainActor @Test func attachSendRemoveCancelsAPendingPreparation() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity())
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: attachPNG)))
    await store.send(.attachmentRemoved)
    // Exhaustive from here: once every effect has finished, a late `attachmentPrepared` would be
    // an unhandled received action and the probe send fails.
    store.exhaustivity = .on
    await store.finish()
    await store.send(.replyCancelled)   // probe
    store.exhaustivity = .off
    #expect(store.state.pendingAttachment == nil)
}

@MainActor @Test func attachSendUndecodableImageFails() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.pendingAttachment = pendingFile()   // replaced by the new pick, even when it fails
    }
    await store.send(.attachmentPicked(PickedItem(kind: AttachmentKind.image, name: "", data: Data("junk".utf8))))
    #expect(store.state.pendingAttachment == nil)
    await store.receive(.attachmentFailed(AttachmentPreparation.undecodableImage))
    #expect(store.state.attachmentError == AttachmentPreparation.undecodableImage)
    #expect(!store.state.attachmentPreparing)
    #expect(store.state.pendingAttachment == nil)
}

@Test func attachSendSizeNotesAndFormatting() {
    #expect(AttachmentSizeNote.note(for: 100) == nil)
    #expect(AttachmentSizeNote.note(for: 256_000) == nil)
    #expect(AttachmentSizeNote.note(for: 256_001) == AttachmentSizeNote.overPropagation)
    #expect(AttachmentSizeNote.note(for: 1_000_000) == AttachmentSizeNote.overPropagation)
    #expect(AttachmentSizeNote.note(for: 1_000_001) == AttachmentSizeNote.overDelivery)
    #expect(AttachmentSizeNote.formattedSize(900) == "900 B")
    #expect(AttachmentSizeNote.formattedSize(34_211) == "34 KB")
    #expect(AttachmentSizeNote.formattedSize(1_234_567) == "1.2 MB")
    #expect(AttachmentSizeNote.formattedSize(10_500_000) == "10.5 MB")
}

/// The whole send saga for an image: bytes on disk, both rows, the 0x06 field, and the caption.
@MainActor @Test func attachSendImageWritesRowsFileAndFields() async throws {
    let db = try! AppDatabase.makeInMemory()
    let files = attachTempStore()
    let jpeg = TestImages.jpeg(width: 40, height: 30)
    let store = makeStore(db, identity: Identity(), attachmentStore: files) { s in
        s.openPeerHex = peerA
        s.draft = "cap"
        s.pendingAttachment = pendingImage(jpeg)
    }
    await store.send(.sendTapped)
    #expect(store.state.pendingAttachment == nil)
    #expect(store.state.draft == "")
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let msg = try #require(sent)
    #expect(msg.fields.map(\.key) == [0x06])
    #expect(AttachmentWire.decode(msg.fields)?.data == jpeg)
    #expect(msg.content == Data("cap".utf8))
    let row = try #require(try await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }.first)
    #expect(row.body == "cap")
    #expect(row.fieldKeys == "0x06")
    #expect(row.wireSize == msg.packed.count)
    #expect(row.status == MessageStatus.sending)
    let a = try #require(try await db.read { try Attachment.all.fetchAll($0) }.first)
    #expect(a.messageId == row.id)
    #expect(a.kind == "image")
    #expect(a.name == "IMG_20231114_221320.jpg")
    #expect(a.format == "jpeg")
    #expect(a.size == jpeg.count)
    #expect(a.width == 40 && a.height == 30)
    #expect(a.path == "\(msg.hash.hexString)-out.jpeg")
    #expect(try Data(contentsOf: files.url(forRelativePath: a.path)) == jpeg)
    #expect(store.state.attachmentsByMessageId[row.id] == a)
}

@MainActor @Test func attachSendFileWithNoTextIsAllowed() async throws {
    let db = try! AppDatabase.makeInMemory()
    let files = attachTempStore()
    let store = makeStore(db, identity: Identity(), attachmentStore: files) { s in
        s.openPeerHex = peerA
        s.draft = ""
        s.pendingAttachment = pendingFile()
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let msg = try #require(sent)
    #expect(msg.fields.map(\.key) == [0x05])
    #expect(AttachmentWire.decode(msg.fields)?.name == "Trail map.pdf")
    #expect(msg.content.isEmpty)
    let a = try #require(try await db.read { try Attachment.all.fetchAll($0) }.first)
    #expect(a.kind == "file")
    #expect(a.path == "\(msg.hash.hexString)-out.pdf")
    #expect(files.exists(a.path))
}

@MainActor @Test func attachSendWithReplyOrdersAttachmentFirst() async throws {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), attachmentStore: attachTempStore()) { s in
        s.openPeerHex = peerA
        s.draft = ""
        s.pendingAttachment = pendingImage()
        s.replyTarget = AppFeature.ReplyTarget(messageHash: replyTargetHash, body: "see you", isOutgoing: false)
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    #expect(sent?.fields.map(\.key) == [0x06, 0x30, 0x31])
    #expect(store.state.replyTarget == nil)
}

/// Review Focus 4 (send half): a store that cannot write sends NOTHING, says so inline, and gives
/// the caption back.
@MainActor @Test func attachSendStoreFailureSendsNothing() async throws {
    let db = try! AppDatabase.makeInMemory()
    let blocker = FileManager.default.temporaryDirectory.appending(path: "attachSendBlocker-\(UUID().uuidString)")
    try Data([0]).write(to: blocker)
    let broken = AttachmentStore(baseDirectory: blocker.appending(path: "Attachments"))
    let store = makeStore(db, identity: Identity(), attachmentStore: broken) { s in
        s.openPeerHex = peerA
        s.draft = "cap"
        s.pendingAttachment = pendingImage()
    }
    store.exhaustivity = .on
    await store.send(.sendTapped) {
        $0.draft = ""
        $0.pendingAttachment = nil
        $0.attachmentError = nil
    }
    await store.receive(.attachmentSendFailed(draft: "cap")) {
        $0.attachmentError = AttachmentPreparation.storeFailed
        $0.draft = "cap"
    }
    // Exhaustive probe: no sendMessage, no reload followed.
    await store.send(.replyCancelled)
    store.exhaustivity = .off
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.isEmpty)
}

@MainActor @Test func attachSendTextOnlyLeavesNoAttachmentRow() async throws {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "just text"
    }
    await store.send(.sendTapped)
    var sent: LXMessage?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action { sent = msg; return true }
        return false
    }
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    #expect(sent?.fields.isEmpty == true)
    #expect(try await db.read { try Attachment.all.fetchAll($0) }.isEmpty)
}

@MainActor @Test func attachSendGuardsWhilePreparingAndClearsOnClose() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.draft = "x"
        s.attachmentPreparing = true
    }
    store.exhaustivity = .on
    await store.send(.sendTapped)            // nothing happens while a pick is being prepared
    await store.send(.replyCancelled)         // probe
    store.exhaustivity = .off
    #expect(store.state.draft == "x")
    // Empty draft and no attachment: nothing happens either.
    let empty = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in s.openPeerHex = peerA }
    empty.exhaustivity = .on
    await empty.send(.sendTapped)
    await empty.send(.replyCancelled)
    empty.exhaustivity = .off
    // Leaving the conversation drops a pending attachment and its error.
    let leaving = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.pendingAttachment = pendingFile()
        s.attachmentError = "old"
    }
    await leaving.send(.closeConversation)
    #expect(leaving.state.pendingAttachment == nil)
    #expect(leaving.state.attachmentError == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachSend`
Expected: compile errors (`PickedItem`, `PendingAttachment`, the new actions unknown).

- [ ] **Step 3: `PendingAttachment.swift`**

Create `CORE/Sources/ReTiCaMsgrCore/PendingAttachment.swift`:

```swift
import Foundation

/// What the composer's picker handed over: the bytes plus the kind and, for a file, its name.
/// The view reads the picker item (security-scoped for `fileImporter`) and sends this.
public struct PickedItem: Equatable, Sendable {
    public var kind: String       // AttachmentKind.*
    public var name: String       // "" for a photo (the name is generated)
    public var data: Data

    public init(kind: String, name: String, data: Data) {
        self.kind = kind
        self.name = name
        self.data = data
    }
}

/// The attachment waiting in the composer bar (spec 2026-09-28 §3): already encoded for the wire.
public struct PendingAttachment: Equatable, Sendable {
    public var kind: String
    public var name: String
    public var format: String
    public var data: Data
    public var width: Int?
    public var height: Int?
    /// Images: the picker's bytes, kept so the Original toggle can re-encode. nil for files.
    public var originalSource: Data?
    public var isOriginal: Bool

    public init(kind: String, name: String, format: String, data: Data, width: Int?, height: Int?,
                originalSource: Data?, isOriginal: Bool) {
        self.kind = kind
        self.name = name
        self.format = format
        self.data = data
        self.width = width
        self.height = height
        self.originalSource = originalSource
        self.isOriginal = isOriginal
    }

    public var isImage: Bool { kind == AttachmentKind.image }
    public var size: Int { data.count }
}

/// The size notes the composer shows (spec: informational, never blocking). The limits are the
/// reference LXMF defaults: a propagation node accepts 256 KB per message and a receiving router
/// 1 000 KB (neither is announced per peer, so these are the safe assumptions).
public enum AttachmentSizeNote {
    public static let propagationLimitBytes = 256_000
    public static let deliveryLimitBytes = 1_000_000
    public static let overPropagation = "Over 256 KB — direct only, won't be stored at the propagation node"
    public static let overDelivery = "Over 1 MB — may be refused by other clients"

    public static func note(for size: Int) -> String? {
        if size > deliveryLimitBytes { return overDelivery }
        if size > propagationLimitBytes { return overPropagation }
        return nil
    }

    /// `900 B`, `34 KB`, `1.2 MB` (decimal units, like the limits).
    public static func formattedSize(_ bytes: Int) -> String {
        if bytes < 1000 { return "\(bytes) B" }
        if bytes < 1_000_000 { return "\(bytes / 1000) KB" }
        let mb = Double(bytes) / 1_000_000
        return String(format: "%.1f MB", mb)
    }
}

/// Turns a picked item into a pending attachment. Pure and synchronous; `AppFeature` runs it in
/// an effect so a large photo never encodes on the main thread.
public enum AttachmentPreparation {
    public static let undecodableImage = "Couldn't read that image"
    public static let encodingFailed = "Couldn't encode that image"
    public static let storeFailed = "Couldn't save the attachment — nothing was sent"

    public struct PreparationError: Error, Equatable, Sendable {
        public var message: String
        public init(message: String) { self.message = message }
    }

    public static func prepare(_ item: PickedItem, original: Bool, now: Date) -> Result<PendingAttachment, PreparationError> {
        if item.kind == AttachmentKind.image {
            do {
                let encoded = try ImageEncoder.encodeJPEG(item.data, preset: original ? .original : .standard)
                let name = item.name.isEmpty ? imageName(at: now) : item.name
                return .success(PendingAttachment(
                    kind: AttachmentKind.image, name: name, format: AttachmentWire.sentImageFormat,
                    data: encoded.data, width: encoded.width, height: encoded.height,
                    originalSource: item.data, isOriginal: original))
            } catch ImageEncoder.Failure.encodingFailed {
                // ImageIO read the image but could not write the JPEG: not the user's file's fault.
                return .failure(PreparationError(message: encodingFailed))
            } catch {
                return .failure(PreparationError(message: undecodableImage))
            }
        }
        let name = AttachmentWire.sanitizedFileName(item.name)
        return .success(PendingAttachment(
            kind: AttachmentKind.file, name: name, format: AttachmentWire.fileExtension(name),
            data: item.data, width: nil, height: nil, originalSource: nil, isOriginal: false))
    }

    /// `IMG_yyyyMMdd_HHmmss.jpg` in UTC, so the name is the same wherever the phone is.
    public static func imageName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "'IMG_'yyyyMMdd'_'HHmmss'.jpg'"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: `AppFeature.swift` — state and actions**

In `State`, after `replyTarget` add:

```swift
        /// The attachment waiting in the composer, its in-flight preparation, and the last error.
        /// Session-only; cleared by send, remove, or leaving the conversation.
        public var pendingAttachment: PendingAttachment? = nil
        public var attachmentPreparing = false
        public var attachmentError: String? = nil
```

In `Action`, after `replyCancelled` add:

```swift
        /// The composer's picker delivered bytes; prepare them (encode a photo) off the main thread.
        case attachmentPicked(PickedItem)
        case attachmentPrepared(PendingAttachment)
        case attachmentFailed(String)
        /// The × on the attachment bar.
        case attachmentRemoved
        /// The Original toggle on a pending photo: re-encode from the picker's bytes.
        case attachmentOriginalToggled(Bool)
        /// The send could not write the attachment's bytes, so nothing was sent: show `storeFailed`
        /// in the attachment bar and give the caption back. Internal.
        case attachmentSendFailed(draft: String)
```

In `CancelID` add:

```swift
        /// The one in-flight preparation (photo encode) of a picked attachment.
        case attachmentPreparation
```

Replace the `.openConversation`, `.closeConversation` and `.startConversation` cases with (Task 6's `attachmentsByMessageId` line is kept in `.closeConversation`):

```swift
            case let .openConversation(peerHex):
                state.openPeerHex = peerHex
                // Review fix: a target from the previous conversation must not survive the switch —
                // it would point at a message the new thread doesn't even contain.
                state.replyTarget = nil
                // Neither may a pending attachment, nor its preparation still in flight.
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                return .merge(
                    .cancel(id: CancelID.attachmentPreparation),
                    .run { [database] send in try await reloadThread(database, peerHex, send) }
                )

            case .closeConversation:
                state.openPeerHex = nil
                state.threadMessages = []
                state.setThreadReactionRows([])
                state.attachmentsByMessageId = [:]
                state.draft = ""
                state.replyTarget = nil
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                return .cancel(id: CancelID.attachmentPreparation)

            case let .startConversation(hex):
                guard let data = Data(hexString: hex), data.count == 16 else { return .none }
                state.openPeerHex = hex
                // Review fix: same as `openConversation` — clear any stale target from before.
                state.replyTarget = nil
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                return .merge(
                    .cancel(id: CancelID.attachmentPreparation),
                    .run { [database] send in try await reloadThread(database, hex, send) }
                )
```

Add a private method on `AppFeature` (after `body`, inside the struct):

```swift
    /// Encodes a picked item off the main thread (spec §3). One preparation at a time: a newer
    /// pick or Original toggle cancels the one in flight (`cancelInFlight`), and Remove, leaving or
    /// switching the thread, and Send cancel it too, so a late result can never replace or
    /// resurrect the pending attachment (a cancelled effect's `send` is dropped).
    private func prepareEffect(_ item: PickedItem, original: Bool) -> Effect<Action> {
        let now = date.now
        return .run { send in
            switch AttachmentPreparation.prepare(item, original: original, now: now) {
            case let .success(pending): await send(.attachmentPrepared(pending))
            case let .failure(error): await send(.attachmentFailed(error.message))
            }
        }
        .cancellable(id: CancelID.attachmentPreparation, cancelInFlight: true)
    }
```

Add the new cases after `.replyCancelled`:

```swift
            case let .attachmentPicked(item):
                // A new pick replaces whatever was pending, even if it then fails.
                state.pendingAttachment = nil
                state.attachmentError = nil
                state.attachmentPreparing = true
                return prepareEffect(item, original: false)

            case let .attachmentOriginalToggled(original):
                guard let pending = state.pendingAttachment, pending.isImage,
                      let source = pending.originalSource, pending.isOriginal != original
                else { return .none }
                state.attachmentPreparing = true
                // The name is passed through so a toggle never renames the photo.
                return prepareEffect(PickedItem(kind: AttachmentKind.image, name: pending.name, data: source),
                                     original: original)

            case let .attachmentPrepared(pending):
                state.pendingAttachment = pending
                state.attachmentPreparing = false
                state.attachmentError = nil
                return .none

            case let .attachmentFailed(reason):
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = reason
                return .none

            case .attachmentRemoved:
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                return .cancel(id: CancelID.attachmentPreparation)

            case let .attachmentSendFailed(draft):
                // Inline, in the attachment bar (no alert plumbing): nothing was sent, the caption
                // comes back, and the attachment has to be picked again.
                state.attachmentError = AttachmentPreparation.storeFailed
                state.draft = draft
                return .none
```

- [ ] **Step 5: `sendTapped`**

Replace the `.sendTapped` case with:

```swift
            case .sendTapped:
                let text = state.draft
                let pending = state.pendingAttachment
                // Text or an attachment, not while a pick is still being prepared.
                guard !text.isEmpty || pending != nil,
                      !state.attachmentPreparing,
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
                    // Review fix: an empty trimmed quote (a whitespace-only original) is stored as
                    // nil, matching the wire, which now omits 0x31 for an empty quote too.
                    replyQuote = quote.isEmpty ? nil : quote
                }
                // The attachment field (0x05 or 0x06) comes first, then any reply fields.
                var attachmentFields: [MsgPackValue.IntPair] = []
                if let pending {
                    attachmentFields = pending.isImage
                        ? AttachmentWire.encodeImage(pending.data)
                        : AttachmentWire.encodeFile(name: pending.name, data: pending.data)
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
                    fields: attachmentFields + replyFields
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
                state.pendingAttachment = nil
                state.attachmentError = nil
                // The guard above refuses while preparing, so nothing should be in flight here;
                // cancelling anyway means no late result can land on the emptied composer.
                guard let pending else {
                    return .merge(
                        .cancel(id: CancelID.attachmentPreparation),
                        .send(.node(.client(.sendMessage(message: msg, alsoViaPropagation: alsoViaPropagation)))),
                        .run { [database] send in
                            try await database.write { try Message.insert { row }.execute($0) }
                            try await reloadThread(database, peerHex, send)
                            try await reloadConversations(database, send)
                        }
                    )
                }
                // With an attachment the bytes go to disk first, then both rows in one transaction,
                // and only then the send — a write failure sends nothing (spec §4 errors).
                let attachmentStore = self.attachmentStore
                let messageHash = msg.hash.hexString
                return .merge(
                    .cancel(id: CancelID.attachmentPreparation),
                    .run { [database] send in
                        let path: String
                        do {
                            path = try attachmentStore.store(pending.data, messageHash: messageHash,
                                                             outgoing: true, ext: pending.format)
                        } catch {
                            AppFeature.inbound.error("attachment send: store failed for \(String(messageHash.prefix(8)), privacy: .public): \(String(describing: error), privacy: .public)")
                            await send(.attachmentSendFailed(draft: text))
                            return
                        }
                        let attachment = Attachment(
                            id: UUID(), messageId: row.id, kind: pending.kind, name: pending.name,
                            format: pending.format, size: pending.data.count,
                            width: pending.width, height: pending.height, path: path)
                        try await database.write { db in
                            try Message.insert { row }.execute(db)
                            try Attachment.insert { attachment }.execute(db)
                        }
                        await send(.node(.client(.sendMessage(message: msg, alsoViaPropagation: alsoViaPropagation))))
                        try await reloadThread(database, peerHex, send)
                        try await reloadConversations(database, send)
                    }
                )
```

- [ ] **Step 6: Run the new tests**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachSend`
Expected: 12 tests PASS. `attachSendStoreFailureSendsNothing` is exhaustive: if it reports an unexpected state change, match the closure to exactly what `sendTapped` and `attachmentSendFailed` mutate (draft cleared then restored, replyTarget stays nil, pendingAttachment, attachmentError) — do not loosen to `.off`. If `attachSendRemoveCancelsAPendingPreparation` fails with an unhandled `attachmentPrepared`, the preparation is not cancellable — fix the reducer, not the test.

- [ ] **Step 7: Mutation batch (five sub-batches)**

Sub-batch A (apply together):
2. `sendTapped` attachment path: delete `try Attachment.insert { attachment }.execute(db)` → RED `attachSendImageWritesRowsFileAndFields`, `attachSendFileWithNoTextIsAllowed`.
3. `sendTapped` guard: `!text.isEmpty || pending != nil` → `!text.isEmpty` → RED `attachSendFileWithNoTextIsAllowed`, `attachSendWithReplyOrdersAttachmentFirst` (draft is "" there too).
5. `AttachmentSizeNote.note`: swap the two thresholds' messages → RED `attachSendSizeNotesAndFormatting`.
6. `.attachmentFailed` case: delete `state.attachmentError = reason` → RED `attachSendUndecodableImageFails`.
7. `sendTapped` guard: delete `!state.attachmentPreparing,` → RED `attachSendGuardsWhilePreparingAndClearsOnClose`.
10. `prepareEffect`: delete `.cancellable(id: CancelID.attachmentPreparation, cancelInFlight: true)` → RED `attachSendRemoveCancelsAPendingPreparation` (the late `attachmentPrepared` fails the exhaustive probe).
11. `.attachmentSendFailed` case: delete `state.draft = draft` → RED `attachSendStoreFailureSendsNothing` (the caption is not restored).
12. `AttachmentPreparation.prepare` file branch: `format: AttachmentWire.fileExtension(name)` → `format: ""` → RED `attachSendPickingAFilePassesThrough` (format "pdf").
13. `sendTapped` text-only `.run`: after `try Message.insert { row }.execute($0)` add `try Attachment.insert { Attachment(id: UUID(), messageId: row.id, kind: AttachmentKind.file, name: "", format: "", size: 0, width: nil, height: nil, path: "") }.execute($0)` → RED `attachSendTextOnlyLeavesNoAttachmentRow`.

Sub-batch B (alone, after A is reverted and green):
1. `sendTapped`: `attachmentFields + replyFields` → `replyFields + attachmentFields` → RED `attachSendWithReplyOrdersAttachmentFirst`. Alone: mutation 3 reddens the same test.

Sub-batch C (alone):
4. `sendTapped` catch: replace the log + `await send(.attachmentSendFailed(draft: text)); return` with `path = ""` (carry on) → RED `attachSendStoreFailureSendsNothing` (a message is sent). Alone: mutation 11 reddens the same test.

Sub-batch D (alone):
8. `AttachmentPreparation.prepare`: `original ? .original : .standard` → `.original` → RED `attachSendPickingAnImagePreparesAStandardJPEG` (width 1600), `attachSendOriginalToggleReencodesFromTheSource` (toggle back stays 1600).

Sub-batch E (alone):
9. `imageName(at:)`: dateFormat → `"'IMG.jpg'"` → RED `attachSendPickingAnImagePreparesAStandardJPEG` (name), `attachSendOriginalToggleReencodesFromTheSource` (name). Alone: mutation 8 reddens the same tests.

Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 8: Full suite, commit**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/att-t7-full.log 2>&1`
Expected: all pass; count = Task 6 count + 12. The existing send tests (`deliveryFailedMarksFailedAndReloads`, `replySendAndFetch`-based tests) are unaffected: the text-only path is the old one plus a `.cancel` effect, which emits no action and changes no state.

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/PendingAttachment.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`

Write `/tmp/ReTiCaMsgr/msg-att-task-7.txt`:

```
feat: send a photo or a file with a message

The composer prepares a picked item off the main thread (photos become
1280 px JPEG, with an Original toggle that re-encodes from the source),
shows size notes, and sendTapped writes the bytes, inserts the message
and attachment rows in one transaction, then sends with the 0x05/0x06
field first. One preparation runs at a time and Remove, leaving the
thread or Send cancel it. A store failure sends nothing, logs the
error, reports it inline and gives the caption back.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments commit -F /tmp/ReTiCaMsgr/msg-att-task-7.txt`

---

### Task 8: Transfer state — progress, cancel, rejected/cancelled, refusal, inbound

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` (state, actions, `CancelID`, the delivery-outcome cases, new delegate cases, `linkClosed`, helpers)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (`makeStore` gains `clock:`; two `tadCompat` expectations change to `cancelled`; tests appended)

**Interfaces:**
- Consumes: ReTiCA `LXMFNode.Action.Delegate.deliveryProgress(messageHash:fraction:)`, `.inboundTransferProgress(sourceHash:linkID:fraction:)`, `.propagationRefused(messageHash:reason:)`, `.deliveryRejected`, `.deliveryCancelled`, `LXMFNode.Action.cancelOutbound(messageHash:)`, `TransportEndpoint.Action.Delegate.linkClosed(linkID:reason:)`; T1 `MessageStatus.cancelled`, `FailureReason`, `PropagationRefusal`.
- Produces: `AppFeature.InboundTransfer { sourceHash: Data?, fraction: Double, updatedAt: Date }`; `State.outgoingProgress: [String: Double]` (by message hash hex, monotonic, cleared by every terminal delivery outcome), `State.inboundTransfers: [Data: InboundTransfer]` (by link ID), computed `inboundTransfersForOpenThread: [InboundTransfer]` (unattributed + attributed to the open peer) and `unattributedInboundTransfers`; `AppFeature.inboundTransferTimeout: Duration = .seconds(60)`; actions `cancelSendTapped(Message.ID)`, `inboundTransferTimedOut(linkID: Data)`; `CancelID.inboundTransfer(Data)`.
- Semantics (spec §3–§4): `propagationRefused`'s text is bound as `let text: String?` (the column is optional and the update subscript takes an optional expression, like `milestoneAt: Date?`); `deliveryCancelled` → status `cancelled` + `failureReason = "cancelled"` with the delivered/stored/outgoing guards and the `failedAt` milestone; `deliveryRejected` → `failed` + `"rejected"`; `deliveryFailed` → `failed`, reason nil; `propagationRefused` → `propagationRefused` column on the outgoing row, status untouched; `cancelSendTapped` sends `cancelOutbound` only for an outgoing `.sending` row with a hash; inbound entries clear at fraction ≥ 1, on `linkClosed`, and after 60 s of silence (the timer restarts on every report).

- [ ] **Step 1: `makeStore` accepts a clock; two expectations move to `cancelled`**

In `makeStore` add a parameter after `attachmentStore`:

```swift
                       clock: TestClock<Duration>? = nil,
```

and replace `$0.continuousClock = TestClock()` with `$0.continuousClock = clock ?? TestClock()`.

In `tadCompatDeliveryCancelledMarksFailedAndRecordsFailedAt`, change `#expect(row?.status == MessageStatus.failed)` to `#expect(row?.status == MessageStatus.cancelled)` and rename the test to `tadCompatDeliveryCancelledMarksCancelledAndRecordsFailedAt`. In `tadCompatRejectedThenCancelledBothReachTheFailureMarkingCode`, change the final expectation to `#expect(rows["\(shared)/out"]?.status == MessageStatus.cancelled)`. These are the only existing expectations that change (they were written when cancelled shared the failed status).

Update the doc comments to match:
- Above `tadCompatDeliveryRejectedMarksFailedAndRecordsFailedAt`, replace the two lines with:
  ```swift
  /// A message the recipient refused will never go out: it must leave "sending" for "failed" and
  /// record when, exactly like `deliveryFailed`. (A cancelled one leaves it for "cancelled" — next.)
  ```
- Above the renamed `tadCompatDeliveryCancelledMarksCancelledAndRecordsFailedAt` (it has none today), add:
  ```swift
  /// A message the user cancelled will never go out either: it must leave "sending" for its own
  /// "cancelled" status and still record `failedAt`, like `deliveryFailed`.
  ```
- Above `tadCompatRejectedThenCancelledBothReachTheFailureMarkingCode`, change `the outgoing "sending" row flips to "failed"` to `the outgoing "sending" row flips to "cancelled"`.

- [ ] **Step 2: Write the failing tests**

Append to `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`:

```swift

// MARK: - Attachments: transfer state (spec 2026-09-28 §3–§4)

private let linkL = Data(repeating: 0x4C, count: 16)
private let linkM = Data(repeating: 0x4D, count: 16)

private func progress(_ hex: String, _ fraction: Double) -> AppFeature.Action {
    .node(.client(.delegate(.deliveryProgress(messageHash: hashData(hex), fraction: fraction))))
}

private func inbound(_ link: Data, _ fraction: Double, source: Data? = nil) -> AppFeature.Action {
    .node(.client(.delegate(.inboundTransferProgress(sourceHash: source, linkID: link, fraction: fraction))))
}

/// Review Focus 5: never backwards, and every terminal outcome clears the bar — including the two
/// new ones. `propagationAccepted` is not terminal for the delivery copy and leaves it alone.
@MainActor @Test func attachTransferProgressIsMonotonicAndClearedByEveryTerminal() async {
    let db = try! AppDatabase.makeInMemory()
    let h = (1...5).map { String(repeating: "7\($0)", count: 16) }
    try! await seed(db, h.enumerated().map { i, hash in msg(i + 1, peerA, "m", 1000, status: MessageStatus.sending, hash: hash) })
    let store = makeStore(db, identity: Identity())
    await store.send(progress(h[0], 0.05))
    await store.send(progress(h[0], 0.5))
    await store.send(progress(h[0], 0.3))    // late/lower: ignored
    #expect(store.state.outgoingProgress[h[0]] == 0.5)
    await store.send(progress(h[0], 1.7))    // clamped
    #expect(store.state.outgoingProgress[h[0]] == 1.0)
    for hash in h.dropFirst() { await store.send(progress(hash, 0.4)) }
    #expect(store.state.outgoingProgress.count == 5)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(h[0]))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(h[1]))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(h[2]))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryCancelled(messageHash: hashData(h[3]))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(h[4]))))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.outgoingProgress == [h[4]: 0.4])
}

@MainActor @Test func attachTransferCancelledStatusReasonAndGuards() async {
    let db = try! AppDatabase.makeInMemory()
    let sending = String(repeating: "81", count: 16)
    let delivered = String(repeating: "82", count: 16)
    let shared = String(repeating: "83", count: 16)
    try! await seed(db, [
        msg(1, peerA, "s", 1000, status: MessageStatus.sending, hash: sending),
        msg(2, peerA, "d", 1000, status: MessageStatus.delivered, hash: delivered),
        msg(3, peerA, "out", 1000, outgoing: true, status: MessageStatus.sending, hash: shared),
        msg(4, peerA, "in", 1000, outgoing: false, status: MessageStatus.received, hash: shared),
    ])
    let store = makeStore(db, identity: Identity())
    for hash in [sending, delivered, shared] {
        await sendAndSettle(store, .node(.client(.delegate(.deliveryCancelled(messageHash: hashData(hash))))))
    }
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(sending)/out"]?.status == MessageStatus.cancelled)
    #expect(rows["\(sending)/out"]?.failureReason == FailureReason.cancelled)
    #expect(rows["\(sending)/out"]?.failedAt == infoT0)
    #expect(rows["\(delivered)/out"]?.status == MessageStatus.delivered)     // never downgraded
    #expect(rows["\(delivered)/out"]?.failureReason == nil)
    #expect(rows["\(shared)/out"]?.status == MessageStatus.cancelled)
    #expect(rows["\(shared)/in"]?.status == MessageStatus.received)          // incoming untouched
    #expect(rows["\(shared)/in"]?.failureReason == nil)
}

@MainActor @Test func attachTransferRejectedAndFailedReasons() async {
    let db = try! AppDatabase.makeInMemory()
    let rejected = String(repeating: "84", count: 16)
    let failed = String(repeating: "85", count: 16)
    try! await seed(db, [
        msg(1, peerA, "r", 1000, status: MessageStatus.sending, hash: rejected),
        msg(2, peerA, "f", 1000, status: MessageStatus.sending, hash: failed),
    ])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(rejected))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(failed))))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(rejected)/out"]?.status == MessageStatus.failed)
    #expect(rows["\(rejected)/out"]?.failureReason == FailureReason.rejected)
    #expect(rows["\(failed)/out"]?.status == MessageStatus.failed)
    #expect(rows["\(failed)/out"]?.failureReason == nil)
}

@MainActor @Test func attachTransferPropagationRefusedRecordsTheReason() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "86", count: 16)
    try! await seed(db, [
        msg(1, peerA, "big", 1000, status: MessageStatus.sending, hash: h),
        msg(2, peerA, "in", 1000, outgoing: false, status: MessageStatus.received, hash: h),
    ])
    let store = makeStore(db, identity: Identity()) { s in s.openPeerHex = peerA }
    await sendAndSettle(store, .node(.client(.delegate(.propagationRefused(messageHash: hashData(h), reason: .tooLargeForNode)))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(h)/out"]?.propagationRefused == PropagationRefusal.tooLargeForNode)
    #expect(rows["\(h)/out"]?.status == MessageStatus.sending)   // the direct copy is still going
    #expect(rows["\(h)/in"]?.propagationRefused == nil)
    // The open thread reloaded so the Info sheet sees it.
    #expect(store.state.threadMessages.first { $0.isOutgoing }?.propagationRefused == PropagationRefusal.tooLargeForNode)
}

@MainActor @Test func attachTransferCancelSendsCancelOutbound() async {
    let h = String(repeating: "87", count: 16)
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.threadMessages = [msg(1, peerA, "big", 1000, status: MessageStatus.sending, hash: h)]
    }
    await store.send(.cancelSendTapped(uuid(1)))
    await store.receive(.node(.client(.cancelOutbound(messageHash: hashData(h)))))
}

/// Review Focus 6: only an outgoing message still sending, with a hash, can be cancelled.
@MainActor @Test func attachTransferCancelIsIgnoredUnlessSending() async {
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in
        s.openPeerHex = peerA
        s.threadMessages = [
            msg(1, peerA, "done", 1000, status: MessageStatus.delivered, hash: String(repeating: "88", count: 16)),
            msg(2, peerA, "theirs", 1000, outgoing: false, status: MessageStatus.received, hash: String(repeating: "89", count: 16)),
            msg(3, peerA, "legacy", 1000, status: MessageStatus.sending, hash: ""),
            msg(4, peerA, "failed", 1000, status: MessageStatus.failed, hash: String(repeating: "8a", count: 16)),
        ]
    }
    store.exhaustivity = .on
    for id in [1, 2, 3, 4, 99] {
        await store.send(.cancelSendTapped(uuid(id)))
    }
    await store.send(.replyCancelled)   // probe: nothing was sent to the node
    store.exhaustivity = .off
}

@MainActor @Test func attachTransferInboundEntryTracksLinksAndAttribution() async {
    let peerHash = hashData(peerA)
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity()) { s in s.openPeerHex = peerA }
    await store.send(inbound(linkL, 0.3))
    #expect(store.state.inboundTransfers[linkL] == AppFeature.InboundTransfer(sourceHash: nil, fraction: 0.3, updatedAt: infoT0))
    await store.send(inbound(linkL, 0.7))
    #expect(store.state.inboundTransfers[linkL]?.fraction == 0.7)
    await store.send(inbound(linkM, 0.1, source: peerHash))
    await store.send(inbound(Data(repeating: 0x4E, count: 16), 0.2, source: hashData(peerB)))
    // The open thread shows the unattributed one and the one attributed to its peer, not peerB's.
    #expect(store.state.inboundTransfersForOpenThread.map(\.fraction).sorted() == [0.1, 0.7])
    #expect(store.state.unattributedInboundTransfers.map(\.fraction) == [0.7])
    // Done: the entry goes away.
    await store.send(inbound(linkL, 1.0))
    #expect(store.state.inboundTransfers[linkL] == nil)
    #expect(store.state.inboundTransfers.count == 2)
    // A closed link clears its entry too.
    await store.send(.node(.client(.endpoint(.delegate(.linkClosed(linkID: linkM, reason: .timedOut))))))
    #expect(store.state.inboundTransfers[linkM] == nil)
    #expect(store.state.inboundTransfers.count == 1)
}

/// Review Focus 7: a transfer that stops reporting disappears after 60 s of silence; a report
/// restarts the clock.
@MainActor @Test func attachTransferInboundEntryExpiresAfterSilence() async {
    let clock = TestClock()
    let store = makeStore(try! AppDatabase.makeInMemory(), identity: Identity(), clock: clock)
    await store.send(inbound(linkL, 0.3))
    await clock.advance(by: .seconds(59))
    await store.send(inbound(linkL, 0.4))          // restarts the 60 s
    // Exhaustive window: 59 s after the restart (118 s after the first report) nothing may fire.
    // A timer that was NOT restarted fires at 60 s from the first report, inside this window, and
    // its `inboundTransferTimedOut` fails the probe. (Under `.off`, a bare `store.state` check here
    // would assert nothing: state lags until a receive.)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(59))
    await store.send(.replyCancelled)              // probe
    store.exhaustivity = .off
    await clock.advance(by: .seconds(1))
    await store.receive(.inboundTransferTimedOut(linkID: linkL))
    #expect(store.state.inboundTransfers[linkL] == nil)
    // Completion cancels the timer: nothing fires later.
    await store.send(inbound(linkM, 0.5))
    await store.send(inbound(linkM, 1.0))
    store.exhaustivity = .on
    await clock.advance(by: .seconds(120))
    await store.send(.replyCancelled)   // probe
    store.exhaustivity = .off
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachTransfer`
Expected: compile errors (`outgoingProgress`, `InboundTransfer`, `cancelSendTapped` unknown).

- [ ] **Step 4: State, actions, cancel id**

In `AppFeature`, after the `ReplyTarget` struct add:

```swift
    /// A Resource arriving on one link (spec 2026-09-28 §4). `sourceHash` is the peer when we
    /// opened the link, nil when a peer linked to our own destination (the sender is unknown until
    /// the message unpacks), so the UI shows an unattributed one everywhere.
    public struct InboundTransfer: Equatable, Sendable {
        public var sourceHash: Data?
        public var fraction: Double
        public var updatedAt: Date

        public init(sourceHash: Data?, fraction: Double, updatedAt: Date) {
            self.sourceHash = sourceHash
            self.fraction = fraction
            self.updatedAt = updatedAt
        }
    }

    /// An inbound transfer that stops reporting for this long is dropped from the UI.
    public static let inboundTransferTimeout: Duration = .seconds(60)
```

In `State`, after `attachmentError` add:

```swift
        /// Outgoing transfer progress by message hash hex, from `deliveryProgress`: monotonic, and
        /// cleared by every terminal delivery outcome. Session-only.
        public var outgoingProgress: [String: Double] = [:]
        /// Inbound transfers by link ID, from `inboundTransferProgress`. Session-only.
        public var inboundTransfers: [Data: InboundTransfer] = [:]

        /// Transfers to show in the open thread: the unattributed ones, plus those attributed to
        /// the open peer.
        public var inboundTransfersForOpenThread: [InboundTransfer] {
            let open = openPeerHex.flatMap { Data(hexString: $0) }
            return inboundTransfers.values.filter { $0.sourceHash == nil || $0.sourceHash == open }
        }

        /// Transfers nobody can be named for, shown on the conversation list.
        public var unattributedInboundTransfers: [InboundTransfer] {
            inboundTransfers.values.filter { $0.sourceHash == nil }
        }
```

In `Action`, after `attachmentOriginalToggled` add:

```swift
        /// Long-press → Cancel Send on an outgoing message still sending.
        case cancelSendTapped(Message.ID)
        /// The 60 s silence timer for one inbound transfer fired. Internal.
        case inboundTransferTimedOut(linkID: Data)
```

In `CancelID` add:

```swift
        /// The silence timer of one inbound transfer, keyed by link ID.
        case inboundTransfer(Data)
```

- [ ] **Step 5: Delivery outcomes**

Replace the merged `deliveryFailed`/`deliveryRejected`/`deliveryCancelled` case with three cases:

```swift
            case let .node(.client(.delegate(.deliveryFailed(hash)))):
                return markUndeliverable(&state, hash, status: MessageStatus.failed, reason: nil)

            case let .node(.client(.delegate(.deliveryRejected(hash)))):
                // The recipient refused the transfer: terminal, styled as failed with a reason.
                return markUndeliverable(&state, hash, status: MessageStatus.failed, reason: FailureReason.rejected)

            case let .node(.client(.delegate(.deliveryCancelled(hash)))):
                // The user stopped the send: its own status, same guards and milestone as failed.
                return markUndeliverable(&state, hash, status: MessageStatus.cancelled, reason: FailureReason.cancelled)
```

Add a private method on `AppFeature` (after `body`, inside the struct):

```swift
    /// A message that will not go out: `failed` or `cancelled`, with the reason the Info sheet
    /// shows. The status guards keep a stored or delivered row as it is (a success is never
    /// clobbered), `messageHash` alone is not unique (an incoming row can share it) so only
    /// outgoing rows are touched, and `failedAt` records the FIRST failure time only.
    private func markUndeliverable(_ state: inout State, _ hash: Data, status: String, reason: String?) -> Effect<Action> {
        let hex = hash.hexString
        state.outgoingProgress[hex] = nil
        let openPeer = state.openPeerHex
        let milestoneAt: Date? = date.now
        return .run { [database] send in
            try await database.write { db in
                try Message.where {
                    $0.messageHash.eq(hex)
                        && $0.status.neq(MessageStatus.propagated)
                        && $0.status.neq(MessageStatus.delivered)
                        && $0.isOutgoing
                }
                    .update {
                        $0.status = status
                        $0.failureReason = reason
                    }
                    .execute(db)
                try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing && $0.failedAt.is(nil) }
                    .update { $0.failedAt = milestoneAt }
                    .execute(db)
            }
            try await reloadConversations(database, send)
            if let openPeer {
                try await reloadThread(database, openPeer, send)
            }
        }
    }
```

In `.deliveryConfirmed`, after `let hex = hash.hexString` add `state.outgoingProgress[hex] = nil`.

- [ ] **Step 6: Progress, refusal, cancel, inbound**

Add these cases before `case .node, .binding:`:

```swift
            case let .node(.client(.delegate(.deliveryProgress(hash, fraction)))):
                // Monotonic per message: a retry restarts the wire transfer, the bar does not.
                let hex = hash.hexString
                let clamped = min(max(fraction, 0), 1)
                state.outgoingProgress[hex] = max(state.outgoingProgress[hex] ?? 0, clamped)
                return .none

            case let .node(.client(.delegate(.propagationRefused(hash, reason)))):
                // The propagated copy was never sent; the direct copy decides the message. Recorded
                // for the Info sheet so "stored" never arriving has an explanation.
                let hex = hash.hexString
                // Optional on purpose: the column is `String?`, and structured-queries' update
                // subscript takes an optional expression (the `milestoneAt: Date?` pattern).
                let text: String?
                switch reason {
                case .tooLargeForNode: text = PropagationRefusal.tooLargeForNode
                }
                let openPeer = state.openPeerHex
                return .run { [database] send in
                    try await database.write { db in
                        try Message.where { $0.messageHash.eq(hex) && $0.isOutgoing }
                            .update { $0.propagationRefused = text }
                            .execute(db)
                    }
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                }

            case let .cancelSendTapped(id):
                // Only our own message, still sending, with a hash the node can act on.
                guard let message = state.threadMessages.first(where: { $0.id == id }),
                      message.isOutgoing, message.status == MessageStatus.sending,
                      let hash = Data(hexString: message.messageHash), !hash.isEmpty
                else { return .none }
                return .send(.node(.client(.cancelOutbound(messageHash: hash))))

            case let .node(.client(.delegate(.inboundTransferProgress(sourceHash, linkID, fraction)))):
                if fraction >= 1 {
                    state.inboundTransfers[linkID] = nil
                    return .cancel(id: CancelID.inboundTransfer(linkID))
                }
                state.inboundTransfers[linkID] = InboundTransfer(sourceHash: sourceHash, fraction: fraction, updatedAt: date.now)
                // Review Focus 7: every report restarts the silence timer.
                return .run { [clock] send in
                    try await clock.sleep(for: AppFeature.inboundTransferTimeout)
                    await send(.inboundTransferTimedOut(linkID: linkID))
                }
                .cancellable(id: CancelID.inboundTransfer(linkID), cancelInFlight: true)

            case let .inboundTransferTimedOut(linkID):
                state.inboundTransfers[linkID] = nil
                return .none
```

Replace the existing `linkClosed` case with:

```swift
            case let .node(.client(.endpoint(.delegate(.linkClosed(linkID, _))))):
                // An inbound transfer on this link is over, one way or the other.
                var effects: [Effect<Action>] = []
                if state.inboundTransfers.removeValue(forKey: linkID) != nil {
                    effects.append(.cancel(id: CancelID.inboundTransfer(linkID)))
                }
                // The link went away while a public-key request was in flight. LinkSession's close
                // path only CANCELS the pending request deadlines — it emits no requestFailed — so
                // without this a closed link would leave the row stuck on "requesting" forever.
                if let hex = state.publicKeyRequestLinks[linkID],
                   state.publicKeyRequests[hex] == .requesting {
                    state.publicKeyRequestLinks[linkID] = nil
                    state.publicKeyRequests[hex] = .failed(reason: "link closed")
                }
                return .merge(effects)
```

- [ ] **Step 7: Run the new tests**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore --filter attachTransfer --filter tadCompat --filter linkClosed --filter PublicKey`
Expected: the 8 new tests PASS, the two edited `tadCompat` tests PASS, and the existing link-close and public-key tests (`linkClosedMarksInFlightRequestFailed` and the `*PublicKey*` tests — the filter is case-sensitive) still pass (the `linkClosed` restructure is behaviour-preserving for them).

- [ ] **Step 8: Mutation batch (six sub-batches)**

Sub-batch A (apply together):
1. `deliveryProgress`: `max(state.outgoingProgress[hex] ?? 0, clamped)` → `clamped` → RED `attachTransferProgressIsMonotonicAndClearedByEveryTerminal` (0.3 lands).
2. `markUndeliverable`: delete `$0.failureReason = reason` → RED `attachTransferCancelledStatusReasonAndGuards`, `attachTransferRejectedAndFailedReasons`.
3. `propagationRefused`: `$0.messageHash.eq(hex) && $0.isOutgoing` → `$0.messageHash.eq(hex)` → RED `attachTransferPropagationRefusedRecordsTheReason` (the incoming row is written too).
4. `cancelSendTapped`: delete `message.status == MessageStatus.sending,` → RED `attachTransferCancelIsIgnoredUnlessSending` (the delivered and failed rows send a cancel).
5. `inboundTransferProgress`: `if fraction >= 1` → `if fraction >= 2` → RED `attachTransferInboundEntryTracksLinksAndAttribution` (1.0 keeps the entry) and `attachTransferInboundEntryExpiresAfterSilence` (the linkM timer fires).

Sub-batch B (alone, after A is reverted and green):
6. `inboundTransfersForOpenThread`: `$0.sourceHash == nil || $0.sourceHash == open` → `$0.sourceHash == nil` → RED `attachTransferInboundEntryTracksLinksAndAttribution`. Not in A: mutation 5 reddens the same test.

Sub-batch C (apply together):
7. `deliveryCancelled` case: `status: MessageStatus.cancelled` → `MessageStatus.failed` → RED `attachTransferCancelledStatusReasonAndGuards`, `tadCompatDeliveryCancelledMarksCancelledAndRecordsFailedAt`, `tadCompatRejectedThenCancelledBothReachTheFailureMarkingCode`.
11. `cancelSendTapped`: replace the whole case body with `return .none` → RED `attachTransferCancelSendsCancelOutbound` (no `cancelOutbound` to receive), and nothing else. Not in A: it would make mutation 4 inert. Neither 7 nor 11 touches the other's tests.

Sub-batch D (apply together):
8. `inboundTransferProgress`: remove `.cancellable(id: CancelID.inboundTransfer(linkID), cancelInFlight: true)` → RED `attachTransferInboundEntryExpiresAfterSilence` (the first timer fires at 60 s inside the exhaustive window, and the completed linkM's timer fires before the final probe).
9. `linkClosed`: delete the `inboundTransfers.removeValue` block → RED `attachTransferInboundEntryTracksLinksAndAttribution`. (Masked by 5 in A; observed here.)

Sub-batch E (alone):
10. `markUndeliverable`: delete `state.outgoingProgress[hex] = nil` and the same line in `deliveryConfirmed` → RED `attachTransferProgressIsMonotonicAndClearedByEveryTerminal`. (Masked by 1 in A; observed here.)

Sub-batch F (alone):
12. `inboundTransferProgress`: `.cancellable(id: CancelID.inboundTransfer(linkID), cancelInFlight: true)` → `cancelInFlight: false` → RED `attachTransferInboundEntryExpiresAfterSilence` (the first report's timer is not restarted and fires at t = 60, inside the exhaustive window). This pins "a report restarts the timer" on its own; mutation 8 also removes the completion cancel.

Run A to F in order, reverting and re-greening between them. Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 9: Full suite, commit**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/att-t8-full.log 2>&1`
Expected: all pass; count = Task 7 count + 8.

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`

Write `/tmp/ReTiCaMsgr/msg-att-task-8.txt`:

```
feat: transfer progress, cancel, and the rejected and cancelled outcomes

deliveryProgress feeds a monotonic per-message bar that every terminal
outcome clears, deliveryCancelled gets its own cancelled status and
deliveryRejected a reason, propagationRefused is recorded for the Info
sheet, Cancel Send forwards cancelOutbound for a message still sending,
and inbound transfers are tracked per link, attributed when the link
is ours, and dropped at completion, link close, or 60 s of silence.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments commit -F /tmp/ReTiCaMsgr/msg-att-task-8.txt`

---
### Task 9: The views — composer, bubbles, viewer, QuickLook, progress, capsule

**Files (app target `APP/ReTiCaMsgr/`, synchronized folder — no pbxproj edit):**
- Create: `AttachmentPicker.swift`
- Create: `AttachmentViews.swift`
- Modify: `ChatView.swift` (composer, bubble slot, context menu, capsule, sheets)
- Modify: `MessageInfoSheet.swift` (pass the attachment)
- Modify: `ConversationListView.swift` (toolbar capsule)

**Interfaces:**
- Consumes: everything Tasks 1–8 produce through `StoreOf<AppFeature>` (`pendingAttachment`, `attachmentPreparing`, `attachmentError`, `attachmentsByMessageId`, `outgoingProgress`, `inboundTransfersForOpenThread`, `unattributedInboundTransfers`, actions `attachmentPicked`, `attachmentFailed`, `attachmentRemoved`, `attachmentOriginalToggled`, `cancelSendTapped`), `AttachmentStore` via `@Dependency(\.attachmentStore)` (`url(for:)`, and `exportURL(for:)` for the share sheet and QuickLook, falling back to the stored URL on error), `AttachmentSizeNote`, `AttachmentPlaceholder`, `MessageInfo.sections(for:attachment:)`, `ReplyPreview.resolve(for:in:peerName:attachments:)` (passed `store.attachmentsByMessageId`).
- Decisions carried from the pre-flight rulings: the viewer is a `.fullScreenCover` that ALSO dismisses on a downward drag of more than 120 pt at zoom 1 (spec §4 swipe-down); a file row says "Attachment could not be saved" when `path == ""` and "Attachment unavailable" when the file is missing on disk (checked off the main thread in a `.task`); `fileImporter` reads the bytes in `Task.detached` and hops back to the main actor to call `onPicked`; every picker `catch` logs the error before showing the user text; `ThumbnailCache` has ONE private decode path; the pending preview is keyed `"pending-\(name)-\(size)-\(isOriginal)"` (not `Data.hashValue`, which hashes only the first 80 bytes).
- Produces: nothing new for the core. No unit tests (views are not unit-tested in this app); verification is the app-target build plus the manual checklist in Step 8.

- [ ] **Step 1: `AttachmentPicker.swift`**

Create `APP/ReTiCaMsgr/AttachmentPicker.swift`:

```swift
//
//  AttachmentPicker.swift
//  ReTiCaMsgr
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import os
import ReTiCaMsgrCore

/// The paperclip beside the text field: Photo Library (one image) or Document (one file). Reads
/// the picker's bytes here — `fileImporter` hands over a security-scoped URL only the view can
/// open — and hands a `PickedItem` to the store, which prepares it off the main thread.
struct AttachmentPickerButton: View {
    let onPicked: (PickedItem) -> Void
    let onFailed: (String) -> Void

    private static let log = Logger(subsystem: "com.reticamsgr", category: "attachments")

    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var showingFiles = false

    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showingPhotos = true }
            Button("Document", systemImage: "doc") { showingFiles = true }
        } label: {
            Image(systemName: "paperclip")
                .font(.title3)
                // UI rule: a 44 pt hit area, all of it tappable.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Attach")
        .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        Self.log.error("photo pick: loadTransferable returned no data")
                        onFailed("Couldn't read that photo")
                        return
                    }
                    onPicked(PickedItem(kind: AttachmentKind.image, name: "", data: data))
                } catch {
                    Self.log.error("photo pick failed: \(String(describing: error), privacy: .public)")
                    onFailed("Couldn't read that photo")
                }
            }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item]) { result in
            switch result {
            case let .success(url):
                // The read happens off the main thread (a document can be large); the Task inherits
                // the view's main-actor isolation, so `onPicked` / `onFailed` run back on it.
                Task {
                    let read = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return Result { try Data(contentsOf: url) }
                    }.value
                    switch read {
                    case let .success(data):
                        onPicked(PickedItem(kind: AttachmentKind.file, name: url.lastPathComponent, data: data))
                    case let .failure(error):
                        Self.log.error("file import read failed: \(String(describing: error), privacy: .public)")
                        onFailed("Couldn't read that file")
                    }
                }
            case let .failure(error):
                Self.log.error("file import failed: \(String(describing: error), privacy: .public)")
                onFailed("Couldn't read that file")
            }
        }
    }
}
```

- [ ] **Step 2: `AttachmentViews.swift`**

Create `APP/ReTiCaMsgr/AttachmentViews.swift`:

```swift
//
//  AttachmentViews.swift
//  ReTiCaMsgr
//

import SwiftUI
import UIKit
import ImageIO
import ReTiCaMsgrCore

// MARK: - Thumbnails

/// Decodes images at a capped pixel size off the main thread and keeps them in memory. Keyed by
/// attachment id (or the pending attachment's name, size and preset) plus the size, so a
/// thumbnail and the viewer's larger decode of the same file do not collide.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for url: URL, key: String, maxPixels: Int) async -> UIImage? {
        await image(key: key, maxPixels: maxPixels) { CGImageSourceCreateWithURL(url as CFURL, nil) }
    }

    func image(for data: Data, key: String, maxPixels: Int) async -> UIImage? {
        await image(key: key, maxPixels: maxPixels) { CGImageSourceCreateWithData(data as CFData, nil) }
    }

    /// The one decode path: cache lookup, then the source is opened and decoded off the main thread.
    private func image(key: String, maxPixels: Int,
                       source: @escaping @Sendable () -> CGImageSource?) async -> UIImage? {
        let cacheKey = "\(key)/\(maxPixels)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let src = source() else { return nil }
            return Self.decode(src, maxPixels: maxPixels)
        }.value
        if let decoded { cache.setObject(decoded, forKey: cacheKey) }
        return decoded
    }

    nonisolated private static func decode(_ source: CGImageSource, maxPixels: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCache: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// An attachment's thumbnail, sized from the stored dimensions so the bubble does not jump when
/// the decode lands. `url == nil` means the bytes were never written; a missing file means they
/// were removed since.
struct AttachmentThumbnail: View {
    static let maxWidth: CGFloat = 240
    static let maxHeight: CGFloat = 320
    static let decodePixels = 640

    let attachment: Attachment
    let url: URL?
    @State private var image: UIImage?
    @State private var failed = false

    private var displaySize: CGSize {
        let w = CGFloat(attachment.width ?? 4), h = CGFloat(attachment.height ?? 3)
        let scale = min(Self.maxWidth / w, Self.maxHeight / h, 1)
        return CGSize(width: max(w * scale, 80), height: max(h * scale, 60))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
                if url == nil {
                    Label("Attachment could not be saved", systemImage: "exclamationmark.triangle")
                        .font(.caption).padding(8)
                } else if failed {
                    Label("Attachment unavailable", systemImage: "photo")
                        .font(.caption).padding(8)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: attachment.id) {
            guard let url else { return }
            let decoded = await ThumbnailCache.shared.image(for: url, key: attachment.id.uuidString, maxPixels: Self.decodePixels)
            image = decoded
            failed = decoded == nil
        }
        .accessibilityLabel(attachment.isImage ? "Photo" : attachment.name)
    }
}

// MARK: - Bubble slot

/// What sits above the caption in a bubble: the thumbnail or the file row, then the progress bar
/// while the message is still sending.
struct AttachmentBubbleSlot: View {
    let attachment: Attachment
    let url: URL?
    let progress: Double?
    let onOutgoingBubble: Bool
    var onTapImage: (() -> Void)? = nil
    var onTapFile: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if attachment.isImage {
                Button { onTapImage?() } label: {
                    AttachmentThumbnail(attachment: attachment, url: url)
                }
                .buttonStyle(.plain)
                .disabled(onTapImage == nil || url == nil)
            } else {
                FileAttachmentRow(attachment: attachment, url: url, onOutgoingBubble: onOutgoingBubble,
                                  onTap: onTapFile)
            }
            if let progress {
                TransferProgressBar(fraction: progress, onOutgoingBubble: onOutgoingBubble)
            }
        }
    }
}

/// A file attachment: icon, name, and size — or why it cannot be opened. `url == nil` means the
/// bytes were never written ("could not be saved"); a URL whose file is gone from disk means they
/// were removed since ("unavailable"). Either way the row is not tappable.
struct FileAttachmentRow: View {
    let attachment: Attachment
    let url: URL?
    let onOutgoingBubble: Bool
    var onTap: (() -> Void)? = nil
    @State private var missing = false

    private var status: String {
        if url == nil { return "Attachment could not be saved" }
        if missing { return "Attachment unavailable" }
        return AttachmentSizeNote.formattedSize(attachment.size)
    }

    var body: some View {
        Button { onTap?() } label: {
            HStack(spacing: 10) {
                Image(systemName: (url == nil || missing) ? "doc.badge.ellipsis" : "doc.fill")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(status)
                        .font(.caption)
                        .opacity(0.8)
                }
            }
            .padding(8)
            // UI rule: the whole row is the tap target.
            .frame(minWidth: 160, maxWidth: AttachmentThumbnail.maxWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(onOutgoingBubble ? Color.white.opacity(0.2) : Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil || url == nil || missing)
        .accessibilityElement(children: .combine)
        .task(id: attachment.id) {
            guard let url else { return }
            let path = url.path()
            missing = await Task.detached { !FileManager.default.fileExists(atPath: path) }.value
        }
    }
}

/// Thin bar under an attachment while its message is sending: indeterminate until the transfer
/// has started (ReTiCA reports 0.05 for "link active", 0.10 at transfer start), then the fraction.
struct TransferProgressBar: View {
    let fraction: Double
    let onOutgoingBubble: Bool

    var body: some View {
        Group {
            if fraction < 0.10 {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }
        }
        .tint(onOutgoingBubble ? .white : .accentColor)
        .frame(maxWidth: AttachmentThumbnail.maxWidth)
        .accessibilityLabel(fraction < 0.10 ? "Waiting for link" : "Sending \(Int(fraction * 100)) percent")
    }
}

// MARK: - Inbound capsule

/// "Receiving… 43%" for transfers on their way in. Shows the lowest fraction when several run.
struct ReceivingCapsule: View {
    let transfers: [AppFeature.InboundTransfer]

    var body: some View {
        if !transfers.isEmpty {
            let lowest = transfers.map(\.fraction).min() ?? 0
            let label = transfers.count == 1
                ? "Receiving… \(Int(lowest * 100))%"
                : "Receiving \(transfers.count)… \(Int(lowest * 100))%"
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(label).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .accessibilityLabel(label)
        }
    }
}

// MARK: - Composer bar

/// The pending attachment above the text field: preview, name · size, size note, Original toggle
/// for a photo, and × to remove. Also shows the preparing spinner and the last error.
struct AttachmentComposerBar: View {
    let pending: PendingAttachment?
    let preparing: Bool
    let error: String?
    let onRemove: () -> Void
    let onOriginalToggled: (Bool) -> Void

    @State private var preview: UIImage?

    /// The pending preview's cache key: name, size and preset identify one encode (a toggle
    /// changes the preset, a new pick the name or size). `Data.hashValue` would hash only the
    /// first 80 bytes, which two JPEGs with the same headers share.
    private var previewKey: String? {
        pending.map { "pending-\($0.name)-\($0.size)-\($0.isOriginal)" }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            previewView
            VStack(alignment: .leading, spacing: 2) {
                if let pending {
                    Text(pending.name).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(AttachmentSizeNote.formattedSize(pending.size)).font(.caption).foregroundStyle(.secondary)
                    if let note = AttachmentSizeNote.note(for: pending.size) {
                        Text(note).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    }
                    if pending.isImage, pending.originalSource != nil {
                        Toggle("Original", isOn: Binding(get: { pending.isOriginal }, set: onOriginalToggled))
                            .font(.caption)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .disabled(preparing)
                    }
                } else if preparing {
                    Text("Preparing…").font(.caption).foregroundStyle(.secondary)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.top, 4)
        .task(id: previewKey) {
            preview = nil
            guard let pending, pending.isImage, let previewKey else { return }
            preview = await ThumbnailCache.shared.image(for: pending.data, key: previewKey, maxPixels: 160)
        }
    }

    @ViewBuilder
    private var previewView: some View {
        if preparing {
            ProgressView().frame(width: 48, height: 48)
        } else if let preview {
            Image(uiImage: preview).resizable().scaledToFill()
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
        } else if pending != nil {
            Image(systemName: "doc.fill").font(.title).frame(width: 48, height: 48)
        } else {
            Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.red).frame(width: 48, height: 48)
        }
    }
}

// MARK: - Viewer

/// Full-screen photo: pinch to zoom, share, done, or swipe down (at zoom 1) to dismiss. Decodes at
/// most 2048 px on the long edge. `shareURL` is the copy under the attachment's real name
/// (`AttachmentStore.exportURL`), or the stored file if that copy failed.
struct ImageViewerSheet: View {
    static let dismissDragDistance: CGFloat = 120

    let attachment: Attachment
    let url: URL
    let shareURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: UIScreen.main.bounds.width * zoom)
                    }
                    .offset(y: dragOffset)
                    .gesture(MagnifyGesture()
                        .onChanged { value in zoom = min(max(lastZoom * value.magnification, 1), 5) }
                        .onEnded { _ in lastZoom = zoom })
                    // Spec §4: swipe down to dismiss — only at zoom 1, where a drag is not a pan.
                    .simultaneousGesture(DragGesture()
                        .onChanged { value in
                            guard zoom == 1 else { return }
                            dragOffset = max(value.translation.height, 0)
                        }
                        .onEnded { value in
                            guard zoom == 1 else { return }
                            if value.translation.height > Self.dismissDragDistance {
                                dismiss()
                            } else {
                                withAnimation(.spring) { dragOffset = 0 }
                            }
                        })
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: shareURL, preview: SharePreview(attachment.name))
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task(id: attachment.id) {
            image = await ThumbnailCache.shared.image(for: url, key: attachment.id.uuidString, maxPixels: 2048)
        }
    }
}
```

- [ ] **Step 3: `ChatView.swift`**

Replace the whole file with:

```swift
//
//  ChatView.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import UIKit
import QuickLook
import os
import ComposableArchitecture
import ReTiCaMsgrCore

struct ChatView: View {
    private static let log = Logger(subsystem: "com.reticamsgr", category: "attachments")

    @Bindable var store: StoreOf<AppFeature>
    @Dependency(\.attachmentStore) private var attachmentStore
    @State private var pickerTarget: PickerTarget?
    @State private var infoTarget: InfoTarget?
    @State private var viewerTarget: ViewerTarget?
    /// A file to open in QuickLook (the system preview with share / save to Files).
    @State private var quickLookURL: URL?
    /// The bubble briefly outlined after a quote tap scrolled to it.
    @State private var highlightedMessageID: Message.ID?
    /// Bumped per quote tap, so only the latest tap's timer clears the highlight.
    @State private var highlightGeneration = 0
    @FocusState private var draftFocused: Bool

    private var peerReachable: Bool {
        guard let peer = store.openPeerHex else { return false }
        return store.reachablePeers.contains(peer)
    }

    /// Text or an attachment, once the attachment is ready.
    private var canSend: Bool {
        peerReachable && !store.attachmentPreparing && (!store.draft.isEmpty || store.pendingAttachment != nil)
    }

    private var showAttachmentBar: Bool {
        store.pendingAttachment != nil || store.attachmentPreparing || store.attachmentError != nil
    }

    var body: some View {
        let peerName = store.openPeerDisplayName
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(store.threadMessages) { message in
                    let reactions = store.threadReactions[message.messageHash] ?? []
                    // A reply to a caption-less photo or file in the thread quotes its placeholder.
                    let replyPreview = ReplyPreview.resolve(for: message, in: store.threadMessages, peerName: peerName,
                                                            attachments: store.attachmentsByMessageId)
                    let attachment = store.attachmentsByMessageId[message.id]
                    let progress = message.isOutgoing && message.status == MessageStatus.sending
                        ? store.outgoingProgress[message.messageHash] : nil
                    MessageBubble(
                        message: message,
                        reactions: reactions,
                        replyPreview: replyPreview,
                        attachment: attachment,
                        attachmentURL: attachment.flatMap(attachmentStore.url(for:)),
                        progress: attachment != nil ? progress : nil,
                        isHighlighted: highlightedMessageID == message.id,
                        onQuoteTap: { showOriginal($0, proxy: proxy) },
                        onImageTap: { a, url in
                            viewerTarget = ViewerTarget(attachment: a, url: url, shareURL: shareableURL(for: a, stored: url))
                        },
                        onFileTap: { a, url in quickLookURL = shareableURL(for: a, stored: url) }
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
                        if message.isOutgoing, message.status == MessageStatus.sending, !message.messageHash.isEmpty {
                            Button("Cancel Send", systemImage: "xmark.circle", role: .destructive) {
                                store.send(.cancelSendTapped(message.id))
                            }
                        }
                        Button("Info", systemImage: "info.circle") {
                            infoTarget = InfoTarget(id: message.id)
                        }
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.body
                        }
                    } preview: {
                        BubbleText(message: message, replyPreview: replyPreview,
                                   attachment: attachment, attachmentURL: attachment.flatMap(attachmentStore.url(for:)))
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
                let trimmedQuote = ReplyWire.trimQuote(target.body)
                ReplyComposerBar(
                    senderLabel: ReplyPreview.senderLabel(originalIsOutgoing: target.isOutgoing, peerName: peerName),
                    // A whitespace-only original trims to "", so it shows the same "not available"
                    // text as the resolver rather than an empty line (P1).
                    text: trimmedQuote.isEmpty ? ReplyPreview.unavailable : trimmedQuote,
                    onCancel: { store.send(.replyCancelled) }
                )
            }

            if showAttachmentBar {
                AttachmentComposerBar(
                    pending: store.pendingAttachment,
                    preparing: store.attachmentPreparing,
                    error: store.attachmentError,
                    onRemove: { store.send(.attachmentRemoved) },
                    onOriginalToggled: { store.send(.attachmentOriginalToggled($0)) }
                )
            }

            HStack(spacing: 4) {
                AttachmentPickerButton(
                    onPicked: { store.send(.attachmentPicked($0)) },
                    onFailed: { store.send(.attachmentFailed($0)) }
                )
                TextField("Message", text: $store.draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($draftFocused)
                Button("Send") { store.send(.sendTapped) }
                    .disabled(!canSend)
                    .padding(.leading, 4)
            }
            .padding(.vertical)
            .padding(.trailing)
            .padding(.leading, 8)
        }
        .safeAreaInset(edge: .top) {
            let transfers = store.inboundTransfersForOpenThread
            if !transfers.isEmpty {
                ReceivingCapsule(transfers: transfers).padding(.top, 4)
            }
        }
        .navigationTitle(store.openPeerHex.map(shortHex) ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pickerTarget) { target in
            EmojiPickerSheet { emoji in
                store.send(.reactionSelected(messageHash: target.messageHash, emoji: emoji))
            }
        }
        .fullScreenCover(item: $viewerTarget) { target in
            ImageViewerSheet(attachment: target.attachment, url: target.url, shareURL: target.shareURL)
        }
        .quickLookPreview($quickLookURL)
    }

    /// The bytes under the attachment's real name for QuickLook and the share sheet, so "save to
    /// Files" writes `Trail map.pdf`, not `<hash>-in.pdf`. Falls back to the stored file (and logs)
    /// if the copy fails.
    private func shareableURL(for attachment: Attachment, stored: URL) -> URL {
        do {
            return try attachmentStore.exportURL(for: attachment)
        } catch {
            Self.log.error("attachment export failed: \(String(describing: error), privacy: .public)")
            return stored
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

private struct ViewerTarget: Identifiable {
    let attachment: Attachment
    let url: URL
    /// What the share button hands over: the real-name copy, or `url` if the copy failed.
    let shareURL: URL
    var id: UUID { attachment.id }
}

struct MessageBubble: View {
    let message: Message
    var reactions: [ReactionSummary.Item] = []
    var replyPreview: ReplyPreview.Resolved? = nil
    var attachment: Attachment? = nil
    var attachmentURL: URL? = nil
    var progress: Double? = nil
    var isHighlighted = false
    var onQuoteTap: ((Message.ID) -> Void)? = nil
    var onImageTap: ((Attachment, URL) -> Void)? = nil
    var onFileTap: ((Attachment, URL) -> Void)? = nil

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer() }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                BubbleText(message: message, replyPreview: replyPreview,
                           attachment: attachment, attachmentURL: attachmentURL, progress: progress,
                           onQuoteTap: onQuoteTap, onImageTap: onImageTap, onFileTap: onFileTap)
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
/// A reply shows its quote block above the text; an attachment sits above the caption.
struct BubbleText: View {
    let message: Message
    var replyPreview: ReplyPreview.Resolved? = nil
    var attachment: Attachment? = nil
    var attachmentURL: URL? = nil
    var progress: Double? = nil
    var onQuoteTap: ((Message.ID) -> Void)? = nil
    var onImageTap: ((Attachment, URL) -> Void)? = nil
    var onFileTap: ((Attachment, URL) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyPreview {
                QuoteBlock(preview: replyPreview, onOutgoingBubble: message.isOutgoing, onTap: onQuoteTap)
            }
            if let attachment {
                AttachmentBubbleSlot(
                    attachment: attachment,
                    url: attachmentURL,
                    progress: progress,
                    onOutgoingBubble: message.isOutgoing,
                    onTapImage: (onImageTap != nil && attachmentURL != nil) ? { onImageTap?(attachment, attachmentURL!) } : nil,
                    onTapFile: (onFileTap != nil && attachmentURL != nil) ? { onFileTap?(attachment, attachmentURL!) } : nil
                )
            }
            if !message.body.isEmpty || attachment == nil {
                Text(message.body)
            }
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

- [ ] **Step 4: `MessageInfoSheet.swift`**

Replace the `ForEach(Array(MessageInfo.sections(for: message).enumerated()), id: \.offset)` line with:

```swift
                        ForEach(Array(MessageInfo.sections(for: message,
                                                           attachment: store.attachmentsByMessageId[message.id]).enumerated()),
                                id: \.offset) { _, section in
```

- [ ] **Step 5: `ConversationListView.swift`**

In the `.toolbar`, after the connection-circle `ToolbarItem`, add:

```swift
                ToolbarItem(placement: .navigationBarLeading) {
                    ReceivingCapsule(transfers: store.unattributedInboundTransfers)
                }
```

- [ ] **Step 6: Build the app target**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCaMsgr/att-t9-xcodebuild.log 2>&1`
Expected: `** BUILD SUCCEEDED **`. Fix compile errors in the view code (typical: `MagnifyGesture` is iOS 17+, fine; `.photosPicker(isPresented:selection:matching:)` is iOS 17+; `@Dependency` in a `View` needs `import ComposableArchitecture`, already there). Never change core code from this task — if a core signature is wrong, STOP and report.

- [ ] **Step 7: Core suite unchanged**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-attachments/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/att-t9-full.log 2>&1`
Expected: same count and result as Task 8 (no core files changed).

- [ ] **Step 8: Manual checklist (record in the report as "not run" if no device/simulator session is available)**

- Pick a photo → bar shows thumbnail, `IMG_….jpg · N KB`, Original toggle; Send enabled with an empty draft.
- Toggle Original → size grows, note appears when over 256 KB / 1 MB.
- Send → bubble shows the thumbnail, then a progress bar while `sending`; long-press → Cancel Send → status `cancelled`.
- Pick a document → file row; send; tap the row on the receiving side → QuickLook with share; "Save to Files" offers the real name (`Trail map.pdf`), not the hash.
- Open a photo → pinch zooms; at zoom 1 a downward swipe of more than ~120 pt dismisses, a shorter one springs back; Share offers `IMG_….jpg` / `image.jpeg`.
- Reply to a caption-less photo → the reply bubble's quote block says `📷 Photo`.
- Info on an attachment message → Attachment section present.
- A Sideband peer's WebP renders; an unknown format shows as a file row.

- [ ] **Step 9: Restore Xcode's user-data drift, commit**

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments status --short`
Expected: exactly the five intended files (two new, three modified). If either `xcschememanagement.plist` shows as modified, restore it with `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments checkout -- <that path>` (allowed here only, see Task 0).

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments add ReTiCaMsgr/AttachmentPicker.swift ReTiCaMsgr/AttachmentViews.swift ReTiCaMsgr/ChatView.swift ReTiCaMsgr/MessageInfoSheet.swift ReTiCaMsgr/ConversationListView.swift`

Write `/tmp/ReTiCaMsgr/msg-att-task-9.txt`:

```
feat: attachment composer, bubbles, viewer, QuickLook and progress

A paperclip menu picks a photo or a document, the attachment bar shows
the pending item with size notes and an Original toggle, bubbles show
thumbnails or file rows with a progress bar while sending, a tap opens
the photo viewer (swipe down to dismiss) or QuickLook with the real
file name for sharing, Cancel Send sits in the context menu,
a Receiving capsule tracks inbound transfers, and the Info sheet gets
the attachment section.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-attachments commit -F /tmp/ReTiCaMsgr/msg-att-task-9.txt`

---

## Self-review notes (for the reviewer)

**Spec coverage.** §1 data model and storage → Tasks 1, 2, 5 (Info section), 6 (thread/list loading), 8 (transfer state). §2 wire format and image pipeline → Tasks 3, 4; the composer's size notes → Task 7 (`AttachmentSizeNote`) and Task 9. §3 send flow → Task 7 (state, preparation, send), Task 8 (progress, cancel, `cancelled` status, refusal), Task 9 (composer, Cancel Send). §4 receive flow and display → Task 6 (receive), Task 5 (placeholders, preview), Task 8 (inbound capsule state), Task 9 (bubbles, viewer, QuickLook, capsule). §4 errors → Tasks 6, 7, 9. §5 testing → the core tests in Tasks 1–8; `ImageEncoder` moved INTO the core package (ImageIO is available on macOS) so it is covered by `swift test` rather than an app-target XCTest — a deliberate improvement on the spec's "app target" placement; the views remain untested as the spec allows; the manual checks are Task 9 Step 8.

**Where the plan departs from the spec's wording, and why.**
1. `ImageEncoder` lives in `ReTiCaMsgrCore`, not the app target (above).
2. A store write failure on RECEIVE inserts the attachment row with `path == ""` (spec: "attachment dropped with a bubble note") — the row is what carries the note and the Info sheet's "Stored: No"; nothing else is stored.
3. `PickedItem` is read by the view (security-scoped URLs), not by the reducer — the spec's "`.attachmentPicked` reads the bytes" is split into view read + reducer prepare, keeping the core free of PhotosUI.
4. Generated photo names use UTC so tests are deterministic and the name is the same wherever the phone is.
5. `propagationProgress` is not handled (falls into the catch-all), as the spec says: the direct copy's progress is what the user waits for. (Listed for completeness; not a departure.)
6. The reply quote for an attachment message is built from `AttachmentPlaceholder.preview` at `replyTapped` time (the composer bar and the wire quote then agree); the thread's quote block for a reply whose original is IN the thread resolves the same placeholder at display time (`ReplyPreview.resolve(…attachments:)`, Task 5).
7. **File protection (spec §1 amended):** `AttachmentStore` writes with `.completeFileProtectionUntilFirstUserAuthentication` — the same class as the SQLite file — not complete protection. BLE runs in the background, and under complete protection an attachment received while the phone is locked could not be written (every such receive would end as "could not be saved"). The cost: attachment bytes are readable while locked after the first unlock, exactly like the database today.
8. **Send-side store failure (P12 a):** the spec asks for an alert "Couldn't save attachment"; the plan shows `storeFailed` inline in the attachment bar (no alert plumbing) and `attachmentSendFailed(draft:)` puts the caption back in the draft. The attachment itself must be picked again.
9. **Viewer dismissal (P12 b):** the viewer stays a `.fullScreenCover` (black, edge to edge) and gains the spec's swipe-down: a downward drag of more than 120 pt at zoom 1 dismisses it.
10. **File-row wording (P12 c):** `path == ""` says "Attachment could not be saved"; a row whose file is missing on disk (checked off the main thread) says "Attachment unavailable". Both are untappable.
11. **`fileImporter` off the main thread (P12 d):** the bytes are read in `Task.detached`, then `onPicked` runs back on the main actor, as the spec's "off the main thread" asks.
12. **Dropped entries logged (P12 e):** `AttachmentWire.Decoded.droppedFileCount` counts the 0x05 entries left out (beyond the first, or all of them when an image wins); `AppFeature` logs `inbound.notice` when it is > 0.
13. **`AttachmentStore` API (P12 f):** `url(for:)` returns `URL?` (nil for a row with no bytes) and `delete` takes a relative path, where the spec says `url(for:) -> URL` and `delete(_ attachment:)`; the spec is amended to match. `exportURL(for:)` is added for sharing under the real name.

**Pre-flight rubric items addressed:** no verbatim duplicates remain — the two prepare `.run` blocks are one `prepareEffect` (which also makes the preparation cancellable), `ThumbnailCache` has one private decode path, and `Attachment.byMessageId(_:)` replaces the two dictionary builds; no swallowed errors — the send `catch` and every picker/export `catch` log the error before showing user text, and `encodingFailed` has its own message ("Couldn't encode that image"); the pending preview no longer keys on `Data.hashValue`; every new test is turned red by at least one mutation in its task, and no mutation is masked by another in its sub-batch; no tuple `#expect`s; the `Testing.Attachment` ambiguity is handled by a per-file typealias (Global Constraints).

**Placeholder scan:** none — every code step carries the code. The only open-ended instructions are Task 4 Step 5's ImageIO rounding note and Task 9 Step 6's compile-fix latitude, both bounded.

**Type consistency:** `Attachment(id:messageId:kind:name:format:size:width:height:path:)`, `Attachment.byMessageId(_:)`, `AttachmentStore.store(_:messageHash:outgoing:ext:)`, `AttachmentStore.exportURL(for:)`, `AttachmentWire.Decoded(kind:name:format:data:droppedFileCount:)`, `ReplyPreview.resolve(for:in:peerName:attachments:)`, action `attachmentSendFailed(draft:)`, `AttachmentWire.encodeImage(_:)`/`encodeFile(name:data:)`/`decode(_:)`, `ImageEncoder.encodeJPEG(_:preset:)`/`dimensions(of:)`, `AttachmentPlaceholder.preview(body:attachment:)`, `MessageInfo.sections(for:attachment:timeZone:)`, `Conversation.list(from:attachments:)`, `PickedItem(kind:name:data:)`, `PendingAttachment(kind:name:format:data:width:height:originalSource:isOriginal:)`, `AttachmentPreparation.prepare(_:original:now:)`, `AppFeature.InboundTransfer(sourceHash:fraction:updatedAt:)`, actions `attachmentPicked`/`attachmentPrepared`/`attachmentFailed`/`attachmentRemoved`/`attachmentOriginalToggled`/`cancelSendTapped`/`inboundTransferTimedOut(linkID:)`, `threadLoaded(_:reactions:attachments:)` are spelled the same in every task that defines or uses them.

**Review Focus:** all eight lines are pinned by named tests in Tasks 2, 3, 4, 6, 8 (see the Review Focus section); none is left to the views.
