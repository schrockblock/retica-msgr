# ReTiCAPush: verified sender attribution and sender directory — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Notification Service Extension learn, from a pushed packet, which known sender wrote it — only when the LXMF signature verifies — and read that sender's name, public key and picture from an app-group directory the host app writes.

**Architecture:** `ReTiCAPushCore` gains `PushSender` (decrypt + unpack shared with `BlockedSenderFilter`, then signature check against a caller-supplied public key) and `SenderDirectoryStore` (JSON + content-named images in an app-group folder). `ReTiCAPushExtension.PushServiceHandler` gains `outcome(userInfo:) -> PushOutcome` (verdict + the one verified sender, if any); `handle(userInfo:)` keeps returning the verdict.

**Tech Stack:** Swift 6 strict concurrency, ReTiCA (`Identity`, `Packet`, `LXMessage`), swift-testing. Tests: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush-worktrees/sender-attribution --filter <prefix>`.

**Spec:** `/Users/ell/development/ios/apps/ReTiCaMsgr-sender-push/docs/superpowers/specs/2026-11-05-sender-in-push-design.md` (§1, §2, Constraints, Testing). The app half is `2026-11-05-app-sender-in-push.md`, which depends on this branch being merged to ReTiCAPush `main` first (the app resolves `../../../pods/ReTiCAPush`).

## Global Constraints

- Worktree: `git -C /Users/ell/development/ios/pods/ReTiCAPush worktree add -b feat/sender-attribution /Users/ell/development/ios/pods/ReTiCAPush-worktrees/sender-attribution main`. The `../ReTiCA` symlink already exists in `ReTiCAPush-worktrees/`.
- `ReTiCAPushCore` and `ReTiCAPushExtension` stay TCA-free (only tests may use `LockIsolated`).
- `BlockedSenderFilter` behaviour is unchanged: still unauthenticated, still used for the verdict.
- Display attribution requires a valid LXMF signature against the sender's known public key; anything else means no sender.
- A push names a sender only when **every** packet verifies to the **same** sender who is in the directory.
- Directory decoding never throws: missing, undecodable, or unknown-version → empty.
- Directory files: written atomically, `completeUntilFirstUserAuthentication` on iOS, folder excluded from backup.
- Hex keys are lowercase everywhere (`Data.pushHex`).
- User shell rule for anyone running commands: one command per Bash call, no pipes / `&&` / `;` / `$(...)`.
- Test verification per the user's global rule: green → mutate (one named mutation per test, batched) → all new tests red → revert → green. Each task's Mutation step lists one mutation per test.

## Review Focus

1. **A forged source hash** (Mallory's signature, Alice's hash) must yield no sender even though `BlockedSenderFilter` attributes it to Alice — Task 1 `pushSenderRejectsAForgedSourceHash`.
2. **A public key whose delivery hash isn't the claimed sender** (directory entry mixed up between two peers) must yield no sender — Task 1 `pushSenderRejectsAKeyForAnotherIdentity`.
3. **A torn directory read** (extension reads while the app rewrites) must not crash or return a half entry — Task 2 `senderDirectoryIgnoresATruncatedFile` (truncated JSON → empty).
4. **Empty blocklist** must not skip attribution (today `verdict(for:)` returns early) — Task 3 `pushOutcomeNamesASenderWithAnEmptyBlocklist`.
5. **Slow proof upload past the deadline** must not lose the sender — Task 3 `pushOutcomeKeepsTheSenderPastTheDeadline`.

---

### Task 1: `PushSender.verifiedSource`

**Files:**
- Create: `Sources/ReTiCAPushCore/PushSender.swift`
- Modify: `Sources/ReTiCAPushCore/BlockedSenderFilter.swift` (body becomes `PushSender.openMessage(...)?.sourceHash`)
- Test: `Tests/ReTiCAPushCoreTests/PushSenderTests.swift` (reuse `lxmfPacket(from:to:)` from `BlockedSenderFilterTests.swift`, it is module-internal)

**Interfaces:**
- Produces:
  - `public enum PushSender`
  - `public static func openMessage(_ raw: Data, identity: Identity, deliveryHash: Data) -> LXMessage?` — exactly today's checks in `BlockedSenderFilter.sourceHash` (private key present, no IFAC flag, DATA/SINGLE to `deliveryHash`, static-key decrypt, `LXMessage.fromOpportunistic`).
  - `public static func verifiedSource(of raw: Data, identity: Identity, deliveryHash: Data, publicKeyFor: (Data) -> Data?) -> Data?` — `openMessage`, then `publicKeyFor(message.sourceHash)` → `Identity(publicKey:)` → require `LXMessage.deliveryHash(identityHash: sender.hash) == message.sourceHash` → require `message.validateSignature(source: sender)` → return `message.sourceHash`.

- [ ] **Step 1: Write the failing tests** (add a file-private helper `forgedPacket(claiming victim: Identity, signedBy forger: Identity, to me: Identity) -> Data`: build `LXMessage.create(source: forger, …)`, take `opportunisticPayload`, replace its first 16 bytes with `victim.lxmfDeliveryHash`, then `Packet.data(to: dest, plaintext:)`.)

```swift
@Test func pushSenderVerifiesASignedPacket() {
    let me = Identity(), alice = Identity()
    let raw = lxmfPacket(from: alice, to: me)
    let keys = [alice.lxmfDeliveryHash: alice.publicKey]
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { keys[$0] }) == alice.lxmfDeliveryHash)
}

@Test func pushSenderRejectsAForgedSourceHash() {
    let me = Identity(), alice = Identity(), mallory = Identity()
    let raw = forgedPacket(claiming: alice, signedBy: mallory, to: me)
    // The unauthenticated filter is fooled; the verified path is not.
    #expect(BlockedSenderFilter.sourceHash(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash) == alice.lxmfDeliveryHash)
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { _ in alice.publicKey }) == nil)
}

@Test func pushSenderRejectsAKeyForAnotherIdentity() {
    // Mallory claims Alice's hash and signs with her own key; a lookup that hands back Mallory's
    // key for Alice's hash would validate the signature. Only the hash-equality check stops it.
    let me = Identity(), alice = Identity(), mallory = Identity()
    let raw = forgedPacket(claiming: alice, signedBy: mallory, to: me)
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { _ in mallory.publicKey }) == nil)
}

@Test func pushSenderRejectsAnUnknownSender() {
    let me = Identity()
    let raw = lxmfPacket(from: Identity(), to: me)
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { _ in nil }) == nil)
}

@Test func pushSenderRejectsAnUnparseableKey() {
    let me = Identity()
    let raw = lxmfPacket(from: Identity(), to: me)
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { _ in Data(repeating: 1, count: 3) }) == nil)
}

@Test func pushSenderRejectsALinkRequest() throws {
    let me = Identity()
    let linkRequest = try Packet(packetType: .linkRequest, destinationType: .single,
                                 destinationHash: me.lxmfDeliveryHash, payload: Data(repeating: 7, count: 64)).packed()
    #expect(PushSender.verifiedSource(of: linkRequest, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { _ in Identity().publicKey }) == nil)
}

@Test func pushSenderOpenMessageMatchesTheFilter() {
    let me = Identity(), alice = Identity()
    let raw = lxmfPacket(from: alice, to: me)
    #expect(PushSender.openMessage(raw, identity: me, deliveryHash: me.lxmfDeliveryHash)?.sourceHash
            == alice.lxmfDeliveryHash)
    #expect(PushSender.openMessage(raw, identity: me, deliveryHash: Identity().lxmfDeliveryHash) == nil)
}
```

- [ ] **Step 2: Run, expect a compile failure** (`PushSender` undefined): `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush-worktrees/sender-attribution --filter pushSender`
- [ ] **Step 3: Implement `PushSender`** in `PushSender.swift`, move the checks out of `BlockedSenderFilter.sourceHash` into `openMessage`, and make `sourceHash` call it. Doc comment: verified, unlike `BlockedSenderFilter`; the caller supplies keys it already trusts.
- [ ] **Step 4: Run `--filter pushSender` and `--filter blockedSenderFilter`** — all pass (the existing filter tests prove the refactor kept behaviour).
- [ ] **Step 5: Mutation check** (one batch; all 7 new tests must fail):
  - `pushSenderVerifiesASignedPacket` ← return nil when `publicKeyFor` returns a key (invert final return) — *run alone*, it masks the rejection tests.
  - Batch B (restore the above first):
    - `pushSenderRejectsAForgedSourceHash` ← drop the `validateSignature` check.
    - `pushSenderRejectsAKeyForAnotherIdentity` ← drop the delivery-hash equality check (the signature is valid under Mallory's key, so nothing else catches it).
    - `pushSenderRejectsAnUnknownSender` ← when `publicKeyFor` returns nil, return `message.sourceHash`.
    - `pushSenderRejectsAnUnparseableKey` ← when `Identity(publicKey:)` fails, return `message.sourceHash`.
    - `pushSenderRejectsALinkRequest` ← in `verifiedSource`, when `openMessage` returns nil, return `Data(repeating: 0, count: 16)`. (The packet-type check itself stays covered by the existing `blockedSenderFilter…` tests, which now run through `openMessage`.)
    - `pushSenderOpenMessageMatchesTheFilter` ← skip the `destinationHash == deliveryHash` check.
  Report a table (test → mutation → red?). Revert, rerun green.
- [ ] **Step 6: Commit** `feat(core): PushSender — signature-verified sender for a pushed packet`.

### Task 2: `SenderDirectoryStore`

**Files:**
- Create: `Sources/ReTiCAPushCore/SenderDirectory.swift`
- Modify: `Sources/ReTiCAPushCore/PushStorage.swift`
- Test: `Tests/ReTiCAPushCoreTests/SenderDirectoryStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct SenderDirectory: Equatable, Sendable { public static let version = 1; public var entries: [String: Entry]; public static let empty }`
  - `public struct SenderDirectory.Entry: Codable, Equatable, Sendable { public var name: String?; public var publicKey: Data; public var imageFile: String? }`
  - `public struct SenderDirectory.Input: Equatable, Sendable { public var name: String?; public var publicKey: Data; public var imageData: Data? }` (what the app hands in)
  - `public struct SenderDirectoryStore: Sendable { public let directory: URL; public init(directory: URL); public func save(_ inputs: [String: SenderDirectory.Input]) throws; public func load() -> SenderDirectory; public func imageURL(for entry: SenderDirectory.Entry) -> URL? }`
  - `PushStorage.sendersDirectory: URL` (new stored property; `init(inboxDirectory:settingsSuiteName:sendersDirectory:)` with default `inboxDirectory.deletingLastPathComponent().appending(path: "senders", directoryHint: .isDirectory)`), `init(containerURL:appGroupID:)` → `<container>/ReTiCAPush/senders`, `temporary()` → `<tmp>/<suite>/inbox` and `<tmp>/<suite>/senders`, and `public var senderDirectory: SenderDirectoryStore`.
- File format: `directory.json` = `{"v":1,"entries":{"<hex>":{...Entry}}}`; images `<sha256 hex of bytes>.jpg` beside it. `save` lowercases keys, writes images that don't already exist, writes JSON to a temp file then `replaceItemAt`, then deletes `*.jpg` no entry names. `load` returns `.empty` on any failure or `v != 1`, lowercases keys.

- [ ] **Step 1: Write the failing tests**

```swift
private func store() -> SenderDirectoryStore {
    SenderDirectoryStore(directory: FileManager.default.temporaryDirectory
        .appending(path: "SenderDirectory-\(UUID().uuidString)", directoryHint: .isDirectory))
}
private let keyA = Data(repeating: 0xA1, count: 64), keyB = Data(repeating: 0xB2, count: 64)
private let hexA = String(repeating: "a", count: 32), hexB = String(repeating: "b", count: 32)

@Test func senderDirectoryRoundTripsNamesKeysAndImages() throws {
    let s = store()
    try s.save([hexA: .init(name: "Alice", publicKey: keyA, imageData: Data([1, 2, 3])),
                hexB: .init(name: nil, publicKey: keyB, imageData: nil)])
    let dir = s.load()
    #expect(dir.entries[hexA]?.name == "Alice")
    #expect(dir.entries[hexA]?.publicKey == keyA)
    #expect(try Data(contentsOf: #require(s.imageURL(for: #require(dir.entries[hexA])))) == Data([1, 2, 3]))
    #expect(dir.entries[hexB]?.imageFile == nil)
}

@Test func senderDirectoryLowercasesKeys() throws {
    let s = store()
    try s.save([hexA.uppercased(): .init(name: "Alice", publicKey: keyA, imageData: nil)])
    #expect(s.load().entries[hexA]?.name == "Alice")
}

@Test func senderDirectoryRemovesImagesNoEntryNames() throws {
    let s = store()
    try s.save([hexA: .init(name: "A", publicKey: keyA, imageData: Data([1]))])
    try s.save([hexA: .init(name: "A", publicKey: keyA, imageData: Data([2]))])
    let jpgs = try FileManager.default.contentsOfDirectory(atPath: s.directory.path).filter { $0.hasSuffix(".jpg") }
    #expect(jpgs.count == 1)
}

@Test func senderDirectoryIsEmptyWhenMissing() {
    #expect(store().load() == .empty)
}

@Test func senderDirectoryIgnoresATruncatedFile() throws {
    let s = store()
    try s.save([hexA: .init(name: "A", publicKey: keyA, imageData: nil)])
    let json = s.directory.appending(path: "directory.json")
    let bytes = try Data(contentsOf: json)
    try bytes.prefix(bytes.count / 2).write(to: json)
    #expect(s.load() == .empty)
}

@Test func senderDirectoryIgnoresAnUnknownVersion() throws {
    let s = store()
    try s.save([hexA: .init(name: "A", publicKey: keyA, imageData: nil)])
    let json = s.directory.appending(path: "directory.json")
    let text = try String(contentsOf: json, encoding: .utf8).replacingOccurrences(of: "\"v\":1", with: "\"v\":2")
    try Data(text.utf8).write(to: json)
    #expect(s.load() == .empty)
}

@Test func pushStorageSendersDirectoryIsBesideTheInbox() {
    let container = URL(filePath: "/tmp/container", directoryHint: .isDirectory)
    let storage = PushStorage(containerURL: container, appGroupID: "group.x")
    #expect(storage.sendersDirectory.path().hasSuffix("ReTiCAPush/senders/"))
    #expect(PushStorage.temporary().sendersDirectory != PushStorage.temporary().sendersDirectory)
}
```

(Encode with `JSONEncoder` `.sortedKeys` so the `"v":1` replacement in the version test is exact; if the encoder emits spaces, adjust the test string, not the format.)

- [ ] **Step 2: Run, expect compile failure:** `--filter senderDirectory` and `--filter pushStorage`.
- [ ] **Step 3: Implement** `SenderDirectory.swift` and the `PushStorage` changes. On iOS write files with `.completeFileProtectionUntilFirstUserAuthentication`, and set `isExcludedFromBackup` on the folder (copy `AvatarStore`'s pattern from the app). Image names: SHA-256 via CryptoKit `SHA256` (or ReTiCA `Crypto.fullHash`).
- [ ] **Step 4: Run** the filters plus the full `ReTiCAPushCoreTests` target — all green (existing `PushStorage` tests still pass with the new property).
- [ ] **Step 5: Mutation check** (one batch unless noted; 7 tests):
  - `…RoundTripsNamesKeysAndImages` ← `save` never writes image files.
  - `…LowercasesKeys` ← drop lowercasing in both `save` and `load`.
  - `…RemovesImagesNoEntryNames` ← skip the orphan sweep.
  - `…IsEmptyWhenMissing` ← `load` returns a fixed one-entry directory when the file is missing.
  - `…IgnoresATruncatedFile` ← on decode failure, return the last good cache (a static) — isolated run, because the missing-file mutation above would mask it.
  - `…IgnoresAnUnknownVersion` ← drop the `v` check.
  - `pushStorageSendersDirectoryIsBesideTheInbox` ← `init(containerURL:)` uses `ReTiCAPush/inbox` for senders too.
  Table, revert, green.
- [ ] **Step 6: Commit** `feat(core): SenderDirectoryStore in the app group`.

### Task 3: `PushOutcome` from the service handler, and the contract amendment

**Files:**
- Modify: `Sources/ReTiCAPushExtension/PushServiceHandler.swift`
- Modify: `docs/server-contract.md` (§3 "never changes it", §4 item 2)
- Test: `Tests/ReTiCAPushExtensionTests/PushOutcomeTests.swift` (copy the private helpers from `PushVerdictTests.swift`; add `forgedPacket` as in Task 1)

**Interfaces:**
- Consumes: `PushSender.verifiedSource`, `SenderDirectory`, `PushStorage.senderDirectory` (Tasks 1–2).
- Produces:
  - `public struct PushSenderMatch: Equatable, Sendable { public var hex: String; public var entry: SenderDirectory.Entry; public var imageURL: URL? }`
  - `public struct PushOutcome: Equatable, Sendable { public var verdict: PushVerdict; public var sender: PushSenderMatch? }`
  - `PushServiceHandler.init(..., senders: SenderDirectory = .empty, sendersStore: SenderDirectoryStore? = nil, ...)` (the store only resolves `imageURL`); `live(storage:)` loads `storage.senderDirectory.load()`.
  - `public func outcome(userInfo:) async -> PushOutcome`; `handle(userInfo:)` becomes `await outcome(userInfo:).verdict`.
  - `static func sender(for packets: [Data], identity: Identity?, senders: SenderDirectory) -> String?` — the hex when every packet verifies (public key from `senders.entries[hex]`) to one hex; nil otherwise. Computed in `process` beside the verdict, stored in the same locked box (`LockedVerdict` grows into a locked `PushOutcome`), so the deadline path keeps it. Not behind the `blockedSenders.isEmpty` early return.

- [ ] **Step 1: Write the failing tests** (`directory(_ ids: Identity..., names:)` helper builds a `SenderDirectory` keyed by `lxmfDeliveryHash.pushHex` with each `publicKey`):

```swift
@Test func pushOutcomeNamesASenderWithAnEmptyBlocklist() async {
    let me = Identity(), alice = Identity()
    let out = await handler(identity: me, blocked: [], senders: directory([alice: "Alice"]))
        .outcome(userInfo: userInfo([lxmfPacket(from: alice, to: me), lxmfPacket(from: alice, to: me)]))
    #expect(out.verdict == .deliverOriginal)
    #expect(out.sender?.hex == alice.lxmfDeliveryHash.pushHex)
    #expect(out.sender?.entry.name == "Alice")
}

@Test func pushOutcomeNamesNobodyForTwoSenders() async {
    let me = Identity(), alice = Identity(), bob = Identity()
    let out = await handler(identity: me, blocked: [], senders: directory([alice: "Alice", bob: "Bob"]))
        .outcome(userInfo: userInfo([lxmfPacket(from: alice, to: me), lxmfPacket(from: bob, to: me)]))
    #expect(out.sender == nil)
}

@Test func pushOutcomeNamesNobodyWhenAnUnattributablePacketRidesAlong() async {
    let me = Identity(), alice = Identity()
    let out = await handler(identity: me, blocked: [], senders: directory([alice: "Alice"]))
        .outcome(userInfo: userInfo([lxmfPacket(from: alice, to: me), plainPacket(to: me)]))
    #expect(out.sender == nil)
}

@Test func pushOutcomeNamesNobodyForAForgery() async {
    let me = Identity(), alice = Identity(), mallory = Identity()
    let out = await handler(identity: me, blocked: [], senders: directory([alice: "Alice"]))
        .outcome(userInfo: userInfo([forgedPacket(claiming: alice, signedBy: mallory, to: me)]))
    #expect(out.sender == nil)
}

@Test func pushOutcomeNamesNobodyOutsideTheDirectory() async {
    let me = Identity()
    let out = await handler(identity: me, blocked: [], senders: .empty)
        .outcome(userInfo: userInfo([lxmfPacket(from: Identity(), to: me)]))
    #expect(out.sender == nil)
}

@Test func pushOutcomeSuppressionIsUnchanged() async {
    let me = Identity(), blocked = Identity()
    let out = await handler(identity: me, blocked: [blocked.lxmfDeliveryHash.pushHex],
                            senders: directory([blocked: "B"]))
        .outcome(userInfo: userInfo([lxmfPacket(from: blocked, to: me)]))
    #expect(out.verdict == .suppress)
}

@Test func pushOutcomeKeepsTheSenderPastTheDeadline() async {
    // Same shape as pushVerdictSurvivesASenderThatOutlivesTheDeadline: an 8 s uncancellable
    // sendFrames, a 200 ms deadline.
    let me = Identity(), alice = Identity()
    let out = await slowHandler(identity: me, senders: directory([alice: "Alice"]))
        .outcome(userInfo: userInfo([lxmfPacket(from: alice, to: me)]))
    #expect(out.sender?.entry.name == "Alice")
}
```

- [ ] **Step 2: Run, expect compile failure:** `--filter pushOutcome`.
- [ ] **Step 3: Implement** per Interfaces. Also update the doc comment on `PushServiceHandler` (it now reads the sender for display, verified). Amend `docs/server-contract.md` §3 and §4 item 2: the hub's title is still fixed and carries nothing; the client's extension may replace it on the device with a name from the client's own data, after verifying the sender's signature; it decrypts only to attribute and check.
- [ ] **Step 4: Run** `--filter pushOutcome`, `--filter pushVerdict`, `--filter pushServiceHandler` — all green (existing tests call `handle` and must not change).
- [ ] **Step 5: Mutation check** (7 tests):
  - `…WithAnEmptyBlocklist` ← compute the sender only when `!blockedSenders.isEmpty`.
  - `…ForTwoSenders` ← return the first verified hex instead of requiring one distinct hex.
  - `…WhenAnUnattributablePacketRidesAlong` ← ignore packets that fail verification (compactMap without the count check) — isolated run (the two-senders mutation could mask it).
  - `…ForAForgery` ← use `BlockedSenderFilter.sourceHash` instead of `PushSender.verifiedSource`.
  - `…OutsideTheDirectory` ← when the hex is not in `senders`, return a match with an empty entry.
  - `…SuppressionIsUnchanged` ← when a sender is named, force `.deliverOriginal`.
  - `…PastTheDeadline` ← set the sender in the box only after `sendFrames` returns.
  Table, revert, green; then the whole package `swift test --package-path …/sender-attribution` green.
- [ ] **Step 6: Commit** `feat(extension): PushOutcome names one verified sender; contract amended`.

## Hand-off

After Task 3: a whole-branch review, then ask the user before merging `feat/sender-attribution` into ReTiCAPush `main` (the app plan builds against `main`).
