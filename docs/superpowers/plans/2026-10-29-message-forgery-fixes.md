# Message Forgery Fixes: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- ReTiCA drops validly-signed messages addressed to someone else.
- ReTiCA drops messages from known senders whose signatures fail.
- The app shows unknown-sender messages as "Unverified sender", keeps them out of the unread counts, and re-checks them once the sender's key arrives.

**Architecture:** Three parallel tasks (one ReTiCA, two app), then an integration task that verifies the app against the ReTiCA branch and merges ReTiCA, then the app.
- **ReTiCA:** the router gains a destination check and a known-bad-signature drop, ordered before `seen`.
- **App core:** stores the packed bytes of unverified rows and re-checks them.
- **App views:** add the markers.

**Tech Stack:** Swift 6.3, ReTiCA (TCA reducers `LXMFRouter`, `LXMFNode`), SwiftUI, TCA, SQLiteData/GRDB, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-28-message-forgery-fixes-design.md`, in the app worktree, including "Settled details" 1–5.

## Global Constraints

- **Worktrees and paths:**
  - ReTiCA worktree: `/Users/ell/development/ios/pods/ReTiCA-worktrees/forgery` (branch `fix/forgery`). Never touch `/Users/ell/development/ios/pods/ReTiCA` itself, where another agent works.
  - App worktree: `/Users/ell/development/ios/apps/ReTiCaMsgr-forgery` (branch `fix/forgery`).
  - Parallel app tasks use sibling worktrees `ReTiCaMsgr-forgery-core` and `ReTiCaMsgr-forgery-ui` (branches `fix/forgery-core` and `fix/forgery-ui`).
- **"Ours" means `deliveryDestinationHash`** for both `.direct` and `.propagated`. A nil value means drop.
- **Check order** in `LXMFRouter` `.received`:
  1. unpack;
  2. the destination check (direct and propagated only);
  3. the known-identity signature check, which drops on failure;
  4. `seen.insert`;
  5. deliver.

  Unknown senders are delivered with `signatureValidated: false`, and are still marked seen.
- **The opportunistic proof stays where it is.** It matches reference `LXMRouter.delivery_packet` and reveals only arrival. This is the controller's ruling under spec "Shape: ReTiCA", which made moving the proof optional.
- **A propagated message dropped by either check is still marked downloaded** (spec settled detail 5). The existing `messagesDownloaded` effect stays unconditional.
- **The app stores packed bytes only for unverified incoming rows,** and only when they are ≤ 262_144 bytes (256 KB, spec settled detail 3).
- **The unverified marker copy is exactly "Unverified sender".**
- **Tests:** Swift Testing. Every new test follows the user's three-step mutation rule (pass, fail under a batch mutation, revert and pass), with the evidence recorded.
- **Commands:**
  - ReTiCA tests: `swift test --package-path <worktree> --scratch-path /tmp/ReTiCaMsgr/retica-forgery --no-parallel --filter <name>`. Use `--no-parallel` for full runs. Known flake: `pnNodeOfferRejectedWithInvalidPeeringKey`.
  - App core tests: `swift test --package-path ReTiCaMsgrCore --scratch-path /tmp/ReTiCaMsgr/core-<task>`. Known flakes: `meshLiveScanMapsEachRadio` and `meshLiveScanFinishesWhenTheSourceFinishes`.
  - App builds: iOS and macOS `xcodebuild` with `-derivedDataPath /tmp/ReTiCaMsgr/dd-<task>-{ios,mac}`; macOS adds `CODE_SIGNING_ALLOWED=NO`.
- **Disk:** the disk filled earlier. Delete your own scratch and derived-data dirs when you finish.
- **Shell:** one command per Bash call, with no pipes, `&&`, `;` or `$(...)` (including inside commit messages). Write scripts to `/tmp/ReTiCaMsgr/`. Commit trailers per the user's rule.

## Review Focus

1. **A validly-signed message from Bob, addressed to Carol, delivered to us over a link:** dropped, with nothing stored. Test: Task 1, `directMessageForAnotherRecipientIsDropped`.
2. **A forged copy of a contact's message arriving first:** it must not block the genuine message. Test: Task 1, `knownSenderBadSignatureIsNotMarkedSeen`, where the genuine copy is delivered after the bad one.
3. **An unverified row whose sender's key arrives later with a mismatching signature:** the row is deleted along with its attachments. Test: Task 2, `recheckDeletesForgedRow`.
4. **An unverified message larger than 256 KB:** stored with no bytes, never re-checked, and the app doesn't crash. Test: Task 2, `oversizedUnverifiedStoresNoBytes`.
5. **Rows stored before this change (`validated = false`, no bytes):** they keep their marker, are left alone by the re-check, and don't count as unread. Test: Task 2, `legacyUnverifiedRowsAreLeftAlone`.

---

### Task 1: ReTiCA router checks (parallel, ReTiCA worktree)

**Files:**
- Modify:
  - `Sources/ReTiCANode/LXMFRouter.swift` (`.received`, around lines 706–723; the `Delegate` enum around line 306);
  - `Sources/ReTiCANode/LXMFNode.swift`: the `.received` sends at around lines 799, 1104, 1106 and 1111 pass `state.deliveryDestinationHash ?? Data()` in place of `Data()`, plus handling of the new router delegate.
- Test: `Tests/ReTiCANodeTests/LXMFForgeryTests.swift` (new). Mirror the helpers in `LXMFRouterTests.swift` and `LXMFArrivalMethodTests.swift`.

**Interfaces:**
- Produces:
  - **Router delegate** `LXMFRouter.Action.Delegate.messageRejected(hash: Data, reason: RejectReason)`, with `public enum RejectReason: Equatable, Sendable { case notAddressedToUs, badSignature }`.
  - **`LXMFNode`:** handles the new delegate as a no-op. Don't add a node delegate, so the app needs no change for it.
  - **Router `.received` contract:** for `.direct` and `.propagated`, `destinationHash` is our delivery hash, or empty when not registered. The message's `destinationHash` must equal it, and must be non-empty. For `.opportunistic`, the existing meaning is unchanged.

- [ ] **Step 1: Write the failing tests** (TestStore on `LXMFRouter`, or `LXMFNode` where the call-site change needs it):
  - **`directMessageForAnotherRecipientIsDropped`:** Bob's identity is known, and Bob signs a message to Carol's delivery hash. `.received(method: .direct, destinationHash: aliceDelivery, data: packed)` yields `.messageRejected(hash:, reason: .notAddressedToUs)` and no `.messageDelivered`.
  - **`propagatedMessageForAnotherRecipientIsDropped`:** the same, with `.propagated`.
  - **`directMessageToUsIsDelivered`:** Bob signs to Alice. It is delivered with `signatureValidated: true`.
  - **`receivedWithoutRegistrationDropsDirect`:** `destinationHash: Data()` gives `.messageRejected(.notAddressedToUs)`.
  - **`knownSenderBadSignatureIsDropped`:** Bob is known, and the message claims Bob with a random 64-byte signature. The result is `.messageRejected(reason: .badSignature)`, with no delivery.
  - **`knownSenderBadSignatureIsNotMarkedSeen`:** after the bad copy is rejected, the genuine copy (same hash, real signature) is delivered with `signatureValidated: true`, not `.duplicateDropped`.
  - **`unknownSenderIsDeliveredUnvalidated`:** Bob is not known. Delivered with `signatureValidated: false`. A second copy then gives `.duplicateDropped`.
  - **`rejectedPropagatedStillMarkedDownloaded`** (LXMFNode level): a propagated blob addressed to someone else is rejected, and its transient id still appears in `.messagesDownloaded`.
  - **`nodePassesDeliveryHashForPropagatedAndDirect`** (LXMFNode level): after `registerDelivery`, a propagated blob addressed to us is delivered. A link data packet on a non-delivery link, carrying a message addressed to us, is delivered too.
- [ ] **Step 2:** Run `--filter LXMFForgery`. Expected: FAIL (compile: `messageRejected` is missing).
- [ ] **Step 3:** Implement the check order from Global Constraints, the new delegate, and the call-site changes.
- [ ] **Step 4:** Run the filter, which must pass. Then run the full ReTiCA suite with `--no-parallel`. The existing `LXMFRouterTests` and `LXMFArrivalMethodTests` must stay green. If an existing test feeds `.direct`/`.propagated` with `destinationHash: Data()` and expects delivery, update its input to pass the real destination. Don't weaken its assertions, and list every such edit in the report.
- [ ] **Step 5: Mutation batch.** Apply all of these at once:
  - drop the destination check;
  - compare against `message.sourceHash`;
  - deliver on a known bad signature;
  - insert into `seen` before validating;
  - accept an empty destination.

  Every new test must fail. Revert, then confirm green.
- [ ] **Step 6:** Commit: `fix(lxmf): drop messages not addressed to us and known-sender bad signatures`.

### Task 2: App core, storing and re-checking unverified rows (parallel, worktree `ReTiCaMsgr-forgery-core`)

**Files:**
- Modify:
  - `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Database.swift`: the `addUnverifiedPacked` migration, appended last; a nullable `unverifiedPacked` BLOB on `messages`.
  - `Message.swift`: `public var unverifiedPacked: Data?`, defaulting to nil in the initialiser.
  - `AppFeature.swift`:
    - the incoming store (around 2155–2167) sets `unverifiedPacked`;
    - the `.pathLearned` handlers (around 1947 and 2869) trigger the re-check;
    - the launch effect triggers it once.
  - `UnreadCount.swift`: `AND m.validated = 1` in both queries.
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/UnverifiedRecheck.swift`.
- Test: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/UnverifiedSenderTests.swift`.

**Interfaces:**
- Produces:
  - **`enum UnverifiedRecheck`:**
    - `static let maxStoredBytes = 262_144`;
    - `static func run(_ database: any DatabaseWriter, attachmentStore: AttachmentStore, sourceHex: String, identity: Identity) async throws -> (verified: Int, removed: [UUID])`. For each row with `peerHex == sourceHex`, `validated == false` and `unverifiedPacked != nil`, it runs `LXMessage.unpack(bytes)?.validateSignature(source: identity)`:
      - true: set `validated = true` and `unverifiedPacked = nil`;
      - false, or the bytes won't unpack: remove the row through `MessagePurge.removeMessages`, so attachments and reactions go too.

      It returns the removed attachment ids for the cache evictor.
  - **App wiring:**
    - on a store with `validated == false` and `m.packed.count <= maxStoredBytes`, keep `m.packed` in `unverifiedPacked`;
    - if `state.node.client.endpoint.learned[sourceHash]?.identity` exists at store time, run the re-check right after storing;
    - on `.pathLearned(h)`, run the re-check when `endpoint.learned[h]?.identity` exists;
    - at launch, run it for every distinct `peerHex` with stored bytes whose identity is in `learned`;
    - after any re-check that changed rows: reload the open thread and the list, evict the cache, and `refreshBadge`.
- Consumes: nothing from Task 1. It works against today's ReTiCA, where unknown senders are already delivered unvalidated.

- [ ] **Step 1: Write the failing tests:**
  - **`unverifiedRowStoresPackedBytes`** (TestStore): a message from an unknown sender is stored with `validated == false` and `unverifiedPacked == m.packed`.
  - **`unverifiedRowsDoNotCount`:** with the unverified row in place, `UnreadCount.count == 0` and `perConversation` is empty. A validated row in the same thread counts 1.
  - **`recheckVerifiesGenuineRow`:** stored bytes signed by the sender's real identity, then `UnverifiedRecheck.run` with that identity, give `verified == 1`, the row validated, the bytes nil, and the count 1.
  - **`recheckDeletesForgedRow`:** stored bytes with a junk signature, plus an attachment file, then run with the claimed identity. The row is gone and the attachment file is deleted.
  - **`pathLearnedTriggersRecheck`** (TestStore): an unverified row is stored, then the sender's announce is learned (`.pathLearned`, with `endpoint.learned` seeded). The row is validated, and `badge.set` receives the new count.
  - **`oversizedUnverifiedStoresNoBytes`:** a message with `packed.count > 262_144` is stored unverified with `unverifiedPacked == nil`.
  - **`legacyUnverifiedRowsAreLeftAlone`:** a row with `validated == false` and no bytes survives `run` untouched, and doesn't count.
- [ ] **Step 2:** Run them. Expected: FAIL (compile).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the filtered tests and the full core suite; they must pass. Then run both app builds.
- [ ] **Step 5: Mutation batch.** Apply all of these at once:
  - don't store the bytes;
  - drop `validated = 1` from the count;
  - in the re-check, mark every row validated;
  - don't delete forged rows (leave them);
  - change the size limit to `>=`/`<`, or drop it;
  - make `.pathLearned` skip the re-check.

  Every new test must fail. Revert, then confirm green.
- [ ] **Step 6:** Commit: `fix: store unverified messages for a later signature check, keep them out of unread counts`.

### Task 3: App views, the "Unverified sender" marker (parallel, worktree `ReTiCaMsgr-forgery-ui`)

**Files:**
- `ReTiCaMsgr/ChatView.swift`: the incoming bubble.
- `ReTiCaMsgr/ConversationListView.swift`: the row preview.
- Either `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Conversation.swift`, adding `lastIsUnverified: Bool` to `Conversation`, set in `Conversation.list(from:)` from the newest message's `!isOutgoing && !validated`, or an equivalent the builder prefers.
- Test: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/ConversationListUnverifiedTests.swift`.

**Interfaces:**
- Produces:
  - `Conversation.lastIsUnverified: Bool`, defaulting to false;
  - **view marker:** an incoming message with `validated == false` shows a small label above or below the bubble: `Label("Unverified sender", systemImage: "exclamationmark.shield")` in `.caption2`, tinted orange;
  - **list marker:** when `lastIsUnverified`, the preview line is prefixed with the same icon and the text "Unverified sender · ".
- iOS and macOS share the same views. No `#if` is needed.

- [ ] **Step 1: Write the failing tests:**
  - `listMarksLatestUnverifiedIncoming`: newest message incoming and unvalidated gives `lastIsUnverified == true`.
  - `listDoesNotMarkValidatedOrOutgoing`: a validated incoming or an outgoing newest message gives false.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement the model field and both view markers.
- [ ] **Step 4:** The tests pass, the full core suite passes, and both app builds are green.
- [ ] **Step 5: Mutation batch:** invert the condition, and ignore `isOutgoing`. Both tests must fail. Revert, then confirm green.
- [ ] **Step 6:** Commit: `fix: show "Unverified sender" on unverified messages and chat rows`.

### Task 4: Integration and merge order (sequential, after Tasks 1–3)

- [ ] **Step 1:** In the app worktree (`fix/forgery`), merge `fix/forgery-core` and then `fix/forgery-ui` with `--no-ff`. Resolve conflicts by keeping both sides. `Conversation.swift` and `AppFeature.swift` may touch nearby lines.
- [ ] **Step 2: Verify the app against the ReTiCA branch.**
  1. Create the symlink `/tmp/ReTiCaMsgr/ReTiCA` → `/Users/ell/development/ios/pods/ReTiCA-worktrees/forgery`.
  2. Point `ReTiCaMsgrCore/Package.swift`'s ReTiCA path at it temporarily.
  3. Run the full core suite, the iOS app suite and both builds.
  4. Restore `Package.swift` byte-identical (check with `cmp` against `git show HEAD:...`) before any commit.
- [ ] **Step 3: Add an end-to-end app test, `forgedMessageForAnotherRecipientNeverStored`.**
  - **Setup:** a TestStore wired with a real `LXMFNode` (or the existing TestStore patterns that inject `.node(.client(.endpoint(.delegate(...))))`). Bob's identity is known, and a link data packet carries Bob's message signed to Carol.
  - **Expectation:** no row is stored.
  - **Where it lives:** it only passes against the ReTiCA branch, so it is added here.
  - **Mutation:** revert Task 1's destination check in the worktree. The test must fail. Then restore.
- [ ] **Step 3b:** If Step 3's wiring is impractical in the app suite, say so in the report. Task 1's ReTiCA tests already cover this case.
- [ ] **Step 4:** Commit the integration on `fix/forgery`. **Do not merge to any main.** The controller merges after the final review, ReTiCA first and then the app.
