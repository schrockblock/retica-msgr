# Delete Conversations, Unread Badge, Names in Messages: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- Delete a conversation from this device: swipe on iOS, right-click on Mac.
- Badge the app icon with unread incoming messages.
- Carry my display name on outgoing messages until each peer confirms it, the way profile photos ride.

**Architecture:** three independent feature tracks (Tasks 1–3) built in parallel in sibling worktrees, then one integration task (Task 4) that merges them, wires delete into the badge, and verifies everything. Core logic lives in `ReTiCAMsgrCore` (TCA + SQLiteData), with views in `ReTiCAMsgr/` and the push counter in the `ReTiCAMsgrPushService` target.

**Tech Stack:** Swift 6.3, SwiftUI, TCA, SQLiteData/GRDB migrations, UserNotifications, Swift Testing.

**Specs (read the one for your task):**
- `docs/superpowers/specs/2026-10-25-delete-conversations-and-unread-badge-design.md`, including amendments A1 and A2;
- `docs/superpowers/specs/2026-10-25-name-in-messages-design.md`.

## Global Constraints

- **Base:** branch `feat/delete-badge-names`, worktree `/Users/ell/development/ios/apps/ReTiCAMsgr-convos`. Parallel tasks use sibling worktrees `ReTiCAMsgr-convos-<task>` (branches `feat/convos-<task>`), so the `../../../pods` paths resolve.
- **Conversation key:** `groupHex ?? peerHex`, lowercased, everywhere (delete, read marker, open-thread check).
- **iOS behaviour outside these features is unchanged.** Mac-only UI goes through `#if os(macOS)` or the `ReTiCAMsgr/Platform/` helpers.
- **Migrations:** append new `registerMigration` blocks at the END of `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Database.swift`, with these exact names:
  - Task 2: `createConversationReads`;
  - Task 3: `addPeerNames`, then `createProfileNameDeliveries`.

  The parallel merge will conflict there. Task 4 orders them Task 2 first, then Task 3.
- **Tests:** Swift Testing and TCA `TestStore`, following `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/` patterns. Read `/Users/ell/.claude/projects/-Users-ell-development-ios-apps-ReTiCAMsgr/memory/tca-teststore-lessons.md` before writing TestStore tests.
- **Mutation rule:** every new or changed test follows the user's three-step rule:
  - (a) the tests pass;
  - (b) one batch of meaningful production mutations makes every changed test fail;
  - (c) after the revert, the tests pass again.

  Record the evidence for each step.
- **Commands:**
  - core tests: `swift test --package-path ReTiCAMsgrCore --scratch-path /tmp/ReTiCAMsgr/core-<task>`
  - app builds: the iOS and macOS `xcodebuild` commands from the macOS port, with derived data `/tmp/ReTiCAMsgr/dd-<task>-{ios,mac}`; macOS uses `CODE_SIGNING_ALLOWED=NO`.
- **Shell rules:** one command per Bash call, with no pipes, chaining, `;`, `$(...)` or inline scripts. Temp files go in `/tmp/ReTiCAMsgr/`. Commit trailers as in the user's attribution rule.

## Review Focus

1. **Deleting a conversation with a message still sending.** It must be cancelled, and the thread must not reappear on its status update. Test: Task 1, `deleteCancelsInFlightSends`.
2. **First launch after the update.** Existing history must not badge. Test: Task 2, `migrationSeedsReadMarkersForExistingConversations`.
3. **A message arriving in the chat you're watching** must not count as unread, while one arriving while the app is inactive (Mac) or the chat is closed must. Tests: Task 2, `arrivalInWatchedThreadIsRead` and `arrivalWhileInactiveIsUnread`.
4. **A late, older message carrying an old name** must not overwrite a newer one. Test: Task 3, `olderNameDoesNotOverwriteNewer`.
5. **Deleting a group conversation** must keep the group and its members, so the next group post brings the row back. Test: Task 1, `deleteGroupKeepsGroupAndMembers`.

---

### Task 1: Delete a conversation (parallel, worktree `-delete`)

**Files:**
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ConversationDeletion.swift`
- Modify:
  - `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/MessagePurge.swift`: extract the per-row file and reaction clean-up into a shared internal helper used by both purge and delete;
  - `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift`: the action and handler;
  - `ReTiCAMsgr/ConversationListView.swift`: swipe action, context menu and confirmation.
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ConversationDeletionTests.swift`

**Interfaces:**
- Produces:
  - `enum ConversationDeletion { static func run(_ database: any DatabaseWriter, attachmentStore: AttachmentStore, key: String, isGroup: Bool) async throws -> Result }`
    - `Result` holds `deleted: Int`, `deletedAttachmentIds: [UUID]` and `inFlightHashes: [Data]`. The last is the outgoing `sending` rows' hashes, read before deletion.
    - Deleted: message rows for the key (peer: `peerHex == key && groupHex IS NULL`; group: `groupHex == key`), their attachments (files and export copies) and their reactions.
    - Kept: seen-hash rows, `ConversationSetting` (A2), `chatGroups`/`groupMembers`, `peerProfiles`, `contactLinks` and `blockedPeers`.
  - `AppFeature.Action.deleteConversation(key: String)`. The handler:
    1. runs `ConversationDeletion.run`;
    2. sends `.node(.client(.cancelOutbound(messageHash:)))` for each in-flight hash;
    3. removes the key's draft (the drafts file, as the composer's clear path does);
    4. evicts `attachmentCacheEvictor` for the deleted ids;
    5. closes the open thread if it is this key;
    6. reloads the conversation list (the existing list-reload effect).
  - Task 4 hooks read-marker deletion and badge recompute onto this action.

- [ ] **Step 1: Write the failing tests** in `ConversationDeletionTests.swift`:
  - `deletesOnlyThatPeersMessages`: two peers A and B, each with 2 messages; delete A. Then A has 0 rows, B has 2, and `deleted == 2`.
  - `deletesAttachmentFilesAndReactions`: a message with an attachment file and a reaction; after the delete, the file doesn't exist and its reaction rows are gone.
  - `keepsSeenHashesAndTimer`: the seen-hash row and the `ConversationSetting` row both survive.
  - `deleteGroupKeepsGroupAndMembers`: deleting the group key removes its posts. `ChatGroup` and `GroupMember` rows survive, and a peer's one-to-one messages with a group member survive.
  - `deleteCancelsInFlightSends` (TestStore on `AppFeature`): an outgoing `sending` row with hash H, then `.deleteConversation(key:)`. Expect `.node(.client(.cancelOutbound(messageHash: H)))` and an empty list for that key.
  - `deleteClearsDraft` (TestStore): a draft for the key, then delete. The draft is gone.
- [ ] **Step 2:** Run `swift test --package-path ReTiCAMsgrCore --scratch-path /tmp/ReTiCAMsgr/core-delete --filter ConversationDeletion`. Expected: FAIL (compile: `ConversationDeletion` missing).
- [ ] **Step 3:** Implement `ConversationDeletion.run`, the shared purge helper and the `AppFeature` action. `MessagePurge`'s existing tests must stay green.
- [ ] **Step 4:** Run the same filter, then the full core suite. Expected: PASS.
- [ ] **Step 5: UI** in `ConversationListView.swift`. The row's `Button` gets:
  - **iOS:** `.swipeActions(edge: .trailing) { Button("Delete", role: .destructive) { pendingDelete = convo } }`;
  - **macOS:** `.contextMenu { Button("Delete Conversation", role: .destructive) { pendingDelete = convo } }`;
  - **both:** one `.confirmationDialog` driven by `@State private var pendingDelete: Conversation?`, with title "Delete this conversation?", message "Its messages are removed from this device. This can't be undone.", and a destructive "Delete" that sends `.deleteConversation(key: convo.peerHex)`.

  The row keeps `.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())`, so a right-click anywhere on the row works.
- [ ] **Step 6:** iOS and macOS builds are green.
- [ ] **Step 7:** Mutation batch, all at once:
  - drop the `groupHex IS NULL` clause;
  - skip the file delete;
  - skip `cancelOutbound`;
  - delete `ConversationSetting` too.

  Every Task 1 test must fail. Then revert and confirm green.
- [ ] **Step 8:** Commit: `feat: delete a conversation from this device`.

### Task 2: Unread badge (parallel, worktree `-badge`)

**Files:**
- Create:
  - `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ConversationRead.swift`: a `@Table("conversationReads")` model with `key: String` (primary key) and `readAt: Date`;
  - `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/UnreadCount.swift`;
  - `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/BadgeClient.swift`;
  - `ReTiCAMsgrCore/Sources/ReTiCAMsgrPushService/BadgeCounter.swift`;
  - `ReTiCAMsgr/BadgeClient+Live.swift`.
- Modify:
  - `Database.swift`: the `createConversationReads` migration;
  - `AppFeature.swift`: mark-read and recompute;
  - `ReTiCAMsgrNotificationService/NotificationService.swift`;
  - `ReTiCAMsgr/PushPlatform+UIKit.swift` and `ReTiCAMsgr/PushPlatform+AppKit.swift`: add `.badge` to the authorization options;
  - `ReTiCAMsgr/AppRuntime.swift`: install the live `BadgeClient`;
  - `ReTiCAMsgrCore/Package.swift`: add `ReTiCAMsgrPushService` to the test target's dependencies if the tests can't import it.
- Test:
  - `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/UnreadBadgeTests.swift`;
  - `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/BadgeCounterTests.swift`.

**Interfaces:**
- Produces:
  - **`ConversationRead`:**
    - `static func markRead(_ key: String, at: Date, _ db: Database) throws`, an upsert;
    - `static func delete(_ key: String, _ db: Database) throws`.
  - **`UnreadCount.count(_ db: Database) throws -> Int`:** incoming rows (`isOutgoing == false`, `isTimerChange == false`, `isGroupEvent == false`) whose key's sender is not in `blockedPeers`, with `timestamp > readAt` for their key, or any `timestamp` when the key has no `conversationReads` row. Blocked means the row's `peerHex` is blocked.
  - **`BadgeClient`:** `struct BadgeClient { var set: @Sendable (Int) async -> Void }`, a TCA `DependencyKey`.
    - `liveValue` is a no-op.
    - `testValue` is `unimplemented`, so tests must override it (it's explicit, like `backgroundTask`).
    - `\.badge` on `DependencyValues`.
  - **`AppFeature.recomputeBadge(_ database:) -> Effect`** (internal): reads `UnreadCount.count`, then calls `badge.set(n)`.
  - **`BadgeCounter`** (in `ReTiCAMsgrPushService`, no TCA): wraps `UserDefaults(suiteName: ReTiCAMsgrPush.appGroupID)`, key `"badgeCount"`, with `static func increment(_ defaults: UserDefaults) -> Int` and `static func set(_ n: Int, _ defaults: UserDefaults)`.
  - **The live `BadgeClient`** (app): `UNUserNotificationCenter.current().setBadgeCount(n)` plus `BadgeCounter.set(n, defaults)`.
- **Mark-read triggers:** exactly where `stampViewed` runs today (thread open, `viewOpenThreadEffect`, an arrival with `viewedNow != nil`), mark the open key read at `now`. This happens independently of expiry: `stampViewed` is skipped for groups and non-expiring threads, and mark-read is not.
- **Recompute triggers:**
  - launch (after migrations);
  - `.foregrounded`;
  - after mark-read;
  - after any incoming message is stored;
  - after an expiry purge;
  - after a block or unblock;
  - after the push inbox drains.
- **Migration `createConversationReads`:** create the table, then insert one row per existing conversation key with `readAt = now`.

- [ ] **Step 1: Write the failing tests** in `UnreadBadgeTests.swift`:
  - `migrationSeedsReadMarkersForExistingConversations`: messages exist before the migration; after it, `UnreadCount.count == 0`.
  - `countsIncomingAfterReadAt`: readAt T, with incoming rows at T-1, T+1 and T+2 plus one outgoing at T+3. The count is 2.
  - `keyWithoutMarkerCountsAll`: three incoming rows from a new peer, no marker. The count is 3.
  - `excludesTimerChangesGroupEventsAndBlocked`: one of each excluded kind and one counted row. The count is 1.
  - `groupPostsCountUnderGroupKey`: marking the group key read zeroes its posts.
  - `arrivalInWatchedThreadIsRead` (TestStore): the thread is open, `isForeground` and `chatVisible`, and a message arrives. `badge.set(0)` is called and the count is 0.
  - `arrivalWhileInactiveIsUnread` (TestStore): the same, but `activityChanged(isActive: false)` is sent first. `badge.set(1)` is called.
  - `openingThreadMarksRead` (TestStore): two unread, then open the thread. `badge.set(0)` is called.
- [ ] **Step 2:** `BadgeCounterTests.swift`, using a fresh `UserDefaults(suiteName: "test.\(UUID())")`:
  - `incrementStartsAtOne`;
  - `incrementAccumulates` (three calls make 3);
  - `setOverwrites` (`set(7)`, then `increment` gives 8).
- [ ] **Step 3:** Run `swift test ... --filter "UnreadBadge|BadgeCounter"`. Expected: FAIL (compile).
- [ ] **Step 4:** Implement the model, migration, count, client, triggers and counter. In `NotificationService.content(for:original:)`, for `.deliverOriginal`:
  - copy the original into a `UNMutableNotificationContent` and set `.badge = NSNumber(value: BadgeCounter.increment(defaults))`, when the app-group defaults exist;
  - leave `.suppress` unchanged, with nothing incremented.
- [ ] **Step 5:** The filtered tests and the full core suite pass, and both app builds are green.
- [ ] **Step 6:** Mutation batch, all at once:
  - seed `readAt` as `distantPast`;
  - use `>=` in place of `>`;
  - drop the blocked join;
  - skip mark-read on arrival;
  - make `increment` not persist.

  The targeted tests must fail. Then revert and confirm green.
- [ ] **Step 7:** Commit: `feat: unread-message badge on the app icon`.

### Task 3: Display name carried in messages (parallel, worktree `-names`)

**Files:**
- Create:
  - `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/NameWire.swift`;
  - `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ProfileNameOutbox.swift`;
  - `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ProfileNameDelivery.swift`.
- Modify:
  - `PeerProfile.swift`: add `name: String?` and `nameSetAt: Date?`, plus `setName(_:setAt:at:db)`, newer-wins like `isNewer`;
  - `Database.swift`: the `addPeerNames` and `createProfileNameDeliveries` migrations;
  - `AppFeature.swift`:
    - merge name fields wherever `ProfilePhotoOutbox.plan` is applied;
    - settle `ProfileNameDelivery` wherever `ProfilePhotoDelivery.applyOutcome` / `clearAllPending` / `markPending` is called;
    - decode on validated receive next to `ProfileWire.decode`;
    - display precedence in `peerDisplayName`.
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/NameInMessagesTests.swift`

**Interfaces:**
- Produces:
  - **`NameWire`:**
    - `static let fieldDisplayName = 0xA1`;
    - `static let maxBytes = 128`;
    - `static func encode(_ name: String) -> [MsgPackValue.IntPair]`: trims, then truncates at a character boundary to ≤ 128 UTF-8 bytes;
    - `static func decode(_ fields: [MsgPackValue.IntPair]) -> String?`: nil when the field is absent, longer than 128 bytes, or not valid UTF-8; `""` means a cleared name.
  - **`ProfileNameOutbox.plan(myName: String, delivery: ProfileNameDelivery?) -> (fields: [MsgPackValue.IntPair], pendingName: String?)`:** the name rides when `myName != delivery?.deliveredName && myName != delivery?.pendingName`. When `myName` is empty, it rides only if `deliveredName` is non-empty.
  - **`ProfileNameDelivery`** (`@Table("profileNameDeliveries")`, with `peerHex`, `deliveredName`, `pendingName` and `pendingHash`): `markPending`, `applyOutcome(hash:confirmed:)` and `clearAllPending`, mirroring `ProfilePhotoDelivery`.
  - **`State.peerDisplayName(_:)`:** the contact name, else the newer of `PeerProfile.name` (by `nameSetAt`) and the announce name (by `learnedPeers[hash].learnedAt`). An empty winner gives nil.
  - `State` needs the peer names loaded. Extend the existing `reloadPeerProfiles` and the profile state it fills with `name` and `nameSetAt`.

- [ ] **Step 1: Write the failing tests** in `NameInMessagesTests.swift`:
  - `encodeTruncatesAtCharacterBoundary`: 200 bytes of "é" gives ≤ 128 bytes of valid UTF-8.
  - `decodeRejectsOversizeAndBadUTF8`.
  - `planRidesUntilConfirmed`: no delivery means it rides with a pending name; pending equal to the name means it doesn't ride; delivered equal to the name means it doesn't ride; a changed name rides again.
  - `planClearOnlyAfterDeliveredName`: empty with delivered "Al" rides `""`; empty with no delivery doesn't ride.
  - `olderNameDoesNotOverwriteNewer`: `setName("New", setAt: T2)` then `setName("Old", setAt: T1)` leaves "New".
  - `displayPrefersContactThenNewer`:
    - a contact name beats everything;
    - a message name at T2 beats an announce at T1;
    - an announce at T3 beats a message name at T2;
    - a cleared message name that is newer gives nil.
  - `outgoingMessageCarriesNameUntilDelivered` (TestStore):
    1. Set a name, then send to a peer. The outgoing fields contain `0xA1`.
    2. Deliver it, then send again. No `0xA1`.

    Read the send path to find where fields are observable in tests. Mirror the existing profile-photo outbox test.
- [ ] **Step 2:** Run `swift test ... --filter NameInMessages`. Expected: FAIL (compile).
- [ ] **Step 3:** Implement. Receive: on a validated message whose `NameWire.decode` is non-nil, call `PeerProfile.setName` with `setAt` = the sender timestamp capped at arrival (the photo rule), then reload profiles.
- [ ] **Step 4:** The filtered tests and the full core suite pass, and both app builds are green.
- [ ] **Step 5:** Mutation batch, all at once:
  - drop the truncation;
  - flip newer-wins;
  - always ride;
  - ignore `nameSetAt` in the precedence.

  The targeted tests must fail. Then revert and confirm green.
- [ ] **Step 6:** Commit: `feat: carry my display name on messages until each peer confirms it`.

### Task 4: Integration (sequential, after Tasks 1–3)

- [ ] **Step 1:** Merge `feat/convos-delete`, `feat/convos-badge` and `feat/convos-names` into `feat/delete-badge-names` with `--no-ff`. Resolve the `Database.swift` migration conflict in this order: `createConversationReads`, `addPeerNames`, `createProfileNameDeliveries`. Resolve any `AppFeature.swift` conflicts by keeping both sides.
- [ ] **Step 2: Wire delete into the badge.** The `.deleteConversation` handler also calls `ConversationRead.delete(key)` and then `recomputeBadge`. Add the TestStore test `deleteRecomputesBadge`: one unread conversation, delete it, then `badge.set(0)`. A follow-up incoming message from that peer gives `badge.set(1)`, since there is no marker. Mutation: skip the recompute; the test must fail. Then revert.
- [ ] **Step 3:** Run:
  - the full core suite;
  - the iOS app suite;
  - the macOS app tests (`-only-testing:ReTiCAMsgrTests`, `arch=arm64`);
  - both app builds.

  All must be green.
- [ ] **Step 4:** Commit the integration fixes. Don't merge to main; that's the user's call.
