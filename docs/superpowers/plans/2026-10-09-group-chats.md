# Group Chats Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serverless group conversations of up to 12 members: every post is an ordinary LXMF message sent once per member, with the group id and a post id in `FIELD_CUSTOM_META` (0xFD), creator-signed rosters, and one `messages` row per post backed by a per-member delivery table.

**Architecture:** Four pure Core types (`GroupWire` codec, `GroupRoster` rules and derived status, `GroupEventText` lines, `GroupControlApply` database rules for incoming rosters and leaves) plus three tables (`chatGroups`, `groupMembers`, `groupDeliveries`). `AppFeature` gains the fan-out: a group row is written once with a `waiting` delivery row per member, one file-scope dispatcher builds and sends each member's copy when that member is reachable (at send, on `pathLearned`, on `interfaceConnected`), and the delivery delegates update member rows and write the post's derived status back. The SwiftUI target adds group creation, the group thread (sender names, aggregate status, invite bar), a group info screen and a Members section in the Info sheet.

**Tech Stack:** Swift 6, SwiftUI, TCA (`@Reducer`, `TestStore`, `TestClock`), SQLiteData/GRDB append-only migrations, ReTiCA (`LXMessage`, `MsgPackValue`).

**Spec:** `docs/superpowers/specs/2026-10-09-group-chats-design.md` (app main, with "Amendments at planning time" A1–A14 at its end). The spec is the authority; this plan argues from it.

## Global Constraints

- **Where:** all work happens ONLY in the app worktree `/Users/ell/development/ios/apps/ReTiCaMsgr-groups` on branch `feat/group-chats`, cut from app `main` in Task 0. `APP` below means that path; `CORE` means `APP/ReTiCaMsgrCore`. Never build, test or run git against the main checkout `/Users/ell/development/ios/apps/ReTiCaMsgr` after Task 0's `worktree add`, and never touch `/Users/ell/development/ios/pods/ReTiCA` (read-only path dependency; `CORE/Package.swift`'s `../../../pods/ReTiCA` resolves from the worktree unchanged).
- **Task 0 is a gate:** the baseline core suite `swift test --package-path CORE` must be green and `xcodebuild -project APP/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build` must succeed before Task 1. Record the baseline test count in `/tmp/ReTiCaMsgr/grp-baseline.txt`.
- **Commits** go on `feat/group-chats` only. Stage explicit paths (`git -C APP add <path> ...`, never `-A`/`.`). Never stage `ReTiCaMsgr.xcodeproj/xcuserdata/**`, `ReTiCaMsgrCore/.swiftpm/**` or `Package.resolved`. Each task writes its message to its OWN file `/tmp/ReTiCaMsgr/msg-grp-task-N.txt` with the Write tool, then `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-N.txt`. Message = `feat:`/`fix:`/`test:`/`docs:` subject, blank line, body, blank line, then exactly these two lines at column 0 (the first names the model that wrote the commit):
  `Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1`
  No semicolons anywhere in a commit message.
- **Shell:** one command per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreters (`python -c`, heredocs into an interpreter). Scripts go in files under `/tmp/ReTiCaMsgr/` (`mkdir -p /tmp/ReTiCaMsgr` if missing). Redirecting one command's output to a file (`cmd > /tmp/ReTiCaMsgr/x.log 2>&1`) is allowed.
- **Tests:** `swift test --package-path CORE --filter <prefix>` runs one task's tests; the full core suite is `swift test --package-path CORE`. Known flake: `deliveryFailedMarksFailedAndReloads` can fail when run ALONE via `--filter`; it passes in a full run. Never run `swift test` and `xcodebuild` at the same time on the same package. Filtering still compiles every target, so the whole package must compile at the end of every task. Every new test name starts with its task's prefix — `groupTable` (T1), `groupWire` (T2), `groupRules` (T3), `groupConv` (T4), `groupCreate` (T5), `groupSend` (T6), `groupDeliver` (T7), `groupReceive` (T8), `groupControl` (T9), `groupInfo` (T10). No existing test name starts with `group` (checked 2026-10-09 with a grep of `func group` over the test folder: none).
- **Mutation verification is mandatory** for every task with tests: (a) run the task's filter, all GREEN; (b) apply the task's listed mutation batch to production code, run the filter once, confirm EVERY listed test is RED — where the table says "sub-batch", run the sub-batches separately so no mutation masks another; (c) revert every mutation BY HAND with the Edit tool (never `git checkout -- <file>`), confirm `git -C APP diff` shows only the task's intended changes, run again, all GREEN. If a test survives its mutation, fix the test and restart at (a). Tests edited only mechanically to compile against a new shape are exempt.
- **TCA TestStore facts these tests rely on:** under `exhaustivity = .off`, `store.state` reflects effect-delivered actions only after `receive` or `await store.skipReceivedActions(strict: false)`; every `send` clears not-yet-received actions, so a `receive` for something an earlier `send` produced must come before the next `send`; a non-exhaustive `receive { predicate }` skips the actions that do not match and waits for one that does. **Never call `store.finish()` after an action that reaches the node's send path or `pathLearned`**: the router arms a retry timer and the path handler arms a 30 s debounce on the `TestClock`, and `finish()` would wait on them. After such actions, `receive` the expected actions and then `await store.skipReceivedActions(strict: false)` before reading rows. `\.date` is frozen at 1700000000 (`infoT0`) in `makeStore`. The reducer calls `UUID()` directly; group and post ids come from `GroupWire.randomId()`, so tests read them back from rows rather than predicting them.
- **Test style** (match `AppFeatureTests.swift`): free `@MainActor @Test func` functions, `makeStore(db, identity:)` with `exhaustivity = .off`, `#expect` with literals. New AppFeature tests go in `AppFeatureTests.swift` so they can use its private helpers (`makeStore`, `seed`, `msg`, `uuid`, `peerA`, `peerB`, `infoT0`, `sendAndSettle`, `wireMessage`, `receiveAndFetch`, `reactionMessage`, `hashData`, `learnedEntry`). Task 4 adds the group helpers (`groupHexA`, `memberC`, `memberD`, `groupMemberHash`, `groupStore`, `groupSends`) that later tasks use, and Task 8 adds `groupPostWire` and `groupReceive`.
- **`Attachment` vs `Testing.Attachment`:** every TEST file that names the model type adds `import struct ReTiCaMsgrCore.Attachment` after its imports. Production code is unaffected.
- **Constants (from the spec and amendments):** `GroupWire.fieldCustomMeta = 0xFD`, `groupKey = "reticamsgr.group"`, `controlKey = "reticamsgr.group.ctl"`, `idLength = 16`, `maxNameBytes = 32`, `maxMembers = 12`, actions `"roster"` / `"leave"`, control map keys `"a"`, `"n"`, `"m"`, `"r"`; `GroupState.invited/active/left/dissolved`; `GroupDeliveryStatus.waiting = "waiting"`; `GroupControl.roster = "roster"`, `.leave = "leave"`; migration `createGroups`; tables `chatGroups`, `groupMembers`, `groupDeliveries` (amendment A1: the Swift type is `ChatGroup`, since SwiftUI owns `Group` and `GROUPS` is an SQLite keyword); wire bodies and lines exactly as `GroupEventText` in Task 3 spells them; caveat `Members on other apps see posts as separate direct messages and cannot reply to the group.`
- **App target:** new SwiftUI files go in `APP/ReTiCaMsgr/` (synchronized folders, no pbxproj edit). The app build must succeed at the end of Task 11; every core task must leave the package compiling, which the filtered test runs prove.

## Review Focus

Inputs the spec implies but its own examples don't exercise, most likely to bite first. Each is pinned by a named test in the owning task.

1. **A post from a member removed one revision ago**, arriving after the removal, must land as an ordinary one-to-one message, never in the group. Test: T8 `groupReceivePostFromNonMemberIsPlainMessage`.
2. **A roster that does not list its own sender** (a buggy or hostile creator) must not apply. Test: T9 `groupControlRosterOmittingSenderIsPlainMessage`.
3. **The same post id in two different groups** must store two rows; the duplicate guard is per group. Test: T1 `groupTableDuplicatePostIdRejectedWithinGroupAllowedAcross`.
4. **A group name over 32 bytes or a roster over 12 members on the wire** must decode as nil, and our own encoder must trim the name so a local pick never produces such a message. Tests: T2 `groupWireDecodeRejectsOversizedNameAndRoster`, `groupWireTrimNameKeepsCharacterBoundaries`.
5. **A re-invite after the user left** (a roster from the creator that lists them again) must bring the group back as `invited`, not silently `active`. Test: T9 `groupControlReinviteAfterLeftBecomesInvited`.

---

### Task 0: Worktree and baseline

**Files:** none changed.

- [ ] **Step 1: Create the worktree from app main**

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr worktree add /Users/ell/development/ios/apps/ReTiCaMsgr-groups -b feat/group-chats main`
Expected: a new worktree at `APP` on `feat/group-chats`, HEAD = app main (the commit carrying this plan, or later).

- [ ] **Step 2: Temp directory**

Run: `mkdir -p /tmp/ReTiCaMsgr`

- [ ] **Step 3: Baseline core suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/grp-t0-core.log 2>&1`
Expected: the log ends with `Test run with N tests in 0 suites passed`. Write `N` to `/tmp/ReTiCaMsgr/grp-baseline.txt` with the Write tool.

- [ ] **Step 4: Baseline app build**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCaMsgr/grp-t0-xcodebuild.log 2>&1`
Expected: `** BUILD SUCCEEDED **` at the end of the log.

- [ ] **Step 5: Restore any files Xcode rewrote**

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-groups status --short`
Expected: empty. If the two `xcschememanagement.plist` files show as modified, restore them with `git -C APP checkout -- <path>` (the ONLY `git checkout --` allowed in this plan, only here and in Task 11 Step 9). Nothing to commit.

---

### Task 1: Schema, `Message` columns, `ChatGroup`, `GroupMember`, `GroupDelivery`

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/Database.swift` (new migration after `addExpiresAtIndex`)
- Modify: `CORE/Sources/ReTiCaMsgrCore/Message.swift` (four properties after `isTimerChange`)
- Create: `CORE/Sources/ReTiCaMsgrCore/ChatGroup.swift`
- Create: `CORE/Sources/ReTiCaMsgrCore/GroupMember.swift`
- Create: `CORE/Sources/ReTiCaMsgrCore/GroupDelivery.swift`
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/DatabaseTests.swift` (append)

**Interfaces:**
- Produces: `Message.groupHex: String?`, `Message.groupPostId: String?`, `Message.isGroupEvent: Bool`, `Message.groupControl: String?` (init parameters after `isTimerChange`, defaults `nil`, `nil`, `false`, `nil`). `GroupState` (`invited`, `active`, `left`, `dissolved`), `GroupControl` (`roster`, `leave`), `GroupDeliveryStatus.waiting`. `ChatGroup` (`@Table`): `groupHex`, `name`, `creatorHex`, `revision: Int`, `state`, `updatedAt: Date`; `isOpen: Bool` (invited or active); `static func fetch(_ groupHex: String, _ db: GRDB.Database) throws -> ChatGroup?`; `static func upsert(_ group: ChatGroup, _ db: GRDB.Database) throws`. `GroupMember` (`@Table`): `groupHex`, `memberHex`; `static func members(of groupHex: String, _ db: GRDB.Database) throws -> [String]` (sorted); `static func replace(_ groupHex: String, with members: [String], _ db: GRDB.Database) throws`; `static func contains(_ groupHex: String, _ memberHex: String, _ db: GRDB.Database) throws -> Bool`. `GroupDelivery` (`@Table`): `messageId: UUID`, `memberHex`, `messageHash: String?`, `status`, `storedAt`, `deliveredAt`, `failedAt: Date?`; `static func byMessageId(_ rows: [GroupDelivery]) -> [UUID: [GroupDelivery]]` (each list sorted by `memberHex`). Migration `createGroups`.

- [ ] **Step 1: Write the failing tests**

Append to `CORE/Tests/ReTiCaMsgrCoreTests/DatabaseTests.swift`:

```swift

// MARK: - Group chats (createGroups)

private let groupTableG1 = String(repeating: "1a", count: 16)
private let groupTableG2 = String(repeating: "2b", count: 16)
private let groupTableP1 = String(repeating: "3c", count: 16)
private let groupTableMe = String(repeating: "e", count: 32)
private let groupTablePeer = String(repeating: "f", count: 32)

private func groupTableMessage(_ id: String, groupHex: String?, postId: String?) -> Message {
    Message(
        id: UUID(uuidString: id)!,
        peerHex: groupTablePeer,
        isOutgoing: false,
        body: "post",
        timestamp: Date(timeIntervalSince1970: 1700000000),
        status: MessageStatus.received,
        validated: true,
        messageHash: postId ?? "",
        groupHex: groupHex,
        groupPostId: postId
    )
}

@Test func groupTableGroupAndMembersRoundTrip() throws {
    let db = try AppDatabase.makeInMemory()
    let group = ChatGroup(groupHex: groupTableG1, name: "Mutual Aid", creatorHex: groupTableMe, revision: 1,
                          state: GroupState.active, updatedAt: Date(timeIntervalSince1970: 1700000000))
    try db.write { db in
        try ChatGroup.upsert(group, db)
        try GroupMember.replace(groupTableG1, with: [groupTablePeer, groupTableMe], db)
    }
    #expect(try db.read { try ChatGroup.fetch(groupTableG1, $0) } == group)
    #expect(try db.read { try ChatGroup.fetch(groupTableG2, $0) } == nil)
    // Sorted, so a roster compares by value regardless of insertion order.
    #expect(try db.read { try GroupMember.members(of: groupTableG1, $0) } == [groupTableMe, groupTablePeer])
    #expect(try db.read { try GroupMember.contains(groupTableG1, groupTablePeer, $0) } == true)
    #expect(try db.read { try GroupMember.contains(groupTableG1, groupTableG2, $0) } == false)
    // upsert replaces, replace replaces.
    var renamed = group
    renamed.name = "Block 4"
    renamed.revision = 2
    try db.write { db in
        try ChatGroup.upsert(renamed, db)
        try GroupMember.replace(groupTableG1, with: [groupTableMe], db)
    }
    #expect(try db.read { try ChatGroup.all.fetchAll($0) } == [renamed])
    #expect(try db.read { try GroupMember.members(of: groupTableG1, $0) } == [groupTableMe])
    #expect(group.isOpen == true)
    #expect(ChatGroup(groupHex: groupTableG2, name: "x", creatorHex: groupTableMe, revision: 1,
                      state: GroupState.left, updatedAt: Date()).isOpen == false)
}

@Test func groupTableDeletingGroupCascadesMembers() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { db in
        try ChatGroup.upsert(ChatGroup(groupHex: groupTableG1, name: "g", creatorHex: groupTableMe, revision: 1,
                                       state: GroupState.active, updatedAt: Date(timeIntervalSince1970: 1)), db)
        try GroupMember.replace(groupTableG1, with: [groupTablePeer], db)
        try ChatGroup.where { $0.groupHex.eq(groupTableG1) }.delete().execute(db)
    }
    #expect(try db.read { try GroupMember.all.fetchAll($0) }.isEmpty)
}

/// Literal expectations, not only `back == m`, so a model that drops a field on init cannot pass
/// by dropping it on both sides.
@Test func groupTableMessageColumnsRoundTrip() throws {
    let db = try AppDatabase.makeInMemory()
    var m = groupTableMessage("00000000-0000-0000-0000-000000000030", groupHex: groupTableG1, postId: groupTableP1)
    m.isGroupEvent = true
    m.groupControl = GroupControl.roster
    try db.write { try Message.insert { m }.execute($0) }
    let back = try #require(try db.read { try Message.all.fetchAll($0) }.first)
    #expect(back.groupHex == groupTableG1)
    #expect(back.groupPostId == groupTableP1)
    #expect(back.isGroupEvent == true)
    #expect(back.groupControl == "roster")
    #expect(back == m)
    let plain = groupTableMessage("00000000-0000-0000-0000-000000000031", groupHex: nil, postId: nil)
    #expect(plain.groupHex == nil)
    #expect(plain.groupPostId == nil)
    #expect(plain.isGroupEvent == false)
    #expect(plain.groupControl == nil)
}

/// Review Focus 3: the duplicate guard is per group.
@Test func groupTableDuplicatePostIdRejectedWithinGroupAllowedAcross() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try Message.insert { groupTableMessage("00000000-0000-0000-0000-000000000032", groupHex: groupTableG1, postId: groupTableP1) }.execute($0) }
    #expect(throws: (any Error).self) {
        try db.write { try Message.insert { groupTableMessage("00000000-0000-0000-0000-000000000033", groupHex: groupTableG1, postId: groupTableP1) }.execute($0) }
    }
    try db.write { try Message.insert { groupTableMessage("00000000-0000-0000-0000-000000000034", groupHex: groupTableG2, postId: groupTableP1) }.execute($0) }
    // NULLs never collide: two one-to-one rows, two event lines.
    try db.write { try Message.insert { groupTableMessage("00000000-0000-0000-0000-000000000035", groupHex: nil, postId: nil) }.execute($0) }
    try db.write { try Message.insert { groupTableMessage("00000000-0000-0000-0000-000000000036", groupHex: nil, postId: nil) }.execute($0) }
    try db.write { try Message.insert { groupTableMessage("00000000-0000-0000-0000-000000000037", groupHex: groupTableG1, postId: nil) }.execute($0) }
    try db.write { try Message.insert { groupTableMessage("00000000-0000-0000-0000-000000000038", groupHex: groupTableG1, postId: nil) }.execute($0) }
    #expect(try db.read { try Message.all.fetchAll($0) }.count == 6)
}

@Test func groupTableDeliveriesRoundTripAndCascade() throws {
    let db = try AppDatabase.makeInMemory()
    let m = groupTableMessage("00000000-0000-0000-0000-000000000039", groupHex: groupTableG1, postId: groupTableP1)
    let waiting = GroupDelivery(messageId: m.id, memberHex: groupTablePeer, messageHash: nil,
                                status: GroupDeliveryStatus.waiting, storedAt: nil, deliveredAt: nil, failedAt: nil)
    let sent = GroupDelivery(messageId: m.id, memberHex: groupTableMe, messageHash: String(repeating: "ab", count: 32),
                             status: MessageStatus.delivered, storedAt: nil,
                             deliveredAt: Date(timeIntervalSince1970: 1700000005), failedAt: nil)
    try db.write { db in
        try Message.insert { m }.execute(db)
        try GroupDelivery.insert { waiting }.execute(db)
        try GroupDelivery.insert { sent }.execute(db)
    }
    let rows = try db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(rows.count == 2)
    #expect(rows.contains(waiting))
    #expect(rows.contains(sent))
    #expect(GroupDelivery.byMessageId(rows) == [m.id: [sent, waiting]])   // sorted by memberHex: e… before f…
    try db.write { try Message.where { $0.id.eq(m.id) }.delete().execute($0) }
    #expect(try db.read { try GroupDelivery.all.fetchAll($0) }.isEmpty)
}

/// A row written before `createGroups` reads back as an ordinary one-to-one bubble.
@Test func groupTableLegacyRowReadsBackWithDefaults() throws {
    let queue = try DatabaseQueue()
    try AppDatabase.migrator().migrate(queue, upTo: "addExpiresAtIndex")
    try queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO messages (id, peerHex, isOutgoing, body, timestamp, status, validated, messageHash, isTimerChange)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: ["00000000-0000-0000-0000-00000000003a", groupTablePeer,
                        0, "old", "2023-11-14 22:13:20.000", MessageStatus.received, 1, "", 0]
        )
    }
    try AppDatabase.migrator().migrate(queue)
    let row = try #require(try queue.read { try Message.all.fetchAll($0) }.first)
    #expect(row.body == "old")
    #expect(row.groupHex == nil)
    #expect(row.groupPostId == nil)
    #expect(row.isGroupEvent == false)
    #expect(row.groupControl == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupTable > /tmp/ReTiCaMsgr/grp-t1-red.log 2>&1`
Expected: compile errors (`ChatGroup`, `groupHex` unknown).

- [ ] **Step 3: Add the migration**

In `CORE/Sources/ReTiCaMsgrCore/Database.swift`, after the `addExpiresAtIndex` migration's closing `}` and before `return m`:

```swift
        m.registerMigration("createGroups") { db in
            // Group chats (spec 2026-10-09 §2, amendment A1). `chatGroups` holds one row per group
            // the user created or was invited to; `groupMembers` its roster, me included, replaced
            // whole on every applied roster; `groupDeliveries` one row per member per outgoing
            // group row (post or event line), which is where the per-member LXMF hashes and
            // outcomes live. The message row's own `status` is derived from those rows.
            try db.create(table: "chatGroups") { t in
                t.primaryKey("groupHex", .text).notNull()
                t.column("name", .text).notNull()
                t.column("creatorHex", .text).notNull()
                t.column("revision", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "groupMembers") { t in
                t.column("groupHex", .text).notNull().references("chatGroups", onDelete: .cascade)
                t.column("memberHex", .text).notNull()
                t.primaryKey(["groupHex", "memberHex"])
            }
            // `groupHex` keys a row to its group (NULL = one-to-one), `groupPostId` is the 16-byte
            // post id as hex (NULL on event lines), `isGroupEvent` marks roster/leave lines, and
            // `groupControl` marks an outgoing line that carries a roster or leave to its members
            // so a deferred copy can be rebuilt (amendment A3). Rows from before this migration
            // read back NULL / NULL / false / NULL.
            try db.alter(table: "messages") { t in
                t.add(column: "groupHex", .text)
                t.add(column: "groupPostId", .text)
                t.add(column: "isGroupEvent", .boolean).notNull().defaults(to: false)
                t.add(column: "groupControl", .text)
            }
            // The duplicate-post guard (spec §2): one row per post id per group. Partial, so
            // one-to-one rows and event lines (NULL ids) never collide.
            try db.execute(sql: "CREATE UNIQUE INDEX messages_groupPost ON messages(groupHex, groupPostId) WHERE groupHex IS NOT NULL AND groupPostId IS NOT NULL")
            try db.create(table: "groupDeliveries") { t in
                t.column("messageId", .text).notNull().references("messages", onDelete: .cascade)
                t.column("memberHex", .text).notNull()
                t.column("messageHash", .text)          // NULL while waiting
                t.column("status", .text).notNull()
                t.column("storedAt", .datetime)
                t.column("deliveredAt", .datetime)
                t.column("failedAt", .datetime)
                t.primaryKey(["messageId", "memberHex"])
            }
            try db.create(indexOn: "groupDeliveries", columns: ["messageHash"])
        }
```

- [ ] **Step 4: Add the `Message` properties**

In `CORE/Sources/ReTiCaMsgrCore/Message.swift`, after `public var isTimerChange: Bool`:

```swift
    /// Group chats (spec 2026-10-09 §2): the group this row belongs to, as hex. nil for a
    /// one-to-one row. `peerHex` is then the sender (incoming) or my own address (outgoing).
    public var groupHex: String?
    /// The 16-byte post id as hex, set on every group post and nil on event lines. A group post
    /// row also stores it in `messageHash` (amendment A2), so replies and reactions key on it.
    public var groupPostId: String?
    /// A roster or leave line ("Alice added Bob"): rendered as a system line, never carries an
    /// attachment or reactions.
    public var isGroupEvent: Bool
    /// Outgoing event lines that carry a message to the members: `GroupControl.roster` or
    /// `GroupControl.leave`. A deferred copy is rebuilt from this (amendment A3). nil on posts.
    public var groupControl: String?
```

Add init parameters after `isTimerChange: Bool = false`:

```swift
        isTimerChange: Bool = false,
        groupHex: String? = nil,
        groupPostId: String? = nil,
        isGroupEvent: Bool = false,
        groupControl: String? = nil
```

and assignments after `self.isTimerChange = isTimerChange`:

```swift
        self.groupHex = groupHex
        self.groupPostId = groupPostId
        self.isGroupEvent = isGroupEvent
        self.groupControl = groupControl
```

Update the type's doc comment's last sentence to mention `createGroups` beside `addDisappearingMessages`.

- [ ] **Step 5: Create `ChatGroup.swift`**

```swift
import Foundation
import GRDB
import SQLiteData

/// One group the user created or was invited to (spec 2026-10-09 §2). Named `ChatGroup` because
/// SwiftUI owns `Group` and `GROUPS` is an SQLite keyword (amendment A1). `creatorHex` is the
/// roster authority: the sender of the first roster ever seen for this id, or me. `revision` is
/// the last applied roster revision. `state` is `GroupState.*`.
@Table
public struct ChatGroup: Equatable, Sendable {
    public var groupHex: String
    public var name: String
    public var creatorHex: String
    public var revision: Int
    public var state: String
    public var updatedAt: Date

    public init(groupHex: String, name: String, creatorHex: String, revision: Int, state: String, updatedAt: Date) {
        self.groupHex = groupHex
        self.name = name
        self.creatorHex = creatorHex
        self.revision = revision
        self.state = state
        self.updatedAt = updatedAt
    }

    /// Posts, reactions and leaves from members are accepted while the group is invited or active.
    public var isOpen: Bool { state == GroupState.active || state == GroupState.invited }

    public static func fetch(_ groupHex: String, _ db: GRDB.Database) throws -> ChatGroup? {
        try ChatGroup.where { $0.groupHex.eq(groupHex) }.fetchOne(db)
    }

    /// Upsert by primary key (delete then insert, as `ConversationSetting.set` does).
    public static func upsert(_ group: ChatGroup, _ db: GRDB.Database) throws {
        try ChatGroup.where { $0.groupHex.eq(group.groupHex) }.delete().execute(db)
        try ChatGroup.insert { group }.execute(db)
    }
}

public enum GroupState {
    /// A roster arrived for a group the user has not accepted yet.
    public static let invited = "invited"
    public static let active = "active"
    /// The user left, declined, or was removed. Read-only.
    public static let left = "left"
    /// The creator deleted the group (an empty roster). Read-only and terminal.
    public static let dissolved = "dissolved"
}

/// What an outgoing event line carries to the members (`Message.groupControl`).
public enum GroupControl {
    public static let roster = "roster"
    public static let leave = "leave"
}
```

- [ ] **Step 6: Create `GroupMember.swift`**

```swift
import Foundation
import GRDB
import SQLiteData

/// One member of one group, me included (spec 2026-10-09 §2). Replaced whole on every applied
/// roster, so the table always mirrors the creator's last roster.
@Table
public struct GroupMember: Equatable, Sendable {
    public var groupHex: String
    public var memberHex: String

    public init(groupHex: String, memberHex: String) {
        self.groupHex = groupHex
        self.memberHex = memberHex
    }

    /// The roster, sorted, so two rosters compare by value.
    public static func members(of groupHex: String, _ db: GRDB.Database) throws -> [String] {
        try GroupMember.where { $0.groupHex.eq(groupHex) }.fetchAll(db).map(\.memberHex).sorted()
    }

    public static func replace(_ groupHex: String, with members: [String], _ db: GRDB.Database) throws {
        try GroupMember.where { $0.groupHex.eq(groupHex) }.delete().execute(db)
        for member in Set(members) {
            try GroupMember.insert { GroupMember(groupHex: groupHex, memberHex: member) }.execute(db)
        }
    }

    public static func contains(_ groupHex: String, _ memberHex: String, _ db: GRDB.Database) throws -> Bool {
        try GroupMember.where { $0.groupHex.eq(groupHex) && $0.memberHex.eq(memberHex) }.fetchOne(db) != nil
    }
}
```

- [ ] **Step 7: Create `GroupDelivery.swift`**

```swift
import Foundation
import GRDB
import SQLiteData

/// One member's copy of one outgoing group row (spec 2026-10-09 §2): its LXMF hash once built,
/// and the outcome the delivery delegates reported for that hash. `messageHash` is nil and
/// `status` is `GroupDeliveryStatus.waiting` until the member has a path; from then on `status`
/// takes the `MessageStatus` values with the same first-milestone rules as `messages`.
@Table
public struct GroupDelivery: Equatable, Sendable {
    public var messageId: UUID
    public var memberHex: String
    public var messageHash: String?
    public var status: String
    public var storedAt: Date?
    public var deliveredAt: Date?
    public var failedAt: Date?

    public init(messageId: UUID, memberHex: String, messageHash: String?, status: String,
                storedAt: Date?, deliveredAt: Date?, failedAt: Date?) {
        self.messageId = messageId
        self.memberHex = memberHex
        self.messageHash = messageHash
        self.status = status
        self.storedAt = storedAt
        self.deliveredAt = deliveredAt
        self.failedAt = failedAt
    }

    /// A row that has not been sent yet: the member has no path.
    public static func waiting(messageId: UUID, memberHex: String) -> GroupDelivery {
        GroupDelivery(messageId: messageId, memberHex: memberHex, messageHash: nil,
                      status: GroupDeliveryStatus.waiting, storedAt: nil, deliveredAt: nil, failedAt: nil)
    }

    /// Rows keyed by their message, each list sorted by member so the UI order is stable.
    public static func byMessageId(_ rows: [GroupDelivery]) -> [UUID: [GroupDelivery]] {
        Dictionary(grouping: rows, by: \.messageId).mapValues { $0.sorted { $0.memberHex < $1.memberHex } }
    }
}

public enum GroupDeliveryStatus {
    /// Not sent yet: the member had no known path when the row was written.
    public static let waiting = "waiting"
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupTable > /tmp/ReTiCaMsgr/grp-t1-green.log 2>&1`
Expected: 6 tests passed.

- [ ] **Step 9: Mutation verification**

| Mutation (production code) | Test that must go RED |
|---|---|
| In `GroupMember.members(of:)`, delete `.sorted()` and insert the members in the order given (replace iterates `members` not `Set(members)` for this mutation) | `groupTableGroupAndMembersRoundTrip` |
| In the migration, drop `.references("chatGroups", onDelete: .cascade)` from `groupMembers.groupHex` | `groupTableDeletingGroupCascadesMembers` |
| In `Message.init`, replace `self.isGroupEvent = isGroupEvent` with `self.isGroupEvent = false` | `groupTableMessageColumnsRoundTrip` |
| In the migration, delete the `CREATE UNIQUE INDEX messages_groupPost` line | `groupTableDuplicatePostIdRejectedWithinGroupAllowedAcross` |
| In `GroupDelivery.byMessageId`, drop the `.sorted { ... }` | `groupTableDeliveriesRoundTripAndCascade` |
| In the migration, change `isGroupEvent`'s `.defaults(to: false)` to `.defaults(to: true)` | `groupTableLegacyRowReadsBackWithDefaults` |

Apply all six, run the filter once, confirm all six RED. Revert by hand, run again, all GREEN.

- [ ] **Step 10: Commit**

Write `/tmp/ReTiCaMsgr/msg-grp-task-1.txt`:

```
feat: group-chat schema and models

Adds chatGroups, groupMembers and groupDeliveries (migration createGroups),
the groupHex, groupPostId, isGroupEvent and groupControl columns on
messages with the per-group unique post index, and the ChatGroup,
GroupMember and GroupDelivery models with their fetch, upsert, replace
and grouping helpers.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C APP add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Database.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Message.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/ChatGroup.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/GroupMember.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/GroupDelivery.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/DatabaseTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-1.txt`

---

### Task 2: `GroupWire` codec

**Files:**
- Create: `CORE/Sources/ReTiCaMsgrCore/GroupWire.swift`
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/GroupWireTests.swift`

**Interfaces:**
- Produces: `GroupWire.fieldCustomMeta = 0xFD`, `groupKey`, `controlKey`, `idLength = 16`, `maxNameBytes = 32`, `maxMembers = 12`, `actionRoster = "roster"`, `actionLeave = "leave"`; `enum Decoded: Equatable, Sendable { case post(groupId: Data, postId: Data); case marker(groupId: Data); case roster(groupId: Data, name: String, members: [Data], revision: Int); case leave(groupId: Data) }`; `static func randomId() -> Data` (16 random bytes); `static func trimName(_ name: String) -> String` (trimmed, at most 32 UTF-8 bytes, cut on a Character boundary); `static func encodePost(groupId: Data, postId: Data) -> [MsgPackValue.IntPair]`; `static func encodeMarker(groupId: Data) -> [MsgPackValue.IntPair]`; `static func encodeRoster(groupId: Data, name: String, members: [Data], revision: Int) -> [MsgPackValue.IntPair]`; `static func encodeLeave(groupId: Data) -> [MsgPackValue.IntPair]`; `static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded?` (nil = not a group message). Every `encode*` returns exactly one 0xFD pair.

- [ ] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/GroupWireTests.swift`:

```swift
import Testing
import Foundation
import ReTiCA
@testable import ReTiCaMsgrCore

private let gid = Data((0..<16).map { UInt8($0 + 0x10) })
private let pid = Data((0..<16).map { UInt8(0xF0 - $0) })
private let memberX = Data(repeating: 0xAA, count: 16)
private let memberY = Data(repeating: 0xBB, count: 16)

/// A 0xFD field built by hand, so these tests pin the wire shape rather than `encode`.
private func meta(_ value: MsgPackValue) -> [MsgPackValue.IntPair] { [.init(0xFD, value)] }

private func ctl(_ pairs: [MsgPackValue.Pair], ids: [MsgPackValue] = [.bin(gid)]) -> [MsgPackValue.IntPair] {
    meta(.map([.init("reticamsgr.group", .array(ids)), .init("reticamsgr.group.ctl", .map(pairs))]))
}

@Test func groupWireConstantsMatchTheSpec() {
    #expect(GroupWire.fieldCustomMeta == 0xFD)
    #expect(GroupWire.groupKey == "reticamsgr.group")
    #expect(GroupWire.controlKey == "reticamsgr.group.ctl")
    #expect(GroupWire.idLength == 16)
    #expect(GroupWire.maxNameBytes == 32)
    #expect(GroupWire.maxMembers == 12)
    #expect(GroupWire.actionRoster == "roster")
    #expect(GroupWire.actionLeave == "leave")
}

@Test func groupWireRandomIdsAre16BytesAndDistinct() {
    let a = GroupWire.randomId()
    let b = GroupWire.randomId()
    #expect(a.count == 16)
    #expect(b.count == 16)
    #expect(a != b)
}

/// Spec §1: a post carries `[group id, post id]` under the group key, nothing else.
@Test func groupWireEncodePostIsOneMetaFieldWithBothIds() {
    let fields = GroupWire.encodePost(groupId: gid, postId: pid)
    #expect(fields.count == 1)
    #expect(fields[0].key == 0xFD)
    #expect(fields[0].value == .map([.init("reticamsgr.group", .array([.bin(gid), .bin(pid)]))]))
    #expect(GroupWire.decode(fields) == .post(groupId: gid, postId: pid))
}

@Test func groupWireEncodeMarkerIsOneIdOnly() {
    let fields = GroupWire.encodeMarker(groupId: gid)
    #expect(fields[0].value == .map([.init("reticamsgr.group", .array([.bin(gid)]))]))
    #expect(GroupWire.decode(fields) == .marker(groupId: gid))
}

/// Spec §1: the control map keys are `a`, `n`, `m`, `r`, in that order, with the full roster.
@Test func groupWireEncodeRosterShapeAndRoundTrip() throws {
    let fields = GroupWire.encodeRoster(groupId: gid, name: "Mutual Aid", members: [memberX, memberY], revision: 3)
    #expect(fields.count == 1)
    #expect(fields[0].value == .map([
        .init("reticamsgr.group", .array([.bin(gid)])),
        .init("reticamsgr.group.ctl", .map([
            .init("a", .string("roster")),
            .init("n", .string("Mutual Aid")),
            .init("m", .array([.bin(memberX), .bin(memberY)])),
            .init("r", .uint(3)),
        ])),
    ]))
    let m = LXMessage.create(
        source: Identity(),
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data("Mutual Aid".utf8),
        content: Data("Ada invited you to the group Mutual Aid in ReTiCaMsgr".utf8),
        fields: fields
    )
    let back = try #require(LXMessage.unpack(m.packed))
    #expect(back.fields.map(\.key) == [0xFD])
    #expect(GroupWire.decode(back.fields) == .roster(groupId: gid, name: "Mutual Aid", members: [memberX, memberY], revision: 3))
}

@Test func groupWireEncodeLeaveRoundTrips() {
    let fields = GroupWire.encodeLeave(groupId: gid)
    #expect(fields[0].value == .map([
        .init("reticamsgr.group", .array([.bin(gid)])),
        .init("reticamsgr.group.ctl", .map([.init("a", .string("leave"))])),
    ]))
    #expect(GroupWire.decode(fields) == .leave(groupId: gid))
}

/// An encoder trims the name to the cap so a local pick never produces an undecodable roster.
@Test func groupWireEncodeRosterTrimsTheName() {
    let long = String(repeating: "é", count: 20)   // 40 bytes
    let fields = GroupWire.encodeRoster(groupId: gid, name: "  " + long + "  ", members: [memberX], revision: 1)
    #expect(GroupWire.decode(fields) == .roster(groupId: gid, name: String(repeating: "é", count: 16), members: [memberX], revision: 1))
}

/// Review Focus 4: cut on a Character boundary, never mid-scalar, and whitespace trimmed first.
@Test func groupWireTrimNameKeepsCharacterBoundaries() {
    #expect(GroupWire.trimName("  Block 4  ") == "Block 4")
    #expect(GroupWire.trimName(String(repeating: "a", count: 40)) == String(repeating: "a", count: 32))
    let family = "👨‍👩‍👧‍👦"   // 25 bytes, one Character
    #expect(GroupWire.trimName(family + family) == family)
    #expect(GroupWire.trimName("") == "")
}

/// Not a group message: no field, a foreign 0xFD, no group key, or a value that is not an array
/// of one or two 16-byte ids.
@Test func groupWireDecodeIgnoresForeignAndMalformedIds() {
    #expect(GroupWire.decode([]) == nil)
    #expect(GroupWire.decode(meta(.bin(Data([1, 2, 3])))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.expiry", .uint(60))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .bin(gid))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .array([]))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .array([.bin(Data(repeating: 1, count: 15))]))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .array([.bin(gid), .bin(Data(repeating: 1, count: 32))]))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .array([.bin(gid), .string("x")]))]))) == nil)
    #expect(GroupWire.decode(meta(.map([.init("reticamsgr.group", .array([.bin(gid), .bin(pid), .bin(pid)]))]))) == nil)
}

/// Review Focus 4: an oversized name or roster, a bad member, or an unknown action is nil.
@Test func groupWireDecodeRejectsOversizedNameAndRoster() {
    let ok: [MsgPackValue.Pair] = [.init("a", .string("roster")), .init("n", .string("g")), .init("m", .array([.bin(memberX)])), .init("r", .uint(1))]
    #expect(GroupWire.decode(ctl(ok)) == .roster(groupId: gid, name: "g", members: [memberX], revision: 1))
    let thirteen = MsgPackValue.array((0..<13).map { .bin(Data(repeating: UInt8($0), count: 16)) })
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string("g")), .init("m", thirteen), .init("r", .uint(1))])) == nil)
    let twelve = MsgPackValue.array((0..<12).map { .bin(Data(repeating: UInt8($0), count: 16)) })
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string("g")), .init("m", twelve), .init("r", .uint(1))])) != nil)
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string(String(repeating: "x", count: 33))), .init("m", .array([.bin(memberX)])), .init("r", .uint(1))])) == nil)
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string("g")), .init("m", .array([.bin(Data(repeating: 1, count: 8))])), .init("r", .uint(1))])) == nil)
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string("g")), .init("m", .array([.bin(memberX)])), .init("r", .int(-1))])) == nil)
    #expect(GroupWire.decode(ctl([.init("a", .string("roster")), .init("n", .string("g")), .init("m", .array([.bin(memberX)]))])) == nil)
    #expect(GroupWire.decode(ctl([.init("a", .string("kick"))])) == nil)
    #expect(GroupWire.decode(ctl([.init("n", .string("g"))])) == nil)
    // A control map on a post-shaped entry is ignored: it is a post.
    #expect(GroupWire.decode(ctl([.init("a", .string("leave"))], ids: [.bin(gid), .bin(pid)])) == .post(groupId: gid, postId: pid))
}

/// Lenient where it is safe: extra keys ignored, a `bin` name accepted, a non-negative `int`
/// revision accepted, an empty roster accepted (that is a delete), and the group entry decodes
/// beside an expiry entry under both codecs.
@Test func groupWireDecodeIsLenientWhereSafe() {
    let extra = ctl([.init("a", .string("roster")), .init("n", .bin(Data("Block 4".utf8))), .init("m", .array([])), .init("r", .int(7)), .init("z", .null)])
    #expect(GroupWire.decode(extra) == .roster(groupId: gid, name: "Block 4", members: [], revision: 7))
    let mixed = meta(.map([
        .init("reticamsgr.expiry", .uint(600)),
        .init("reticamsgr.group", .array([.bin(gid), .bin(pid)])),
    ]))
    #expect(GroupWire.decode(mixed) == .post(groupId: gid, postId: pid))
    #expect(ExpiryWire.decode(mixed) == ExpiryWire.Decoded(seconds: 600, isChange: false))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupWire > /tmp/ReTiCaMsgr/grp-t2-red.log 2>&1`
Expected: compile errors (`GroupWire` unknown).

- [ ] **Step 3: Create `GroupWire.swift`**

```swift
import Foundation
import ReTiCA

/// Wire codec for group chats (spec 2026-10-09 §1). Everything rides in `FIELD_CUSTOM_META` (0xFD),
/// the string-keyed msgpack map `ExpiryWire` already uses, under two keys: `reticamsgr.group` is an
/// array of one or two 16-byte ids (`[group id, post id]` on a post, `[group id]` on a reaction or
/// control message), and `reticamsgr.group.ctl` is the control map `{a, n, m, r}` on a roster or
/// `{a}` on a leave. Other clients ignore the map and see an ordinary message.
///
/// Received leniently: no 0xFD, a 0xFD that is not a map, no group key, an id of the wrong length,
/// a roster over the caps, an unknown action, all decode as nil ("not a group message"). A
/// malformed field never drops the message. Group sends never carry the expiry key (amendment A9),
/// so the two codecs never have to merge one map.
public enum GroupWire {
    public static let fieldCustomMeta = 0xFD
    public static let groupKey = "reticamsgr.group"
    public static let controlKey = "reticamsgr.group.ctl"
    public static let idLength = 16
    public static let maxNameBytes = 32
    public static let maxMembers = 12
    public static let actionRoster = "roster"
    public static let actionLeave = "leave"
    static let actionKey = "a"
    static let nameKey = "n"
    static let membersKey = "m"
    static let revisionKey = "r"

    public enum Decoded: Equatable, Sendable {
        case post(groupId: Data, postId: Data)
        /// A reaction (or any non-post, non-control message) tagged with its group.
        case marker(groupId: Data)
        case roster(groupId: Data, name: String, members: [Data], revision: Int)
        case leave(groupId: Data)
    }

    /// 16 random bytes: a group id at creation, a post id at send.
    public static func randomId() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<idLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Whitespace trimmed, then at most `maxNameBytes` of UTF-8, dropping whole Characters from the
    /// end so an emoji sequence is never split.
    public static func trimName(_ name: String) -> String {
        var kept = Substring(name.trimmingCharacters(in: .whitespacesAndNewlines))
        while !kept.isEmpty, kept.utf8.count > maxNameBytes {
            kept = kept.dropLast()
        }
        return String(kept)
    }

    public static func encodePost(groupId: Data, postId: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([.init(groupKey, .array([.bin(groupId), .bin(postId)]))]))]
    }

    public static func encodeMarker(groupId: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([.init(groupKey, .array([.bin(groupId)]))]))]
    }

    /// The full roster every time, the creator included, at most `maxMembers` entries.
    public static func encodeRoster(groupId: Data, name: String, members: [Data], revision: Int) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([
            .init(groupKey, .array([.bin(groupId)])),
            .init(controlKey, .map([
                .init(actionKey, .string(actionRoster)),
                .init(nameKey, .string(trimName(name))),
                .init(membersKey, .array(members.prefix(maxMembers).map { .bin($0) })),
                .init(revisionKey, .uint(UInt64(max(0, revision)))),
            ])),
        ]))]
    }

    public static func encodeLeave(groupId: Data) -> [MsgPackValue.IntPair] {
        [.init(fieldCustomMeta, .map([
            .init(groupKey, .array([.bin(groupId)])),
            .init(controlKey, .map([.init(actionKey, .string(actionLeave))])),
        ]))]
    }

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded? {
        guard case let .map(pairs)? = fields.first(where: { $0.key == fieldCustomMeta })?.value,
              case let .array(ids)? = pairs.first(where: { $0.key == groupKey })?.value,
              (1...2).contains(ids.count),
              let groupId = id(ids[0])
        else { return nil }
        if ids.count == 2 {
            guard let postId = id(ids[1]) else { return nil }
            return .post(groupId: groupId, postId: postId)
        }
        guard case let .map(control)? = pairs.first(where: { $0.key == controlKey })?.value else {
            return .marker(groupId: groupId)
        }
        guard case let .string(action)? = control.first(where: { $0.key == actionKey })?.value else { return nil }
        switch action {
        case actionLeave:
            return .leave(groupId: groupId)
        case actionRoster:
            guard let name = name(control.first(where: { $0.key == nameKey })?.value),
                  case let .array(rawMembers)? = control.first(where: { $0.key == membersKey })?.value,
                  rawMembers.count <= maxMembers,
                  let revision = revision(control.first(where: { $0.key == revisionKey })?.value)
            else { return nil }
            var members: [Data] = []
            for raw in rawMembers {
                guard let member = id(raw) else { return nil }
                members.append(member)
            }
            return .roster(groupId: groupId, name: name, members: members, revision: revision)
        default:
            return nil
        }
    }

    /// A 16-byte bin, else nil.
    private static func id(_ value: MsgPackValue) -> Data? {
        guard case let .bin(bytes) = value, bytes.count == idLength else { return nil }
        return bytes
    }

    /// `str` or strict-UTF-8 `bin`, within the byte cap.
    private static func name(_ value: MsgPackValue?) -> String? {
        switch value {
        case let .string(s):
            return s.utf8.count <= maxNameBytes ? s : nil
        case let .bin(bytes):
            guard bytes.count <= maxNameBytes else { return nil }
            let text = String(decoding: bytes, as: UTF8.self)
            return Data(text.utf8) == bytes ? text : nil
        default:
            return nil
        }
    }

    /// `uint` or a non-negative `int` tag, within `Int`.
    private static func revision(_ value: MsgPackValue?) -> Int? {
        switch value {
        case let .uint(u): return u <= UInt64(Int.max) ? Int(u) : nil
        case let .int(i): return i >= 0 ? Int(i) : nil
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupWire > /tmp/ReTiCaMsgr/grp-t2-green.log 2>&1`
Expected: 11 tests passed.

- [ ] **Step 5: Mutation verification**

| Mutation (production code) | Test that must go RED |
|---|---|
| `encodePost`: swap the order to `[.bin(postId), .bin(groupId)]` | `groupWireEncodePostIsOneMetaFieldWithBothIds` |
| `encodeMarker`: emit `.array([.bin(groupId), .bin(groupId)])` | `groupWireEncodeMarkerIsOneIdOnly` |
| `encodeRoster`: write `revisionKey` as `.int(Int64(revision))` | `groupWireEncodeRosterShapeAndRoundTrip` |
| `encodeLeave`: write `actionRoster` instead of `actionLeave` | `groupWireEncodeLeaveRoundTrips` |
| `encodeRoster`: use `name` instead of `trimName(name)` | `groupWireEncodeRosterTrimsTheName` |
| `trimName`: change `kept.utf8.count > maxNameBytes` to `kept.count > maxNameBytes` | `groupWireTrimNameKeepsCharacterBoundaries` |
| `id(_:)`: change `bytes.count == idLength` to `bytes.count >= idLength` | `groupWireDecodeIgnoresForeignAndMalformedIds` |
| `decode`: change `rawMembers.count <= maxMembers` to `<= maxMembers + 1` | `groupWireDecodeRejectsOversizedNameAndRoster` |
| `name(_:)`: in the `.bin` case return `nil` unconditionally | `groupWireDecodeIsLenientWhereSafe` |
| `randomId`: return `Data(repeating: 0, count: idLength)` | `groupWireRandomIdsAre16BytesAndDistinct` |

Sub-batch A: the first five rows together. Sub-batch B: the last five together. `groupWireConstantsMatchTheSpec` is pinned by any constant edit and needs no mutation.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCaMsgr/msg-grp-task-2.txt`:

```
feat: GroupWire codec for the 0xFD group entries

Encodes and leniently decodes the post, marker, roster and leave shapes
under reticamsgr.group and reticamsgr.group.ctl, with the id, name and
roster caps, a random id helper and a Character-safe name trim.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C APP add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/GroupWire.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/GroupWireTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-2.txt`

---

### Task 3: `GroupRoster` rules, derived status, `GroupEventText`

**Files:**
- Create: `CORE/Sources/ReTiCaMsgrCore/GroupRoster.swift`
- Create: `CORE/Sources/ReTiCaMsgrCore/GroupEventText.swift`
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/GroupRulesTests.swift`

**Interfaces:**
- Produces: `GroupRoster.applies(revision: Int, from senderHex: String, to stored: ChatGroup?) -> Bool`; `struct GroupRoster.Diff: Equatable, Sendable { added: [String]; removed: [String]; renamed: String?; dissolved: Bool }`; `GroupRoster.diff(oldMembers: [String], oldName: String, newMembers: [String], newName: String) -> Diff` (lists sorted); `GroupRoster.derivedStatus(_ rows: [GroupDelivery]) -> String`; `GroupRoster.statusLabel(_ rows: [GroupDelivery]) -> String`. `GroupEventText`: `you = "You"`, `appName = "ReTiCaMsgr"`, `caveat`, `fallbackName(_ hex: String) -> String` (first 8 characters), the line functions `created(name:)`, `invited(by:name:)`, `added(by:who:)`, `removed(by:who:)`, `removedYou(by:)`, `renamed(by:to:)`, `left(who:)`, `declined()`, `deleted(by:)`, and the wire bodies `rosterBody(inviter:name:)`, `leaveBody(who:name:)`, `deleteBody(who:name:)`.

- [ ] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/GroupRulesTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCaMsgrCore

private let creator = String(repeating: "c", count: 32)
private let other = String(repeating: "d", count: 32)
private let me = String(repeating: "e", count: 32)
private let groupHex = String(repeating: "1a", count: 16)
private let messageId = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!

private func stored(revision: Int, state: String = GroupState.active) -> ChatGroup {
    ChatGroup(groupHex: groupHex, name: "g", creatorHex: creator, revision: revision, state: state,
              updatedAt: Date(timeIntervalSince1970: 1700000000))
}

private func delivery(_ member: String, _ status: String) -> GroupDelivery {
    GroupDelivery(messageId: messageId, memberHex: member, messageHash: status == GroupDeliveryStatus.waiting ? nil : "h",
                  status: status, storedAt: nil, deliveredAt: nil, failedAt: nil)
}

/// Spec §1 receive rules: the first roster for an id establishes its creator, later ones must come
/// from that creator with a strictly higher revision, and a dissolved group never revives.
@Test func groupRulesRosterAppliesOnlyFromCreatorWithHigherRevision() {
    #expect(GroupRoster.applies(revision: 1, from: other, to: nil) == true)
    #expect(GroupRoster.applies(revision: 2, from: creator, to: stored(revision: 1)) == true)
    #expect(GroupRoster.applies(revision: 1, from: creator, to: stored(revision: 1)) == false)
    #expect(GroupRoster.applies(revision: 0, from: creator, to: stored(revision: 1)) == false)
    #expect(GroupRoster.applies(revision: 9, from: other, to: stored(revision: 1)) == false)
    #expect(GroupRoster.applies(revision: 9, from: creator, to: stored(revision: 1, state: GroupState.dissolved)) == false)
    #expect(GroupRoster.applies(revision: 9, from: creator, to: stored(revision: 1, state: GroupState.left)) == true)
}

@Test func groupRulesDiffYieldsAddedRemovedRenamedAndDissolved() {
    let diff = GroupRoster.diff(oldMembers: [creator, me, other], oldName: "g",
                                newMembers: [me, creator, "ff" + String(repeating: "0", count: 30)], newName: "G2")
    #expect(diff == GroupRoster.Diff(added: ["ff" + String(repeating: "0", count: 30)], removed: [other], renamed: "G2", dissolved: false))
    let same = GroupRoster.diff(oldMembers: [me, creator], oldName: "g", newMembers: [creator, me], newName: "g")
    #expect(same == GroupRoster.Diff(added: [], removed: [], renamed: nil, dissolved: false))
    let gone = GroupRoster.diff(oldMembers: [me, creator], oldName: "g", newMembers: [], newName: "g")
    #expect(gone == GroupRoster.Diff(added: [], removed: [creator, me], renamed: nil, dissolved: true))
    // Sorted output, whatever order the inputs came in.
    let two = GroupRoster.diff(oldMembers: [], oldName: "g", newMembers: [other, creator], newName: "g")
    #expect(two.added == [creator, other])
}

/// Amendment A8: sending beats everything, then delivered, stored, failed, else sent.
@Test func groupRulesDerivedStatusFollowsTheAmendmentOrder() {
    let d = MessageStatus.delivered, s = MessageStatus.propagated, f = MessageStatus.failed
    let c = MessageStatus.cancelled, g = MessageStatus.sending, w = GroupDeliveryStatus.waiting
    #expect(GroupRoster.derivedStatus([]) == MessageStatus.sent)
    #expect(GroupRoster.derivedStatus([delivery(creator, d), delivery(other, w)]) == MessageStatus.sending)
    #expect(GroupRoster.derivedStatus([delivery(creator, f), delivery(other, g)]) == MessageStatus.sending)
    #expect(GroupRoster.derivedStatus([delivery(creator, d), delivery(other, d)]) == MessageStatus.delivered)
    #expect(GroupRoster.derivedStatus([delivery(creator, d), delivery(other, s)]) == MessageStatus.propagated)
    #expect(GroupRoster.derivedStatus([delivery(creator, s)]) == MessageStatus.propagated)
    #expect(GroupRoster.derivedStatus([delivery(creator, f), delivery(other, c)]) == MessageStatus.failed)
    #expect(GroupRoster.derivedStatus([delivery(creator, d), delivery(other, f)]) == MessageStatus.sent)
    #expect(GroupRoster.derivedStatus([delivery(creator, MessageStatus.sent), delivery(other, d)]) == MessageStatus.sent)
}

/// Spec §4: "Delivered to d of n" while partial, else the derived status word.
@Test func groupRulesStatusLabelCountsDeliveries() {
    let d = MessageStatus.delivered, f = MessageStatus.failed, g = MessageStatus.sending
    #expect(GroupRoster.statusLabel([]) == "sent")
    #expect(GroupRoster.statusLabel([delivery(creator, g), delivery(other, g)]) == "sending")
    #expect(GroupRoster.statusLabel([delivery(creator, d), delivery(other, g)]) == "Delivered to 1 of 2")
    #expect(GroupRoster.statusLabel([delivery(creator, d), delivery(other, f)]) == "Delivered to 1 of 2")
    #expect(GroupRoster.statusLabel([delivery(creator, d), delivery(other, d)]) == "delivered")
    #expect(GroupRoster.statusLabel([delivery(creator, f), delivery(other, f)]) == "failed")
}

@Test func groupRulesEventLinesReadAsSpecified() {
    #expect(GroupEventText.you == "You")
    #expect(GroupEventText.fallbackName(String(repeating: "ab", count: 16)) == "abababab")
    #expect(GroupEventText.created(name: "Mutual Aid") == "You created the group Mutual Aid")
    #expect(GroupEventText.invited(by: "Ada", name: "Mutual Aid") == "Ada invited you to the group Mutual Aid")
    #expect(GroupEventText.added(by: "Ada", who: "Bob") == "Ada added Bob")
    #expect(GroupEventText.added(by: "You", who: "Bob, Cy") == "You added Bob, Cy")
    #expect(GroupEventText.removed(by: "Ada", who: "Bob") == "Ada removed Bob")
    #expect(GroupEventText.removedYou(by: "Ada") == "Ada removed you from the group")
    #expect(GroupEventText.renamed(by: "Ada", to: "Block 4") == "Ada renamed the group to Block 4")
    #expect(GroupEventText.left(who: "Bob") == "Bob left the group")
    #expect(GroupEventText.left(who: "You") == "You left the group")
    #expect(GroupEventText.declined() == "You declined the invitation")
    #expect(GroupEventText.deleted(by: "Ada") == "Ada deleted the group")
}

/// Amendment A4: the bodies other clients see.
@Test func groupRulesWireBodiesNameTheAppAndGroup() {
    #expect(GroupEventText.rosterBody(inviter: "Ada", name: "Mutual Aid") == "Ada invited you to the group Mutual Aid in ReTiCaMsgr")
    #expect(GroupEventText.leaveBody(who: "Bob", name: "Mutual Aid") == "Bob left the group Mutual Aid")
    #expect(GroupEventText.deleteBody(who: "Ada", name: "Mutual Aid") == "Ada deleted the group Mutual Aid")
    #expect(GroupEventText.caveat == "Members on other apps see posts as separate direct messages and cannot reply to the group.")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupRules > /tmp/ReTiCaMsgr/grp-t3-red.log 2>&1`
Expected: compile errors (`GroupRoster`, `GroupEventText` unknown).

- [ ] **Step 3: Create `GroupRoster.swift`**

```swift
import Foundation

/// The pure group rules (spec 2026-10-09 §3): whether a roster applies, what changed between two
/// rosters, and a post's status derived from its per-member delivery rows (amendment A8).
public enum GroupRoster {
    public struct Diff: Equatable, Sendable {
        public var added: [String]
        public var removed: [String]
        /// The new name when it changed, else nil.
        public var renamed: String?
        /// The new roster is empty: the creator deleted the group.
        public var dissolved: Bool

        public init(added: [String], removed: [String], renamed: String?, dissolved: Bool) {
            self.added = added
            self.removed = removed
            self.renamed = renamed
            self.dissolved = dissolved
        }
    }

    /// Spec §1 receive rules. No stored group: the first roster establishes its creator. A stored
    /// group: only its creator, only a strictly higher revision, and never once dissolved.
    public static func applies(revision: Int, from senderHex: String, to stored: ChatGroup?) -> Bool {
        guard let stored else { return true }
        return stored.creatorHex == senderHex
            && revision > stored.revision
            && stored.state != GroupState.dissolved
    }

    public static func diff(oldMembers: [String], oldName: String, newMembers: [String], newName: String) -> Diff {
        let old = Set(oldMembers)
        let new = Set(newMembers)
        return Diff(added: new.subtracting(old).sorted(),
                    removed: old.subtracting(new).sorted(),
                    renamed: newName == oldName ? nil : newName,
                    dissolved: new.isEmpty)
    }

    /// Amendment A8, in order: `sending` while any copy is waiting or sending; `delivered` when
    /// every copy was proved; `stored` when every copy was proved or stored and at least one was
    /// stored; `failed` when every copy failed or was cancelled; otherwise `sent`. No copies at
    /// all (a group of one) is `sent`.
    public static func derivedStatus(_ rows: [GroupDelivery]) -> String {
        guard !rows.isEmpty else { return MessageStatus.sent }
        let statuses = rows.map(\.status)
        if statuses.contains(where: { $0 == GroupDeliveryStatus.waiting || $0 == MessageStatus.sending }) {
            return MessageStatus.sending
        }
        if statuses.allSatisfy({ $0 == MessageStatus.delivered }) { return MessageStatus.delivered }
        if statuses.allSatisfy({ $0 == MessageStatus.delivered || $0 == MessageStatus.propagated }) {
            return MessageStatus.propagated
        }
        if statuses.allSatisfy({ $0 == MessageStatus.failed || $0 == MessageStatus.cancelled }) {
            return MessageStatus.failed
        }
        return MessageStatus.sent
    }

    /// The bubble's status text (spec §4): "Delivered to d of n" while some but not all members
    /// proved receipt, else the derived status word.
    public static func statusLabel(_ rows: [GroupDelivery]) -> String {
        let delivered = rows.filter { $0.status == MessageStatus.delivered }.count
        if delivered > 0, delivered < rows.count {
            return "Delivered to \(delivered) of \(rows.count)"
        }
        return derivedStatus(rows)
    }
}
```

- [ ] **Step 4: Create `GroupEventText.swift`**

```swift
import Foundation

/// The system lines a group thread shows and the readable bodies group control messages carry
/// for other LXMF clients (spec 2026-10-09 §1 and §3, amendment A4). Pure, so every string is
/// testable and the same text serves the thread, the list preview and the wire.
public enum GroupEventText {
    public static let you = "You"
    public static let appName = "ReTiCaMsgr"
    /// Shown on the group info screen (spec §4).
    public static let caveat = "Members on other apps see posts as separate direct messages and cannot reply to the group."

    /// A member with no announce display name: the first eight hex characters of their address.
    public static func fallbackName(_ hex: String) -> String { String(hex.prefix(8)) }

    // MARK: Lines in the thread

    public static func created(name: String) -> String { "\(you) created the group \(name)" }
    public static func invited(by inviter: String, name: String) -> String { "\(inviter) invited you to the group \(name)" }
    public static func added(by actor: String, who: String) -> String { "\(actor) added \(who)" }
    public static func removed(by actor: String, who: String) -> String { "\(actor) removed \(who)" }
    public static func removedYou(by actor: String) -> String { "\(actor) removed you from the group" }
    public static func renamed(by actor: String, to name: String) -> String { "\(actor) renamed the group to \(name)" }
    public static func left(who: String) -> String { "\(who) left the group" }
    public static func declined() -> String { "\(you) declined the invitation" }
    public static func deleted(by actor: String) -> String { "\(actor) deleted the group" }

    // MARK: Bodies on the wire

    /// Every roster message carries the invite sentence (amendment A4).
    public static func rosterBody(inviter: String, name: String) -> String {
        "\(inviter) invited you to the group \(name) in \(appName)"
    }
    public static func leaveBody(who: String, name: String) -> String { "\(who) left the group \(name)" }
    public static func deleteBody(who: String, name: String) -> String { "\(who) deleted the group \(name)" }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupRules > /tmp/ReTiCaMsgr/grp-t3-green.log 2>&1`
Expected: 6 tests passed.

- [ ] **Step 6: Mutation verification**

| Mutation (production code) | Test that must go RED |
|---|---|
| `applies`: change `revision > stored.revision` to `>=` | `groupRulesRosterAppliesOnlyFromCreatorWithHigherRevision` |
| `diff`: compute `removed` as `new.subtracting(old).sorted()` | `groupRulesDiffYieldsAddedRemovedRenamedAndDissolved` |
| `derivedStatus`: delete the `propagated` branch | `groupRulesDerivedStatusFollowsTheAmendmentOrder` |
| `statusLabel`: change `delivered < rows.count` to `delivered <= rows.count` | `groupRulesStatusLabelCountsDeliveries` |
| `removedYou`: return `"\(actor) removed you"` | `groupRulesEventLinesReadAsSpecified` |
| `rosterBody`: drop ` in \(appName)` | `groupRulesWireBodiesNameTheAppAndGroup` |

Apply all six, run the filter once, confirm all six RED. Revert by hand, run again, all GREEN.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCaMsgr/msg-grp-task-3.txt`:

```
feat: group roster rules, derived status and event text

GroupRoster decides which rosters apply, diffs two rosters, and derives a
post's status and bubble label from its delivery rows. GroupEventText
holds the system lines and the readable wire bodies.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C APP add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/GroupRoster.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/GroupEventText.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/GroupRulesTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-3.txt`

---

### Task 4: `Conversation` kinds, group thread state and loading

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/Conversation.swift`
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` (State, Action, `openConversation`, `startConversation`, `closeConversation`, `threadLoaded`, new cases, `reloadConversations`, `reloadThread`)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/ConversationTests.swift` (append)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (append; also adds the shared group helpers Tasks 5–10 use)

**Interfaces:**
- Consumes: Task 1.
- Produces: `Conversation.Kind` (`.peer`, `.group`), `Conversation.kind`, `Conversation.title: String?`, `Conversation.groupState: String?`; `Conversation.list(from:attachments:groups: [String: ChatGroup])`. `AppFeature.ConversationKind` (`.peer`, `.group`); `State.openConversationKind`, `State.openGroup: ChatGroup?`, `State.openGroupMembers: [GroupMember]` (sorted by member), `State.deliveriesByMessageId: [UUID: [GroupDelivery]]`; computed `State.myName`, `State.isOpenGroupCreator`, `State.openGroupOthers: [String]`, `State.anyGroupMemberReachable`, `State.groupMemberName(_ hex: String) -> String`, `State.threadSenderNames: [String: String]`. `Action.openGroupConversation(String)`, `Action.groupLoaded(groupHex: String, group: ChatGroup?, members: [GroupMember], deliveries: [GroupDelivery])`. `reloadThread(_:_:_:)` now sends `groupLoaded` first, then `threadLoaded`, then `conversationExpiryLoaded`, and selects rows by amendment A13. Test helpers in `AppFeatureTests.swift`: `groupHexA`, `memberC`, `memberD`, `groupStore(_:identity:name:creatorHex:members:state:reachable:configure:)`, `groupSends(_:_:count:)`, `groupMemberHash(_:)`.

- [ ] **Step 1: Write the failing tests**

Append to `CORE/Tests/ReTiCaMsgrCoreTests/ConversationTests.swift`:

```swift

// MARK: - Group chats (spec 2026-10-09 §2)

/// Group rows collapse by group id with the group's name as title, one-to-one rows by peer as
/// before, and the newest row wins inside each.
@Test func groupConvListCollapsesByGroupAndCarriesTitle() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = Date(timeIntervalSince1970: 2000)
    let t2 = Date(timeIntervalSince1970: 3000)
    let g = String(repeating: "1a", count: 16)
    func row(_ peer: String, _ body: String, _ ts: Date, group: String? = nil) -> Message {
        Message(id: UUID(), peerHex: peer, isOutgoing: false, body: body, timestamp: ts,
                status: MessageStatus.received, validated: true, messageHash: "", groupHex: group)
    }
    let groups = [g: ChatGroup(groupHex: g, name: "Mutual Aid", creatorHex: "cc", revision: 1,
                               state: GroupState.invited, updatedAt: t0)]
    let convos = Conversation.list(from: [
        row("aa", "from aa", t1),
        row("aa", "aa in group", t0, group: g),
        row("bb", "bb in group", t2, group: g),
    ], groups: groups)
    #expect(convos.count == 2)
    #expect(convos[0].peerHex == g)
    #expect(convos[0].kind == .group)
    #expect(convos[0].title == "Mutual Aid")
    #expect(convos[0].groupState == "invited")
    #expect(convos[0].lastBody == "bb in group")
    #expect(convos[1].peerHex == "aa")
    #expect(convos[1].kind == .peer)
    #expect(convos[1].title == nil)
    #expect(convos[1].lastBody == "from aa")
    // A group row whose group is unknown still lists, under a placeholder title.
    let orphan = Conversation.list(from: [row("aa", "x", t0, group: "ff")])
    #expect(orphan.first?.title == "Group")
}
```

Append to `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`:

```swift

// MARK: - Group chats: shared helpers (spec 2026-10-09)

private let groupHexA = String(repeating: "1a", count: 16)
private let memberC = String(repeating: "c", count: 32)
private let memberD = String(repeating: "d", count: 32)

private func groupMemberHash(_ identity: Identity) -> Data { LXMessage.deliveryHash(identityHash: identity.hash) }

/// Seeds `groupHexA` with `members` plus me and returns a store with it open as a group thread.
/// `creatorHex` nil means I created it.
@MainActor
private func groupStore(_ db: any DatabaseWriter, identity: Identity, name: String = "Mutual Aid",
                        creatorHex: String? = nil, members: [String],
                        state groupState: String = GroupState.active,
                        reachable: Set<String> = [],
                        configure: ((inout AppFeature.State) -> Void)? = nil) async -> TestStoreOf<AppFeature> {
    let me = lxmfAddressHex(identity)
    let group = ChatGroup(groupHex: groupHexA, name: name, creatorHex: creatorHex ?? me, revision: 1,
                          state: groupState, updatedAt: infoT0)
    let roster = Set(members + [me]).sorted()
    try! await db.write { db in
        try ChatGroup.upsert(group, db)
        try GroupMember.replace(groupHexA, with: roster, db)
    }
    return makeStore(db, identity: identity) { s in
        s.openPeerHex = groupHexA
        s.openConversationKind = .group
        s.chatVisible = true
        s.openGroup = group
        s.openGroupMembers = roster.map { GroupMember(groupHex: groupHexA, memberHex: $0) }
        s.reachablePeers = reachable
        configure?(&s)
    }
}

/// The LXMessages handed to the node after `action`: exactly `count` sendMessage actions are
/// awaited, then the rest are drained. Never `finish()` here (Global Constraints).
@MainActor
private func groupSends(_ store: TestStoreOf<AppFeature>, _ action: AppFeature.Action, count: Int) async -> [LXMessage] {
    var sent: [LXMessage] = []
    await store.send(action)
    for _ in 0..<count {
        await store.receive { a in
            if case let .node(.client(.sendMessage(m, _))) = a { sent.append(m); return true }
            return false
        }
    }
    await store.skipReceivedActions(strict: false)
    return sent
}

// MARK: - Group chats: conversation kinds and loading (Task 4)

/// Opening a group loads its row, members and the outgoing rows' deliveries, and the thread holds
/// only that group's rows: a one-to-one message from a member stays in the member's own thread.
@MainActor @Test func groupConvOpenGroupLoadsGroupMembersDeliveriesAndThread() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, members: [memberC, memberD])
    let post = Message(id: uuid(1), peerHex: myHex, isOutgoing: true, body: "to the group", timestamp: infoT0,
                       status: MessageStatus.sending, validated: false, messageHash: String(repeating: "3c", count: 16),
                       groupHex: groupHexA, groupPostId: String(repeating: "3c", count: 16))
    let direct = msg(2, memberC, "just to me", 1700000001, outgoing: false, status: MessageStatus.received)
    let fromC = Message(id: uuid(3), peerHex: memberC, isOutgoing: false, body: "C in group", timestamp: infoT0.addingTimeInterval(2),
                        status: MessageStatus.received, validated: true, messageHash: String(repeating: "4d", count: 16),
                        groupHex: groupHexA, groupPostId: String(repeating: "4d", count: 16))
    try await db.write { db in
        for row in [post, direct, fromC] { try Message.insert { row }.execute(db) }
        try GroupDelivery.insert { GroupDelivery.waiting(messageId: post.id, memberHex: memberD) }.execute(db)
        try GroupDelivery.insert { GroupDelivery.waiting(messageId: post.id, memberHex: memberC) }.execute(db)
    }
    await store.send(.closeConversation)
    #expect(store.state.openGroup == nil)
    #expect(store.state.openConversationKind == .peer)
    await store.send(.openGroupConversation(groupHexA))
    #expect(store.state.openConversationKind == .group)
    await store.receive { if case .groupLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.openGroup?.name == "Mutual Aid")
    #expect(store.state.openGroupMembers.map(\.memberHex) == [memberC, memberD, myHex].sorted())
    #expect(store.state.deliveriesByMessageId[post.id]?.map(\.memberHex) == [memberC, memberD])
    #expect(store.state.threadMessages.map(\.body) == ["to the group", "C in group"])
    #expect(store.state.openGroupOthers == [memberC, memberD])
    #expect(store.state.isOpenGroupCreator == true)
    await store.skipReceivedActions(strict: false)
    // The member's own thread holds only the one-to-one row.
    await store.send(.openConversation(memberC))
    #expect(store.state.openConversationKind == .peer)
    await store.receive { if case .groupLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.openGroup == nil)
    #expect(store.state.openGroupMembers.isEmpty)
    #expect(store.state.threadMessages.map(\.body) == ["just to me"])
    await store.skipReceivedActions(strict: false)
}

/// Spec §3: a group thread asks for the paths of the members it cannot reach, so Send unlocks
/// when they answer; a reachable member gets no request.
@MainActor @Test func groupConvOpenGroupRequestsPathsForUnreachableMembers() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = await groupStore(db, identity: me, members: [memberC, memberD], reachable: [memberC])
    await store.send(.openGroupConversation(groupHexA))
    await store.receive { a in
        if case let .node(.client(.endpoint(.requestPath(dest)))) = a { return dest == Data(hexString: memberD)! }
        return false
    }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberD)!] != nil)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberC)!] == nil)
    #expect(store.state.anyGroupMemberReachable == true)
}

/// Reactions in a group thread are kept for me and current members only (spec §2).
@MainActor @Test func groupConvThreadReactionsFilteredToMembers() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let postId = String(repeating: "5e", count: 16)
    let store = await groupStore(db, identity: me, members: [memberC])
    try await db.write { db in
        try Message.insert {
            Message(id: uuid(1), peerHex: memberC, isOutgoing: false, body: "p", timestamp: infoT0,
                    status: MessageStatus.received, validated: true, messageHash: postId,
                    groupHex: groupHexA, groupPostId: postId)
        }.execute(db)
        try Reaction.apply(Reaction(messageHash: postId, reactorHex: memberC, emoji: "👍", sentAt: 1), db)
        try Reaction.apply(Reaction(messageHash: postId, reactorHex: myHex, emoji: "❤️", sentAt: 2), db)
        try Reaction.apply(Reaction(messageHash: postId, reactorHex: memberD, emoji: "😂", sentAt: 3), db)   // not a member
    }
    await store.send(.openGroupConversation(groupHexA))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions[postId]?.map(\.emoji) == ["👍", "❤️"])
    await store.skipReceivedActions(strict: false)
}

@MainActor @Test func groupConvCloseResetsGroupState() async throws {
    let store = await groupStore(try AppDatabase.makeInMemory(), identity: Identity(), members: [memberC]) { s in
        s.deliveriesByMessageId = [uuid(1): [GroupDelivery.waiting(messageId: uuid(1), memberHex: memberC)]]
    }
    await store.send(.closeConversation)
    #expect(store.state.openConversationKind == .peer)
    #expect(store.state.openGroup == nil)
    #expect(store.state.openGroupMembers.isEmpty)
    #expect(store.state.deliveriesByMessageId.isEmpty)
}

/// Names: me is "You", an announced member its display name, anyone else a short hex. The
/// sender-name map covers announced members only.
@MainActor @Test func groupConvMemberNamesFallBack() async throws {
    let me = Identity()
    let store = await groupStore(try AppDatabase.makeInMemory(), identity: me, members: [memberC, memberD]) { s in
        s.$displayName.withLock { $0 = "  Ada  " }
    }
    let learned = LXMFNode.LearnedPeer(displayName: "Cy", stampCost: nil, supportsCompression: false, learnedAt: infoT0)
    await store.send(.node(.client(.rehydrateLearnedPeers([Data(hexString: memberC)!: learned]))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.myName == "Ada")
    #expect(store.state.groupMemberName(lxmfAddressHex(me)) == "You")
    #expect(store.state.groupMemberName(memberC) == "Cy")
    #expect(store.state.groupMemberName(memberD) == "dddddddd")
    #expect(store.state.threadSenderNames == [memberC: "Cy"])
    let unnamed = makeStore(try AppDatabase.makeInMemory(), identity: me)
    #expect(unnamed.state.myName == String(lxmfAddressHex(me).prefix(8)))
}

/// A late `groupLoaded` for a thread the user has left changes nothing.
@MainActor @Test func groupConvLateGroupLoadIsIgnored() async throws {
    let store = makeStore(try AppDatabase.makeInMemory(), identity: Identity()) { $0.openPeerHex = peerA }
    let group = ChatGroup(groupHex: groupHexA, name: "g", creatorHex: memberC, revision: 1, state: GroupState.active, updatedAt: infoT0)
    await store.send(.groupLoaded(groupHex: groupHexA, group: group, members: [GroupMember(groupHex: groupHexA, memberHex: memberC)], deliveries: []))
    #expect(store.state.openGroup == nil)
    #expect(store.state.openGroupMembers.isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupConv > /tmp/ReTiCaMsgr/grp-t4-red.log 2>&1`
Expected: compile errors (`kind`, `openGroupConversation` unknown).

- [ ] **Step 3: `Conversation` kinds**

Replace the whole of `CORE/Sources/ReTiCaMsgrCore/Conversation.swift` above `isValidPeerAddress` with:

```swift
import Foundation

/// A derived (never-persisted) summary of one thread: a peer's, or a group's (spec 2026-10-09
/// §2, amendment A11). `peerHex` is the list key: the other party's lxmf.delivery hash (hex), or
/// for a group its group id.
public struct Conversation: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case peer, group }

    public var peerHex: String
    public var kind: Kind
    /// The group's name; nil for a peer.
    public var title: String?
    /// `GroupState.*` for a group; nil for a peer.
    public var groupState: String?
    public var lastBody: String
    public var lastTimestamp: Date
    public var id: String { peerHex }

    public init(peerHex: String, kind: Kind = .peer, title: String? = nil, groupState: String? = nil,
                lastBody: String, lastTimestamp: Date) {
        self.peerHex = peerHex
        self.kind = kind
        self.title = title
        self.groupState = groupState
        self.lastBody = lastBody
        self.lastTimestamp = lastTimestamp
    }
}

public extension Conversation {
    /// A group row whose group is not stored (it should not happen) shows this.
    static let unknownGroupTitle = "Group"

    /// Build the conversation list from all messages: keep the newest row per key (the group id
    /// for a group row, else `peerHex`), sorted most-recent-first. `attachments` (by message id)
    /// supplies the preview for a message whose body is empty because it carried a photo or a
    /// file; `groups` (by group id) supplies the titles.
    static func list(from messages: [Message], attachments: [UUID: Attachment] = [:],
                     groups: [String: ChatGroup] = [:]) -> [Conversation] {
        var latest: [String: Message] = [:]
        for m in messages {
            let key = m.groupHex ?? m.peerHex
            if let existing = latest[key] {
                if m.timestamp > existing.timestamp { latest[key] = m }
            } else {
                latest[key] = m
            }
        }
        return latest
            .map { key, m in
                let group = m.groupHex.flatMap { groups[$0] }
                return Conversation(
                    peerHex: key,
                    kind: m.groupHex == nil ? .peer : .group,
                    title: m.groupHex == nil ? nil : (group?.name ?? unknownGroupTitle),
                    groupState: group?.state,
                    lastBody: AttachmentPlaceholder.preview(body: m.body, attachment: attachments[m.id]),
                    lastTimestamp: m.timestamp)
            }
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
    }
}
```

Keep `isValidPeerAddress` as it is.

- [ ] **Step 4: State and actions**

In `AppFeature`, before `@ObservableState public struct State`, add:

```swift
    /// What the open thread is (spec 2026-10-09 §3): `openPeerHex` holds a peer's address or a
    /// group's id accordingly.
    public enum ConversationKind: Equatable, Sendable { case peer, group }
```

In `State`, after `public var attachmentsByMessageId: [UUID: Attachment] = [:]`:

```swift
        /// Whether `openPeerHex` is a peer or a group. Set by the open actions, reset by close.
        public var openConversationKind: ConversationKind = .peer
        /// The open group's row, members (sorted by address, me included) and the delivery rows of
        /// its outgoing messages, loaded with the thread (`groupLoaded`). Session-only.
        public var openGroup: ChatGroup? = nil
        public var openGroupMembers: [GroupMember] = []
        public var deliveriesByMessageId: [UUID: [GroupDelivery]] = [:]
```

In `State`, after `peerDisplayName(_:)`:

```swift
        /// My name as other members see it in lines and wire bodies: the trimmed display name,
        /// else the first eight hex characters of my address.
        public var myName: String {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? GroupEventText.fallbackName(myAddressHex) : trimmed
        }

        public var isOpenGroupCreator: Bool { openGroup?.creatorHex == myAddressHex }

        /// The open group's members other than me, sorted.
        public var openGroupOthers: [String] {
            openGroupMembers.map(\.memberHex).filter { $0 != myAddressHex }
        }

        /// The group Send gate (spec §3): at least one other member would route right now.
        public var anyGroupMemberReachable: Bool {
            openGroupOthers.contains { reachablePeers.contains($0) }
        }

        /// A member's name for a line: "You", the announce display name, else a short hex.
        public func groupMemberName(_ hex: String) -> String {
            if hex == myAddressHex { return GroupEventText.you }
            return peerDisplayName(hex) ?? GroupEventText.fallbackName(hex)
        }

        /// Display names of the open group's announced members, by address, for reply labels and
        /// the Info sheet.
        public var threadSenderNames: [String: String] {
            Dictionary(uniqueKeysWithValues: openGroupMembers.compactMap { member in
                peerDisplayName(member.memberHex).map { (member.memberHex, $0) }
            })
        }
```

In `Action`, after `case openConversation(String)`:

```swift
        /// A tap on a group row: opens it as a group thread.
        case openGroupConversation(String)
```

and after `case threadLoaded(...)`:

```swift
        /// The open thread's group, members and delivery rows, sent by `reloadThread` before
        /// `threadLoaded` (nil group for a peer thread) and guarded on the open key.
        case groupLoaded(groupHex: String, group: ChatGroup?, members: [GroupMember], deliveries: [GroupDelivery])
```

- [ ] **Step 5: Open, close, load**

In `.openConversation` and `.startConversation`, right after `state.chatVisible = true`, add:

```swift
                state.openConversationKind = .peer
                state.openGroup = nil
                state.openGroupMembers = []
                state.deliveriesByMessageId = [:]
```

In `.closeConversation`, after `state.attachmentsByMessageId = [:]`, add the same four lines.

Add the new cases after `.closeConversation`:

```swift
            case let .openGroupConversation(groupHex):
                guard let data = Data(hexString: groupHex), data.count == GroupWire.idLength else { return .none }
                state.openPeerHex = groupHex
                state.openConversationKind = .group
                state.chatVisible = true
                state.openGroup = nil
                state.openGroupMembers = []
                state.deliveriesByMessageId = [:]
                state.openConversationExpiryLoaded = false
                state.replyTarget = nil
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                state.attachmentOriginalRequested = nil
                // No first-view stamp and no purge: timers are one-to-one only in v1.
                return .merge(
                    .cancel(id: CancelID.attachmentPreparation),
                    .run { [database] send in try await reloadThread(database, groupHex, send) }
                )

            case let .groupLoaded(groupHex, group, members, deliveries):
                // Guarded like reactions and attachments: a late load for a thread the user has
                // left must not label the next conversation with the previous group.
                guard groupHex == state.openPeerHex else { return .none }
                state.openGroup = group
                state.openGroupMembers = members.sorted { $0.memberHex < $1.memberHex }
                state.deliveriesByMessageId = GroupDelivery.byMessageId(deliveries)
                guard group != nil else { return .none }
                // Spec §3: a group thread asks for the paths of the members it cannot reach, so
                // the Send gate unlocks when they answer (the one-to-one open does the same).
                return .merge(state.openGroupOthers.map { state.pathRequestIfUnreachable($0) })
```

In `.threadLoaded`, replace the `allowed` line with:

```swift
                // Spec §2: in a group thread the reactor must be me or a current member; in a peer
                // thread me or the open peer. `groupLoaded` lands first, so the members are known.
                let allowed: Set<String> = state.openConversationKind == .group
                    ? Set(state.openGroupMembers.map(\.memberHex)).union([state.myAddressHex])
                    : [state.myAddressHex, state.openPeerHex ?? ""]
```

- [ ] **Step 6: Reload helpers**

Replace `reloadConversations` with:

```swift
private func reloadConversations(_ database: any DatabaseWriter, _ send: Send<AppFeature.Action>) async throws {
    let (all, attachments, groups) = try await database.read { db -> ([Message], [Attachment], [ChatGroup]) in
        let all = try Message.fetchAll(db)
        // Only a message with no text needs its attachment for the preview placeholder.
        let ids = all.filter { $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id)
        let attachments = ids.isEmpty ? [] : try Attachment.where { $0.messageId.in(ids) }.fetchAll(db)
        let groups = try ChatGroup.all.fetchAll(db)
        return (all, attachments, groups)
    }
    let byMessage = Attachment.byMessageId(attachments)
    let byGroup = Dictionary(uniqueKeysWithValues: groups.map { ($0.groupHex, $0) })
    await send(.conversationsLoaded(Conversation.list(from: all, attachments: byMessage, groups: byGroup)))
}
```

Replace `reloadThread` with:

```swift
/// Loads one thread by its key: a peer's address or a group's id. Sends `groupLoaded` first (nil
/// group for a peer thread), then `threadLoaded`, then the conversation's timer.
private func reloadThread(_ database: any DatabaseWriter, _ key: String, _ send: Send<AppFeature.Action>) async throws {
    let loaded = try await database.read { db -> ([Message], [Reaction], [Attachment], Int?, ChatGroup?, [GroupMember], [GroupDelivery]) in
        // Amendment A13: a group thread is its rows, a peer thread is the rows with no group.
        let rows = try Message
            .where { $0.groupHex.eq(key) || ($0.groupHex.is(nil) && $0.peerHex.eq(key)) }
            .order(by: \.timestamp).fetchAll(db)
        let hashes = rows.map(\.messageHash).filter { !$0.isEmpty }
        let reactions = hashes.isEmpty ? [] : try Reaction.where { $0.messageHash.in(hashes) }.fetchAll(db)
        let ids = rows.map(\.id)
        let attachments = ids.isEmpty ? [] : try Attachment.where { $0.messageId.in(ids) }.fetchAll(db)
        let expiry = try ConversationSetting.expiry(for: key, db)
        let group = try ChatGroup.fetch(key, db)
        let members = group == nil ? [] : try GroupMember.where { $0.groupHex.eq(key) }.fetchAll(db)
        let outgoingIds = rows.filter(\.isOutgoing).map(\.id)
        let deliveries = (group == nil || outgoingIds.isEmpty) ? [] : try GroupDelivery.where { $0.messageId.in(outgoingIds) }.fetchAll(db)
        return (rows, reactions, attachments, expiry, group, members, deliveries)
    }
    await send(.groupLoaded(groupHex: key, group: loaded.4, members: loaded.5, deliveries: loaded.6))
    await send(.threadLoaded(loaded.0, reactions: loaded.1, attachments: loaded.2))
    await send(.conversationExpiryLoaded(peerHex: key, seconds: loaded.3))
}
```

If structured-queries rejects `||` in the `where` closure, fetch the two halves separately (`groupHex.eq(key)` and `groupHex.is(nil) && peerHex.eq(key)`), concatenate, and sort by `timestamp` in Swift; the observable behaviour is the same.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupConv > /tmp/ReTiCaMsgr/grp-t4-green.log 2>&1`
Expected: 7 tests passed. Then run the full suite: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/grp-t4-full.log 2>&1`. Expected: baseline + 30 passed, no failures (the existing `threadLoaded` and `conversationsLoaded` tests still pass, since a peer thread now receives one extra `groupLoaded` first and the non-exhaustive `receive` skips it).

- [ ] **Step 8: Mutation verification**

| Mutation (production code) | Test that must go RED |
|---|---|
| `Conversation.list`: use `m.peerHex` as the key (ignore `groupHex`) | `groupConvListCollapsesByGroupAndCarriesTitle` |
| `reloadThread`: change the row predicate to `$0.peerHex.eq(key) \|\| $0.groupHex.eq(key)` | `groupConvOpenGroupLoadsGroupMembersDeliveriesAndThread` |
| `.groupLoaded`: return `.none` instead of the path-request merge | `groupConvOpenGroupRequestsPathsForUnreachableMembers` |
| `.threadLoaded`: use the peer branch of `allowed` for both kinds | `groupConvThreadReactionsFilteredToMembers` |
| `.closeConversation`: delete `state.openGroup = nil` | `groupConvCloseResetsGroupState` |
| `groupMemberName`: return `peerDisplayName(hex) ?? hex` | `groupConvMemberNamesFallBack` |
| `.groupLoaded`: delete the `guard groupHex == state.openPeerHex` line | `groupConvLateGroupLoadIsIgnored` |

Apply all seven, run the filter once, confirm all seven RED. Revert by hand, run again, all GREEN.

- [ ] **Step 9: Commit**

Write `/tmp/ReTiCaMsgr/msg-grp-task-4.txt`:

```
feat: group conversations in the list and the thread state

Conversation rows collapse by group id with the group's name and state,
the thread loads the group, its members and its delivery rows ahead of
the messages, openGroupConversation opens a group thread and asks for
unreachable members' paths, and reactions in a group thread are kept for
members only.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C APP add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Conversation.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/ConversationTests.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-4.txt`

---

### Task 5: Copy builder, deferred dispatcher, creating a group

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/GroupDelivery.swift` (add `refreshDerivedStatus`)
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` (Action, `createGroup`, `pathLearned`, `interfaceConnected`, `rehydrateLearnedDestinations`, two static builders, one private effect helper, one file-scope dispatcher)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (append)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: `GroupDelivery.refreshDerivedStatus(messageId: UUID, _ db: GRDB.Database) throws` (writes `GroupRoster.derivedStatus` of the row's deliveries into `messages.status`). `AppFeature.groupCopy(of row: Message, to member: Data, group: ChatGroup, members: [String], identity: Identity, myName: String, timestamp: Double) -> LXMessage?`; `AppFeature.groupEventRow(groupHex: String, me: String, body: String, control: String?, now: Date) -> Message`; `Action.createGroup(name: String, members: [String])`; private `groupDispatchEffect(_ state: State, members: Set<String>) -> Effect<Action>`; file-scope `dispatchWaitingGroupCopies(_ database:, members: Set<String>, identity:, myName:, alsoViaPropagation:, now: Date, _ send:) async throws -> Int`. Tasks 6 and 9 call the dispatcher and the row builder.

- [ ] **Step 1: Write the failing tests**

Append to `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`:

```swift

// MARK: - Group chats: copies, dispatch, creating (Task 5)

/// Amendment A3: a member's copy follows the row's kind. The group name is the title, a post
/// carries its reply fields then the ids, a roster line the current roster (or an empty one for
/// a deleted group, with the delete body), a leave line the leave marker.
@Test func groupCreateCopyShapesFollowTheRowKind() throws {
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let gid = Data(hexString: groupHexA)!
    let pid = Data(repeating: 0x5a, count: 16)
    let member = Data(hexString: memberC)!
    let group = ChatGroup(groupHex: groupHexA, name: "Mutual Aid", creatorHex: myHex, revision: 4,
                          state: GroupState.active, updatedAt: infoT0)
    let post = Message(id: uuid(1), peerHex: myHex, isOutgoing: true, body: "see you at 6", timestamp: infoT0,
                       status: MessageStatus.sending, validated: false, messageHash: pid.hexString,
                       replyToHash: String(repeating: "7b", count: 16), replyQuote: "orig",
                       groupHex: groupHexA, groupPostId: pid.hexString)
    let postCopy = try #require(AppFeature.groupCopy(of: post, to: member, group: group, members: [memberC, myHex],
                                                     identity: me, myName: "Ada", timestamp: 1700000010))
    #expect(postCopy.destinationHash == member)
    #expect(postCopy.title == Data("Mutual Aid".utf8))
    #expect(postCopy.content == Data("see you at 6".utf8))
    #expect(postCopy.timestamp == 1700000010)
    #expect(postCopy.fields.map(\.key) == [0x30, 0x31, 0xFD])
    #expect(ReplyWire.decode(postCopy.fields)?.replyTo == Data(repeating: 0x7b, count: 16))
    #expect(ReplyWire.decode(postCopy.fields)?.quote == "orig")
    #expect(GroupWire.decode(postCopy.fields) == .post(groupId: gid, postId: pid))

    let roster = AppFeature.groupEventRow(groupHex: groupHexA, me: myHex, body: "You added Cy",
                                          control: GroupControl.roster, now: infoT0)
    #expect(roster.isGroupEvent == true)
    #expect(roster.isOutgoing == true)
    #expect(roster.peerHex == myHex)
    #expect(roster.groupHex == groupHexA)
    #expect(roster.messageHash == "")
    let rosterCopy = try #require(AppFeature.groupCopy(of: roster, to: member, group: group, members: [memberC, myHex],
                                                       identity: me, myName: "Ada", timestamp: 1700000010))
    #expect(rosterCopy.title == Data("Mutual Aid".utf8))
    #expect(rosterCopy.content == Data("Ada invited you to the group Mutual Aid in ReTiCaMsgr".utf8))
    #expect(GroupWire.decode(rosterCopy.fields) == .roster(groupId: gid, name: "Mutual Aid",
                                                           members: [member, Data(hexString: myHex)!], revision: 4))

    var dissolved = group
    dissolved.state = GroupState.dissolved
    let deleteCopy = try #require(AppFeature.groupCopy(of: roster, to: member, group: dissolved, members: [],
                                                       identity: me, myName: "Ada", timestamp: 1700000010))
    #expect(deleteCopy.content == Data("Ada deleted the group Mutual Aid".utf8))
    #expect(GroupWire.decode(deleteCopy.fields) == .roster(groupId: gid, name: "Mutual Aid", members: [], revision: 4))

    let leave = AppFeature.groupEventRow(groupHex: groupHexA, me: myHex, body: "You left the group",
                                         control: GroupControl.leave, now: infoT0)
    let leaveCopy = try #require(AppFeature.groupCopy(of: leave, to: member, group: group, members: [memberC],
                                                      identity: me, myName: "Ada", timestamp: 1700000010))
    #expect(leaveCopy.content == Data("Ada left the group Mutual Aid".utf8))
    #expect(GroupWire.decode(leaveCopy.fields) == .leave(groupId: gid))

    var idless = post
    idless.groupPostId = nil
    #expect(AppFeature.groupCopy(of: idless, to: member, group: group, members: [], identity: me, myName: "Ada", timestamp: 1) == nil)
}

/// Spec §3 "Creating": the group, its roster (me included), the creation line with one waiting
/// delivery per member, path requests for the members I cannot reach, and the thread opens.
@MainActor @Test func groupCreateWritesGroupMembersLineAndWaitingDeliveries() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = makeStore(db, identity: me)
    await store.send(.createGroup(name: "  Mutual Aid  ", members: [memberC, memberD.uppercased(), myHex]))
    let groupHex = try #require(store.state.openPeerHex)
    #expect(groupHex.count == 32)
    #expect(store.state.openConversationKind == .group)
    #expect(store.state.chatVisible == true)
    #expect(store.state.openGroup?.name == "Mutual Aid")
    #expect(store.state.openGroup?.creatorHex == myHex)
    #expect(store.state.openGroupMembers.map(\.memberHex) == [memberC, memberD, myHex].sorted())
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    let group = try #require(try await db.read { try ChatGroup.fetch(groupHex, $0) })
    #expect(group.revision == 1)
    #expect(group.state == GroupState.active)
    #expect(group.updatedAt == infoT0)
    #expect(try await db.read { try GroupMember.members(of: groupHex, $0) } == [memberC, memberD, myHex].sorted())
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let line = try #require(rows.first)
    #expect(line.body == "You created the group Mutual Aid")
    #expect(line.isGroupEvent == true)
    #expect(line.groupControl == "roster")
    #expect(line.groupHex == groupHex)
    #expect(line.status == MessageStatus.sending)   // derived: every copy is waiting
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(deliveries.map(\.memberHex).sorted() == [memberC, memberD])
    #expect(deliveries.allSatisfy { $0.status == GroupDeliveryStatus.waiting && $0.messageHash == nil && $0.messageId == line.id })
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberC)!] != nil)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberD)!] != nil)
    #expect(store.state.conversations.first?.title == "Mutual Aid")
    #expect(store.state.conversations.first?.kind == .group)
    #expect(store.state.threadMessages.map(\.body) == ["You created the group Mutual Aid"])
}

/// A reachable member gets their roster copy at once: title, invite body, full roster, revision
/// 1; their row moves to sending with the copy's hash, the unreachable member's stays waiting.
@MainActor @Test func groupCreateSendsRosterToReachableMembers() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = makeStore(db, identity: me) { s in
        s.reachablePeers = [memberC]
        s.$displayName.withLock { $0 = "Ada" }
    }
    let sent = await groupSends(store, .createGroup(name: "Mutual Aid", members: [memberC, memberD]), count: 1)
    let groupHex = try #require(store.state.openPeerHex)
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberC))
    #expect(wire.title == Data("Mutual Aid".utf8))
    #expect(wire.content == Data("Ada invited you to the group Mutual Aid in ReTiCaMsgr".utf8))
    #expect(wire.timestamp == infoT0.timeIntervalSince1970)
    let expectedRoster = [memberC, memberD, myHex].sorted().map { Data(hexString: $0)! }
    #expect(GroupWire.decode(wire.fields) == .roster(groupId: Data(hexString: groupHex)!, name: "Mutual Aid",
                                                     members: expectedRoster, revision: 1))
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    let toC = try #require(deliveries.first { $0.memberHex == memberC })
    let toD = try #require(deliveries.first { $0.memberHex == memberD })
    #expect(toC.status == MessageStatus.sending)
    #expect(toC.messageHash == wire.hash.hexString)
    #expect(toD.status == GroupDeliveryStatus.waiting)
    #expect(toD.messageHash == nil)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberC)!] == nil)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberD)!] != nil)
}

/// An empty name, no other member, or more than 12 in all, creates nothing.
@MainActor @Test func groupCreateRejectsBadInput() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me)
    store.exhaustivity = .on
    await store.send(.createGroup(name: "   ", members: [memberC]))
    await store.send(.createGroup(name: "g", members: []))
    await store.send(.createGroup(name: "g", members: [lxmfAddressHex(me), "nothex"]))
    let twelveOthers = (0..<12).map { String(format: "%02x", $0) + String(repeating: "0", count: 30) }
    await store.send(.createGroup(name: "g", members: twelveOthers))
    #expect(store.state.openPeerHex == nil)
    #expect(try await db.read { try ChatGroup.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    // Eleven others plus me is the ceiling and is accepted.
    store.exhaustivity = .off
    await store.send(.createGroup(name: "g", members: Array(twelveOthers.prefix(11))))
    #expect(store.state.openPeerHex != nil)
    await store.skipReceivedActions(strict: false)
}

/// Spec §3 "Deferred copies": the member's path arriving sends their waiting copy.
@MainActor @Test func groupCreatePathLearnedSendsWaitingCopy() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me) { $0.$displayName.withLock { $0 = "Ada" } }
    await store.send(.createGroup(name: "Mutual Aid", members: [memberC]))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    let groupHex = try #require(store.state.openPeerHex)
    let sent = await groupSends(store, .node(.client(.endpoint(.delegate(.pathLearned(destinationHash: Data(hexString: memberC)!, hops: 2))))), count: 1)
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberC))
    guard case let .roster(gid, _, _, _)? = GroupWire.decode(wire.fields) else { Issue.record("expected a roster"); return }
    #expect(gid == Data(hexString: groupHex))
    let delivery = try #require(try await db.read { try GroupDelivery.all.fetchAll($0) }.first)
    #expect(delivery.status == MessageStatus.sending)
    #expect(delivery.messageHash == wire.hash.hexString)
}

/// Amendment A12: a failed roster copy is re-sent when the member's path is learned again (they
/// are behind on the roster); a failed post is not.
@MainActor @Test func groupCreateFailedRosterIsResentButFailedPostIsNot() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, members: [memberC])
    let rosterLine = AppFeature.groupEventRow(groupHex: groupHexA, me: myHex, body: "You added Cy",
                                              control: GroupControl.roster, now: infoT0)
    let post = Message(id: uuid(7), peerHex: myHex, isOutgoing: true, body: "hi", timestamp: infoT0,
                       status: MessageStatus.failed, validated: false, messageHash: String(repeating: "6f", count: 16),
                       groupHex: groupHexA, groupPostId: String(repeating: "6f", count: 16))
    func failed(_ id: UUID) -> GroupDelivery {
        GroupDelivery(messageId: id, memberHex: memberC, messageHash: String(repeating: "77", count: 32),
                      status: MessageStatus.failed, storedAt: nil, deliveredAt: nil, failedAt: infoT0)
    }
    try await db.write { db in
        try Message.insert { rosterLine }.execute(db)
        try Message.insert { post }.execute(db)
        try GroupDelivery.insert { failed(rosterLine.id) }.execute(db)
        try GroupDelivery.insert { failed(post.id) }.execute(db)
    }
    let sent = await groupSends(store, .node(.client(.endpoint(.delegate(.pathLearned(destinationHash: Data(hexString: memberC)!, hops: 1))))), count: 1)
    guard case let .roster(_, name, _, revision)? = GroupWire.decode(try #require(sent.first).fields) else {
        Issue.record("expected a roster"); return
    }
    #expect(name == "Mutual Aid")
    #expect(revision == 1)
    let rows = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(rows.first { $0.messageId == rosterLine.id }?.status == MessageStatus.sending)
    #expect(rows.first { $0.messageId == rosterLine.id }?.messageHash == sent[0].hash.hexString)
    #expect(rows.first { $0.messageId == post.id }?.status == MessageStatus.failed)
    #expect(rows.first { $0.messageId == post.id }?.messageHash == String(repeating: "77", count: 32))
    let messages = try await db.read { try Message.all.fetchAll($0) }
    #expect(messages.first { $0.id == rosterLine.id }?.status == MessageStatus.sending)
    #expect(messages.first { $0.id == post.id }?.status == MessageStatus.failed)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupCreate > /tmp/ReTiCaMsgr/grp-t5-red.log 2>&1`
Expected: compile errors (`groupCopy`, `createGroup` unknown).

- [ ] **Step 3: `GroupDelivery.refreshDerivedStatus`**

Append inside `GroupDelivery` (after `byMessageId`):

```swift
    /// Writes the row's derived status (amendment A8) into `messages.status`, so the bubble, the
    /// list preview and the Info sheet keep reading one column.
    public static func refreshDerivedStatus(messageId: UUID, _ db: GRDB.Database) throws {
        let rows = try GroupDelivery.where { $0.messageId.eq(messageId) }.fetchAll(db)
        let status = GroupRoster.derivedStatus(rows)
        try Message.where { $0.id.eq(messageId) }.update { $0.status = status }.execute(db)
    }
```

- [ ] **Step 4: Action and the two static builders**

In `Action`, after `case openGroupConversation(String)`:

```swift
        /// "Create group" (spec §3): `name` is trimmed, `members` are the other members' addresses
        /// (me and invalid entries are dropped). Opens the new group's thread.
        case createGroup(name: String, members: [String])
```

In `AppFeature`, after `static func outgoing(...)` (before `prepareEffect`):

```swift
    /// An outgoing event line (spec §3): a system line with `isGroupEvent`, carrying `control` to
    /// the members through its delivery rows. `status` starts as `sending` and is derived from the
    /// delivery rows from then on (`GroupDelivery.refreshDerivedStatus`).
    static func groupEventRow(groupHex: String, me: String, body: String, control: String?, now: Date) -> Message {
        Message(id: UUID(), peerHex: me, isOutgoing: true, body: body, timestamp: now,
                status: MessageStatus.sending, validated: false, messageHash: "",
                senderTimestamp: now, fieldKeys: "", groupHex: groupHex, isGroupEvent: true, groupControl: control)
    }

    /// One member's copy of a group row (spec §3, amendment A3). The title is the group name; the
    /// fields follow the row's kind: a post carries its reply fields then the group and post ids,
    /// a roster line the group's current roster (an empty one, with the delete body, once the
    /// group is dissolved), a leave line the leave marker. `timestamp` is the dispatch time, so a
    /// re-sent copy has a fresh hash. nil when an id does not decode.
    static func groupCopy(of row: Message, to member: Data, group: ChatGroup, members: [String],
                          identity: Identity, myName: String, timestamp: Double) -> LXMessage? {
        guard let groupId = Data(hexString: group.groupHex), groupId.count == GroupWire.idLength else { return nil }
        let title = Data(GroupWire.trimName(group.name).utf8)
        let body: String
        let fields: [MsgPackValue.IntPair]
        switch row.groupControl {
        case GroupControl.roster?:
            let roster = members.compactMap { Data(hexString: $0) }.filter { $0.count == GroupWire.idLength }
            body = group.state == GroupState.dissolved
                ? GroupEventText.deleteBody(who: myName, name: group.name)
                : GroupEventText.rosterBody(inviter: myName, name: group.name)
            fields = GroupWire.encodeRoster(groupId: groupId, name: group.name, members: roster, revision: group.revision)
        case GroupControl.leave?:
            body = GroupEventText.leaveBody(who: myName, name: group.name)
            fields = GroupWire.encodeLeave(groupId: groupId)
        default:
            guard let postId = row.groupPostId.flatMap({ Data(hexString: $0) }), postId.count == GroupWire.idLength
            else { return nil }
            var replyFields: [MsgPackValue.IntPair] = []
            if let replyTo = row.replyToHash.flatMap({ Data(hexString: $0) }), !replyTo.isEmpty {
                replyFields = ReplyWire.encode(replyTo: replyTo, quote: row.replyQuote ?? "")
            }
            body = row.body
            fields = replyFields + GroupWire.encodePost(groupId: groupId, postId: postId)
        }
        return LXMessage.create(source: identity, destinationHash: member, timestamp: timestamp,
                                title: title, content: Data(body.utf8), fields: fields)
    }

    /// Spec §3 "Deferred copies": sends the waiting group copies addressed to `members`, then
    /// reloads if anything went out. Used at `pathLearned`, `interfaceConnected` and the launch
    /// seeding of reachable peers.
    private func groupDispatchEffect(_ state: State, members: Set<String>) -> Effect<Action> {
        guard !members.isEmpty else { return .none }
        let identity = state.identity
        let myName = state.myName
        let alsoViaPropagation = !state.propagationNodeHex.isEmpty
        let openPeer = state.openPeerHex
        let now = date.now
        return .run { [database] send in
            let sent = try await dispatchWaitingGroupCopies(database, members: members, identity: identity,
                                                            myName: myName, alsoViaPropagation: alsoViaPropagation,
                                                            now: now, send)
            guard sent > 0 else { return }
            try await reloadConversations(database, send)
            if let openPeer { try await reloadThread(database, openPeer, send) }
        }
    }
```

- [ ] **Step 5: The dispatcher (file scope, after `reloadThread`)**

```swift
/// Spec §3 "Deferred copies" (amendments A3, A12): every `waiting` delivery row addressed to one
/// of `members` gets its copy built and sent, and moves to `sending` with that copy's hash. A
/// `failed` roster copy for one of them is re-sent the same way, since the roster is what that
/// member is behind on; a failed post is not. Each row's message gets its derived status
/// refreshed. Returns how many copies went out.
private func dispatchWaitingGroupCopies(_ database: any DatabaseWriter, members: Set<String>,
                                        identity: Identity, myName: String, alsoViaPropagation: Bool,
                                        now: Date, _ send: Send<AppFeature.Action>) async throws -> Int {
    guard !members.isEmpty else { return 0 }
    let memberList = Array(members)
    let copies: [LXMessage] = try await database.write { db in
        var copies: [LXMessage] = []
        let waiting = try GroupDelivery
            .where { $0.memberHex.in(memberList) && $0.status.eq(GroupDeliveryStatus.waiting) }
            .fetchAll(db)
        let failed = try GroupDelivery
            .where { $0.memberHex.in(memberList) && $0.status.eq(MessageStatus.failed) }
            .fetchAll(db)
        for delivery in waiting + failed {
            guard let row = try Message.where { $0.id.eq(delivery.messageId) }.fetchOne(db),
                  let groupHex = row.groupHex,
                  let group = try ChatGroup.fetch(groupHex, db),
                  let member = Data(hexString: delivery.memberHex), member.count == GroupWire.idLength
            else { continue }
            if delivery.status == MessageStatus.failed, row.groupControl != GroupControl.roster { continue }
            let roster = try GroupMember.members(of: groupHex, db)
            guard let copy = AppFeature.groupCopy(of: row, to: member, group: group, members: roster,
                                                  identity: identity, myName: myName,
                                                  timestamp: now.timeIntervalSince1970)
            else { continue }
            let hashHex: String? = copy.hash.hexString
            try GroupDelivery
                .where { $0.messageId.eq(delivery.messageId) && $0.memberHex.eq(delivery.memberHex) }
                .update {
                    $0.messageHash = hashHex
                    $0.status = MessageStatus.sending
                }
                .execute(db)
            try GroupDelivery.refreshDerivedStatus(messageId: delivery.messageId, db)
            copies.append(copy)
        }
        return copies
    }
    for copy in copies {
        await send(.node(.client(.sendMessage(message: copy, alsoViaPropagation: alsoViaPropagation))))
    }
    return copies.count
}
```

- [ ] **Step 6: `createGroup`**

Add after the `.groupLoaded` case:

```swift
            case let .createGroup(name, members):
                let trimmedName = GroupWire.trimName(name)
                let me = state.myAddressHex
                let others = Set(members.map { $0.lowercased() }.filter { isValidPeerAddress($0) && $0 != me })
                guard !trimmedName.isEmpty, !others.isEmpty, others.count + 1 <= GroupWire.maxMembers else { return .none }
                let groupHex = GroupWire.randomId().hexString
                let now = date.now
                let group = ChatGroup(groupHex: groupHex, name: trimmedName, creatorHex: me, revision: 1,
                                      state: GroupState.active, updatedAt: now)
                let roster = others.union([me]).sorted()
                let line = Self.groupEventRow(groupHex: groupHex, me: me, body: GroupEventText.created(name: trimmedName),
                                              control: GroupControl.roster, now: now)
                let deliveries = others.sorted().map { GroupDelivery.waiting(messageId: line.id, memberHex: $0) }
                // Open the new group as `startConversation` opens a peer.
                state.openPeerHex = groupHex
                state.openConversationKind = .group
                state.chatVisible = true
                state.openGroup = group
                state.openGroupMembers = roster.map { GroupMember(groupHex: groupHex, memberHex: $0) }
                state.deliveriesByMessageId = [:]
                state.openConversationExpiryLoaded = false
                state.replyTarget = nil
                state.pendingAttachment = nil
                state.attachmentPreparing = false
                state.attachmentError = nil
                state.attachmentOriginalRequested = nil
                let reachable = others.intersection(state.reachablePeers)
                let identity = state.identity
                let myName = state.myName
                let alsoViaPropagation = !state.propagationNodeHex.isEmpty
                // Spec §3: members with no path get a request now; their copies wait.
                let pathRequests = others.subtracting(reachable).map { state.pathRequestIfUnreachable($0) }
                let write: Effect<Action> = .run { [database] send in
                    try await database.write { db in
                        try ChatGroup.upsert(group, db)
                        try GroupMember.replace(groupHex, with: roster, db)
                        try Message.insert { line }.execute(db)
                        for delivery in deliveries { try GroupDelivery.insert { delivery }.execute(db) }
                        try GroupDelivery.refreshDerivedStatus(messageId: line.id, db)
                    }
                    _ = try await dispatchWaitingGroupCopies(database, members: reachable, identity: identity,
                                                             myName: myName, alsoViaPropagation: alsoViaPropagation,
                                                             now: now, send)
                    try await reloadThread(database, groupHex, send)
                    try await reloadConversations(database, send)
                }
                return .merge(pathRequests + [.cancel(id: CancelID.attachmentPreparation), write])
```

- [ ] **Step 7: Dispatch hooks**

In the `.pathLearned` case, right after `state.reachablePeers.insert(h.hexString)`, add:

```swift
                // Spec §3 "Deferred copies": this member may have group copies waiting for a path.
                let groupDispatch = groupDispatchEffect(state, members: [h.hexString])
```

and change the two returns of that case: `return debounceEffect` becomes `return .merge(debounceEffect, groupDispatch)`, and the final `.merge(debounceEffect, .run { ... })` gains `groupDispatch` as a third argument.

In the `.interfaceConnected` case, right after the `var effects: [Effect<Action>] = [ ... ]` declaration, add:

```swift
                // Group copies waiting on members whose persisted path just became usable.
                effects.append(groupDispatchEffect(state, members: state.reachablePeers))
```

In the `.rehydrateLearnedDestinations` case, replace the `if state.connection == .connected { seedReachablePeers(...) }` block and the `return .send(...)` with:

```swift
                var groupDispatch: Effect<Action> = .none
                if state.connection == .connected {
                    seedReachablePeers(&state, from: destinations)
                    groupDispatch = groupDispatchEffect(state, members: state.reachablePeers)
                }
                return .merge(
                    .send(.node(.client(.endpoint(.transport(.rehydrateLearnedDestinations(destinations)))))),
                    groupDispatch
                )
```

These two hooks share the dispatcher the `pathLearned` test exercises; they have no test of their own because simulating a live interface registration in a `TestStore` needs a transport interface, which no existing test constructs. Say so in the commit body.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupCreate > /tmp/ReTiCaMsgr/grp-t5-green.log 2>&1`
Expected: 6 tests passed.

- [ ] **Step 9: Mutation verification**

| Mutation (production code) | Test that must go RED |
|---|---|
| `groupCopy`: encode the roster with `revision: group.revision + 1` | `groupCreateCopyShapesFollowTheRowKind` |
| `createGroup`: delete the `for delivery in deliveries { ... }` insert loop | `groupCreateWritesGroupMembersLineAndWaitingDeliveries` |
| `createGroup`: pass `members: others` instead of `reachable` to the dispatcher | `groupCreateSendsRosterToReachableMembers` (memberD's row is no longer waiting) |
| `createGroup`: change `others.count + 1 <= GroupWire.maxMembers` to `<= GroupWire.maxMembers + 1` | `groupCreateRejectsBadInput` |
| `.pathLearned`: replace `groupDispatchEffect(state, members: [h.hexString])` with `.none` | `groupCreatePathLearnedSendsWaitingCopy` |
| `dispatchWaitingGroupCopies`: delete the `if delivery.status == MessageStatus.failed, row.groupControl != GroupControl.roster { continue }` line | `groupCreateFailedRosterIsResentButFailedPostIsNot` |

Apply all six, run the filter once, confirm all six RED. Revert by hand, run again, all GREEN.

- [ ] **Step 10: Commit**

Write `/tmp/ReTiCaMsgr/msg-grp-task-5.txt`:

```
feat: group creation with per-member roster copies and deferred dispatch

createGroup writes the group, its roster and the creation line with one
waiting delivery per member, sends the roster copy to every reachable
member and asks for the others' paths. The dispatcher builds a member's
copy from its row (post, roster or leave) when the path arrives, at
pathLearned, interfaceConnected and the launch seeding, and re-sends a
failed roster copy but not a failed post. The interfaceConnected and
rehydrate hooks share the tested dispatcher and have no test of their own.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C APP add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/GroupDelivery.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-5.txt`

---

### Task 6: Sending posts and reactions in a group

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` (`sendTapped`, `reactionSelected`, one private helper)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (append)

**Interfaces:**
- Consumes: Tasks 1–5 (`groupCopy`, `dispatchWaitingGroupCopies`, `GroupDelivery.waiting`, `refreshDerivedStatus`).
- Produces: `sendTapped` and `reactionSelected` branch on `state.openConversationKind`; private `sendGroupPost(_ state: inout State) -> Effect<Action>`. A group post row has `messageHash == groupPostId` (amendment A2), `peerHex == myAddressHex`, `fieldKeys` of the copy's fields, `titleSize` of the group name, `contentSize` of the text, `wireSize` nil.

- [ ] **Step 1: Write the failing tests**

Append to `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`:

```swift

// MARK: - Group chats: sending posts and reactions (Task 6)

/// Spec §3 "Sending a post": one row (post id in `messageHash` too, amendment A2), one delivery
/// per other member, the copy to the reachable member carries title, text and ids, the other
/// member's row waits with a path request.
@MainActor @Test func groupSendPostWritesRowDeliveriesAndSendsToReachable() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, members: [memberC, memberD], reachable: [memberC]) { s in
        s.draft = "sandbags at 6"
        s.$propagationNodeHex.withLock { $0 = pnHex }
    }
    let sent = await groupSends(store, .sendTapped, count: 1)
    #expect(store.state.draft == "")
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberC))
    #expect(wire.title == Data("Mutual Aid".utf8))
    #expect(wire.content == Data("sandbags at 6".utf8))
    #expect(wire.fields.map(\.key) == [0xFD])
    guard case let .post(gid, pid)? = GroupWire.decode(wire.fields) else { Issue.record("expected a post"); return }
    #expect(gid == Data(hexString: groupHexA))
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.groupHex == groupHexA)
    #expect(row.groupPostId == pid.hexString)
    #expect(row.messageHash == pid.hexString)
    #expect(row.peerHex == myHex)
    #expect(row.isOutgoing == true)
    #expect(row.isGroupEvent == false)
    #expect(row.body == "sandbags at 6")
    #expect(row.status == MessageStatus.sending)
    #expect(row.sentViaPropagation == true)
    #expect(row.fieldKeys == "0xfd")
    #expect(row.titleSize == 10)
    #expect(row.contentSize == 13)
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(deliveries.map(\.memberHex).sorted() == [memberC, memberD])
    #expect(deliveries.first { $0.memberHex == memberC }?.status == MessageStatus.sending)
    #expect(deliveries.first { $0.memberHex == memberC }?.messageHash == wire.hash.hexString)
    #expect(deliveries.first { $0.memberHex == memberD }?.status == GroupDeliveryStatus.waiting)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberD)!] != nil)
    #expect(store.state.threadMessages.map(\.body) == ["sandbags at 6"])
    #expect(store.state.deliveriesByMessageId[row.id]?.count == 2)
    #expect(store.state.conversations.first?.lastBody == "sandbags at 6")
}

/// A reply in a group targets the original's post id in the standard reply fields (spec §1).
@MainActor @Test func groupSendReplyCarriesPostIdTarget() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let original = String(repeating: "7b", count: 16)
    let store = await groupStore(db, identity: me, members: [memberC], reachable: [memberC]) { s in
        s.draft = "yes"
        s.replyTarget = AppFeature.ReplyTarget(messageHash: original, body: "sandbags at 6", isOutgoing: false)
    }
    let sent = await groupSends(store, .sendTapped, count: 1)
    let wire = try #require(sent.first)
    #expect(wire.fields.map(\.key) == [0x30, 0x31, 0xFD])
    #expect(ReplyWire.decode(wire.fields)?.replyTo == Data(hexString: original))
    #expect(ReplyWire.decode(wire.fields)?.quote == "sandbags at 6")
    #expect(store.state.replyTarget == nil)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.replyToHash == original)
    #expect(row.replyQuote == "sandbags at 6")
    #expect(row.fieldKeys == "0x30,0x31,0xfd")
}

/// Only an active group accepts a post: invited, left and dissolved groups, an empty draft and a
/// pending attachment all send nothing.
@MainActor @Test func groupSendRefusedUnlessGroupActive() async throws {
    for state in [GroupState.invited, GroupState.left, GroupState.dissolved] {
        let db = try AppDatabase.makeInMemory()
        let store = await groupStore(db, identity: Identity(), members: [memberC], state: state, reachable: [memberC]) { $0.draft = "hi" }
        store.exhaustivity = .on
        await store.send(.sendTapped)
        #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty, Comment(rawValue: state))
        #expect(store.state.draft == "hi", Comment(rawValue: state))
    }
    let db = try AppDatabase.makeInMemory()
    let store = await groupStore(db, identity: Identity(), members: [memberC], reachable: [memberC]) { s in
        s.draft = "cap"
        s.pendingAttachment = pendingImage()
    }
    store.exhaustivity = .on
    await store.send(.sendTapped)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
}

/// Spec §3: a reaction fans out to the reachable members only, each copy carrying the standard
/// reaction with the 16-byte post id as target plus the group marker; the row keys on the post id.
@MainActor @Test func groupSendReactionFansOutToReachableMembersWithMarker() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let postId = String(repeating: "5e", count: 16)
    let store = await groupStore(db, identity: me, members: [memberC, memberD, peerA], reachable: [memberC, memberD])
    let sent = await groupSends(store, .reactionSelected(messageHash: postId, emoji: "👍"), count: 2)
    #expect(Set(sent.map(\.destinationHash)) == [Data(hexString: memberC)!, Data(hexString: memberD)!])
    for wire in sent {
        #expect(wire.fields.map(\.key) == [0x40, 0xFD])
        #expect(ReactionWire.decode(wire.fields) == .reaction(target: Data(hexString: postId)!, emoji: "👍"))
        #expect(GroupWire.decode(wire.fields) == .marker(groupId: Data(hexString: groupHexA)!))
        #expect(wire.content.isEmpty)
        #expect(wire.title.isEmpty)
    }
    let rows = try await db.read { try Reaction.all.fetchAll($0) }
    #expect(rows == [Reaction(messageHash: postId, reactorHex: myHex, emoji: "👍", sentAt: infoT0.timeIntervalSince1970)])
    #expect(store.state.threadReactions[postId]?.first?.includesMe == true)
}

/// A reaction in a group whose target is not a 16-byte post id sends nothing.
@MainActor @Test func groupSendReactionRejectsNonPostTarget() async throws {
    let db = try AppDatabase.makeInMemory()
    let store = await groupStore(db, identity: Identity(), members: [memberC], reachable: [memberC])
    store.exhaustivity = .on
    await store.send(.reactionSelected(messageHash: String(repeating: "9", count: 64), emoji: "👍"))
    #expect(try await db.read { try Reaction.all.fetchAll($0) }.isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupSend > /tmp/ReTiCaMsgr/grp-t6-red.log 2>&1`
Expected: the five tests fail (a group store's `sendTapped` today writes a one-to-one row keyed on the group hex, or hangs waiting for `sendMessage` — a hang is a failure too, under the test timeout).

- [ ] **Step 3: `sendTapped` branches to `sendGroupPost`**

At the top of the `.sendTapped` case, before `let text = state.draft`, add:

```swift
                if state.openConversationKind == .group { return sendGroupPost(&state) }
```

Add the helper after `groupDispatchEffect`:

```swift
    /// Spec §3 "Sending a post": one row with a fresh post id (in `messageHash` too, amendment A2)
    /// and one waiting delivery per other member, then the copies to the reachable members and a
    /// path request for the rest. Text only in v1: a pending attachment blocks the send.
    private func sendGroupPost(_ state: inout State) -> Effect<Action> {
        let text = state.draft
        guard !text.isEmpty, !state.attachmentPreparing, state.pendingAttachment == nil,
              let groupHex = state.openPeerHex, let groupId = Data(hexString: groupHex),
              let group = state.openGroup, group.state == GroupState.active
        else { return .none }
        let me = state.myAddressHex
        let others = Set(state.openGroupOthers)
        let postId = GroupWire.randomId()
        let now = date.now
        var replyFields: [MsgPackValue.IntPair] = []
        var replyToHash: String? = nil
        var replyQuote: String? = nil
        if let target = state.replyTarget,
           let replyTo = Data(hexString: target.messageHash), !replyTo.isEmpty {
            let quote = ReplyWire.trimQuote(target.body)
            replyFields = ReplyWire.encode(replyTo: replyTo, quote: quote)
            replyToHash = target.messageHash
            replyQuote = quote.isEmpty ? nil : quote
        }
        let fields = replyFields + GroupWire.encodePost(groupId: groupId, postId: postId)
        let alsoViaPropagation = !state.propagationNodeHex.isEmpty
        let row = Message(
            id: UUID(), peerHex: me, isOutgoing: true, body: text, timestamp: now,
            status: MessageStatus.sending, validated: false, messageHash: postId.hexString,
            senderTimestamp: now, sentViaPropagation: alsoViaPropagation,
            titleSize: GroupWire.trimName(group.name).utf8.count, contentSize: text.utf8.count,
            fieldKeys: MessageMetadata.fieldKeys(fields),
            replyToHash: replyToHash, replyQuote: replyQuote,
            groupHex: groupHex, groupPostId: postId.hexString)
        let deliveries = others.sorted().map { GroupDelivery.waiting(messageId: row.id, memberHex: $0) }
        state.draft = ""
        state.replyTarget = nil
        state.attachmentError = nil
        let reachable = others.intersection(state.reachablePeers)
        let identity = state.identity
        let myName = state.myName
        let pathRequests = others.subtracting(reachable).map { state.pathRequestIfUnreachable($0) }
        let write: Effect<Action> = .run { [database] send in
            try await database.write { db in
                try Message.insert { row }.execute(db)
                for delivery in deliveries { try GroupDelivery.insert { delivery }.execute(db) }
                try GroupDelivery.refreshDerivedStatus(messageId: row.id, db)
            }
            _ = try await dispatchWaitingGroupCopies(database, members: reachable, identity: identity,
                                                     myName: myName, alsoViaPropagation: alsoViaPropagation,
                                                     now: now, send)
            try await reloadThread(database, groupHex, send)
            try await reloadConversations(database, send)
        }
        return .merge(pathRequests + [.cancel(id: CancelID.attachmentPreparation), write])
    }
```

- [ ] **Step 4: `reactionSelected` in a group**

At the top of the `.reactionSelected` case, replace the `guard` with:

```swift
                guard !messageHash.isEmpty,
                      let target = Data(hexString: messageHash),
                      let peerHex = state.openPeerHex,
                      let peer = Data(hexString: peerHex) else { return .none }
                if state.openConversationKind == .group {
                    // Spec §3: one reaction message per reachable member, the post id as the
                    // standard target plus the group marker; unreachable members miss it
                    // (amendment A9). The row keys on the post id like every group reaction.
                    guard target.count == GroupWire.idLength else { return .none }
                    let me = state.myAddressHex
                    let mine = state.threadReactionRows.first { $0.messageHash == messageHash && $0.reactorHex == me }
                    let newEmoji = mine?.emoji == emoji ? "" : emoji
                    let sentAt = max(date.now.timeIntervalSince1970, (mine?.sentAt ?? 0) + 0.001)
                    let recipients = state.openGroupOthers.filter { state.reachablePeers.contains($0) }
                    let copies: [LXMessage] = recipients.compactMap { hex in
                        guard let member = Data(hexString: hex) else { return nil }
                        return LXMessage.create(
                            source: state.identity, destinationHash: member, timestamp: sentAt,
                            title: Data(), content: Data(),
                            fields: ReactionWire.encode(target: target, emoji: newEmoji) + GroupWire.encodeMarker(groupId: peer))
                    }
                    let row = Reaction(messageHash: messageHash, reactorHex: me, emoji: newEmoji, sentAt: sentAt)
                    state.setThreadReactionRows(
                        state.threadReactionRows.filter { !($0.messageHash == messageHash && $0.reactorHex == me) } + [row]
                    )
                    let alsoViaPropagation = !state.propagationNodeHex.isEmpty
                    let sends: [Effect<Action>] = copies.map {
                        .send(.node(.client(.sendMessage(message: $0, alsoViaPropagation: alsoViaPropagation))))
                    }
                    return .merge(sends + [.run { [database] send in
                        try await database.write { try Reaction.apply(row, $0) }
                        try await reloadThread(database, peerHex, send)
                    }])
                }
```

The rest of the case (the one-to-one path) stays as it is below this block.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupSend > /tmp/ReTiCaMsgr/grp-t6-green.log 2>&1`
Expected: 5 tests passed.

- [ ] **Step 6: Mutation verification**

| Mutation (production code) | Test that must go RED |
|---|---|
| `sendGroupPost`: build the row with `messageHash: ""` | `groupSendPostWritesRowDeliveriesAndSendsToReachable` |
| `sendGroupPost`: use `fields = GroupWire.encodePost(...)` alone (drop `replyFields +`) | `groupSendReplyCarriesPostIdTarget` |
| `sendGroupPost`: change `group.state == GroupState.active` to `group.isOpen` | `groupSendRefusedUnlessGroupActive` |
| `reactionSelected` group branch: build copies for `state.openGroupOthers` (drop the reachability filter) | `groupSendReactionFansOutToReachableMembersWithMarker` (three sends, `peerA` included) |
| `reactionSelected` group branch: delete the `guard target.count == GroupWire.idLength` line | `groupSendReactionRejectsNonPostTarget` |

Apply all five, run the filter once, confirm all five RED. Revert by hand, run again, all GREEN.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCaMsgr/msg-grp-task-6.txt`:

```
feat: send posts and reactions in a group

A group post is one row with its post id, a waiting delivery per member,
copies to the reachable members and path requests for the rest; a reply
targets the original's post id in the standard reply fields. A group
reaction fans out to the reachable members with the post id as target
and the group marker.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C APP add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-6.txt`

---

### Task 7: Delivery delegates update member rows and the derived status

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/GroupDelivery.swift` (add `Outcome` and `applyOutcome`)
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` (`propagationAccepted`, `deliveryConfirmed`, `markUndeliverable`)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (append)

**Interfaces:**
- Consumes: Tasks 1, 3, 5.
- Produces: `enum GroupDelivery.Outcome { case delivered, stored, failed, cancelled }`; `GroupDelivery.applyOutcome(hash: String, _ outcome: Outcome, at now: Date, _ db: GRDB.Database) throws -> UUID?` (the matched row's message id after refreshing the derived status, nil when no group copy has that hash). The four delegate sites call it inside their existing write.

- [ ] **Step 1: Write the failing tests**

Append to `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`:

```swift

// MARK: - Group chats: delivery delegates (Task 7)

private let groupDeliverHashC = String(repeating: "a1", count: 32)
private let groupDeliverHashD = String(repeating: "b2", count: 32)

/// A post row sending to C and D, with the group open, so the thread reload is observable.
@MainActor
private func groupDeliverStore(_ db: any DatabaseWriter) async -> (TestStoreOf<AppFeature>, Message) {
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let post = Message(id: uuid(11), peerHex: myHex, isOutgoing: true, body: "p", timestamp: infoT0,
                       status: MessageStatus.sending, validated: false, messageHash: String(repeating: "5e", count: 16),
                       groupHex: groupHexA, groupPostId: String(repeating: "5e", count: 16))
    try! await db.write { db in
        try Message.insert { post }.execute(db)
        try GroupDelivery.insert {
            GroupDelivery(messageId: post.id, memberHex: memberC, messageHash: groupDeliverHashC,
                          status: MessageStatus.sending, storedAt: nil, deliveredAt: nil, failedAt: nil)
        }.execute(db)
        try GroupDelivery.insert {
            GroupDelivery(messageId: post.id, memberHex: memberD, messageHash: groupDeliverHashD,
                          status: MessageStatus.sending, storedAt: nil, deliveredAt: nil, failedAt: nil)
        }.execute(db)
    }
    let store = await groupStore(db, identity: me, members: [memberC, memberD])
    return (store, post)
}

private func groupDeliverRows(_ db: any DatabaseWriter) async throws -> (c: GroupDelivery?, d: GroupDelivery?, post: Message?) {
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    let post = try await db.read { try Message.where { $0.id.eq(uuid(11)) }.fetchOne($0) }
    return (deliveries.first { $0.memberHex == memberC }, deliveries.first { $0.memberHex == memberD }, post)
}

/// Spec §3 "Delivery delegates": a proof for a member's hash marks that row delivered with its
/// first-proof time, the post stays sending until every member proved, then reads delivered.
@MainActor @Test func groupDeliverConfirmedUpdatesMemberRowAndDerivedStatus() async throws {
    let db = try AppDatabase.makeInMemory()
    let (store, _) = await groupDeliverStore(db)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(groupDeliverHashC))))))
    await store.skipReceivedActions(strict: false)
    var rows = try await groupDeliverRows(db)
    #expect(rows.c?.status == MessageStatus.delivered)
    #expect(rows.c?.deliveredAt == infoT0)
    #expect(rows.d?.status == MessageStatus.sending)
    #expect(rows.post?.status == MessageStatus.sending)
    #expect(store.state.deliveriesByMessageId[uuid(11)]?.first { $0.memberHex == memberC }?.status == MessageStatus.delivered)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(groupDeliverHashD))))))
    await store.skipReceivedActions(strict: false)
    rows = try await groupDeliverRows(db)
    #expect(rows.post?.status == MessageStatus.delivered)
    #expect(store.state.threadMessages.first?.status == MessageStatus.delivered)
    // A repeat proof never moves the first time.
    store.dependencies.date = .constant(infoT0.addingTimeInterval(60))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(groupDeliverHashC))))))
    await store.skipReceivedActions(strict: false)
    #expect(try await groupDeliverRows(db).c?.deliveredAt == infoT0)
}

/// A propagation acceptance marks the member row stored unless it was already delivered; a post
/// whose copies are all proved or stored reads stored.
@MainActor @Test func groupDeliverPropagationAcceptedMarksStored() async throws {
    let db = try AppDatabase.makeInMemory()
    let (store, _) = await groupDeliverStore(db)
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(groupDeliverHashC))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(groupDeliverHashD))))))
    await sendAndSettle(store, .node(.client(.delegate(.propagationAccepted(messageHash: hashData(groupDeliverHashD))))))
    await store.skipReceivedActions(strict: false)
    let rows = try await groupDeliverRows(db)
    #expect(rows.c?.status == MessageStatus.propagated)
    #expect(rows.c?.storedAt == infoT0)
    #expect(rows.d?.status == MessageStatus.delivered)   // delivered beats stored
    #expect(rows.d?.storedAt == infoT0)                   // the acceptance time is still news
    #expect(rows.post?.status == MessageStatus.propagated)
}

/// Failures: a failed, rejected or cancelled copy takes that status with its first failure time,
/// never clobbers a delivered or stored one, and the post reads failed only when every copy did.
@MainActor @Test func groupDeliverFailedRejectedCancelledFollowTheGuards() async throws {
    let db = try AppDatabase.makeInMemory()
    let (store, _) = await groupDeliverStore(db)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(groupDeliverHashC))))))
    await store.skipReceivedActions(strict: false)
    var rows = try await groupDeliverRows(db)
    #expect(rows.c?.status == MessageStatus.failed)
    #expect(rows.c?.failedAt == infoT0)
    #expect(rows.post?.status == MessageStatus.sending)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryCancelled(messageHash: hashData(groupDeliverHashD))))))
    await store.skipReceivedActions(strict: false)
    rows = try await groupDeliverRows(db)
    #expect(rows.d?.status == MessageStatus.cancelled)
    #expect(rows.post?.status == MessageStatus.failed)
    // A late failure for a cancelled row leaves it cancelled; a proof after a failure still wins.
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(groupDeliverHashD))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(groupDeliverHashC))))))
    await store.skipReceivedActions(strict: false)
    rows = try await groupDeliverRows(db)
    #expect(rows.d?.status == MessageStatus.cancelled)
    #expect(rows.c?.status == MessageStatus.delivered)
    #expect(rows.post?.status == MessageStatus.sent)
    // A failure after delivery changes nothing.
    await sendAndSettle(store, .node(.client(.delegate(.deliveryFailed(messageHash: hashData(groupDeliverHashC))))))
    await store.skipReceivedActions(strict: false)
    #expect(try await groupDeliverRows(db).c?.status == MessageStatus.delivered)
}

/// A hash no group copy carries touches no delivery row (the one-to-one path handles it).
@MainActor @Test func groupDeliverUnknownHashTouchesNothing() async throws {
    let db = try AppDatabase.makeInMemory()
    let (store, _) = await groupDeliverStore(db)
    await sendAndSettle(store, .node(.client(.delegate(.deliveryConfirmed(messageHash: hashData(String(repeating: "c3", count: 32)))))))
    await store.skipReceivedActions(strict: false)
    let rows = try await groupDeliverRows(db)
    #expect(rows.c?.status == MessageStatus.sending)
    #expect(rows.d?.status == MessageStatus.sending)
    #expect(rows.post?.status == MessageStatus.sending)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupDeliver > /tmp/ReTiCaMsgr/grp-t7-red.log 2>&1`
Expected: the four tests fail (rows stay `sending`).

- [ ] **Step 3: `GroupDelivery.applyOutcome`**

Append inside `GroupDelivery` (after `refreshDerivedStatus`):

```swift
    public enum Outcome: Equatable, Sendable { case delivered, stored, failed, cancelled }

    /// Spec §3 "Delivery delegates": applies one delegate outcome to the copy with `hash`, under
    /// the same guards and first-milestone rules as `messages`: delivered always wins and records
    /// the first proof time; stored never downgrades delivered and records the first acceptance;
    /// failed or cancelled never clobber stored, delivered or cancelled and record the first
    /// failure. Then the row's message gets its derived status. Returns the message id, or nil when
    /// no group copy carries `hash`.
    @discardableResult
    public static func applyOutcome(hash: String, _ outcome: Outcome, at now: Date, _ db: GRDB.Database) throws -> UUID? {
        guard let row = try GroupDelivery.where { $0.messageHash.eq(hash) }.fetchOne(db) else { return nil }
        let milestone: Date? = now
        switch outcome {
        case .delivered:
            try GroupDelivery.where { $0.messageHash.eq(hash) }
                .update { $0.status = MessageStatus.delivered }
                .execute(db)
            try GroupDelivery.where { $0.messageHash.eq(hash) && $0.deliveredAt.is(nil) }
                .update { $0.deliveredAt = milestone }
                .execute(db)
        case .stored:
            try GroupDelivery.where { $0.messageHash.eq(hash) && $0.status.neq(MessageStatus.delivered) }
                .update { $0.status = MessageStatus.propagated }
                .execute(db)
            try GroupDelivery.where { $0.messageHash.eq(hash) && $0.storedAt.is(nil) }
                .update { $0.storedAt = milestone }
                .execute(db)
        case .failed, .cancelled:
            let status = outcome == .failed ? MessageStatus.failed : MessageStatus.cancelled
            try GroupDelivery.where {
                $0.messageHash.eq(hash)
                    && $0.status.neq(MessageStatus.propagated)
                    && $0.status.neq(MessageStatus.delivered)
                    && $0.status.neq(MessageStatus.cancelled)
            }
                .update { $0.status = status }
                .execute(db)
            try GroupDelivery.where { $0.messageHash.eq(hash) && $0.failedAt.is(nil) }
                .update { $0.failedAt = milestone }
                .execute(db)
        }
        try refreshDerivedStatus(messageId: row.messageId, db)
        return row.messageId
    }
```

- [ ] **Step 4: Call it from the delegates**

In `.propagationAccepted`, inside `database.write { db in ... }` after the second `Message.where ... update ... execute(db)`, add:

```swift
                        // A group copy carries its own hash in its delivery row (spec §3).
                        try GroupDelivery.applyOutcome(hash: hex, .stored, at: milestoneAt ?? .distantPast, db)
```

In `.deliveryConfirmed`, at the same place, add:

```swift
                        try GroupDelivery.applyOutcome(hash: hex, .delivered, at: milestoneAt ?? .distantPast, db)
```

In `markUndeliverable`, after the `failedAt` update inside the write, add:

```swift
                try GroupDelivery.applyOutcome(hash: hex, status == MessageStatus.cancelled ? .cancelled : .failed,
                                               at: milestoneAt ?? .distantPast, db)
```

(`milestoneAt` is declared `Date?` only so the update subscript accepts it; it is never nil, hence the `?? .distantPast` that keeps the call non-optional.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupDeliver > /tmp/ReTiCaMsgr/grp-t7-green.log 2>&1`
Expected: 4 tests passed.

- [ ] **Step 6: Mutation verification**

| Mutation (production code) | Test that must go RED |
|---|---|
| `applyOutcome` `.delivered`: drop `&& $0.deliveredAt.is(nil)` from the milestone update | `groupDeliverConfirmedUpdatesMemberRowAndDerivedStatus` (the repeat proof moves the time) |
| `applyOutcome` `.stored`: drop `&& $0.status.neq(MessageStatus.delivered)` | `groupDeliverPropagationAcceptedMarksStored` (D downgraded) |
| `applyOutcome` `.failed/.cancelled`: drop `&& $0.status.neq(MessageStatus.cancelled)` | `groupDeliverFailedRejectedCancelledFollowTheGuards` |
| `applyOutcome`: change the leading fetch to `GroupDelivery.all.fetchOne(db)` and the three `$0.messageHash.eq(hash)` predicates in the `.delivered` branch to `$0.messageHash.eq(row.messageHash ?? "")` | `groupDeliverUnknownHashTouchesNothing` (an unknown hash now marks the first row delivered) |

Sub-batch A: rows 1–3 together. Sub-batch B: row 4 alone. Revert by hand, run again, all GREEN.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCaMsgr/msg-grp-task-7.txt`:

```
feat: delivery delegates update group member rows

A proof, acceptance, failure, rejection or cancel for a member copy's
hash updates that groupDeliveries row under the messages guards and
first-milestone rules, then writes the post's derived status back.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C APP add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/GroupDelivery.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-7.txt`

---

### Task 8: Receiving posts and reactions

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` (`.messageReceived`: the reaction branch and the ordinary-message write)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (append)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: in `.messageReceived`, `groupDecoded: GroupWire.Decoded?` (nil unless validated) computed once in the reducer body; the ordinary-message write returns `(expiresAt: Date?, threadKey: String?)` and reloads the thread whose key is open. Task 9 adds the `.roster` and `.leave` branches on the same `groupDecoded`.

- [ ] **Step 1: Write the failing tests**

Append to `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`:

```swift

// MARK: - Group chats: receiving posts and reactions (Task 8)

private let groupReceivePid = Data(repeating: 0x5e, count: 16)

/// A member's post to me on the wire, shaped as `groupCopy` builds it.
private func groupPostWire(from sender: Identity, to me: Identity, postId: Data = groupReceivePid,
                           text: String = "sandbags at 6", at ts: Double = 1700000000.5,
                           extra: [MsgPackValue.IntPair] = []) -> LXMessage {
    wireMessage(from: sender, to: me, at: ts, title: "Mutual Aid", content: text,
                fields: extra + GroupWire.encodePost(groupId: Data(hexString: groupHexA)!, postId: postId))
}

/// Delivers `m` to the open group store and drains the effects.
@MainActor
private func groupReceive(_ store: TestStoreOf<AppFeature>, _ m: LXMessage, validated: Bool = true) async {
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: validated, method: .opportunistic)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

/// Spec §3 "Receiving": a post from a current member lands in the group thread, keyed on its post
/// id (amendment A2), with the sender as `peerHex`.
@MainActor @Test func groupReceivePostFromMemberLandsInGroupThread() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex, memberD])
    await groupReceive(store, groupPostWire(from: sender, to: me))
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.groupHex == groupHexA)
    #expect(row.groupPostId == groupReceivePid.hexString)
    #expect(row.messageHash == groupReceivePid.hexString)
    #expect(row.peerHex == senderHex)
    #expect(row.isOutgoing == false)
    #expect(row.body == "sandbags at 6")
    #expect(row.validated == true)
    #expect(row.titleSize == 10)
    #expect(row.fieldKeys == "0xfd")
    #expect(row.expirySeconds == nil)
    #expect(store.state.threadMessages.map(\.body) == ["sandbags at 6"])
    #expect(store.state.conversations.map(\.title) == ["Mutual Aid"])
    let seen = try await db.read { try SeenHashRow.all.fetchAll($0) }
    #expect(seen.map(\.hashHex) == [groupPostWire(from: sender, to: me).hash.hexString])
}

/// Spec §1: the same post id twice (a later copy with a fresh hash) stores one row; both LXMF
/// hashes are remembered so neither is re-delivered.
@MainActor @Test func groupReceiveDuplicatePostIdStoresOneRowAndBothHashes() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex])
    await groupReceive(store, groupPostWire(from: sender, to: me, at: 1700000000.5))
    await store.send(.node(.client(.delegate(.messageReceived(
        message: groupPostWire(from: sender, to: me, text: "sandbags at 6 (again)", at: 1700000009),
        signatureValidated: true, method: .propagated)))))
    await store.skipReceivedActions(strict: false)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.body) == ["sandbags at 6"])
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.count == 2)
}

/// Review Focus 1: a post from someone not on the roster (a removed member, say) is an ordinary
/// one-to-one message from that sender, field ignored.
@MainActor @Test func groupReceivePostFromNonMemberIsPlainMessage() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let outsider = Identity()
    let store = await groupStore(db, identity: me, creatorHex: memberC, members: [memberC])
    let m = groupPostWire(from: outsider, to: me)
    await groupReceive(store, m)
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.groupHex == nil)
    #expect(row.groupPostId == nil)
    #expect(row.messageHash == m.hash.hexString)
    #expect(row.peerHex == groupMemberHash(outsider).hexString)
    #expect(row.body == "sandbags at 6")
    #expect(store.state.threadMessages.isEmpty)   // the open group thread did not gain it
    #expect(store.state.conversations.map(\.kind) == [.peer])
}

/// An unknown group id, a group the user left, and an unvalidated signature all yield a plain
/// message too.
@MainActor @Test func groupReceivePostForUnknownClosedOrUnvalidatedIsPlainMessage() async throws {
    let me = Identity()
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    // Unknown group: no group row at all.
    let unknownDb = try AppDatabase.makeInMemory()
    let unknown = makeStore(unknownDb, identity: me)
    await groupReceive(unknown, groupPostWire(from: sender, to: me))
    #expect(try await unknownDb.read { try Message.all.fetchAll($0) }.first?.groupHex == nil)
    // Left group.
    let leftDb = try AppDatabase.makeInMemory()
    let left = await groupStore(leftDb, identity: me, creatorHex: senderHex, members: [senderHex], state: GroupState.left)
    await groupReceive(left, groupPostWire(from: sender, to: me))
    #expect(try await leftDb.read { try Message.all.fetchAll($0) }.first?.groupHex == nil)
    // Unvalidated.
    let unvalidatedDb = try AppDatabase.makeInMemory()
    let unvalidated = await groupStore(unvalidatedDb, identity: me, creatorHex: senderHex, members: [senderHex])
    await groupReceive(unvalidated, groupPostWire(from: sender, to: me), validated: false)
    #expect(try await unvalidatedDb.read { try Message.all.fetchAll($0) }.first?.groupHex == nil)
    // Invited (not yet accepted) still takes the post into the group.
    let invitedDb = try AppDatabase.makeInMemory()
    let invited = await groupStore(invitedDb, identity: me, creatorHex: senderHex, members: [senderHex], state: GroupState.invited)
    await groupReceive(invited, groupPostWire(from: sender, to: me))
    #expect(try await invitedDb.read { try Message.all.fetchAll($0) }.first?.groupHex == groupHexA)
}

/// Amendment A9: an expiry entry riding beside the group entry is ignored on a group post, and
/// never touches a conversation setting.
@MainActor @Test func groupReceivePostIgnoresExpiryEntry() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex])
    let fields = [MsgPackValue.IntPair(0xFD, .map([
        .init("reticamsgr.expiry", .uint(60)),
        .init("reticamsgr.group", .array([.bin(Data(hexString: groupHexA)!), .bin(groupReceivePid)])),
    ]))]
    await groupReceive(store, wireMessage(from: sender, to: me, at: 1700000000.5, title: "Mutual Aid", content: "x", fields: fields))
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.groupHex == groupHexA)
    #expect(row.expirySeconds == nil)
    #expect(row.expiresAt == nil)
    #expect(try await db.read { try ConversationSetting.all.fetchAll($0) }.isEmpty)
}

/// Spec §3: a group reaction is kept from a current member and keys on the post id; one from a
/// non-member is dropped (its hash still remembered).
@MainActor @Test func groupReceiveReactionFromMemberAttachesToPostAndNonMemberDoesNot() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let member = Identity()
    let outsider = Identity()
    let memberHex = groupMemberHash(member).hexString
    let store = await groupStore(db, identity: me, creatorHex: memberHex, members: [memberHex])
    let marker = GroupWire.encodeMarker(groupId: Data(hexString: groupHexA)!)
    let good = LXMessage.create(source: member, destinationHash: groupMemberHash(me), timestamp: 1700000001,
                                title: Data(), content: Data(),
                                fields: ReactionWire.encode(target: groupReceivePid, emoji: "👍") + marker)
    await store.send(.node(.client(.delegate(.messageReceived(message: good, signatureValidated: true, method: .opportunistic)))))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Reaction.all.fetchAll($0) }
            == [Reaction(messageHash: groupReceivePid.hexString, reactorHex: memberHex, emoji: "👍", sentAt: 1700000001)])
    let bad = LXMessage.create(source: outsider, destinationHash: groupMemberHash(me), timestamp: 1700000002,
                               title: Data(), content: Data(),
                               fields: ReactionWire.encode(target: groupReceivePid, emoji: "😂") + marker)
    await store.send(.node(.client(.delegate(.messageReceived(message: bad, signatureValidated: true, method: .opportunistic)))))
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Reaction.all.fetchAll($0) }.count == 1)
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.count == 2)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
}

/// A reply in a group keeps the original's 16-byte post id as its stored target.
@MainActor @Test func groupReceiveReplyKeepsPostIdTarget() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let original = Data(repeating: 0x7b, count: 16)
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex])
    await groupReceive(store, groupPostWire(from: sender, to: me, text: "yes",
                                            extra: ReplyWire.encode(replyTo: original, quote: "sandbags at 6")))
    let row = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(row.groupHex == groupHexA)
    #expect(row.replyToHash == original.hexString)
    #expect(row.replyQuote == "sandbags at 6")
    #expect(row.fieldKeys == "0x30,0x31,0xfd")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupReceive > /tmp/ReTiCaMsgr/grp-t8-red.log 2>&1`
Expected: the seven tests fail (`groupHex` nil on every stored row; the group reaction from the non-member is kept).

- [ ] **Step 3: The reaction branch**

In `.messageReceived`, replace the `case let .reaction(target, emoji):` branch body with:

```swift
                case let .reaction(target, emoji):
                    // Reactions never become bubbles and never touch the conversation list.
                    // Unvalidated ones can't be attributed, so only the seen hash is recorded.
                    // A group reaction (spec §3 "Receiving") carries the group marker and is kept
                    // only from a current member of a known open group; it keys on the post id.
                    let marker: String? = {
                        guard validated, case let .marker(gid)? = GroupWire.decode(m.fields) else { return nil }
                        return gid.hexString
                    }()
                    let reaction: Reaction? = validated
                        ? Reaction(messageHash: target.hexString, reactorHex: incomingPeer,
                                   emoji: emoji, sentAt: m.timestamp)
                        : nil
                    return .run { [database] send in
                        let applied = try await database.write { db -> Bool in
                            var applied = false
                            if let reaction {
                                if let marker {
                                    if let group = try ChatGroup.fetch(marker, db), group.isOpen,
                                       try GroupMember.contains(marker, incomingPeer, db) {
                                        try Reaction.apply(reaction, db)
                                        applied = true
                                    }
                                } else {
                                    try Reaction.apply(reaction, db)
                                    applied = true
                                }
                            }
                            try recordSeenHash(seenHashHex, at: seenNow, db)
                            return applied
                        }
                        if applied, let openPeer, incomingPeer == openPeer || marker == openPeer {
                            try await reloadThread(database, openPeer, send)
                        }
                    }
```

- [ ] **Step 4: The ordinary-message write**

After `let decodedExpiry = validated ? ExpiryWire.decode(m.fields) : nil`, add:

```swift
                // Group chats (spec §3 "Receiving"): only a validated sender's group entry counts.
                // `.post` is handled in the write below; `.roster` and `.leave` in their own
                // branches; `.marker` on a non-reaction is ignored (an ordinary message).
                let groupDecoded = validated ? GroupWire.decode(m.fields) : nil
```

Change the write's signature and body. Replace

```swift
                    let storedExpiresAt = try await database.write { db -> Date? in
                        var stored = row
                        if let decoded = decodedExpiry {
```

with

```swift
                    let result = try await database.write { db -> (expiresAt: Date?, threadKey: String?) in
                        var stored = row
                        // A post goes into its group only from a current member of a known open
                        // group (spec §1 receive rules); anything else stays a one-to-one message
                        // with the field ignored. A duplicate post id records its hash and stores
                        // nothing. A group post never carries a timer (amendment A9).
                        var isGroupPost = false
                        if case let .post(gid, pid)? = groupDecoded {
                            let gidHex = gid.hexString
                            let pidHex = pid.hexString
                            if let group = try ChatGroup.fetch(gidHex, db), group.isOpen,
                               try GroupMember.contains(gidHex, incomingPeer, db) {
                                if try Message.where { $0.groupHex.eq(gidHex) && $0.groupPostId.eq(pidHex) }.fetchOne(db) != nil {
                                    try recordSeenHash(seenHashHex, at: seenNow, db)
                                    return (nil, nil)
                                }
                                stored.groupHex = gidHex
                                stored.groupPostId = pidHex
                                stored.messageHash = pidHex   // amendment A2
                                stored.expirySeconds = nil
                                stored.expiresAt = nil
                                stored.isTimerChange = false
                                isGroupPost = true
                            }
                        }
                        if isGroupPost {
                            // No conversation-setting logic for a group row.
                        } else if let decoded = decodedExpiry {
```

Then, still inside that write, replace `return stored.expiresAt` with:

```swift
                        return (stored.expiresAt, stored.groupHex ?? incomingPeer)
```

and after the write, replace

```swift
                    try await reloadConversations(database, send)
                    if incomingPeer == openPeer {
                        try await reloadThread(database, incomingPeer, send)
                    }
                    if storedExpiresAt != nil {
```

with

```swift
                    try await reloadConversations(database, send)
                    if let key = result.threadKey, key == openPeer {
                        try await reloadThread(database, key, send)
                    }
                    if result.expiresAt != nil {
```

The `viewedNow` computation above the row stays as it is: it compares `incomingPeer` with the open key, which is never a group post's key, so a group post is never stamped; that is the intended "no timers in groups".

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupReceive > /tmp/ReTiCaMsgr/grp-t8-green.log 2>&1`
Expected: 7 tests passed. Then the full suite: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/grp-t8-full.log 2>&1`, baseline + 57 passed (the one-to-one receive and expiry tests must still pass unchanged).

- [ ] **Step 6: Mutation verification**

| Mutation (production code) | Test that must go RED |
|---|---|
| In the write: delete `stored.messageHash = pidHex` | `groupReceivePostFromMemberLandsInGroupThread` |
| In the write: delete the duplicate check (`if try Message.where ... return (nil, nil)` block) | `groupReceiveDuplicatePostIdStoresOneRowAndBothHashes` (two rows, or a unique-index throw) |
| In the write: drop `try GroupMember.contains(gidHex, incomingPeer, db)` from the condition | `groupReceivePostFromNonMemberIsPlainMessage` |
| In the write: change `group.isOpen` to `group.state != GroupState.dissolved` | `groupReceivePostForUnknownClosedOrUnvalidatedIsPlainMessage` (the left group takes the post) |
| In the write: delete `stored.expirySeconds = nil` | `groupReceivePostIgnoresExpiryEntry` |
| Reaction branch: drop `try GroupMember.contains(marker, incomingPeer, db)` | `groupReceiveReactionFromMemberAttachesToPostAndNonMemberDoesNot` |
| In the row construction above the write: build `replyToHash: groupDecoded == nil ? reply?.replyTo.hexString : nil` | `groupReceiveReplyKeepsPostIdTarget` |

Apply all seven, run the filter once, confirm all seven RED. Revert by hand, run again, all GREEN.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCaMsgr/msg-grp-task-8.txt`:

```
feat: receive group posts and reactions

A validated post from a current member of a known open group lands in
the group thread keyed on its post id, a duplicate post id stores
nothing, and everything else stays a one-to-one message with the field
ignored. A group reaction is kept from members only.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C APP add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-8.txt`

---

### Task 9: Control messages and local roster actions

**Files:**
- Create: `CORE/Sources/ReTiCaMsgrCore/GroupControlApply.swift`
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` (Action, `.messageReceived` control branches, new cases, two private helpers)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (append)

**Interfaces:**
- Consumes: Tasks 1–8.
- Produces: `GroupControlApply.Names(me:sender:byHex:)` with `name(_ hex:) -> String`; `GroupControlApply.Outcome` (`.applied(groupHex:creatorResends:)`, `.dropped`, `.plainMessage`); `GroupControlApply.applyRoster(groupHex:name:members:revision:from:names:validated:now:_:) throws -> Outcome`; `GroupControlApply.applyLeave(groupHex:from:names:validated:now:_:) throws -> Outcome`. Actions: `addGroupMembers([String])`, `removeGroupMember(String)`, `renameGroup(String)`, `deleteGroup`, `leaveGroup`, `acceptInvite`, `declineInvite`, internal `groupRosterChanged(groupHex: String)`. Private `receiveGroupControl(_:message:validated:method:control:)` and `groupChange(_:groupHex:line:control:recipients:mutate:)`.

- [ ] **Step 1: Write the failing tests**

Append to `CORE/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`:

```swift

// MARK: - Group chats: control messages and roster actions (Task 9)

private func groupRosterWire(from sender: Identity, to me: Identity, members: [String], name: String = "Mutual Aid",
                             revision: Int, at ts: Double = 1700000000.5) -> LXMessage {
    wireMessage(from: sender, to: me, at: ts, title: name, content: "someone invited you to the group \(name) in ReTiCaMsgr",
                fields: GroupWire.encodeRoster(groupId: Data(hexString: groupHexA)!, name: name,
                                               members: members.map { Data(hexString: $0)! }, revision: revision))
}

private func groupLeaveWire(from sender: Identity, to me: Identity, at ts: Double = 1700000000.5) -> LXMessage {
    wireMessage(from: sender, to: me, at: ts, title: "Mutual Aid", content: "someone left the group Mutual Aid",
                fields: GroupWire.encodeLeave(groupId: Data(hexString: groupHexA)!))
}

/// Names the sender "Cy" through an announce, so lines read as a person would see them.
@MainActor
private func groupNameSender(_ store: TestStoreOf<AppFeature>, _ sender: Identity) async {
    let learned = LXMFNode.LearnedPeer(displayName: "Cy", stampCost: nil, supportsCompression: false, learnedAt: infoT0)
    await store.send(.node(.client(.rehydrateLearnedPeers([groupMemberHash(sender): learned]))))
    await store.skipReceivedActions(strict: false)
}

private func groupEventBodies(_ db: any DatabaseWriter) async throws -> [String] {
    try await db.read { try Message.where { $0.isGroupEvent }.order(by: \.timestamp).fetchAll($0) }.map(\.body)
}

/// Spec §3: a roster for an unknown group creates it `invited`, with its sender as creator and
/// one invite line; nothing is stored as a bubble.
@MainActor @Test func groupControlRosterForUnknownGroupCreatesInvitedGroupAndLine() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = makeStore(db, identity: me)
    await groupNameSender(store, sender)
    await groupReceive(store, groupRosterWire(from: sender, to: me, members: [senderHex, myHex, memberD], revision: 1))
    let group = try #require(try await db.read { try ChatGroup.fetch(groupHexA, $0) })
    #expect(group.name == "Mutual Aid")
    #expect(group.creatorHex == senderHex)
    #expect(group.revision == 1)
    #expect(group.state == GroupState.invited)
    #expect(group.updatedAt == infoT0)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [senderHex, myHex, memberD].sorted())
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    let line = try #require(rows.first)
    #expect(line.body == "Cy invited you to the group Mutual Aid")
    #expect(line.isGroupEvent == true)
    #expect(line.isOutgoing == false)
    #expect(line.peerHex == senderHex)
    #expect(line.groupHex == groupHexA)
    #expect(line.validated == true)
    #expect(store.state.conversations.first?.title == "Mutual Aid")
    #expect(store.state.conversations.first?.groupState == GroupState.invited)
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.count == 1)
}

/// A higher revision from the creator replaces the roster and name and says what changed, in
/// the order added, removed, renamed.
@MainActor @Test func groupControlHigherRevisionReplacesMembersAndInsertsLines() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex, memberD])
    await groupNameSender(store, sender)
    await groupReceive(store, groupRosterWire(from: sender, to: me, members: [senderHex, myHex, memberC], name: "Block 4", revision: 2))
    let group = try #require(try await db.read { try ChatGroup.fetch(groupHexA, $0) })
    #expect(group.name == "Block 4")
    #expect(group.revision == 2)
    #expect(group.state == GroupState.active)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [senderHex, myHex, memberC].sorted())
    #expect(try await groupEventBodies(db) == ["Cy added cccccccc", "Cy removed dddddddd", "Cy renamed the group to Block 4"])
    #expect(store.state.openGroup?.name == "Block 4")
    #expect(store.state.threadMessages.count == 3)
}

/// Amendment A5: a roster from the real creator that is not newer is dropped silently.
@MainActor @Test func groupControlStaleRosterFromCreatorIsDropped() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex, memberD])
    let m = groupRosterWire(from: sender, to: me, members: [senderHex, myHex], revision: 1)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true, method: .opportunistic)))))
    await store.skipReceivedActions(strict: false)
    #expect(try await db.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [senderHex, myHex, memberD].sorted())
    #expect(try await db.read { try SeenHashRow.all.fetchAll($0) }.map(\.hashHex) == [m.hash.hexString])
}

/// A roster from anyone but the creator of a known group is the plain message its body is.
@MainActor @Test func groupControlRosterFromNonCreatorIsPlainMessage() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let outsider = Identity()
    let outsiderHex = groupMemberHash(outsider).hexString
    let store = await groupStore(db, identity: me, creatorHex: memberC, members: [memberC])
    let m = groupRosterWire(from: outsider, to: me, members: [outsiderHex, myHex], revision: 5)
    await groupReceive(store, m)
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.groupHex == nil)
    #expect(rows.first?.isGroupEvent == false)
    #expect(rows.first?.peerHex == outsiderHex)
    #expect(rows.first?.messageHash == m.hash.hexString)
    #expect(rows.first?.body == "someone invited you to the group Mutual Aid in ReTiCaMsgr")
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.revision == 1)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, myHex].sorted())
}

/// Review Focus 2: a roster that does not list its own sender does not apply.
@MainActor @Test func groupControlRosterOmittingSenderIsPlainMessage() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex])
    await groupReceive(store, groupRosterWire(from: sender, to: me, members: [myHex, memberD], revision: 2))
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.groupHex) == [nil])
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.revision == 1)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [senderHex, myHex].sorted())
}

/// Being left off the roster marks the group `left` with its own line; an empty roster marks it
/// `dissolved`, after which nothing revives it.
@MainActor @Test func groupControlRosterRemovingMeOrEmptyClosesTheGroup() async throws {
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let removedDb = try AppDatabase.makeInMemory()
    let removed = await groupStore(removedDb, identity: me, creatorHex: senderHex, members: [senderHex, memberD])
    await groupNameSender(removed, sender)
    await groupReceive(removed, groupRosterWire(from: sender, to: me, members: [senderHex, memberD], revision: 2))
    #expect(try await removedDb.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.left)
    #expect(try await removedDb.read { try GroupMember.members(of: groupHexA, $0) } == [senderHex, memberD].sorted())
    #expect(try await groupEventBodies(removedDb) == ["Cy removed you from the group"])
    let dissolvedDb = try AppDatabase.makeInMemory()
    let dissolved = await groupStore(dissolvedDb, identity: me, creatorHex: senderHex, members: [senderHex, memberD])
    await groupNameSender(dissolved, sender)
    await groupReceive(dissolved, groupRosterWire(from: sender, to: me, members: [], revision: 2))
    #expect(try await dissolvedDb.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.dissolved)
    #expect(try await dissolvedDb.read { try GroupMember.members(of: groupHexA, $0) }.isEmpty)
    #expect(try await groupEventBodies(dissolvedDb) == ["Cy deleted the group"])
    let revive = groupRosterWire(from: sender, to: me, members: [senderHex, myHex], revision: 3, at: 1700000002)
    await dissolved.send(.node(.client(.delegate(.messageReceived(message: revive, signatureValidated: true, method: .opportunistic)))))
    await dissolved.skipReceivedActions(strict: false)
    #expect(try await dissolvedDb.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.dissolved)
    #expect(try await dissolvedDb.read { try Message.all.fetchAll($0) }.count == 1)
}

/// Review Focus 5: a roster listing me again after I left brings the group back as `invited`.
@MainActor @Test func groupControlReinviteAfterLeftBecomesInvited() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let sender = Identity()
    let senderHex = groupMemberHash(sender).hexString
    let store = await groupStore(db, identity: me, creatorHex: senderHex, members: [senderHex], state: GroupState.left)
    await groupNameSender(store, sender)
    await groupReceive(store, groupRosterWire(from: sender, to: me, members: [senderHex, myHex], revision: 2))
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.invited)
    #expect(try await groupEventBodies(db) == ["Cy invited you to the group Mutual Aid"])
}

/// A leave from a member removes them with a line; from a non-member it is a plain message.
@MainActor @Test func groupControlLeaveFromMemberRemovesAndNonMemberIsPlain() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let leaver = Identity()
    let leaverHex = groupMemberHash(leaver).hexString
    let outsider = Identity()
    let store = await groupStore(db, identity: me, creatorHex: memberC, members: [memberC, leaverHex])
    await groupNameSender(store, leaver)
    await groupReceive(store, groupLeaveWire(from: leaver, to: me))
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, myHex].sorted())
    #expect(try await groupEventBodies(db) == ["Cy left the group"])
    #expect(try await db.read { try GroupDelivery.all.fetchAll($0) }.isEmpty)
    await groupReceive(store, groupLeaveWire(from: outsider, to: me, at: 1700000002))
    let rows = try await db.read { try Message.all.fetchAll($0) }
    #expect(rows.count == 2)
    let plain = try #require(rows.first { $0.groupHex == nil })
    #expect(plain.isGroupEvent == false)
    #expect(plain.body == "someone left the group Mutual Aid")
}

/// Amendment A7: when a member leaves a group I created, the leave line is mine and carries the
/// new roster to the remaining members.
@MainActor @Test func groupControlLeaveWhenIAmCreatorResendsRoster() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let leaver = Identity()
    let leaverHex = groupMemberHash(leaver).hexString
    let store = await groupStore(db, identity: me, members: [leaverHex, memberD], reachable: [memberD])
    await groupNameSender(store, leaver)
    let sent = await groupSends(store, .node(.client(.delegate(.messageReceived(
        message: groupLeaveWire(from: leaver, to: me), signatureValidated: true, method: .opportunistic)))), count: 1)
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberD))
    #expect(GroupWire.decode(wire.fields) == .roster(groupId: Data(hexString: groupHexA)!, name: "Mutual Aid",
                                                     members: [memberD, myHex].sorted().map { Data(hexString: $0)! }, revision: 2))
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.revision == 2)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberD, myHex].sorted())
    let line = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(line.body == "Cy left the group")
    #expect(line.isOutgoing == true)
    #expect(line.groupControl == "roster")
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(deliveries.map(\.memberHex) == [memberD])
    #expect(deliveries.first?.status == MessageStatus.sending)
    #expect(deliveries.first?.messageHash == wire.hash.hexString)
}

/// Spec §3 "Creating and editing": adding members bumps the revision, writes the line, fans the
/// new roster to every member (the new one included) and asks for the paths it lacks.
@MainActor @Test func groupControlAddMembersBumpsRevisionAndFansOut() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, members: [memberC], reachable: [memberC]) { $0.$displayName.withLock { $0 = "Ada" } }
    let sent = await groupSends(store, .addGroupMembers([memberD, memberC, myHex, "junk"]), count: 1)
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberC))
    #expect(wire.content == Data("Ada invited you to the group Mutual Aid in ReTiCaMsgr".utf8))
    #expect(GroupWire.decode(wire.fields) == .roster(groupId: Data(hexString: groupHexA)!, name: "Mutual Aid",
                                                     members: [memberC, memberD, myHex].sorted().map { Data(hexString: $0)! }, revision: 2))
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.revision == 2)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, memberD, myHex].sorted())
    #expect(try await groupEventBodies(db) == ["You added dddddddd"])
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(deliveries.first { $0.memberHex == memberC }?.status == MessageStatus.sending)
    #expect(deliveries.first { $0.memberHex == memberD }?.status == GroupDeliveryStatus.waiting)
    #expect(store.state.node.client.endpoint.transport.pathRequests[Data(hexString: memberD)!] != nil)
    #expect(store.state.openGroupMembers.count == 3)
}

/// Removing a member sends the new roster to the removed member too, so their device marks the
/// group left.
@MainActor @Test func groupControlRemoveMemberSendsRosterToRemovedToo() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let myHex = lxmfAddressHex(me)
    let store = await groupStore(db, identity: me, members: [memberC, memberD], reachable: [memberC, memberD])
    let sent = await groupSends(store, .removeGroupMember(memberD), count: 2)
    #expect(Set(sent.map(\.destinationHash)) == [Data(hexString: memberC)!, Data(hexString: memberD)!])
    for wire in sent {
        #expect(GroupWire.decode(wire.fields) == .roster(groupId: Data(hexString: groupHexA)!, name: "Mutual Aid",
                                                         members: [memberC, myHex].sorted().map { Data(hexString: $0)! }, revision: 2))
    }
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, myHex].sorted())
    #expect(try await groupEventBodies(db) == ["You removed dddddddd"])
}

/// Renaming sends the new name; deleting sends an empty roster with the delete body and marks
/// the group dissolved.
@MainActor @Test func groupControlRenameThenDelete() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = await groupStore(db, identity: me, members: [memberC], reachable: [memberC]) { $0.$displayName.withLock { $0 = "Ada" } }
    let renamed = await groupSends(store, .renameGroup("  Block 4  "), count: 1)
    #expect(GroupWire.decode(try #require(renamed.first).fields)
            == .roster(groupId: Data(hexString: groupHexA)!, name: "Block 4",
                       members: [memberC, lxmfAddressHex(me)].sorted().map { Data(hexString: $0)! }, revision: 2))
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.name == "Block 4")
    #expect(store.state.openGroup?.name == "Block 4")
    let deleted = await groupSends(store, .deleteGroup, count: 1)
    let wire = try #require(deleted.first)
    #expect(wire.content == Data("Ada deleted the group Block 4".utf8))
    #expect(GroupWire.decode(wire.fields) == .roster(groupId: Data(hexString: groupHexA)!, name: "Block 4", members: [], revision: 3))
    let group = try #require(try await db.read { try ChatGroup.fetch(groupHexA, $0) })
    #expect(group.state == GroupState.dissolved)
    #expect(group.revision == 3)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) }.isEmpty)
    #expect(try await groupEventBodies(db) == ["You renamed the group to Block 4", "You deleted the group"])
    // Re-picking the current name sends nothing.
    store.exhaustivity = .on
    await store.send(.renameGroup("Block 4"))
}

/// Leaving sends the leave to every member, drops me from the roster and marks the group left.
@MainActor @Test func groupControlLeaveSendsLeaveAndMarksLeft() async throws {
    let db = try AppDatabase.makeInMemory()
    let me = Identity()
    let store = await groupStore(db, identity: me, creatorHex: memberC, members: [memberC, memberD], reachable: [memberC]) { $0.$displayName.withLock { $0 = "Ada" } }
    let sent = await groupSends(store, .leaveGroup, count: 1)
    let wire = try #require(sent.first)
    #expect(wire.destinationHash == Data(hexString: memberC))
    #expect(wire.content == Data("Ada left the group Mutual Aid".utf8))
    #expect(GroupWire.decode(wire.fields) == .leave(groupId: Data(hexString: groupHexA)!))
    #expect(try await db.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.left)
    #expect(try await db.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, memberD])
    let line = try #require(try await db.read { try Message.all.fetchAll($0) }.first)
    #expect(line.body == "You left the group")
    #expect(line.groupControl == "leave")
    let deliveries = try await db.read { try GroupDelivery.all.fetchAll($0) }
    #expect(deliveries.first { $0.memberHex == memberD }?.status == GroupDeliveryStatus.waiting)
    #expect(store.state.openGroup?.state == GroupState.left)
}

/// Accepting flips invited to active with no message; declining (amendment A6) marks it left,
/// writes its line and sends the leave to the creator only.
@MainActor @Test func groupControlAcceptAndDecline() async throws {
    let me = Identity()
    let acceptDb = try AppDatabase.makeInMemory()
    let accept = await groupStore(acceptDb, identity: me, creatorHex: memberC, members: [memberC, memberD], state: GroupState.invited, reachable: [memberC, memberD])
    await accept.send(.acceptInvite)
    await accept.receive { if case .groupLoaded = $0 { return true }; return false }
    await accept.skipReceivedActions(strict: false)
    #expect(try await acceptDb.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.active)
    #expect(accept.state.openGroup?.state == GroupState.active)
    #expect(try await acceptDb.read { try Message.all.fetchAll($0) }.isEmpty)
    let declineDb = try AppDatabase.makeInMemory()
    let decline = await groupStore(declineDb, identity: me, creatorHex: memberC, members: [memberC, memberD], state: GroupState.invited, reachable: [memberC, memberD])
    let sent = await groupSends(decline, .declineInvite, count: 1)
    #expect(sent.map(\.destinationHash) == [Data(hexString: memberC)!])
    #expect(GroupWire.decode(try #require(sent.first).fields) == .leave(groupId: Data(hexString: groupHexA)!))
    #expect(try await declineDb.read { try ChatGroup.fetch(groupHexA, $0) }?.state == GroupState.left)
    #expect(try await groupEventBodies(declineDb) == ["You declined the invitation"])
    #expect(try await declineDb.read { try GroupDelivery.all.fetchAll($0) }.map(\.memberHex) == [memberC])
    #expect(try await declineDb.read { try GroupMember.members(of: groupHexA, $0) } == [memberC, memberD])
}

/// Only the creator edits, and the creator cannot leave (spec §1); an inactive group refuses edits.
@MainActor @Test func groupControlRoleGuards() async throws {
    let me = Identity()
    let memberDb = try AppDatabase.makeInMemory()
    let member = await groupStore(memberDb, identity: me, creatorHex: memberC, members: [memberC], reachable: [memberC])
    member.exhaustivity = .on
    await member.send(.addGroupMembers([memberD]))
    await member.send(.removeGroupMember(memberC))
    await member.send(.renameGroup("x"))
    await member.send(.deleteGroup)
    await member.send(.acceptInvite)
    await member.send(.declineInvite)
    #expect(try await memberDb.read { try Message.all.fetchAll($0) }.isEmpty)
    #expect(try await memberDb.read { try ChatGroup.fetch(groupHexA, $0) }?.revision == 1)
    let creatorDb = try AppDatabase.makeInMemory()
    let creator = await groupStore(creatorDb, identity: me, members: [memberC], reachable: [memberC])
    creator.exhaustivity = .on
    await creator.send(.leaveGroup)
    await creator.send(.removeGroupMember(lxmfAddressHex(me)))
    await creator.send(.addGroupMembers([memberC]))   // already a member
    #expect(try await creatorDb.read { try Message.all.fetchAll($0) }.isEmpty)
    let leftDb = try AppDatabase.makeInMemory()
    let left = await groupStore(leftDb, identity: me, members: [memberC], state: GroupState.left, reachable: [memberC])
    left.exhaustivity = .on
    await left.send(.renameGroup("x"))
    await left.send(.addGroupMembers([memberD]))
    #expect(try await leftDb.read { try Message.all.fetchAll($0) }.isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupControl > /tmp/ReTiCaMsgr/grp-t9-red.log 2>&1`
Expected: compile errors (`addGroupMembers` etc. unknown).

- [ ] **Step 3: Create `GroupControlApply.swift`**

```swift
import Foundation
import GRDB

/// The database rules for incoming control messages (spec 2026-10-09 §3 "Receiving", amendments
/// A5, A7): what an applied roster or leave writes, and when a message must instead be stored as
/// the plain one-to-one message its body is, or dropped. Runs inside the reducer's write.
public enum GroupControlApply {
    public enum Outcome: Equatable, Sendable {
        /// Rows were written for `groupHex`. `creatorResends` is true when I am the creator and a
        /// member left, so the reducer fans the new roster out (amendment A7).
        case applied(groupHex: String, creatorResends: Bool)
        /// Not applicable but harmless (a stale roster from the real creator): seen hash only.
        case dropped
        /// Not a valid control message for this device: store it as a plain message.
        case plainMessage
    }

    /// Who is who, resolved by the reducer before the write (display names live in state).
    public struct Names: Equatable, Sendable {
        public var me: String
        /// The sender's name as a line should show it.
        public var sender: String
        /// Announce display names of the roster's members, by address.
        public var byHex: [String: String]

        public init(me: String, sender: String, byHex: [String: String]) {
            self.me = me
            self.sender = sender
            self.byHex = byHex
        }

        public func name(_ hex: String) -> String {
            if hex == me { return GroupEventText.you }
            return byHex[hex] ?? GroupEventText.fallbackName(hex)
        }
    }

    /// A roster from `senderHex`. The first roster for an id establishes its creator (spec §1);
    /// later ones must come from that creator with a higher revision; one that does not list its
    /// sender, or that does not list me for a group I do not have, is a plain message; a stale
    /// one from the real creator is dropped (amendment A5).
    public static func applyRoster(groupHex: String, name: String, members: [String], revision: Int,
                                   from senderHex: String, names: Names, validated: Bool, now: Date,
                                   _ db: GRDB.Database) throws -> Outcome {
        guard members.contains(senderHex) else { return .plainMessage }   // Review Focus 2
        let stored = try ChatGroup.fetch(groupHex, db)
        let iAmListed = members.contains(names.me)
        if stored == nil, !iAmListed { return .plainMessage }
        guard GroupRoster.applies(revision: revision, from: senderHex, to: stored) else {
            return stored?.creatorHex == senderHex ? .dropped : .plainMessage
        }
        let oldMembers = stored == nil ? [] : try GroupMember.members(of: groupHex, db)
        let diff = GroupRoster.diff(oldMembers: oldMembers, oldName: stored?.name ?? name,
                                    newMembers: members, newName: name)
        let wasOut = stored == nil || stored?.state == GroupState.left
        let newState: String
        if diff.dissolved {
            newState = GroupState.dissolved
        } else if !iAmListed {
            newState = GroupState.left
        } else if wasOut {
            newState = GroupState.invited
        } else {
            newState = stored?.state ?? GroupState.invited
        }
        var lines: [String] = []
        if diff.dissolved {
            lines = [GroupEventText.deleted(by: names.sender)]
        } else if wasOut {
            lines = [GroupEventText.invited(by: names.sender, name: name)]
        } else {
            for hex in diff.added where hex != names.me {
                lines.append(GroupEventText.added(by: names.sender, who: names.name(hex)))
            }
            for hex in diff.removed {
                lines.append(hex == names.me
                    ? GroupEventText.removedYou(by: names.sender)
                    : GroupEventText.removed(by: names.sender, who: names.name(hex)))
            }
            if let newName = diff.renamed {
                lines.append(GroupEventText.renamed(by: names.sender, to: newName))
            }
        }
        let group = ChatGroup(groupHex: groupHex, name: name, creatorHex: stored?.creatorHex ?? senderHex,
                              revision: revision, state: newState, updatedAt: now)
        try ChatGroup.upsert(group, db)
        try GroupMember.replace(groupHex, with: diff.dissolved ? [] : members, db)
        // 1 ms apart so the lines sort in the order the diff names them.
        for (offset, line) in lines.enumerated() {
            try Message.insert {
                Message(id: UUID(), peerHex: senderHex, isOutgoing: false, body: line,
                        timestamp: now.addingTimeInterval(Double(offset) * 0.001),
                        status: MessageStatus.received, validated: validated, messageHash: "",
                        fieldKeys: "", groupHex: groupHex, isGroupEvent: true)
            }.execute(db)
        }
        return .applied(groupHex: groupHex, creatorResends: false)
    }

    /// A leave from `senderHex`: a current member of a known open group is removed with a line.
    /// When I am the creator, the line is mine and carries the bumped roster to the remaining
    /// members through waiting delivery rows (amendment A7).
    public static func applyLeave(groupHex: String, from senderHex: String, names: Names, validated: Bool,
                                  now: Date, _ db: GRDB.Database) throws -> Outcome {
        guard let stored = try ChatGroup.fetch(groupHex, db), stored.isOpen, senderHex != names.me,
              try GroupMember.contains(groupHex, senderHex, db)
        else { return .plainMessage }
        try GroupMember.where { $0.groupHex.eq(groupHex) && $0.memberHex.eq(senderHex) }.delete().execute(db)
        guard stored.creatorHex == names.me else {
            try Message.insert {
                Message(id: UUID(), peerHex: senderHex, isOutgoing: false, body: GroupEventText.left(who: names.sender),
                        timestamp: now, status: MessageStatus.received, validated: validated, messageHash: "",
                        fieldKeys: "", groupHex: groupHex, isGroupEvent: true)
            }.execute(db)
            return .applied(groupHex: groupHex, creatorResends: false)
        }
        var group = stored
        group.revision += 1
        group.updatedAt = now
        try ChatGroup.upsert(group, db)
        let line = AppFeature.groupEventRow(groupHex: groupHex, me: names.me, body: GroupEventText.left(who: names.sender),
                                            control: GroupControl.roster, now: now)
        try Message.insert { line }.execute(db)
        for member in try GroupMember.members(of: groupHex, db) where member != names.me {
            try GroupDelivery.insert { GroupDelivery.waiting(messageId: line.id, memberHex: member) }.execute(db)
        }
        try GroupDelivery.refreshDerivedStatus(messageId: line.id, db)
        return .applied(groupHex: groupHex, creatorResends: true)
    }
}
```

- [ ] **Step 4: Actions**

In `Action`, after `case createGroup(name:members:)`:

```swift
        /// Creator only, on the open group (spec §3): each bumps the revision, writes its line and
        /// fans the new roster to every member.
        case addGroupMembers([String])
        case removeGroupMember(String)
        case renameGroup(String)
        case deleteGroup
        /// Member only: sends the leave to every member and marks the group left.
        case leaveGroup
        case acceptInvite
        /// Marks the invite left and sends the leave to the creator only (amendment A6).
        case declineInvite
        /// A roster was re-issued inside a receive (a member left a group I created): send the
        /// waiting copies to the reachable members. Internal.
        case groupRosterChanged(groupHex: String)
```

- [ ] **Step 5: Receive branches**

In `.messageReceived`, right after the `let groupDecoded = ...` line added in Task 8, add:

```swift
                switch groupDecoded {
                case .roster?, .leave?:
                    return .merge(state.pathRequestIfUnreachable(incomingPeer),
                                  receiveGroupControl(state, message: m, validated: validated, method: method, control: groupDecoded!))
                default:
                    break
                }
```

Add the helper after `sendGroupPost`:

```swift
    /// Spec §3 "Receiving" for `.roster` and `.leave` (amendments A5, A7): the rules run inside
    /// one write; an applied change reloads (and fans a creator's re-issued roster out), a stale
    /// roster is dropped, and anything invalid is stored as the plain one-to-one message its
    /// readable body already is. Names are resolved here, where announces live.
    private func receiveGroupControl(_ state: State, message m: LXMessage, validated: Bool,
                                     method: LXMFRouter.DeliveryMethod, control: GroupWire.Decoded) -> Effect<Action> {
        let incomingPeer = m.sourceHash.hexString
        let seenHashHex = m.hash.hexString
        let now = date.now
        let openPeer = state.openPeerHex
        var byHex: [String: String] = [:]
        if case let .roster(_, _, members, _) = control {
            for member in members {
                let hex = member.hexString
                if let name = state.peerDisplayName(hex) { byHex[hex] = name }
            }
        }
        let names = GroupControlApply.Names(me: state.myAddressHex, sender: state.groupMemberName(incomingPeer), byHex: byHex)
        let plain = Message(
            id: UUID(), peerHex: incomingPeer, isOutgoing: false,
            body: String(decoding: m.content, as: UTF8.self), timestamp: now,
            status: MessageStatus.received, validated: validated, messageHash: seenHashHex,
            senderTimestamp: MessageMetadata.senderTimestamp(m.timestamp),
            arrivalMethod: MessageMetadata.arrivalMethod(method),
            wireSize: m.receivedBytes?.count, titleSize: m.title.count, contentSize: m.content.count,
            fieldKeys: MessageMetadata.fieldKeys(m.fields), stampState: MessageMetadata.stampState(m))
        return .run { [database] send in
            let outcome = try await database.write { db -> GroupControlApply.Outcome in
                let outcome: GroupControlApply.Outcome
                switch control {
                case let .roster(gid, name, members, revision):
                    outcome = try GroupControlApply.applyRoster(
                        groupHex: gid.hexString, name: name, members: members.map(\.hexString), revision: revision,
                        from: incomingPeer, names: names, validated: validated, now: now, db)
                case let .leave(gid):
                    outcome = try GroupControlApply.applyLeave(
                        groupHex: gid.hexString, from: incomingPeer, names: names, validated: validated, now: now, db)
                default:
                    outcome = .plainMessage
                }
                if outcome == .plainMessage { try Message.insert { plain }.execute(db) }
                try recordSeenHash(seenHashHex, at: now, db)
                return outcome
            }
            switch outcome {
            case .dropped:
                return
            case .plainMessage:
                try await reloadConversations(database, send)
                if incomingPeer == openPeer { try await reloadThread(database, incomingPeer, send) }
            case let .applied(groupHex, creatorResends):
                if creatorResends { await send(.groupRosterChanged(groupHex: groupHex)) }
                try await reloadConversations(database, send)
                if groupHex == openPeer { try await reloadThread(database, groupHex, send) }
            }
        }
    }
```

- [ ] **Step 6: Local roster actions**

Add the helper after `receiveGroupControl`:

```swift
    /// One local roster or membership change (spec §3 "Creating and editing"): `mutate` edits the
    /// group row and its members inside the write, `line` becomes an outgoing event row carrying
    /// `control` to `recipients` through waiting delivery rows, copies go to the reachable
    /// recipients at once and the rest get a path request.
    private func groupChange(_ state: State, groupHex: String, line: String, control: String,
                             recipients: Set<String>,
                             mutate: @escaping @Sendable (inout ChatGroup, GRDB.Database) throws -> Void) -> Effect<Action> {
        let me = state.myAddressHex
        let now = date.now
        let row = Self.groupEventRow(groupHex: groupHex, me: me, body: line, control: control, now: now)
        let deliveries = recipients.sorted().map { GroupDelivery.waiting(messageId: row.id, memberHex: $0) }
        let reachable = recipients.intersection(state.reachablePeers)
        let identity = state.identity
        let myName = state.myName
        let alsoViaPropagation = !state.propagationNodeHex.isEmpty
        let pathRequests = recipients.subtracting(reachable).map { state.pathRequestIfUnreachable($0) }
        let write: Effect<Action> = .run { [database] send in
            try await database.write { db in
                guard var group = try ChatGroup.fetch(groupHex, db) else { return }
                try mutate(&group, db)
                group.updatedAt = now
                try ChatGroup.upsert(group, db)
                try Message.insert { row }.execute(db)
                for delivery in deliveries { try GroupDelivery.insert { delivery }.execute(db) }
                try GroupDelivery.refreshDerivedStatus(messageId: row.id, db)
            }
            _ = try await dispatchWaitingGroupCopies(database, members: reachable, identity: identity,
                                                     myName: myName, alsoViaPropagation: alsoViaPropagation,
                                                     now: now, send)
            try await reloadThread(database, groupHex, send)
            try await reloadConversations(database, send)
        }
        return .merge(pathRequests + [write])
    }
```

Add the cases after `.createGroup`:

```swift
            case let .addGroupMembers(hexes):
                guard let group = state.openGroup, state.isOpenGroupCreator, group.state == GroupState.active else { return .none }
                let current = Set(state.openGroupMembers.map(\.memberHex))
                let added = Set(hexes.map { $0.lowercased() }.filter { isValidPeerAddress($0) }).subtracting(current)
                guard !added.isEmpty, current.count + added.count <= GroupWire.maxMembers else { return .none }
                let who = added.sorted().map { state.groupMemberName($0) }.joined(separator: ", ")
                let groupHex = group.groupHex
                return groupChange(state, groupHex: groupHex, line: GroupEventText.added(by: GroupEventText.you, who: who),
                                   control: GroupControl.roster,
                                   recipients: current.union(added).subtracting([state.myAddressHex])) { group, db in
                    group.revision += 1
                    let members = try GroupMember.members(of: groupHex, db)
                    try GroupMember.replace(groupHex, with: members + Array(added), db)
                }

            case let .removeGroupMember(hex):
                guard let group = state.openGroup, state.isOpenGroupCreator, group.state == GroupState.active,
                      hex != state.myAddressHex, state.openGroupMembers.contains(where: { $0.memberHex == hex })
                else { return .none }
                let groupHex = group.groupHex
                return groupChange(state, groupHex: groupHex,
                                   line: GroupEventText.removed(by: GroupEventText.you, who: state.groupMemberName(hex)),
                                   control: GroupControl.roster, recipients: Set(state.openGroupOthers)) { group, db in
                    group.revision += 1
                    try GroupMember.where { $0.groupHex.eq(groupHex) && $0.memberHex.eq(hex) }.delete().execute(db)
                }

            case let .renameGroup(name):
                let trimmed = GroupWire.trimName(name)
                guard let group = state.openGroup, state.isOpenGroupCreator, group.state == GroupState.active,
                      !trimmed.isEmpty, trimmed != group.name
                else { return .none }
                return groupChange(state, groupHex: group.groupHex,
                                   line: GroupEventText.renamed(by: GroupEventText.you, to: trimmed),
                                   control: GroupControl.roster, recipients: Set(state.openGroupOthers)) { group, _ in
                    group.revision += 1
                    group.name = trimmed
                }

            case .deleteGroup:
                guard let group = state.openGroup, state.isOpenGroupCreator, group.state == GroupState.active else { return .none }
                let groupHex = group.groupHex
                return groupChange(state, groupHex: groupHex, line: GroupEventText.deleted(by: GroupEventText.you),
                                   control: GroupControl.roster, recipients: Set(state.openGroupOthers)) { group, db in
                    group.revision += 1
                    group.state = GroupState.dissolved
                    try GroupMember.replace(groupHex, with: [], db)
                }

            case .leaveGroup:
                guard let group = state.openGroup, !state.isOpenGroupCreator, group.isOpen else { return .none }
                let groupHex = group.groupHex
                let me = state.myAddressHex
                return groupChange(state, groupHex: groupHex, line: GroupEventText.left(who: GroupEventText.you),
                                   control: GroupControl.leave, recipients: Set(state.openGroupOthers)) { group, db in
                    group.state = GroupState.left
                    try GroupMember.where { $0.groupHex.eq(groupHex) && $0.memberHex.eq(me) }.delete().execute(db)
                }

            case .acceptInvite:
                guard let group = state.openGroup, group.state == GroupState.invited else { return .none }
                let groupHex = group.groupHex
                let now = date.now
                return .run { [database] send in
                    try await database.write { db in
                        guard var stored = try ChatGroup.fetch(groupHex, db) else { return }
                        stored.state = GroupState.active
                        stored.updatedAt = now
                        try ChatGroup.upsert(stored, db)
                    }
                    try await reloadThread(database, groupHex, send)
                    try await reloadConversations(database, send)
                }

            case .declineInvite:
                guard let group = state.openGroup, group.state == GroupState.invited else { return .none }
                let groupHex = group.groupHex
                let me = state.myAddressHex
                return groupChange(state, groupHex: groupHex, line: GroupEventText.declined(),
                                   control: GroupControl.leave, recipients: [group.creatorHex]) { group, db in
                    group.state = GroupState.left
                    try GroupMember.where { $0.groupHex.eq(groupHex) && $0.memberHex.eq(me) }.delete().execute(db)
                }

            case .groupRosterChanged:
                // The waiting rows were written inside the receive; the unreachable members get
                // their copy when their path is learned (Task 5's hook).
                return groupDispatchEffect(state, members: state.reachablePeers)
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupControl > /tmp/ReTiCaMsgr/grp-t9-green.log 2>&1`
Expected: 16 tests passed. Then the full suite: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/grp-t9-full.log 2>&1`, baseline + 73 passed.

- [ ] **Step 8: Mutation verification**

| Mutation (production code) | Test that must go RED |
|---|---|
| `applyRoster`: create the group with `state: GroupState.active` when `stored == nil` (replace the `wasOut` → `invited` branch) | `groupControlRosterForUnknownGroupCreatesInvitedGroupAndLine` |
| `applyRoster`: drop the `renamed` line | `groupControlHigherRevisionReplacesMembersAndInsertsLines` |
| `applyRoster`: return `.plainMessage` instead of `.dropped` for a stale creator roster | `groupControlStaleRosterFromCreatorIsDropped` |
| `receiveGroupControl`: on `.plainMessage` skip the `Message.insert { plain }` | `groupControlRosterFromNonCreatorIsPlainMessage` |
| `applyRoster`: delete the `guard members.contains(senderHex)` line | `groupControlRosterOmittingSenderIsPlainMessage` |
| `applyRoster`: compute `newState` as `GroupState.left` instead of `dissolved` for an empty roster | `groupControlRosterRemovingMeOrEmptyClosesTheGroup` |
| `applyRoster`: compute `wasOut` as `stored == nil` only | `groupControlReinviteAfterLeftBecomesInvited` |
| `applyLeave`: drop `try GroupMember.contains(groupHex, senderHex, db)` from the guard | `groupControlLeaveFromMemberRemovesAndNonMemberIsPlain` |
| `applyLeave`: return `.applied(groupHex:, creatorResends: false)` from the creator branch | `groupControlLeaveWhenIAmCreatorResendsRoster` |
| `.addGroupMembers`: pass `recipients: current.subtracting([state.myAddressHex])` (new members excluded) | `groupControlAddMembersBumpsRevisionAndFansOut` |
| `.removeGroupMember`: pass `recipients: Set(state.openGroupOthers).subtracting([hex])` | `groupControlRemoveMemberSendsRosterToRemovedToo` |
| `.deleteGroup`: drop `try GroupMember.replace(groupHex, with: [], db)` | `groupControlRenameThenDelete` |
| `.leaveGroup`: use `control: GroupControl.roster` | `groupControlLeaveSendsLeaveAndMarksLeft` |
| `.declineInvite`: pass `recipients: Set(state.openGroupOthers)` | `groupControlAcceptAndDecline` |
| `.leaveGroup`: drop `!state.isOpenGroupCreator` from the guard | `groupControlRoleGuards` |

Sub-batch A: the first eight rows (`GroupControlApply` and the receive helper). Sub-batch B: the last seven rows (local actions). Revert by hand, run again, all GREEN.

- [ ] **Step 9: Commit**

Write `/tmp/ReTiCaMsgr/msg-grp-task-9.txt`:

```
feat: group rosters and leaves, received and local

GroupControlApply holds the receive rules: a creator's newer roster
replaces the members with lines for the diff, a first roster creates an
invited group, stale creator rosters are dropped, anything else is a
plain message; a member's leave removes them, and a creator re-issues
the roster. Local actions add, remove, rename, delete, leave, accept and
decline through one groupChange helper that fans the change out.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C APP add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/GroupControlApply.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-9.txt`

---

### Task 10: Info sheet Members section and reply labels by sender

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/MessageInfo.swift` (`sections(for:...)` gains `deliveries:` and `memberNames:`; new `members` section)
- Modify: `CORE/Sources/ReTiCaMsgrCore/ReplyPreview.swift` (`resolve` gains `names:`)
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/GroupInfoTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3.
- Produces: `MessageInfo.sections(for message: Message, attachment: Attachment? = nil, deliveries: [GroupDelivery] = [], memberNames: [String: String] = [:], timeZone: TimeZone = .current) -> [Section]` (a "Members" section appended when `deliveries` is non-empty: one row per member, sorted by address, label = name or short hex, display = status word plus the first proof time when proved, copy = the copy's LXMF hash or "" while waiting); `ReplyPreview.resolve(for:in:peerName:attachments:names: [String: String] = [:])` (the original's sender label is `names[original.peerHex]` when present, else `peerName`, else "Them"). Existing call sites compile unchanged.

- [ ] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/GroupInfoTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCaMsgrCore
import struct ReTiCaMsgrCore.Attachment

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1700000000)          // 2023-11-14 22:13:20 UTC
private let me = String(repeating: "e", count: 32)
private let memberC = String(repeating: "c", count: 32)
private let memberD = String(repeating: "d", count: 32)
private let groupHex = String(repeating: "1a", count: 16)
private let postId = String(repeating: "5e", count: 16)
private let hashC = String(repeating: "a1", count: 32)

private func post(outgoing: Bool, peer: String) -> Message {
    Message(id: UUID(uuidString: "00000000-0000-0000-0000-000000000060")!, peerHex: peer, isOutgoing: outgoing,
            body: "sandbags at 6", timestamp: t0, status: MessageStatus.sending, validated: !outgoing,
            messageHash: postId, senderTimestamp: t0, sentViaPropagation: false, wireSize: nil,
            titleSize: 10, contentSize: 13, fieldKeys: "0xfd", groupHex: groupHex, groupPostId: postId)
}

/// Spec §4: a Members section after the others, one row per member sorted by address, naming
/// announced members, with the status and first proof time, and the copy's hash to copy.
@Test func groupInfoMembersSectionListsEachDelivery() {
    let m = post(outgoing: true, peer: me)
    let deliveries = [
        GroupDelivery(messageId: m.id, memberHex: memberD, messageHash: nil, status: GroupDeliveryStatus.waiting,
                      storedAt: nil, deliveredAt: nil, failedAt: nil),
        GroupDelivery(messageId: m.id, memberHex: memberC, messageHash: hashC, status: MessageStatus.delivered,
                      storedAt: nil, deliveredAt: t0.addingTimeInterval(81), failedAt: nil),
    ]
    let sections = MessageInfo.sections(for: m, deliveries: deliveries, memberNames: [memberC: "Cy"], timeZone: utc)
    #expect(sections.map(\.title) == ["Timeline", "Delivery", "Identity", "Payload", "Members"])
    #expect(sections[4].rows == [
        MessageInfo.Row(label: "Cy", display: "delivered 22:14:41", copy: hashC),
        MessageInfo.Row(label: "dddd…dddd", display: "waiting", copy: ""),
    ])
}

@Test func groupInfoNoDeliveriesNoMembersSection() {
    let sections = MessageInfo.sections(for: post(outgoing: false, peer: memberC), timeZone: utc)
    #expect(sections.map(\.title) == ["Timeline", "Delivery", "Identity", "Payload"])
    #expect(MessageInfo.sections(for: post(outgoing: true, peer: me), deliveries: [], timeZone: utc).count == 4)
}

/// In a group the quoted original is found by its post id (amendment A2) and labelled with its
/// own sender's name; a sender with no name falls back to the thread name, then "Them".
@Test func groupInfoReplyPreviewUsesSenderNames() {
    let original = Message(id: UUID(), peerHex: memberC, isOutgoing: false, body: "sandbags at 6", timestamp: t0,
                           status: MessageStatus.received, validated: true, messageHash: postId,
                           groupHex: groupHex, groupPostId: postId)
    let reply = Message(id: UUID(), peerHex: me, isOutgoing: true, body: "yes", timestamp: t0.addingTimeInterval(1),
                        status: MessageStatus.sending, validated: false, messageHash: String(repeating: "6f", count: 16),
                        replyToHash: postId, replyQuote: "sandbags at 6", groupHex: groupHex,
                        groupPostId: String(repeating: "6f", count: 16))
    let named = ReplyPreview.resolve(for: reply, in: [original, reply], peerName: nil, names: [memberC: "Cy"])
    #expect(named == ReplyPreview.Resolved(senderLabel: "Cy", text: "sandbags at 6", originalID: original.id))
    let unnamed = ReplyPreview.resolve(for: reply, in: [original, reply], peerName: nil, names: [memberD: "Dee"])
    #expect(unnamed?.senderLabel == "Them")
    let mine = Message(id: UUID(), peerHex: me, isOutgoing: true, body: "mine", timestamp: t0,
                       status: MessageStatus.sent, validated: false, messageHash: String(repeating: "7a", count: 16),
                       groupHex: groupHex, groupPostId: String(repeating: "7a", count: 16))
    var replyToMine = reply
    replyToMine.replyToHash = String(repeating: "7a", count: 16)
    #expect(ReplyPreview.resolve(for: replyToMine, in: [mine, replyToMine], peerName: nil, names: [me: "Ada"])?.senderLabel == "You")
    // One-to-one threads are unchanged: the peer's name labels the original.
    let direct = Message(id: UUID(), peerHex: memberC, isOutgoing: false, body: "hi", timestamp: t0,
                         status: MessageStatus.received, validated: true, messageHash: String(repeating: "9", count: 64))
    var directReply = reply
    directReply.replyToHash = String(repeating: "9", count: 64)
    #expect(ReplyPreview.resolve(for: directReply, in: [direct, directReply], peerName: "Cy")?.senderLabel == "Cy")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupInfo > /tmp/ReTiCaMsgr/grp-t10-red.log 2>&1`
Expected: compile errors (`deliveries:` and `names:` labels unknown).

- [ ] **Step 3: `MessageInfo` members section**

Replace `sections(for:attachment:timeZone:)` with:

```swift
    public static func sections(for message: Message, attachment: Attachment? = nil,
                                deliveries: [GroupDelivery] = [], memberNames: [String: String] = [:],
                                timeZone: TimeZone = .current) -> [Section] {
        var sections = [timeline(message, timeZone), delivery(message), identity(message), payload(message)]
        if let attachment {
            sections.append(attachmentSection(attachment))
        }
        if !deliveries.isEmpty {
            sections.append(members(deliveries, names: memberNames, sameDayAs: message.timestamp, timeZone))
        }
        return sections
    }
```

Add after `attachmentSection`:

```swift
    /// Spec 2026-10-09 §4: one row per member copy of an outgoing group row, sorted by address.
    /// The label is the member's announce name or a short hex, the display the copy's status and
    /// its first proof time once proved, and the copy value the copy's LXMF hash.
    static func members(_ deliveries: [GroupDelivery], names: [String: String], sameDayAs reference: Date,
                        _ tz: TimeZone) -> Section {
        let rows = deliveries.sorted { $0.memberHex < $1.memberHex }.map { d -> Row in
            var display = d.status
            if let at = d.deliveredAt {
                display += " " + time(at, sameDayAs: reference, timeZone: tz)
            }
            return Row(label: names[d.memberHex] ?? shortHash(d.memberHex), display: display, copy: d.messageHash ?? "")
        }
        return Section(title: "Members", rows: rows)
    }
```

- [ ] **Step 4: `ReplyPreview` names**

Replace `resolve(for:in:peerName:attachments:)` with:

```swift
    /// nil when `message` is not a reply. Otherwise the original from `thread` when present (its
    /// body, trimmed like a quote — or, when the body is empty and the original carries a photo or
    /// a file, its placeholder from `attachments`, keyed by message id), else the carried quote,
    /// else "Original message not available". In a group thread `names` (sender address → display
    /// name) labels the original by its own sender; `peerName` is the fallback.
    public static func resolve(for message: Message, in thread: [Message], peerName: String?,
                               attachments: [UUID: Attachment] = [:], names: [String: String] = [:]) -> Resolved? {
        guard let hash = message.replyToHash else { return nil }
        if let original = thread.first(where: { $0.messageHash == hash }) {
            // Spec 2026-09-28 §4: a caption-less photo or file quotes its placeholder.
            let body = AttachmentPlaceholder.preview(body: original.body, attachment: attachments[original.id])
            let trimmedBody = ReplyWire.trimQuote(body)
            return Resolved(
                senderLabel: senderLabel(originalIsOutgoing: original.isOutgoing,
                                         peerName: names[original.peerHex] ?? peerName),
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

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore --filter groupInfo > /tmp/ReTiCaMsgr/grp-t10-green.log 2>&1`
Expected: 3 tests passed. The existing `MessageInfoTests` and `ReplyPreviewTests` still pass (run them with `--filter infoSections` and `--filter replyPreview`).

- [ ] **Step 6: Mutation verification**

| Mutation (production code) | Test that must go RED |
|---|---|
| `members`: drop the `.sorted { ... }` and build `copy` as `d.messageHash ?? d.memberHex` | `groupInfoMembersSectionListsEachDelivery` |
| `sections`: append the members section when `deliveries.isEmpty` too (invert the condition) | `groupInfoNoDeliveriesNoMembersSection` |
| `resolve`: pass `peerName` alone (drop `names[original.peerHex] ??`) | `groupInfoReplyPreviewUsesSenderNames` |

Apply all three, run the filter once, confirm all three RED. Revert by hand, run again, all GREEN.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCaMsgr/msg-grp-task-10.txt`:

```
feat: Info sheet Members section and reply labels by sender

The Info sheet lists each member copy of an outgoing group row with its
status, first proof time and hash, and a reply's quote in a group names
the original's own sender.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C APP add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/MessageInfo.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/ReplyPreview.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/GroupInfoTests.swift`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-10.txt`

---

### Task 11: UI — new group, group thread, info screen, list rows

**Files:**
- Create: `APP/ReTiCaMsgr/GroupViews.swift`
- Modify: `APP/ReTiCaMsgr/ConversationListView.swift` (rows, the `+` menu)
- Modify: `APP/ReTiCaMsgr/ChatView.swift` (gating, rows, composer, toolbar, bubble status and sender name)
- Modify: `APP/ReTiCaMsgr/MessageInfoSheet.swift` (pass deliveries and names)

**Interfaces:**
- Consumes: `Conversation.kind/title/groupState`, `store.openConversationKind`, `store.openGroup`, `store.openGroupMembers`, `store.deliveriesByMessageId`, `store.anyGroupMemberReachable`, `store.isOpenGroupCreator`, `store.threadSenderNames`, `store.state.groupMemberName(_:)`, the actions of Tasks 4–9, `GroupRoster.statusLabel`, `GroupEventText.caveat`, `GroupWire.maxMembers`, `Message.isGroupEvent`.

No unit tests in the app target (none exist today); the deliverable is a successful build and a manual check in the Simulator.

- [ ] **Step 1: Create `GroupViews.swift`**

```swift
//
//  GroupViews.swift
//  ReTiCaMsgr
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

/// Local hex helper — ReTiCaMsgrCore's `Data.hexString` is internal to the package.
private func groupHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// One announced peer the pickers can offer.
private struct AnnouncedPeer: Identifiable {
    let hex: String
    let name: String?
    var id: String { hex }
}

private func announcedPeers(_ store: StoreOf<AppFeature>, excluding: Set<String>) -> [AnnouncedPeer] {
    store.state.node.client.learnedPeers
        .map { hash, peer in AnnouncedPeer(hex: groupHex(hash), name: peer.displayName) }
        .filter { !excluding.contains($0.hex) }
        .sorted { ($0.name ?? "~") < ($1.name ?? "~") }
}

/// Picks members from the announce list, a typed address or a scanned QR (spec 2026-10-09 §4).
/// `exclude` holds me and anyone already in the group.
struct GroupMemberPicker: View {
    let store: StoreOf<AppFeature>
    let exclude: Set<String>
    @Binding var selected: Set<String>
    @State private var address = ""
    @State private var showingScanner = false

    private var announced: [AnnouncedPeer] { announcedPeers(store, excluding: exclude) }
    private var typedOnly: [String] { selected.subtracting(announced.map(\.hex)).sorted() }
    private var canAddTyped: Bool {
        isValidPeerAddress(address) && !exclude.contains(address.lowercased()) && !selected.contains(address.lowercased())
    }

    var body: some View {
        Section("From announces") {
            if announced.isEmpty {
                Text("No announces heard yet").foregroundStyle(.secondary)
            }
            ForEach(announced) { peer in
                Button {
                    if selected.contains(peer.hex) { selected.remove(peer.hex) } else { selected.insert(peer.hex) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name ?? "Unnamed")
                            Text(shortHex(peer.hex))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected.contains(peer.hex) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    // The whole row is the tap target (UI rule), not just the glyphs.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        Section("By address") {
            TextField("32 hex characters", text: $address)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))
            Button("Add address") {
                selected.insert(address.lowercased())
                address = ""
            }
            .disabled(!canAddTyped)
            Button { showingScanner = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
            ForEach(typedOnly, id: \.self) { hex in
                HStack {
                    Text(shortHex(hex)).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button { selected.remove(hex) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove")
                }
            }
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView(ownAddress: store.myAddressHex) { hex in
                if !exclude.contains(hex.lowercased()) { selected.insert(hex.lowercased()) }
                showingScanner = false
            }
        }
    }
}

/// "New group" (spec §4): a name and members, Create disabled above the ceiling.
struct NewGroupView: View {
    let store: StoreOf<AppFeature>
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var selected: Set<String> = []

    private var memberCount: Int { selected.count + 1 }
    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selected.isEmpty
            && memberCount <= GroupWire.maxMembers
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group name") {
                    TextField("Name", text: $name)
                }
                Section {
                    Text("\(memberCount) of \(GroupWire.maxMembers) members, you included")
                        .foregroundStyle(memberCount > GroupWire.maxMembers ? .red : .secondary)
                }
                GroupMemberPicker(store: store, exclude: [store.myAddressHex], selected: $selected)
                Button("Create group") {
                    store.send(.createGroup(name: name, members: Array(selected)))
                    isPresented = false
                }
                .disabled(!canCreate)
            }
            .navigationTitle("New group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}

/// Add members to the open group (creator only).
struct AddGroupMembersView: View {
    let store: StoreOf<AppFeature>
    @Binding var isPresented: Bool
    @State private var selected: Set<String> = []

    private var current: Set<String> { Set(store.openGroupMembers.map(\.memberHex)) }
    private var canAdd: Bool { !selected.isEmpty && current.count + selected.count <= GroupWire.maxMembers }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(current.count + selected.count) of \(GroupWire.maxMembers) members")
                        .foregroundStyle(current.count + selected.count > GroupWire.maxMembers ? .red : .secondary)
                }
                GroupMemberPicker(store: store, exclude: current, selected: $selected)
                Button("Add members") {
                    store.send(.addGroupMembers(Array(selected)))
                    isPresented = false
                }
                .disabled(!canAdd)
            }
            .navigationTitle("Add members")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}

/// The group info screen (spec §4): name, members with reachability, the role's actions, caveat.
struct GroupInfoView: View {
    let store: StoreOf<AppFeature>
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var confirmingLeave = false

    private var group: ChatGroup? { store.openGroup }
    private var isCreator: Bool { store.isOpenGroupCreator }
    private var isActive: Bool { group?.state == GroupState.active }

    var body: some View {
        NavigationStack {
            List {
                Section("Group") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(group?.name ?? "").foregroundStyle(.secondary)
                    }
                    if let state = group?.state, state != GroupState.active {
                        HStack {
                            Text("State")
                            Spacer()
                            Text(state).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(store.openGroupMembers, id: \.memberHex) { member in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(store.reachablePeers.contains(member.memberHex) || member.memberHex == store.myAddressHex
                                      ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.state.groupMemberName(member.memberHex))
                                Text(shortHex(member.memberHex))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if member.memberHex == group?.creatorHex {
                                Text("Creator").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if isCreator, isActive, member.memberHex != store.myAddressHex {
                                Button("Remove", role: .destructive) { store.send(.removeGroupMember(member.memberHex)) }
                            }
                        }
                    }
                } header: {
                    Text("Members (\(store.openGroupMembers.count) of \(GroupWire.maxMembers))")
                } footer: {
                    Text(GroupEventText.caveat)
                }
                if isCreator, isActive {
                    Section {
                        Button("Add members") { showingAdd = true }
                            .disabled(store.openGroupMembers.count >= GroupWire.maxMembers)
                        Button("Rename group") {
                            newName = group?.name ?? ""
                            renaming = true
                        }
                        Button("Delete group", role: .destructive) { confirmingDelete = true }
                    }
                } else if !isCreator, group?.isOpen == true {
                    Section {
                        Button("Leave group", role: .destructive) { confirmingLeave = true }
                    }
                }
            }
            .navigationTitle("Group info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showingAdd) { AddGroupMembersView(store: store, isPresented: $showingAdd) }
            .alert("Rename group", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Rename") { store.send(.renameGroup(newName)) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this group for everyone?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete group", role: .destructive) {
                    store.send(.deleteGroup)
                    dismiss()
                }
            }
            .confirmationDialog("Leave this group?", isPresented: $confirmingLeave, titleVisibility: .visible) {
                Button("Leave group", role: .destructive) {
                    store.send(.leaveGroup)
                    dismiss()
                }
            }
        }
    }
}

/// Accept and Decline in place of the composer while the group is `invited` (spec §4).
struct InviteBar: View {
    let groupName: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("You were invited to \(groupName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Decline", role: .destructive, action: onDecline)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Accept", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
    }
}

/// The line that replaces the composer once the group is left or dissolved.
struct ClosedGroupLine: View {
    let state: String

    var body: some View {
        Text(state == GroupState.dissolved ? "This group was deleted" : "You are no longer in this group")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding()
    }
}
```

- [ ] **Step 2: Conversation list rows and the `+` menu**

In `ConversationListView`, replace `@State private var showingCompose = false` with:

```swift
    @State private var showingCompose = false
    @State private var showingNewGroup = false
```

Replace the row `Button { store.send(.openConversation(convo.peerHex)) } label: { ... }` so the action and the title read:

```swift
                Button {
                    store.send(convo.kind == .group ? .openGroupConversation(convo.peerHex) : .openConversation(convo.peerHex))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if let title = convo.title {
                                Label(title, systemImage: "person.3")
                                    .font(.headline)
                                    .lineLimit(1)
                            } else {
                                Text(shortHex(convo.peerHex))
                                    .font(.system(.headline, design: .monospaced))
                            }
                            if convo.groupState == GroupState.invited {
                                Text("Invited")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            }
                            Spacer()
                            Text(convo.lastTimestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(convo.lastBody)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
```

Replace the `+` toolbar item with a menu:

```swift
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showingCompose = true } label: { Label("New conversation", systemImage: "bubble.left") }
                        Button { showingNewGroup = true } label: { Label("New group", systemImage: "person.3") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
```

and add a second sheet after the compose sheet:

```swift
            .sheet(isPresented: $showingNewGroup) {
                NewGroupView(store: store, isPresented: $showingNewGroup)
            }
```

- [ ] **Step 3: `ChatView` gating, rows, composer, toolbar**

Add after `@FocusState private var draftFocused: Bool`:

```swift
    @State private var showingGroupInfo = false

    private var isGroup: Bool { store.openConversationKind == .group }
```

Replace `peerReachable` with:

```swift
    /// The Send gate: the peer routes now, or for a group at least one member does (spec §3).
    private var peerReachable: Bool {
        if isGroup { return store.anyGroupMemberReachable }
        guard let peer = store.openPeerHex else { return false }
        return store.reachablePeers.contains(peer)
    }
```

In the `List` closure, change `if message.isTimerChange {` to:

```swift
                    if message.isTimerChange || message.isGroupEvent {
                        TimerChangeLine(text: message.body,
                                        status: message.isOutgoing ? statusText(for: message) : nil)
```

and in the `MessageBubble(...)` call add two arguments after `message: message,`:

```swift
                            senderName: isGroup && !message.isOutgoing
                                ? store.state.groupMemberName(message.peerHex) : nil,
                            statusText: statusText(for: message),
```

Replace `let replyPreview = ReplyPreview.resolve(for: message, in: store.threadMessages, peerName: peerName, attachments: store.attachmentsByMessageId)` with:

```swift
                        let replyPreview = ReplyPreview.resolve(for: message, in: store.threadMessages, peerName: peerName,
                                                                attachments: store.attachmentsByMessageId,
                                                                names: store.threadSenderNames)
```

In the context menu, wrap the Cancel Send button's condition: `if !isGroup, message.isOutgoing, message.status == MessageStatus.sending, !message.messageHash.isEmpty {` (amendment A10).

Add the helper to `ChatView` (after `showOriginal`):

```swift
    /// A group row's status comes from its delivery rows (spec §4); a peer row's from its column.
    private func statusText(for message: Message) -> String {
        guard isGroup, message.isOutgoing, let rows = store.deliveriesByMessageId[message.id] else { return message.status }
        return GroupRoster.statusLabel(rows)
    }
```

Replace the composer `HStack(spacing: 4) { ... }` block (from `HStack(spacing: 4) {` through its `.padding(.leading, 8)`) with:

```swift
            if isGroup, store.openGroup?.state == GroupState.invited {
                InviteBar(groupName: store.openGroup?.name ?? "the group",
                          onAccept: { store.send(.acceptInvite) },
                          onDecline: { store.send(.declineInvite) })
            } else if isGroup, let state = store.openGroup?.state, state != GroupState.active {
                ClosedGroupLine(state: state)
            } else {
                HStack(spacing: 4) {
                    if !isGroup {
                        AttachmentPickerButton(
                            peerHex: store.openPeerHex ?? "",
                            onLoadStarted: { store.send(.attachmentLoadStarted(peerHex: $0)) },
                            onPicked: { store.send(.attachmentPicked($0)) },
                            onFailed: { store.send(.attachmentFailed($0)) }
                        )
                    }
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
```

Replace the `.toolbar { ... }` block with:

```swift
        .toolbar {
            ToolbarItem(placement: .principal) {
                if isGroup {
                    Button { showingGroupInfo = true } label: {
                        ChatTitle(title: store.openGroup?.name ?? "Group", expiry: nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the group's members and settings")
                } else {
                    ChatTitle(title: store.openPeerHex.map(shortHex) ?? "Chat", expiry: store.openConversationExpiry)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isGroup {
                    Button { showingGroupInfo = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Group info")
                } else {
                    // Not gated on reachability (amendment A17): the pick applies here at once, the
                    // change line shows if its message failed, and every later message carries the
                    // timer, so the peer converges even when the change itself never arrived.
                    ExpiryMenu(current: store.openConversationExpiry) { store.send(.expirySelected(seconds: $0)) }
                }
            }
        }
        .sheet(isPresented: $showingGroupInfo) {
            GroupInfoView(store: store)
        }
```

- [ ] **Step 4: `MessageBubble` sender name and status text**

In `MessageBubble`, add two properties after `let message: Message`:

```swift
    /// In a group thread, the incoming sender's name above the bubble (spec §4).
    var senderName: String? = nil
    /// What the status area shows; a group post passes its "Delivered to d of n" label.
    var statusText: String? = nil
```

In its `body`, inside the `VStack(alignment: ..., spacing: 2) {`, before `BubbleText(...)`, add:

```swift
                if let senderName {
                    Text(senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
```

and replace `Text(message.status)` with `Text(statusText ?? message.status)`.

- [ ] **Step 5: Info sheet**

In `MessageInfoSheet`, replace the `MessageInfo.sections(for: message, attachment: store.attachmentsByMessageId[message.id])` call with:

```swift
                        ForEach(Array(MessageInfo.sections(for: message,
                                                           attachment: store.attachmentsByMessageId[message.id],
                                                           deliveries: store.deliveriesByMessageId[message.id] ?? [],
                                                           memberNames: store.threadSenderNames).enumerated()),
                                id: \.offset) { _, section in
```

- [ ] **Step 6: Build the app**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCaMsgr/grp-t11-xcodebuild.log 2>&1`
Expected: `** BUILD SUCCEEDED **`. Fix any compile error in the four app files only. `ChatGroup`, `GroupState`, `GroupRoster`, `GroupEventText`, `GroupWire` and `isValidPeerAddress` are public in Core; if one is not, make it public in Core and note it in the commit body.

- [ ] **Step 7: Full core suite once more**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-groups/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/grp-t11-core.log 2>&1`
Expected: baseline + 76 passed, no failures.

- [ ] **Step 8: Manual check (Simulator)**

Use the `xcodebuildmcp-cli` skill to boot a simulator, install and launch the app, and confirm: the `+` menu offers "New conversation" and "New group"; "New group" shows the name field, the "1 of 12 members" line, the announce picker (empty in the Simulator) and the address field, and Create enables once a name and one valid typed address are given; creating opens the group thread with the "You created the group …" line, the group name as the title, a Send button disabled (no member reachable) and no attachment button; the title opens the group info sheet with the creator badge, the caveat footer and the Add, Rename and Delete actions; Rename inserts its line. The list shows the group with the person.3 glyph. Record what was seen in the task's commit body. If no Simulator is available, say so in the commit body instead of claiming the check.

- [ ] **Step 9: Restore Xcode's scheme files, commit**

Run: `git -C APP status --short`. If only the two `xcschememanagement.plist` files are modified beside the intended changes, restore them with `git -C APP checkout -- <path>`.

Write `/tmp/ReTiCaMsgr/msg-grp-task-11.txt` (subject `feat: group chat screens`, body listing the four screens and the manual-check result, trailers).

Run: `git -C APP add ReTiCaMsgr/GroupViews.swift ReTiCaMsgr/ConversationListView.swift ReTiCaMsgr/ChatView.swift ReTiCaMsgr/MessageInfoSheet.swift`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-11.txt`

---

### Task 12: Docs and hand-off

**Files:**
- Modify: `APP/docs/superpowers/backlog-retica-followups.md` (append a "Group chats" section)
- Modify: this plan (tick boxes as tasks complete)

- [ ] **Step 1: Backlog entry**

Append to `docs/superpowers/backlog-retica-followups.md`:

```markdown

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
```

- [ ] **Step 2: Commit**

Write `/tmp/ReTiCaMsgr/msg-grp-task-12.txt` (subject `docs: group-chat follow-ups`, body, trailers).

Run: `git -C APP add docs/superpowers/backlog-retica-followups.md docs/superpowers/plans/2026-10-09-group-chats.md`
Run: `git -C APP commit -F /tmp/ReTiCaMsgr/msg-grp-task-12.txt`

- [ ] **Step 3: Hand off**

Use `superpowers:finishing-a-development-branch` from the main checkout's session to merge `feat/group-chats` into `main` and remove the worktree.
