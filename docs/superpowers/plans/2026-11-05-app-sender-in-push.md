# App: sender name and picture in push banners — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app keeps an app-group sender directory (name, public key, picture) up to date, and the Notification Service Extension uses ReTiCAPush's verified `PushOutcome` to title the banner with the sender's name and show their picture as a Communication Notification.

**Architecture:** A pure builder turns app state into `[hex: SenderDirectory.Input]`. A `SenderDirectoryReducer`, composed into `AppFeature.body`, watches a cheap fingerprint of the inputs with `.onChange`, debounces 1 s, reads group members from the database and pictures from disk, and writes through a `SenderDirectoryWriter` dependency (disabled by default in tests, so existing TestStore suites see no new effects). The banner logic moves from the extension into `ReTiCaMsgrPushService` as `PushBanner`, a pure plan plus a thin Intents step.

**Tech Stack:** Swift 6, TCA, SQLiteData/GRDB, UserNotifications, Intents, swift-testing. Core tests: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-sender-push/ReTiCaMsgrCore --filter <prefix>`.

**Spec:** `/Users/ell/development/ios/apps/ReTiCaMsgr-sender-push/docs/superpowers/specs/2026-11-05-sender-in-push-design.md` (§3, §4, §5, Testing).

**Prerequisite:** `2026-11-05-reticapush-sender-attribution.md` merged to ReTiCAPush `main` (this package resolves `../../../pods/ReTiCAPush`). It provides `SenderDirectory`, `SenderDirectory.Input/Entry`, `SenderDirectoryStore`, `PushStorage.senderDirectory`, `PushOutcome`, `PushSenderMatch`, `PushServiceHandler.outcome(userInfo:)`.

## Global Constraints

- Worktree `/Users/ell/development/ios/apps/ReTiCaMsgr-sender-push`, branch `feat/sender-in-push` (already holds the spec).
- `ReTiCaMsgrPushService` stays free of TCA and SQLite. It may import `UserNotifications` and `Intents`.
- Directory peers: conversation peers (`Conversation.kind == .peer`) ∪ contact-linked peers ∪ members of every group (`GroupMember` table) − me − blocked − peers with no known public key (`state.node.client.router.knownIdentities`). Entries with neither a name nor a picture are left out.
- Name: `State.peerDisplayName(hex)`. Picture: `AvatarSource.resolve`; `.photo(path)` → the JPEG bytes from `AvatarStore`; `.contact(data)` → `ImageEncoder.encodeAvatar(data).data`; `.icon`/`.initials` → none.
- Banner: title = name, or the first 8 hex characters for a picture-only entry; body = `"New message"`; `threadIdentifier` = sender hex; no sender → the original content untouched (badged as today); suppress → empty content.
- Debounce 1 s on `\.continuousClock`.
- Shell rule: one command per Bash call, no pipes / `&&` / `;` / `$(...)`. Never run `swift test` and `xcodebuild` at the same time.
- Test verification per the user's global rule: green → mutate (one named mutation per test) → red → revert → green, with a table in the report.

## Review Focus

1. **Existing suites must not grow in-flight effects.** `SenderDirectoryWriter.testValue` is disabled, and a disabled writer means the reducer returns `.none` before computing anything — Task 2 `senderDirectoryDisabledWriterDoesNothing`.
2. **Blocking a peer must drop them from the directory** at the next write, or a blocked person's face keeps showing for verified pushes — Task 2 `senderDirectoryDropsAPeerOnceBlocked`.
3. **A group-only member** (never messaged directly) must be named, which needs the DB read, not `openGroupMembers` — Task 2 `senderDirectoryIncludesGroupMembersFromTheDatabase`.
4. **A picture-only entry** must still produce a titled banner (short hex) — Task 3 `pushBannerTitlesAPictureOnlySenderWithShortHex`.
5. **An Intents failure** (no entitlement, donation error) must still leave the name as the title — Task 3 `pushBannerFallsBackWhenTheIntentStepThrows`.

---

### Task 1: The directory builder (pure)

**Files:**
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/SenderDirectoryBuilder.swift`
- Test: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/SenderDirectoryBuilderTests.swift`

**Interfaces:**
- Produces:
  - `enum SenderDirectoryBuilder { static func inputs(candidates: Set<String>, me: String, blocked: Set<String>, name: (String) -> String?, publicKey: (String) -> Data?, picture: (String) -> Data?) -> [String: SenderDirectory.Input] }` — lowercases every hex; excludes `me`, `blocked`, no-key, and no-name-no-picture.
  - `extension AppFeature.State { func senderDirectoryCandidates(groupMembers: [String]) -> Set<String>; func senderPublicKey(_ hex: String) -> Data? }` — candidates = `.peer` conversation keys ∪ `contactLinks.keys` ∪ `groupMembers`; key from `node.client.router.knownIdentities[Data(hexString: hex)]?.publicKey`.

- [ ] **Step 1: Write the failing tests**

```swift
private let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
private let c = String(repeating: "c", count: 32), me = String(repeating: "e", count: 32)
private let key = Data(repeating: 9, count: 64)

@Test func senderDirectoryBuilderKeepsNamedPeersWithKeys() {
    let out = SenderDirectoryBuilder.inputs(candidates: [a], me: me, blocked: [],
        name: { _ in "Alice" }, publicKey: { _ in key }, picture: { _ in nil })
    #expect(out == [a: .init(name: "Alice", publicKey: key, imageData: nil)])
}

@Test func senderDirectoryBuilderSkipsPeersWithoutAKey() {
    let out = SenderDirectoryBuilder.inputs(candidates: [a], me: me, blocked: [],
        name: { _ in "Alice" }, publicKey: { _ in nil }, picture: { _ in nil })
    #expect(out.isEmpty)
}

@Test func senderDirectoryBuilderSkipsBlockedAndMe() {
    let out = SenderDirectoryBuilder.inputs(candidates: [a, b, me], me: me, blocked: [b],
        name: { _ in "X" }, publicKey: { _ in key }, picture: { _ in nil })
    #expect(Set(out.keys) == [a])
}

@Test func senderDirectoryBuilderSkipsPeersWithNothingToShow() {
    let out = SenderDirectoryBuilder.inputs(candidates: [a, b], me: me, blocked: [],
        name: { _ in nil }, publicKey: { _ in key }, picture: { $0 == b ? Data([1]) : nil })
    #expect(Set(out.keys) == [b])
    #expect(out[b]?.name == nil)
}

@Test func senderDirectoryBuilderLowercases() {
    let out = SenderDirectoryBuilder.inputs(candidates: [a.uppercased()], me: me, blocked: [],
        name: { _ in "A" }, publicKey: { _ in key }, picture: { _ in nil })
    #expect(out.keys.first == a)
}

@Test func senderDirectoryCandidatesUnionsPeersLinksAndGroupMembers() {
    var state = AppFeature.State(identity: Identity(), pushStorage: .temporary())
    state.conversations = [Conversation(peerHex: a, lastBody: "", lastTimestamp: .now),
                           Conversation(peerHex: c, kind: .group, title: "G", lastBody: "", lastTimestamp: .now)]
    state.contactLinks[b] = ContactLink(peerHex: b, contactIdentifier: "id", cachedName: "B", source: "manual")
    let members = [String(repeating: "d", count: 32)]
    #expect(state.senderDirectoryCandidates(groupMembers: members) == [a, b, members[0]])   // not the group key c
}
```

(Match `ContactLink.init`'s real parameter list; the call above shows intent.)

- [ ] **Step 2: Run, expect compile failure:** `--filter senderDirectory`.
- [ ] **Step 3: Implement** both pieces in `SenderDirectoryBuilder.swift`.
- [ ] **Step 4: Run `--filter senderDirectory`** — green.
- [ ] **Step 5: Mutation check** (6 tests, one batch):
  - `…KeepsNamedPeersWithKeys` ← drop the `name` from the input (always nil).
  - `…SkipsPeersWithoutAKey` ← use `Data()` when `publicKey` returns nil instead of skipping.
  - `…SkipsBlockedAndMe` ← drop the `blocked` filter **and** keep `me`'s filter — then a second isolated run dropping only `me`'s filter. (Two runs, one per clause.)
  - `…SkipsPeersWithNothingToShow` ← drop the nothing-to-show filter.
  - `…Lowercases` ← drop lowercasing.
  - `senderDirectoryCandidatesUnionsPeersLinksAndGroupMembers` ← include `.group` conversation keys.
  Table, revert, green.
- [ ] **Step 6: Commit** `feat(core): sender directory builder`.

### Task 2: The writer (reducer, dependency, debounce)

**Files:**
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/SenderDirectoryReducer.swift`
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` (compose `SenderDirectoryReducer()` after `BlockingReducer()` near line 2992)
- Test: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/SenderDirectoryWriterTests.swift`

**Interfaces:**
- Consumes: Task 1; `SenderDirectoryStore` via `state.push.storage.senderDirectory`; `@Dependency(\.avatarStore)`, `\.contactsClient` (`thumbnail(id)`), `\.defaultDatabase`, `\.continuousClock`.
- Produces:
  - `struct SenderDirectoryWriter: Sendable { var isEnabled: Bool; var write: @Sendable (SenderDirectoryStore, [String: SenderDirectory.Input]) throws -> Void }` with `liveValue = .init(isEnabled: true) { try $0.save($1) }` and `testValue = .init(isEnabled: false) { _, _ in }`; `DependencyValues.senderDirectoryWriter`.
  - `struct SenderDirectoryFingerprint: Equatable` built from state: `conversations`, `contactLinks`, `contactCards`, `peerProfiles`, `blockedPeers`, and for each candidate in `senderDirectoryCandidates(groupMembers: [])` its `peerDisplayName` and whether `senderPublicKey` is non-nil.
  - `SenderDirectoryReducer: Reducer<AppFeature.State, AppFeature.Action>`: `guard writer.isEnabled`, then `.onChange(of: fingerprint)` → `.run` cancellable (`cancelInFlight: true`, its own `CancelID`): sleep 1 s, read all `GroupMember.memberHex` from the DB, fetch missing contact thumbnails for linked peers via `contactsClient.thumbnail`, build inputs (Task 1) with `peerDisplayName`, `senderPublicKey`, and the picture rule from Global Constraints, then `writer.write(store, inputs)`. Write errors are swallowed (logged), never sent as actions.
  - The effect captures a copy of `state` (a value; copy-on-write makes this cheap) and calls `peerDisplayName`, `senderPublicKey` and `AvatarSource.resolve` on that copy, so group-only members found in the DB get names and keys too. Only group members, photo files and missing thumbnails are read inside the effect.
  - Group roster changes must reach the fingerprint. Check whether applying a roster adds a group-event message (and so changes `conversations`). If it doesn't, add the open group's roster or a roster-version counter to the fingerprint, and add a test that a roster change rewrites the directory. An announce-name change for a group-only member waits for the next fingerprint change; accepted.

- [ ] **Step 1: Write the failing tests.** A `makeDirectoryStore(db, configure:)` helper modelled on `makeBlockStore` in `BlockingTests.swift`, but with `$0.senderDirectoryWriter = .liveValue`, `$0.avatarStore = .testValue`, `$0.contactsClient` stubbed with a fixed thumbnail, and a `TestClock` the test advances. Seed a peer by inserting a `Message` and sending the conversations reload the app already uses, and seed `knownIdentities` in `configure`.

```swift
@MainActor @Test func senderDirectoryWritesNamedPeersAfterTheDebounce() async throws {
    // A conversation with Alice (known identity, announce name "Alice"):
    // advance 999 ms → load() still empty; advance 1 ms more → entries[aliceHex]?.name == "Alice",
    // publicKey == alice.publicKey.
}

@MainActor @Test func senderDirectoryIncludesGroupMembersFromTheDatabase() async throws {
    // GroupMember row for Dana (known identity, announce name "Dana"), no direct conversation:
    // after a fingerprint change + 1 s, entries[danaHex]?.name == "Dana".
}

@MainActor @Test func senderDirectoryDropsAPeerOnceBlocked() async throws {
    // Alice written; send .blockPeer(aliceHex); advance 1 s → entries[aliceHex] == nil.
}

@MainActor @Test func senderDirectoryCopiesAReceivedPhoto() async throws {
    // peerProfiles[alice].photoPath = a file written with avatarStore.storePeer(jpeg, …):
    // the written entry's image bytes == jpeg.
}

@MainActor @Test func senderDirectoryUsesTheLinkedContactThumbnail() async throws {
    // Alice linked to contact "c1", no received photo; contactsClient.thumbnail("c1") returns a
    // TestImages JPEG: the entry has an image whose ImageEncoder.dimensions == (256, 256).
}

@MainActor @Test func senderDirectoryDisabledWriterDoesNothing() async throws {
    // Same setup as the first test but writer = .testValue (disabled); exhaustivity .on; the
    // conversations change completes with no effect in flight and load() stays empty.
}
```

Write each body fully; the comments give the setup and the exact assertions.

- [ ] **Step 2: Run, expect failure:** `--filter senderDirectory`.
- [ ] **Step 3: Implement** `SenderDirectoryReducer.swift` and compose it.
- [ ] **Step 4: Run `--filter senderDirectory`**, then the whole Core suite (`swift test --package-path …/ReTiCaMsgrCore`) — all green, same count as `main` plus the new tests. Any existing test that now fails means the disabled path still produces an effect; fix that, not the test.
- [ ] **Step 5: Mutation check** (6 tests):
  - `…AfterTheDebounce` ← sleep 0 instead of 1 s (the 999 ms assertion goes red).
  - `…IncludesGroupMembersFromTheDatabase` ← pass `[]` as group members.
  - `…DropsAPeerOnceBlocked` ← leave `blockedPeers` out of the builder call (pass `[]`).
  - `…CopiesAReceivedPhoto` ← ignore `.photo` (return nil picture).
  - `…UsesTheLinkedContactThumbnail` ← pass the raw thumbnail without `encodeAvatar` (dimensions differ).
  - `…DisabledWriterDoesNothing` ← drop the `isEnabled` guard.
  Table, revert, green.
- [ ] **Step 6: Commit** `feat(core): keep the app-group sender directory current`.

### Task 3: The banner (`PushBanner` in `ReTiCaMsgrPushService`)

**Files:**
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrPushService/PushBanner.swift`
- Modify: `ReTiCaMsgrNotificationService/NotificationService.swift` (call `handler.outcome(userInfo:)` and `PushBanner.content`; delete its `content(for:original:)`)
- Test: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/PushBannerTests.swift`

**Interfaces:**
- Consumes: `PushOutcome`, `PushSenderMatch` (ReTiCAPush); `BadgeCounter` (same target).
- Produces:
  - `struct PushBanner.Plan: Equatable { var title: String; var body: String; var threadIdentifier: String; var senderHex: String; var imageURL: URL? }`
  - `static func plan(for outcome: PushOutcome) -> Plan?` — nil unless `.deliverOriginal` with a sender; title = `entry.name` (trimmed, non-empty) else `String(hex.prefix(8))`; body `"New message"`.
  - `static func content(for outcome: PushOutcome, original: UNNotificationContent, applyIntent: (UNMutableNotificationContent, Plan) async throws -> UNNotificationContent = PushBanner.liveIntent) async -> UNNotificationContent` — `.suppress` → `UNNotificationContent()`; otherwise badge as today; with a plan, set title/body/thread, then `try await applyIntent`, falling back to the titled copy on throw.
  - `static func liveIntent(_:_:)` — `INPerson(personHandle: INPersonHandle(value: hex, type: .unknown), nameComponents: nil, displayName: title, image: imageURL.flatMap { try? Data(contentsOf: $0) }.map(INImage.init(imageData:)), contactIdentifier: nil, customIdentifier: hex)`; `INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: nil, speakableGroupName: nil, conversationIdentifier: hex, serviceName: nil, sender: person, attachments: nil)`; donate an `.incoming` `INInteraction`; `try content.updating(from: intent)`.

- [ ] **Step 1: Write the failing tests**

```swift
private let hex = String(repeating: "a", count: 32)
private func outcome(_ name: String?, verdict: PushVerdict = .deliverOriginal) -> PushOutcome {
    PushOutcome(verdict: verdict, sender: PushSenderMatch(hex: hex,
        entry: .init(name: name, publicKey: Data(repeating: 1, count: 64), imageFile: nil), imageURL: nil))
}
private func original() -> UNNotificationContent {
    let c = UNMutableNotificationContent(); c.title = "New message"; return c
}

@Test func pushBannerTitlesANamedSender() {
    #expect(PushBanner.plan(for: outcome("Alice")) ==
            .init(title: "Alice", body: "New message", threadIdentifier: hex, senderHex: hex, imageURL: nil))
}

@Test func pushBannerTitlesAPictureOnlySenderWithShortHex() {
    #expect(PushBanner.plan(for: outcome(nil))?.title == "aaaaaaaa")
    #expect(PushBanner.plan(for: outcome("  "))?.title == "aaaaaaaa")
}

@Test func pushBannerHasNoPlanWithoutASender() {
    #expect(PushBanner.plan(for: PushOutcome(verdict: .deliverOriginal, sender: nil)) == nil)
}

@Test func pushBannerSuppressesToEmptyContent() async {
    let c = await PushBanner.content(for: outcome("Alice", verdict: .suppress), original: original(),
                                     applyIntent: { c, _ in c })
    #expect(c.title.isEmpty && c.body.isEmpty && c.sound == nil)
}

@Test func pushBannerLeavesTheOriginalWithoutASender() async {
    let c = await PushBanner.content(for: PushOutcome(verdict: .deliverOriginal, sender: nil),
                                     original: original(), applyIntent: { _, _ in Issue.record("called"); return original() })
    #expect(c.title == "New message")
    #expect(c.threadIdentifier.isEmpty)
}

@Test func pushBannerFallsBackWhenTheIntentStepThrows() async {
    struct Boom: Error {}
    let c = await PushBanner.content(for: outcome("Alice"), original: original(),
                                     applyIntent: { _, _ in throw Boom() })
    #expect(c.title == "Alice")
    #expect(c.body == "New message")
    #expect(c.threadIdentifier == hex)
}
```

- [ ] **Step 2: Run, expect compile failure:** `--filter pushBanner`.
- [ ] **Step 3: Implement** `PushBanner.swift`; slim `NotificationService` to call `handler.outcome(userInfo:)` and `PushBanner.content(for:original:)` (keep its lock, `finish` and the timeout path delivering the original).
- [ ] **Step 4: Run `--filter pushBanner`** and `--filter badgeCounter` — green.
- [ ] **Step 5: Mutation check** (6 tests):
  - `…TitlesANamedSender` ← body `""`.
  - `…TitlesAPictureOnlySenderWithShortHex` ← fall back to `hex` (full) — and an isolated run without the trim, for the `"  "` assertion.
  - `…HasNoPlanWithoutASender` ← return a plan with the empty hex when sender is nil.
  - `…SuppressesToEmptyContent` ← treat `.suppress` like `.deliverOriginal`.
  - `…LeavesTheOriginalWithoutASender` ← set `threadIdentifier = "x"` on every delivered content.
  - `…FallsBackWhenTheIntentStepThrows` ← on throw, return `original` instead of the titled copy.
  Table, revert, green.
- [ ] **Step 6: Commit** `feat(push): name the sender on the banner`.

### Task 4: Capabilities and a device build

**Files:**
- Modify: `ReTiCaMsgr/ReTiCaMsgr.entitlements`, `ReTiCaMsgrNotificationService/ReTiCaMsgrNotificationService.entitlements` — add `com.apple.developer.usernotifications.communication` = `true`.
- Modify: `ReTiCaMsgr/Info.plist` — `NSUserActivityTypes` = `[INSendMessageIntent]`.
- Not the macOS entitlements (no service extension on the Mac).

- [ ] **Step 1: Edit** the three files.
- [ ] **Step 2: Build for the simulator:** `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr-sender-push/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination 'generic/platform=iOS Simulator' build` → `** BUILD SUCCEEDED **`. There is no separate Mac scheme: build the same `ReTiCaMsgr` scheme with `-destination 'generic/platform=macOS'` to prove `ReTiCaMsgrPushService` still compiles there.
- [ ] **Step 3: Device build** with `-allowProvisioningUpdates` (signing is Automatic, so Xcode should add the capability to both App IDs). If it fails on provisioning, stop and tell the user to enable **Communication Notifications** on both App IDs in the developer portal.
- [ ] **Step 4: Commit** `chore: Communication Notifications capability`.

## Hand-off

Whole-branch review, then ask the user before merging and installing. On-device checks owed by the user (from the spec): a named contact with a photo shows name and avatar on the lock screen; a Sideband sender shows their name; a link-based sender shows "New message".
