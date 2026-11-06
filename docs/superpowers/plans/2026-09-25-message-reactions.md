# Message Reactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Long-press a chat bubble to get the system context-menu highlight with a palette of quick emoji reactions (❤️ 👍 👎 😂 😮 😢), a ＋ that opens a searchable full-emoji picker, and Copy; reactions are sent to the peer over LXMF and shown as badges on the bubble.

**Architecture:** A reaction is a standalone LXMF message whose `fields` carry `FIELD_CUSTOM_TYPE = "reticamsgr.reaction"` and `FIELD_CUSTOM_DATA = {target, emoji}`. Pure codec (`ReactionWire`) + a `reactions` table with last-writer-wins upsert (`Reaction.apply`) + a pure badge builder (`ReactionSummary`) live in `ReTiCAMsgrCore`; `AppFeature` routes incoming reaction messages away from the bubble path, and gains a `.reactionSelected` action. The app target adds a `.contextMenu` with a palette row, a badge view, and an `EmojiPickerSheet` backed by a bundled trimmed Unicode `emoji-test.txt` (`EmojiCatalog`).

**Tech Stack:** Swift 6, SwiftUI (iOS 26.4 app target), The Composable Architecture (TCA), swift-testing, GRDB via SQLiteData (`@Table`, structured queries). Package: `ReTiCAMsgrCore` (local SPM package inside the app repo).

**Spec:** `docs/superpowers/specs/2026-09-25-message-reactions-design.md`

## Global Constraints

- Repo: `/Users/ell/development/ios/apps/ReTiCAMsgr`. Core edits in `ReTiCAMsgrCore`; UI edits in `ReTiCAMsgr/`. **No edits to the ReTiCA library** (`/Users/ell/development/ios/pods/ReTiCA`).
- Commit directly to `main`. No feature branch.
- Commit trailers start at **column 0**. Every commit message ends with exactly:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- **One command per shell invocation.** No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, and no inline scripts (`python -c`, `swift -e`, heredocs into interpreters). Write scripts to a file, then run the file. Temp files go in `/tmp/ReTiCAMsgr/`.
- Core tests: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --filter <TestNameOrSuite>`; full suite without `--filter`.
- App build: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build` (run `xcodebuild -list -project …` once if the scheme name differs). The app target uses file-system-synchronized groups: new `.swift` files under `ReTiCAMsgr/` are picked up with no `project.pbxproj` edit.
- **Mutation verification is mandatory** for every task with tests: tests green → apply the task's listed mutation(s) in one batch → run the task's tests, confirm every new test goes RED → revert → confirm GREEN → commit.
- **Keep `store.exhaustivity = .off`** (set by `makeStore` in `AppFeatureTests.swift`). Do not flip it.
- Wire constants (verbatim from spec): `FIELD_CUSTOM_TYPE = 0xFB`, `FIELD_CUSTOM_DATA = 0xFC`, type string `"reticamsgr.reaction"`, data keys `"target"` (bin, 16–32 bytes) and `"emoji"` (str; `""` = removal), emoji ≤ `ReactionWire.maxEmojiBytes` = 64 UTF-8 bytes.
- Quick reactions, in order: `["❤️", "👍", "👎", "😂", "😮", "😢"]`.
- Whole-row tappability rule (user's global): custom tappable cells get `.frame(maxWidth: .infinity, …)` + `.contentShape(Rectangle())`.

## Review Focus

1. **Two of my reactions in the same clock tick** (tap ❤️ then tap ❤️ again instantly, or a frozen test clock) — the second must still win; own `sentAt` is forced strictly monotonic. Pinned in Task 4 (`reactionSelectedTogglesOffWithFrozenClock`).
2. **Reaction arrives before its target message** (propagation reordering) — badge appears once the message arrives. Pinned in Task 4 (`reactionBeforeTargetShowsOnceTargetArrives`).
3. **Peer reacts to *my* outgoing message** — the badge must appear on my bubble (target matches an outgoing row's `messageHash`). Pinned in Task 4 (`peerReactionOnMyOutgoingMessageShows`).
4. **Phase-2-style reaction with non-empty `content`** (fallback text) — must still not become a bubble. Pinned in Task 3 (`reactionWithFallbackContentIsNotABubble`).
5. **Longest catalog emoji vs. the wire limit** — every pickable emoji must survive `ReactionWire.decode`. Pinned in Task 5 (`everyCatalogEmojiFitsWireLimit`).

---

### Task 1: `ReactionWire` codec + `QuickReactions`

**Files:**
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReactionWire.swift`
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReactionWireTests.swift`

**Interfaces:**
- Consumes: `MsgPackValue` (`.string`, `.bin`, `.map([Pair])`, `.intMap`), `MsgPackValue.IntPair(_ key: Int, _ value:)`, `MsgPackValue.Pair(_ key: String, _ value:)`, `LXMessage.create(source:destinationHash:timestamp:title:content:fields:)`, `LXMessage.unpack(_:) -> LXMessage?`, `LXMessage.packed` — all from ReTiCA.
- Produces:
  - `public enum ReactionWire` with `static let fieldCustomType = 0xFB`, `static let fieldCustomData = 0xFC`, `static let customType = "reticamsgr.reaction"`, `static let maxEmojiBytes = 64`, `static let targetLengths = 16...32`
  - `public enum ReactionWire.Decoded: Equatable, Sendable { case notReaction; case reaction(target: Data, emoji: String); case malformed }`
  - `public static func encode(target: Data, emoji: String) -> [MsgPackValue.IntPair]`
  - `public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded`
  - `public enum QuickReactions { public static let `default`: [String] }`

- [ ] **Step 1: Write the failing tests**

`ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReactionWireTests.swift`:
```swift
import Testing
import Foundation
import ReTiCA
@testable import ReTiCAMsgrCore

private let target32 = Data(repeating: 0xAB, count: 32)

@Test func reactionRoundTripsThroughRealLXMessagePackUnpack() throws {
    let sender = Identity()
    let m = LXMessage.create(
        source: sender,
        destinationHash: Data(repeating: 0x11, count: 16),
        timestamp: 1700000000.25,
        title: Data(),
        content: Data(),
        fields: ReactionWire.encode(target: target32, emoji: "❤️")
    )
    let back = try #require(LXMessage.unpack(m.packed))
    #expect(ReactionWire.decode(back.fields) == .reaction(target: target32, emoji: "❤️"))
}

@Test func emptyEmojiRoundTripsAsRemoval() {
    let fields = ReactionWire.encode(target: target32, emoji: "")
    #expect(ReactionWire.decode(fields) == .reaction(target: target32, emoji: ""))
}

@Test func noFieldsIsNotAReaction() {
    #expect(ReactionWire.decode([]) == .notReaction)
}

@Test func otherCustomTypeIsNotAReaction() {
    let fields: [MsgPackValue.IntPair] = [.init(0xFB, .string("someone.else")), .init(0xFC, .map([]))]
    #expect(ReactionWire.decode(fields) == .notReaction)
}

@Test func unrelatedFieldsAreNotAReaction() {
    let fields: [MsgPackValue.IntPair] = [.init(0x04, .array([]))]
    #expect(ReactionWire.decode(fields) == .notReaction)
}

@Test func missingDataIsMalformed() {
    let fields: [MsgPackValue.IntPair] = [.init(0xFB, .string("reticamsgr.reaction"))]
    #expect(ReactionWire.decode(fields) == .malformed)
}

@Test func missingTargetIsMalformed() {
    let fields: [MsgPackValue.IntPair] = [
        .init(0xFB, .string("reticamsgr.reaction")),
        .init(0xFC, .map([.init("emoji", .string("👍"))])),
    ]
    #expect(ReactionWire.decode(fields) == .malformed)
}

@Test func badTargetLengthsAreMalformed() {
    for n in [0, 15, 33] {
        let fields = ReactionWire.encode(target: Data(repeating: 1, count: n), emoji: "👍")
        #expect(ReactionWire.decode(fields) == .malformed, "length \(n)")
    }
    for n in [16, 32] {
        let fields = ReactionWire.encode(target: Data(repeating: 1, count: n), emoji: "👍")
        #expect(ReactionWire.decode(fields) != .malformed, "length \(n)")
    }
}

@Test func nonStringEmojiIsMalformed() {
    let fields: [MsgPackValue.IntPair] = [
        .init(0xFB, .string("reticamsgr.reaction")),
        .init(0xFC, .map([.init("target", .bin(target32)), .init("emoji", .bin(Data([0xF0])))])),
    ]
    #expect(ReactionWire.decode(fields) == .malformed)
}

@Test func oversizedEmojiIsMalformed() {
    let tooLong = String(repeating: "a", count: ReactionWire.maxEmojiBytes + 1)
    #expect(ReactionWire.decode(ReactionWire.encode(target: target32, emoji: tooLong)) == .malformed)
    let atLimit = String(repeating: "a", count: ReactionWire.maxEmojiBytes)
    #expect(ReactionWire.decode(ReactionWire.encode(target: target32, emoji: atLimit))
            == .reaction(target: target32, emoji: atLimit))
}

@Test func quickReactionsAreTheAgreedSix() {
    #expect(QuickReactions.default == ["❤️", "👍", "👎", "😂", "😮", "😢"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --filter ReactionWireTests`
Expected: build FAILS — `cannot find 'ReactionWire' in scope`.

- [ ] **Step 3: Implement**

`ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReactionWire.swift`:
```swift
import Foundation
import ReTiCA

/// Wire codec for an emoji reaction carried in LXMF `fields`.
///
/// Uses LXMF's reserved extension keys rather than inventing a field number:
/// `FIELD_CUSTOM_TYPE` (0xFB) names the extension, `FIELD_CUSTOM_DATA` (0xFC) carries
/// `{ "target": bin, "emoji": str }`. An empty `emoji` means "I removed my reaction".
/// A message whose custom type matches is a reaction regardless of its `content`, so a later
/// human-readable fallback in `content` never renders as a bubble in this app.
public enum ReactionWire {
    public static let fieldCustomType = 0xFB
    public static let fieldCustomData = 0xFC
    public static let customType = "reticamsgr.reaction"
    /// Upper bound on the emoji's UTF-8 size. Generous enough for any ZWJ sequence with skin
    /// tones; small enough that a peer can't stuff a paragraph into a badge.
    public static let maxEmojiBytes = 64
    public static let targetLengths = 16...32

    public enum Decoded: Equatable, Sendable {
        /// Not our extension — handle as an ordinary message.
        case notReaction
        case reaction(target: Data, emoji: String)
        /// Claims to be a reaction but the payload is unusable — drop it.
        case malformed
    }

    public static func encode(target: Data, emoji: String) -> [MsgPackValue.IntPair] {
        [
            .init(fieldCustomType, .string(customType)),
            .init(fieldCustomData, .map([
                .init("target", .bin(target)),
                .init("emoji", .string(emoji)),
            ])),
        ]
    }

    public static func decode(_ fields: [MsgPackValue.IntPair]) -> Decoded {
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

public enum QuickReactions {
    public static let `default`: [String] = ["❤️", "👍", "👎", "😂", "😮", "😢"]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --filter ReactionWireTests`
Expected: all 11 PASS.

- [ ] **Step 5: Mutation check**

Apply in one batch:
- (a) in `decode`, first guard: `return .notReaction` → `return .malformed`
- (b) in `decode`, final `else { return .malformed }` → `else { return .notReaction }`
- (c) in `encode`, `.bin(target)` → `.bin(Data())`
- (d) in `QuickReactions`, swap `"👍"` and `"👎"`

Run the same command. Expected: all 11 RED — round-trip, removal, bad-lengths (16/32 half), oversized (at-limit half) via (c); no-fields, other-type, unrelated via (a); missing-data, missing-target, non-string via (b); quick via (d). Revert all; re-run; confirm all GREEN.

- [ ] **Step 6: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReactionWire.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReactionWireTests.swift
git -C /Users/ell/development/ios/apps/ReTiCAMsgr commit -m "feat: ReactionWire codec for LXMF custom reaction fields" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
(Two separate commands.)

---

### Task 2: `Reaction` table, LWW `apply`, and `ReactionSummary`

**Files:**
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Reaction.swift`
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReactionSummary.swift`
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Database.swift` — append a `createReactions` migration after `createDedupPersistence`, before `return m`.
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReactionTests.swift`

**Interfaces:**
- Consumes: `AppDatabase.makeInMemory()`.
- Produces:
  - `@Table public struct Reaction: Equatable, Sendable { messageHash: String; reactorHex: String; emoji: String; sentAt: Double }` with `public init(messageHash:reactorHex:emoji:sentAt:)`. Table name `reactions`. `sentAt` is seconds since 1970 as a `Double` (stored REAL, so LWW comparisons are exact — no Date text rounding).
  - `@discardableResult public static func apply(_ r: Reaction, _ db: GRDB.Database) throws -> Bool` — upserts iff no row exists for `(messageHash, reactorHex)` or `r.sentAt > existing.sentAt`; returns whether it wrote.
  - `public enum ReactionSummary { public struct Item: Equatable, Sendable { emoji: String; count: Int; includesMe: Bool }; public static func summarize(_ rows: [Reaction], me: String) -> [Item]; public static func byMessage(_ rows: [Reaction], me: String) -> [String: [Item]] }` — `byMessage` omits hashes whose summary is empty.

- [ ] **Step 1: Write the failing tests**

`ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReactionTests.swift`:
```swift
import Testing
import Foundation
import GRDB
import SQLiteData
@testable import ReTiCAMsgrCore

private let h1 = String(repeating: "1", count: 64)
private let h2 = String(repeating: "2", count: 64)
private let me = String(repeating: "e", count: 32)
private let peer = String(repeating: "p", count: 32)

private func r(_ hash: String = h1, _ reactor: String = peer, _ emoji: String, _ at: Double) -> Reaction {
    Reaction(messageHash: hash, reactorHex: reactor, emoji: emoji, sentAt: at)
}

private func all(_ db: any DatabaseWriter) throws -> [Reaction] {
    try db.read { try Reaction.all.fetchAll($0) }
}

@Test func applyInsertsWhenAbsent() throws {
    let db = try AppDatabase.makeInMemory()
    let wrote = try db.write { try Reaction.apply(r("❤️", 10), $0) }
    #expect(wrote)
    #expect(try all(db) == [r("❤️", 10)])
}

@Test func applyNewerReplaces() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try Reaction.apply(r("❤️", 10), $0) }
    try db.write { try Reaction.apply(r("👍", 11), $0) }
    #expect(try all(db) == [r("👍", 11)])
}

@Test func applyOlderIsIgnored() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try Reaction.apply(r("👍", 11), $0) }
    let wrote = try db.write { try Reaction.apply(r("❤️", 10), $0) }
    #expect(!wrote)
    #expect(try all(db) == [r("👍", 11)])
}

@Test func applyEqualTimestampIsIgnored() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try Reaction.apply(r("👍", 11), $0) }
    let wrote = try db.write { try Reaction.apply(r("❤️", 11), $0) }
    #expect(!wrote)
    #expect(try all(db) == [r("👍", 11)])
}

@Test func tombstoneBeatsLateOlderAdd() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try Reaction.apply(r("", 20), $0) }        // removal arrives first
    try db.write { try Reaction.apply(r("❤️", 10), $0) }      // the older add, late
    #expect(try all(db) == [r("", 20)])
}

@Test func reactorsAndMessagesAreIndependentKeys() throws {
    let db = try AppDatabase.makeInMemory()
    try db.write { try Reaction.apply(r(h1, peer, "❤️", 10), $0) }
    try db.write { try Reaction.apply(r(h1, me, "😂", 5), $0) }
    try db.write { try Reaction.apply(r(h2, peer, "👍", 1), $0) }
    #expect(try all(db).count == 3)
}

@Test func summaryDropsTombstonesCountsAndFlagsMe() {
    let rows = [
        r(h1, peer, "❤️", 2),
        r(h1, me, "❤️", 3),
        r(h1, "x", "", 1),          // tombstone
    ]
    #expect(ReactionSummary.summarize(rows, me: me) == [.init(emoji: "❤️", count: 2, includesMe: true)])
}

@Test func summaryOrdersByEarliestSentAt() {
    let rows = [r(h1, peer, "😂", 5), r(h1, me, "👍", 1)]
    #expect(ReactionSummary.summarize(rows, me: me).map(\.emoji) == ["👍", "😂"])
    #expect(ReactionSummary.summarize(rows, me: me).map(\.includesMe) == [true, false])
}

@Test func byMessageGroupsAndOmitsAllTombstoneMessages() {
    let rows = [r(h1, peer, "😂", 5), r(h2, peer, "", 6)]
    let grouped = ReactionSummary.byMessage(rows, me: me)
    #expect(grouped.keys.sorted() == [h1])
    #expect(grouped[h1] == [.init(emoji: "😂", count: 1, includesMe: false)])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --filter ReactionTests`
Expected: build FAILS — `cannot find 'Reaction' in scope`.

- [ ] **Step 3: Implement**

Append to `AppDatabase.migrator()` in `Database.swift`, immediately before `return m`:
```swift
        m.registerMigration("createReactions") { db in
            // One row per (message, reactor): Signal/iMessage semantics, one reaction per person.
            // Removals are tombstones (emoji = "") so a late, older add can't resurrect them.
            // sentAt is REAL seconds-since-1970 so last-writer-wins comparisons are exact.
            try db.create(table: "reactions") { t in
                t.column("messageHash", .text).notNull()
                t.column("reactorHex", .text).notNull()
                t.column("emoji", .text).notNull()
                t.column("sentAt", .double).notNull()
                t.primaryKey(["messageHash", "reactorHex"])
            }
        }
```

`ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Reaction.swift`:
```swift
import Foundation
import GRDB
import SQLiteData

/// One person's current reaction to one message. `messageHash` is the target's LXMF hash (hex);
/// `reactorHex` is the reactor's lxmf.delivery hash (hex) — the peer's, or our own
/// `myAddressHex`. `emoji == ""` is a tombstone (reaction removed). `sentAt` is the reaction
/// LXMessage's own timestamp, i.e. the reactor's clock.
@Table
public struct Reaction: Equatable, Sendable {
    public var messageHash: String
    public var reactorHex: String
    public var emoji: String
    public var sentAt: Double

    public init(messageHash: String, reactorHex: String, emoji: String, sentAt: Double) {
        self.messageHash = messageHash
        self.reactorHex = reactorHex
        self.emoji = emoji
        self.sentAt = sentAt
    }

    /// Last-writer-wins upsert. Writes only if there is no row for (messageHash, reactorHex) or
    /// `r.sentAt` is strictly newer; an equal timestamp is a duplicate delivery and is ignored.
    @discardableResult
    public static func apply(_ r: Reaction, _ db: GRDB.Database) throws -> Bool {
        let existing = try Reaction
            .where { $0.messageHash.eq(r.messageHash) && $0.reactorHex.eq(r.reactorHex) }
            .fetchOne(db)
        if let existing, existing.sentAt >= r.sentAt { return false }
        try Reaction
            .where { $0.messageHash.eq(r.messageHash) && $0.reactorHex.eq(r.reactorHex) }
            .delete()
            .execute(db)
        try Reaction.insert { r }.execute(db)
        return true
    }
}
```

`ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReactionSummary.swift`:
```swift
import Foundation

/// Turns raw reaction rows into badge data.
public enum ReactionSummary {
    public struct Item: Equatable, Sendable {
        public var emoji: String
        public var count: Int
        public var includesMe: Bool
        public init(emoji: String, count: Int, includesMe: Bool) {
            self.emoji = emoji
            self.count = count
            self.includesMe = includesMe
        }
    }

    /// Badge items for one message's rows: tombstones dropped, grouped by emoji, ordered by the
    /// earliest `sentAt` among each emoji's reactors.
    public static func summarize(_ rows: [Reaction], me: String) -> [Item] {
        let live = rows.filter { !$0.emoji.isEmpty }
        let grouped = Dictionary(grouping: live, by: \.emoji)
        return grouped
            .map { emoji, rs in
                (first: rs.map(\.sentAt).min() ?? 0,
                 item: Item(emoji: emoji, count: rs.count, includesMe: rs.contains { $0.reactorHex == me }))
            }
            .sorted { $0.first < $1.first }
            .map(\.item)
    }

    /// `summarize` per message hash; hashes with no live reactions are omitted.
    public static func byMessage(_ rows: [Reaction], me: String) -> [String: [Item]] {
        Dictionary(grouping: rows, by: \.messageHash)
            .mapValues { summarize($0, me: me) }
            .filter { !$0.value.isEmpty }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --filter ReactionTests`
Expected: all 9 PASS. Then run the full suite (no `--filter`) — the new migration must not break existing tests.

- [ ] **Step 5: Mutation check**

Apply in one batch:
- (a) in `apply`, replace `try Reaction.insert { r }.execute(db)` with
  `try Reaction.insert { Reaction(messageHash: r.messageHash, reactorHex: r.reactorHex, emoji: r.emoji, sentAt: r.sentAt + 100) }.execute(db)`
- (b) in `apply`, the `delete()` query's where clause → `.where { $0.messageHash.eq(r.messageHash) }` (drops the reactor key)
- (c) in `summarize`, `let live = rows.filter { !$0.emoji.isEmpty }` → `let live = rows`
- (d) in `summarize`, `.sorted { $0.first < $1.first }` → `.sorted { $0.first > $1.first }`

Run `--filter ReactionTests`. Expected: all 9 RED — the five `apply` tests via (a) (stored `sentAt` is off by 100); independent-keys via (b) (h1/me deletes h1/peer → count 2); summary-tombstones and byMessage via (c); ordering via (d). Revert; confirm GREEN.

- [ ] **Step 6: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Reaction.swift ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/ReactionSummary.swift ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Database.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/ReactionTests.swift
git -C /Users/ell/development/ios/apps/ReTiCAMsgr commit -m "feat: reactions table with last-writer-wins apply and badge summary" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Receive path — store incoming hash, route reaction messages

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift` — the `.node(.client(.delegate(.messageReceived(m, validated))))` case (currently `:558-614`) and add a file-scope `recordSeenHash` helper next to `pruneSeenHashes` (`:946`).
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` — append tests at the end of the file.

**Interfaces:**
- Consumes: `ReactionWire.decode`, `Reaction`, `Reaction.apply` (Tasks 1–2); existing `reloadThread`, `reloadConversations`, `pruneSeenHashes`, `SeenHashRow`.
- Produces: `private func recordSeenHash(_ hashHex: String, at: Date, _ db: GRDB.Database) throws` (file-scope). Incoming `Message` rows now have `messageHash == m.hash.hexString`. Incoming reactions persist to `reactions` with `reactorHex = m.sourceHash.hexString`, `sentAt = m.timestamp`.

- [ ] **Step 1: Write the failing tests**

Append to `AppFeatureTests.swift` (uses the file's existing private `makeStore`):
```swift
// MARK: - Reactions: receive path

private func reactionMessage(from sender: Identity, to me: Identity, target: Data, emoji: String,
                             at ts: Double, content: String = "") -> LXMessage {
    LXMessage.create(
        source: sender,
        destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: ts,
        title: Data(),
        content: Data(content.utf8),
        fields: ReactionWire.encode(target: target, emoji: emoji)
    )
}

@MainActor @Test func incomingTextMessageStoresItsHash() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me)
    let m = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                             timestamp: 1700000000.5, title: Data(), content: Data("hi".utf8))
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    let rows = try! await db.read { try Message.all.fetchAll($0) }
    #expect(rows.map(\.messageHash) == [m.hash.hexString])
}

@MainActor @Test func incomingReactionIsStoredAndNotABubble() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let target = Data(repeating: 0x42, count: 32)
    let store = makeStore(db, identity: me)
    let m = reactionMessage(from: sender, to: me, target: target, emoji: "😂", at: 1700000001)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    let seen = try! await db.read { try SeenHashRow.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions == [Reaction(messageHash: target.hexString, reactorHex: senderHex, emoji: "😂", sentAt: 1700000001)])
    #expect(seen.map(\.hashHex) == [m.hash.hexString])
    #expect(store.state.conversations.isEmpty)
}

@MainActor @Test func reactionWithFallbackContentIsNotABubble() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me)
    let m = reactionMessage(from: sender, to: me, target: Data(repeating: 1, count: 32), emoji: "❤️",
                            at: 1700000001, content: "Reacted ❤️ to \"hi\"")
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions.count == 1)
}

@MainActor @Test func unvalidatedReactionIsDropped() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me)
    let m = reactionMessage(from: Identity(), to: me, target: Data(repeating: 1, count: 32), emoji: "❤️", at: 1)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: false)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    let seen = try! await db.read { try SeenHashRow.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions.isEmpty)
    #expect(seen.count == 1)
}

@MainActor @Test func malformedReactionIsDroppedNotABubble() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let store = makeStore(db, identity: me)
    let m = LXMessage.create(source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                             timestamp: 1, title: Data(), content: Data(),
                             fields: [.init(0xFB, .string("reticamsgr.reaction"))])
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true)))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let messages = try! await db.read { try Message.all.fetchAll($0) }
    let reactions = try! await db.read { try Reaction.all.fetchAll($0) }
    let seen = try! await db.read { try SeenHashRow.all.fetchAll($0) }
    #expect(messages.isEmpty)
    #expect(reactions.isEmpty)
    #expect(seen.count == 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --filter "incomingTextMessageStoresItsHash|incomingReactionIsStoredAndNotABubble|reactionWithFallbackContentIsNotABubble|unvalidatedReactionIsDropped|malformedReactionIsDroppedNotABubble"`
Expected: all 5 FAIL (hash is `""`; reactions become bubbles; `reactions` table empty).

- [ ] **Step 3: Implement**

In `AppFeature.swift`, add next to `pruneSeenHashes`:
```swift
/// Upsert a seen-hash row and prune to the ring capacity (shared by text and reaction receives).
private func recordSeenHash(_ hashHex: String, at now: Date, _ db: GRDB.Database) throws {
    try SeenHashRow.where { $0.hashHex.eq(hashHex) }.delete().execute(db)
    try SeenHashRow.insert { SeenHashRow(hashHex: hashHex, storedAt: now) }.execute(db)
    try pruneSeenHashes(db)
}
```

In the `messageReceived` case, keep the DIAGNOSTIC block exactly as is. Directly after the `AppFeature.inbound.notice(...)` call and **before** `let row = Message(`, insert:
```swift
                let seenHashHex = m.hash.hexString
                let seenNow = date.now
                let openPeer = state.openPeerHex
                switch ReactionWire.decode(m.fields) {
                case let .reaction(target, emoji):
                    // Reactions never become bubbles and never touch the conversation list.
                    // Unvalidated ones can't be attributed, so only the seen hash is recorded.
                    let reaction: Reaction? = validated
                        ? Reaction(messageHash: target.hexString, reactorHex: incomingPeer,
                                   emoji: emoji, sentAt: m.timestamp)
                        : nil
                    return .run { [database] send in
                        try await database.write { db in
                            if let reaction { try Reaction.apply(reaction, db) }
                            try recordSeenHash(seenHashHex, at: seenNow, db)
                        }
                        if reaction != nil, incomingPeer == openPeer {
                            try await reloadThread(database, incomingPeer, send)
                        }
                    }
                case .malformed:
                    return .run { [database] _ in
                        try await database.write { try recordSeenHash(seenHashHex, at: seenNow, $0) }
                    }
                case .notReaction:
                    break
                }
```
Then in the existing (text) path:
- change `messageHash: ""` to `messageHash: seenHashHex`;
- delete the now-duplicate `let openPeer = state.openPeerHex`, `let seenHashHex = m.hash.hexString`, `let seenNow = date.now` lines;
- replace the three SeenHashRow lines (`delete`, `insert`, `pruneSeenHashes`) inside the write with `try recordSeenHash(seenHashHex, at: seenNow, db)`, keeping the existing explanatory comment above it.

Also update the `Message.messageHash` doc comment in `Message.swift` from `// outgoing: LXMessage.hash hex ("" for incoming)` to `// LXMessage.hash hex ("" for incoming rows stored before reactions shipped)`, and the struct doc comment's "`messageHash` is the LXMessage.hash of an outgoing message (hex), used to correlate deliveryFailed" to "`messageHash` is the LXMessage.hash (hex) — correlates deliveryFailed for outgoing rows and is the reaction target for all rows".

- [ ] **Step 4: Run tests to verify they pass**

Run the Step 2 command. Expected: 5 PASS. Then the full suite — expected all PASS (existing receive/dedup tests must be unaffected).

- [ ] **Step 5: Mutation check**

Apply in one batch: (a) text path `messageHash: seenHashHex` → `messageHash: ""`; (b) change `case let .reaction(target, emoji):` body's first line so `reaction` is always `Reaction(... emoji: emoji ...)` (ignore `validated`) — i.e. replace `validated ? … : nil` with the non-nil branch; (c) change `case .notReaction: break` to `case .notReaction, .malformed: break` and delete the `case .malformed:` block (malformed falls through to a bubble); (d) in the `.reaction` branch replace `return .run { … }` with `break` (reaction falls through to a bubble).
Run the Step 2 command. Expected: all 5 RED ((a) hash; (d) stored/fallback; (b) unvalidated; (c) malformed). Revert; confirm GREEN.

- [ ] **Step 6: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Message.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift
git -C /Users/ell/development/ios/apps/ReTiCAMsgr commit -m "feat: route incoming reaction messages to the reactions table; store incoming hashes" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Thread reactions in state + `.reactionSelected`

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift`:
  - `State` (near `threadMessages`, `:60`): add `threadReactionRows` and `threadReactions`.
  - `Action` (`:138`): change `case threadLoaded([Message])` to `case threadLoaded([Message], reactions: [Reaction] = [])`; add `case reactionSelected(messageHash: String, emoji: String)`.
  - `.closeConversation` (`:462-466`): clear reactions.
  - `.threadLoaded` handler (`:640-642`).
  - New `.reactionSelected` case (place right after `.sendTapped`).
  - `reloadThread` (`:907-912`).
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift` — append.

**Interfaces:**
- Consumes: `Reaction`, `Reaction.apply`, `ReactionSummary.byMessage`, `ReactionWire.encode/decode`, `state.myAddressHex` (own lxmf.delivery hex), `state.identity`, `state.propagationNodeHex`.
- Produces:
  - `State.threadReactionRows: [Reaction]` — visible raw rows for the open thread (reactor is me or the open peer).
  - `State.threadReactions: [String: [ReactionSummary.Item]]` — badge data keyed by message hash hex; always equal to `ReactionSummary.byMessage(threadReactionRows, me: myAddressHex)`.
  - `State.setThreadReactionRows(_ rows: [Reaction])` — the only way to assign the two above.
  - `Action.reactionSelected(messageHash: String, emoji: String)` — the UI's only entry point. Passing the emoji I already have removes it.
  - `Action.threadLoaded([Message], reactions: [Reaction])`.

- [ ] **Step 1: Write the failing tests**

Append to `AppFeatureTests.swift`:
```swift
// MARK: - Reactions: thread state + reactionSelected

@MainActor
private func sentReaction(_ store: TestStoreOf<AppFeature>) async -> (target: Data, emoji: String)? {
    var out: (Data, String)?
    await store.receive { action in
        if case let .node(.client(.sendMessage(msg, _))) = action,
           case let .reaction(t, e) = ReactionWire.decode(msg.fields) {
            out = (t, e)
            return true
        }
        return false
    }
    return out
}

@MainActor @Test func reactionSelectedSetsSendsAndShowsBadge() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    let store = makeStore(db, identity: me) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    let sent = await sentReaction(store)
    #expect(sent?.target == Data(hexString: hash))
    #expect(sent?.emoji == "❤️")
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions[hash] == [.init(emoji: "❤️", count: 1, includesMe: true)])
    let rows = try! await db.read { try Reaction.all.fetchAll($0) }
    #expect(rows.map(\.reactorHex) == [store.state.myAddressHex])
}

@MainActor @Test func reactionSelectedReplacesMyEmoji() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    _ = await sentReaction(store)
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.send(.reactionSelected(messageHash: hash, emoji: "😂"))
    let sent = await sentReaction(store)
    #expect(sent?.emoji == "😂")
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions[hash] == [.init(emoji: "😂", count: 1, includesMe: true)])
}

/// Review Focus 1: the test clock is frozen, so both taps see the same `date.now`. The second
/// (toggle-off) must still win — own sentAt is forced strictly monotonic.
@MainActor @Test func reactionSelectedTogglesOffWithFrozenClock() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    _ = await sentReaction(store)
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    let sent = await sentReaction(store)
    #expect(sent?.emoji == "")
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions[hash] == nil)
    let rows = try! await db.read { try Reaction.all.fetchAll($0) }
    #expect(rows.map(\.emoji) == [""])
}

@MainActor @Test func reactionSelectedWithEmptyHashIsNoOp() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: "", emoji: "❤️"))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let rows = try! await db.read { try Reaction.all.fetchAll($0) }
    #expect(rows.isEmpty)
}

@MainActor @Test func reactionFromThirdPartyIsNotShownInThread() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    try! await db.write { try Reaction.apply(Reaction(messageHash: hash, reactorHex: peerB, emoji: "👎", sentAt: 1), $0) }
    let store = makeStore(db, identity: Identity())
    await store.send(.openConversation(peerA))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions.isEmpty)
    #expect(store.state.threadReactionRows.isEmpty)
}

/// Review Focus 3.
@MainActor @Test func peerReactionOnMyOutgoingMessageShows() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let hash = String(repeating: "d", count: 64)
    try! await seed(db, [msg(1, senderHex, "mine", 1000, outgoing: true, hash: hash)])
    let store = makeStore(db, identity: me)
    await store.send(.openConversation(senderHex))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    let m = reactionMessage(from: sender, to: me, target: Data(hexString: hash)!, emoji: "👍", at: 1700000002)
    await store.send(.node(.client(.delegate(.messageReceived(message: m, signatureValidated: true)))))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadReactions[hash] == [.init(emoji: "👍", count: 1, includesMe: false)])
}

/// Review Focus 2.
@MainActor @Test func reactionBeforeTargetShowsOnceTargetArrives() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let text = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                timestamp: 1700000000, title: Data(), content: Data("late".utf8))
    let reaction = reactionMessage(from: sender, to: me, target: text.hash, emoji: "😮", at: 1700000001)
    let store = makeStore(db, identity: me) { $0.openPeerHex = senderHex }
    await store.send(.node(.client(.delegate(.messageReceived(message: reaction, signatureValidated: true)))))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.send(.node(.client(.delegate(.messageReceived(message: text, signatureValidated: true)))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadMessages.map(\.body) == ["late"])
    #expect(store.state.threadReactions[text.hash.hexString] == [.init(emoji: "😮", count: 1, includesMe: false)])
}

@MainActor @Test func closeConversationClearsReactions() async {
    let db = try! AppDatabase.makeInMemory()
    let hash = String(repeating: "c", count: 64)
    try! await seed(db, [msg(1, peerA, "yo", 1000, outgoing: false, status: MessageStatus.received, hash: hash)])
    let store = makeStore(db, identity: Identity()) { $0.openPeerHex = peerA }
    await store.send(.reactionSelected(messageHash: hash, emoji: "❤️"))
    _ = await sentReaction(store)
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    await store.send(.closeConversation)
    #expect(store.state.threadReactions.isEmpty)
    #expect(store.state.threadReactionRows.isEmpty)
}
```
(`reactionMessage` was added in Task 3.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --filter "reactionSelected|reactionFromThirdParty|peerReactionOnMyOutgoing|reactionBeforeTarget|closeConversationClearsReactions"`
Expected: build FAILS — `reactionSelected` / `threadReactions` not found.

- [ ] **Step 3: Implement**

State, directly below `public var threadMessages: [Message] = []`:
```swift
        /// Visible reaction rows for the open thread: reactor is me or the open peer only, so a
        /// third party who knows a message hash can't inject a badge into this conversation.
        /// Always assign through `setThreadReactionRows` so `threadReactions` stays in sync.
        public var threadReactionRows: [Reaction] = []
        /// Badge data keyed by message hash hex. Derived from `threadReactionRows`.
        public var threadReactions: [String: [ReactionSummary.Item]] = [:]
```
And, as a method inside `State` (after `init`):
```swift
        public mutating func setThreadReactionRows(_ rows: [Reaction]) {
            threadReactionRows = rows
            threadReactions = ReactionSummary.byMessage(rows, me: myAddressHex)
        }
```
(Plain stored properties + an explicit setter: `@ObservableState` rewrites stored properties, so `didSet` is not used.)

Action:
```swift
        case threadLoaded([Message], reactions: [Reaction] = [])
        case reactionSelected(messageHash: String, emoji: String)
```

`.closeConversation` — add `state.setThreadReactionRows([])` after `state.threadMessages = []`.

`.threadLoaded` handler, replacing the existing one:
```swift
            case let .threadLoaded(rows, reactions):
                state.threadMessages = rows
                let allowed: Set<String> = [state.myAddressHex, state.openPeerHex ?? ""]
                state.setThreadReactionRows(reactions.filter { allowed.contains($0.reactorHex) })
                return .none
```

New case, after `.sendTapped`:
```swift
            case let .reactionSelected(messageHash, emoji):
                guard !messageHash.isEmpty,
                      let target = Data(hexString: messageHash),
                      let peerHex = state.openPeerHex,
                      let peer = Data(hexString: peerHex) else { return .none }
                let me = state.myAddressHex
                let mine = state.threadReactionRows.first { $0.messageHash == messageHash && $0.reactorHex == me }
                // Same emoji again = remove (Signal/iMessage toggle).
                let newEmoji = mine?.emoji == emoji ? "" : emoji
                // Strictly monotonic per reactor so two taps in one clock tick still apply in order
                // on both ends (Reaction.apply ignores equal timestamps).
                let sentAt = max(date.now.timeIntervalSince1970, (mine?.sentAt ?? 0) + 0.001)
                let msg = LXMessage.create(
                    source: state.identity,
                    destinationHash: peer,
                    timestamp: sentAt,
                    title: Data(),
                    content: Data(),
                    fields: ReactionWire.encode(target: target, emoji: newEmoji)
                )
                let row = Reaction(messageHash: messageHash, reactorHex: me, emoji: newEmoji, sentAt: sentAt)
                // Optimistic: update in-memory rows now so a second tap before the reload sees it.
                state.setThreadReactionRows(
                    state.threadReactionRows.filter { !($0.messageHash == messageHash && $0.reactorHex == me) } + [row]
                )
                let alsoViaPropagation = !state.propagationNodeHex.isEmpty
                return .merge(
                    .send(.node(.client(.sendMessage(message: msg, alsoViaPropagation: alsoViaPropagation)))),
                    .run { [database] send in
                        try await database.write { try Reaction.apply(row, $0) }
                        try await reloadThread(database, peerHex, send)
                    }
                )
```

`reloadThread`, replacing the body:
```swift
private func reloadThread(_ database: any DatabaseWriter, _ peerHex: String, _ send: Send<AppFeature.Action>) async throws {
    let (rows, reactions) = try await database.read { db in
        let rows = try Message.where { $0.peerHex.eq(peerHex) }.order(by: \.timestamp).fetchAll(db)
        let hashes = rows.map(\.messageHash).filter { !$0.isEmpty }
        let reactions = hashes.isEmpty ? [] : try Reaction.where { $0.messageHash.in(hashes) }.fetchAll(db)
        return (rows, reactions)
    }
    await send(.threadLoaded(rows, reactions: reactions))
}
```
(If `.in(_:)` doesn't type-check in this structured-queries version, fetch `Reaction.all` and filter in Swift with `Set(hashes).contains($0.messageHash)`; note the fallback in the commit message.)

- [ ] **Step 4: Run tests to verify they pass**

Run the Step 2 command. Expected: 8 PASS. Then the full suite — all PASS.

- [ ] **Step 5: Mutation check**

Apply in one batch:
- (a) `let newEmoji = mine?.emoji == emoji ? "" : emoji` → `let newEmoji = mine == nil ? emoji : ""` (any second tap removes instead of replacing)
- (b) `(mine?.sentAt ?? 0) + 0.001` → `(mine?.sentAt ?? 0)` (not monotonic)
- (c) in `.threadLoaded`, `reactions.filter { allowed.contains($0.reactorHex) }` → `reactions`
- (d) in `.closeConversation`, delete the `state.setThreadReactionRows([])` line
- (e) in `.reactionSelected`, replace the guard's first two conditions `!messageHash.isEmpty,` and `let target = Data(hexString: messageHash),` with nothing, and add `let target = Data(hexString: messageHash) ?? Data(repeating: 0, count: 32)` after the guard
- (f) in `.reactionSelected`, `ReactionWire.encode(target: target, emoji: newEmoji)` → `ReactionWire.encode(target: Data(repeating: 9, count: 32), emoji: newEmoji)`
- (g) in Task 3's `.reaction` receive branch, `if reaction != nil, incomingPeer == openPeer {` → `if false {`

Run the Step 2 command. Expected: all 8 RED — sets via (f); replaces via (a); toggle via (b) (equal `sentAt` → DB ignores the removal → reload shows ❤️ again); empty-hash via (e); third-party via (c); peer-on-outgoing and before-target via (g) (no `threadLoaded` ever arrives); close via (d). Revert; confirm GREEN.

- [ ] **Step 6: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr add ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/AppFeatureTests.swift
git -C /Users/ell/development/ios/apps/ReTiCAMsgr commit -m "feat: reactionSelected action and per-thread reaction badges" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `EmojiCatalog` + bundled trimmed emoji data

**Files:**
- Create: `scripts/trim-emoji-test.swift` (generator, committed)
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Resources/emoji.tsv` (generated, committed)
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/EmojiCatalog.swift`
- Modify: `ReTiCAMsgrCore/Package.swift` — add `resources: [.process("Resources")]` to the `ReTiCAMsgrCore` target.
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/EmojiCatalogTests.swift`

**Interfaces:**
- Consumes: `ReactionWire.encode/decode`, `QuickReactions.default`.
- Produces:
  - `public struct EmojiCatalog: Sendable` with `public let groups: [Group]`, `public init(tsv: String)`, `public static let shared: EmojiCatalog`, `public func search(_ query: String) -> [Entry]`.
  - `public struct EmojiCatalog.Entry: Hashable, Sendable, Identifiable { emoji: String; name: String; id: String /* = emoji */ }`
  - `public struct EmojiCatalog.Group: Hashable, Sendable, Identifiable { name: String; emojis: [Entry]; id: String /* = name */ }`
  - TSV format: one line per emoji, `group<TAB>emoji<TAB>name`, in `emoji-test.txt` order.

- [ ] **Step 1: Write the generator and produce the resource**

`scripts/trim-emoji-test.swift`:
```swift
// Trims Unicode's emoji-test.txt into ReTiCAMsgrCore's bundled emoji.tsv.
// Keeps fully-qualified entries only, drops skin-tone variants and the "Component" group.
// Usage: swift scripts/trim-emoji-test.swift <emoji-test.txt> <out.tsv>
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: trim-emoji-test.swift <in> <out>\n".utf8))
    exit(1)
}
let input = try String(contentsOfFile: args[1], encoding: .utf8)
let skinTones: Set<String> = ["1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF"]
var group = ""
var out: [String] = []
for line in input.split(separator: "\n", omittingEmptySubsequences: true) {
    if line.hasPrefix("# group: ") {
        group = String(line.dropFirst("# group: ".count))
        continue
    }
    if line.hasPrefix("#") || group == "Component" { continue }
    // "1F600 ; fully-qualified # 😀 E1.0 grinning face"
    let halves = line.split(separator: "#", maxSplits: 1)
    guard halves.count == 2 else { continue }
    let lhs = halves[0].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    guard lhs.count == 2, lhs[1] == "fully-qualified" else { continue }
    let codepoints = lhs[0].split(separator: " ").map(String.init)
    if codepoints.contains(where: skinTones.contains) { continue }
    // rhs: " 😀 E1.0 grinning face"
    let rhs = halves[1].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
    guard rhs.count == 3 else { continue }
    out.append("\(group)\t\(rhs[0])\t\(rhs[2])")
}
try (out.joined(separator: "\n") + "\n").write(toFile: args[2], atomically: true, encoding: .utf8)
print("wrote \(out.count) emoji")
```

Run, one command each:
1. `mkdir -p /tmp/ReTiCAMsgr`
2. `curl -fsSL -o /tmp/ReTiCAMsgr/emoji-test.txt https://unicode.org/Public/emoji/16.0/emoji-test.txt` (Emoji 16.0 — fully rendered by iOS 26.4; do not use `latest`.)
3. `mkdir -p /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Resources`
4. `swift /Users/ell/development/ios/apps/ReTiCAMsgr/scripts/trim-emoji-test.swift /tmp/ReTiCAMsgr/emoji-test.txt /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Resources/emoji.tsv`
   Expected: `wrote N emoji` with N roughly 1,800–1,950.
5. `ls -l /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Resources/emoji.tsv` — expect < 100 KB.

Add to the `ReTiCAMsgrCore` `.target(...)` in `Package.swift`, after `dependencies: [...]`:
```swift
            ,
            resources: [.process("Resources")]
```
(i.e. the target becomes `.target(name: "ReTiCAMsgrCore", dependencies: [...], resources: [.process("Resources")])`.)

- [ ] **Step 2: Write the failing tests**

`ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/EmojiCatalogTests.swift`:
```swift
import Testing
import Foundation
@testable import ReTiCAMsgrCore

@Test func bundledCatalogLoadsWithGroups() {
    let c = EmojiCatalog.shared
    #expect(c.groups.count >= 8)
    #expect(c.groups.first?.name == "Smileys & Emotion")
    #expect(c.groups.flatMap(\.emojis).count > 1500)
    #expect(!c.groups.contains { $0.name == "Component" })
}

@Test func catalogContainsAllQuickReactions() {
    let all = Set(EmojiCatalog.shared.groups.flatMap(\.emojis).map(\.emoji))
    for q in QuickReactions.default { #expect(all.contains(q), "missing \(q)") }
}

@Test func catalogHasNoSkinToneVariants() {
    let tones: Set<UInt32> = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]
    let offenders = EmojiCatalog.shared.groups.flatMap(\.emojis).filter {
        $0.emoji.unicodeScalars.contains { tones.contains($0.value) }
    }
    #expect(offenders.isEmpty)
}

@Test func searchMatchesNameCaseInsensitively() {
    let hits = EmojiCatalog.shared.search("  Red HEART ").map(\.emoji)
    #expect(hits.contains("❤️"))
    #expect(EmojiCatalog.shared.search("").isEmpty)
    #expect(EmojiCatalog.shared.search("zzzznotanemoji").isEmpty)
}

@Test func parsesTSVIntoOrderedGroups() {
    let c = EmojiCatalog(tsv: "A\t😀\tgrinning face\nA\t😃\tbig eyes\nB\t🐶\tdog face\n")
    #expect(c.groups.map(\.name) == ["A", "B"])
    #expect(c.groups[0].emojis.map(\.emoji) == ["😀", "😃"])
    #expect(c.groups[1].emojis == [.init(emoji: "🐶", name: "dog face")])
}

/// Review Focus 5: anything the picker offers must survive the wire limit.
@Test func everyCatalogEmojiFitsWireLimit() {
    let target = Data(repeating: 7, count: 32)
    for e in EmojiCatalog.shared.groups.flatMap(\.emojis) {
        #expect(ReactionWire.decode(ReactionWire.encode(target: target, emoji: e.emoji))
                == .reaction(target: target, emoji: e.emoji), "\(e.name)")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --filter EmojiCatalogTests`
Expected: build FAILS — `cannot find 'EmojiCatalog' in scope`.

- [ ] **Step 4: Implement**

`ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/EmojiCatalog.swift`:
```swift
import Foundation

/// The full emoji set offered by the reaction picker, from a trimmed Unicode 16.0
/// `emoji-test.txt` (fully-qualified only, no skin tones) bundled as `Resources/emoji.tsv`.
/// Regenerate with `scripts/trim-emoji-test.swift`.
public struct EmojiCatalog: Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public let emoji: String
        public let name: String
        public var id: String { emoji }
        public init(emoji: String, name: String) {
            self.emoji = emoji
            self.name = name
        }
    }

    public struct Group: Hashable, Sendable, Identifiable {
        public let name: String
        public let emojis: [Entry]
        public var id: String { name }
    }

    public let groups: [Group]

    /// Parses `group<TAB>emoji<TAB>name` lines, preserving first-seen group order.
    public init(tsv: String) {
        var order: [String] = []
        var byGroup: [String: [Entry]] = [:]
        for line in tsv.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard cols.count == 3 else { continue }
            if byGroup[cols[0]] == nil { order.append(cols[0]) }
            byGroup[cols[0], default: []].append(Entry(emoji: cols[1], name: cols[2]))
        }
        groups = order.map { Group(name: $0, emojis: byGroup[$0] ?? []) }
    }

    public static let shared: EmojiCatalog = {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "tsv"),
              let tsv = try? String(contentsOf: url, encoding: .utf8)
        else { return EmojiCatalog(tsv: "") }
        return EmojiCatalog(tsv: tsv)
    }()

    /// Case-insensitive substring match on the emoji's name. Empty query → no results.
    public func search(_ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return groups.flatMap(\.emojis).filter { $0.name.lowercased().contains(q) }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run the Step 3 command. Expected: 6 PASS. If `everyCatalogEmojiFitsWireLimit` fails, report the offending emoji — do not silently raise `maxEmojiBytes`.

- [ ] **Step 6: Mutation check**

First back up the resource (it isn't committed yet): `cp /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Resources/emoji.tsv /tmp/ReTiCAMsgr/emoji.tsv.bak`.

Apply in one batch:
- (a) in `init(tsv:)`, `groups = order.map { … }` → `groups = order.dropFirst().map { … }` (loses the first group, "Smileys & Emotion", which holds 😂 😮 😢)
- (b) in `search`, `$0.name.lowercased().contains(q)` → `$0.name.lowercased().hasPrefix(q + "x")`
- (c) `ReactionWire.maxEmojiBytes = 64` → `= 4`
- (d) append the line `Smileys & Emotion	👍🏽	thumbs up: medium skin tone` (real tab characters) to the end of `emoji.tsv` with the Edit tool

Run the Step 3 command. Expected: all 6 RED — loads and quick via (a); parse via (a) (`["B"]`); search via (b); wire-limit via (c); no-skin-tone via (d). Revert (a)–(c) and restore the resource with `cp /tmp/ReTiCAMsgr/emoji.tsv.bak /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Resources/emoji.tsv`. Confirm GREEN.

- [ ] **Step 7: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr add scripts/trim-emoji-test.swift ReTiCAMsgrCore/Package.swift ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Resources/emoji.tsv ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/EmojiCatalog.swift ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/EmojiCatalogTests.swift
git -C /Users/ell/development/ios/apps/ReTiCAMsgr commit -m "feat: bundled EmojiCatalog (Unicode 16.0, no skin tones) with search" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: UI spike → `ReactionPaletteMenu`

Decide the palette mechanism on a real simulator, then keep only the winner.

**Files:**
- Create: `ReTiCAMsgr/ReactionPaletteMenu.swift`
- Modify (temporarily, reverted in-task): `ReTiCAMsgr/ChatView.swift`

**Interfaces:**
- Consumes: `QuickReactions.default`.
- Produces: `struct ReactionPaletteMenu: View { init(current: String?, onSelect: @escaping (String) -> Void, onMore: @escaping () -> Void) }` — placed inside a `.contextMenu { }`. `current` is my current emoji on that message (nil if none). `onSelect(e)` fires on **every** tap of a quick emoji, including the already-selected one (the reducer does the toggle). `onMore` fires on ＋.

- [ ] **Step 1: Write both candidates**

`ReTiCAMsgr/ReactionPaletteMenu.swift`:
```swift
import SwiftUI
import ReTiCAMsgrCore

/// The quick-reaction row at the top of a message's context menu: six emoji and a ＋.
/// `onSelect` must fire on every tap, including the currently selected emoji — the reducer
/// turns a repeat into a removal.
struct ReactionPaletteMenu: View {
    let current: String?
    let onSelect: (String) -> Void
    let onMore: () -> Void

    var body: some View {
        controlGroupVariant
    }

    // Candidate A: explicit buttons — every tap fires; no built-in selected state.
    private var controlGroupVariant: some View {
        ControlGroup {
            ForEach(QuickReactions.default, id: \.self) { emoji in
                Button { onSelect(emoji) } label: { Text(emoji) }
                    .accessibilityLabel(current == emoji ? "Remove \(emoji)" : "React \(emoji)")
            }
            Button(action: onMore) { Image(systemName: "plus") }
                .accessibilityLabel("More reactions")
        }
        .controlGroupStyle(.palette)
    }

    // Candidate B: palette picker — free selected highlight; must verify re-tap fires.
    private static let moreTag = "__more__"
    private var pickerVariant: some View {
        Picker("React", selection: Binding(
            get: { current ?? "" },
            set: { value in value == Self.moreTag ? onMore() : onSelect(value) }
        )) {
            ForEach(QuickReactions.default, id: \.self) { emoji in
                Text(emoji).tag(emoji)
            }
            Image(systemName: "plus").tag(Self.moreTag)
        }
        .pickerStyle(.palette)
    }
}
```

Temporarily, in `ChatView.swift`, attach a throwaway menu to each row so the spike can be exercised (`MessageBubble(message: message)` line):
```swift
                MessageBubble(message: message)
                    .contextMenu {
                        ReactionPaletteMenu(current: "❤️", onSelect: { print("SPIKE select", $0) },
                                            onMore: { print("SPIKE more") })
                        Button("Copy", systemImage: "doc.on.doc") { }
                    }
```

- [ ] **Step 2: Evaluate candidate A, then B, in the simulator**

Use the `xcodebuildmcp-cli` skill (or `run` skill) to build and launch on an iOS 26.4 simulator, open a conversation that has at least one message (send one to any peer or seed via a peer), long-press a bubble, screenshot. Then set `body` to `pickerVariant`, rebuild, repeat. Record for each:
1. Do the six emoji render as emoji (colour, legible size) in the palette row?
2. Does tapping ❤️ (the value passed as `current`) log `SPIKE select ❤️`? (Candidate B's crux.)
3. Does ＋ log `SPIKE more`?
4. Is the current reaction visibly indicated?

Decision rule: **use B if (1)(2)(3) all pass** (it also gives (4)); otherwise **use A if (1)(3) pass**. If emoji don't render in either (fails (1)), change the chosen variant's labels to `Image(uiImage: Self.render(emoji))` with
```swift
    @MainActor static func render(_ emoji: String) -> UIImage {
        let r = ImageRenderer(content: Text(emoji).font(.system(size: 28)))
        r.scale = UITraitCollection.current.displayScale
        return (r.uiImage ?? UIImage()).withRenderingMode(.alwaysOriginal)
    }
```
and re-verify.

- [ ] **Step 3: Keep only the winner**

Delete the losing variant (and `moreTag` if A wins) so `body` returns the winner directly; keep the doc comment accurate (drop the "Candidate" comments). Revert the temporary `ChatView.swift` change (`git -C /Users/ell/development/ios/apps/ReTiCAMsgr checkout ReTiCAMsgr/ChatView.swift`). Build the app (Global Constraints build command) — expect `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

Commit message records the spike outcome, e.g. `feat: ReactionPaletteMenu (palette Picker; re-tap fires on iOS 26.4)`:
```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr add ReTiCAMsgr/ReactionPaletteMenu.swift
git -C /Users/ell/development/ios/apps/ReTiCAMsgr commit -m "feat: ReactionPaletteMenu (<winner>; <one-line finding>)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `EmojiPickerSheet`

**Files:**
- Create: `ReTiCAMsgr/EmojiPickerSheet.swift`

**Interfaces:**
- Consumes: `EmojiCatalog.shared`, `EmojiCatalog.Entry`, `EmojiCatalog.Group`.
- Produces: `struct EmojiPickerSheet: View { init(onPick: @escaping (String) -> Void) }` — calls `onPick(emoji)` then dismisses itself.

- [ ] **Step 1: Implement**

`ReTiCAMsgr/EmojiPickerSheet.swift`:
```swift
import SwiftUI
import ReTiCAMsgrCore

/// Full emoji picker for reactions: grouped grid, searchable by name.
struct EmojiPickerSheet: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let catalog = EmojiCatalog.shared
    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    if query.isEmpty {
                        ForEach(catalog.groups) { group in
                            Section {
                                cells(group.emojis)
                            } header: {
                                Text(group.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                        }
                    } else {
                        cells(catalog.search(query))
                    }
                }
                .padding(.horizontal)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search emoji")
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func cells(_ entries: [EmojiCatalog.Entry]) -> some View {
        ForEach(entries) { entry in
            Button {
                onPick(entry.emoji)
                dismiss()
            } label: {
                Text(entry.emoji)
                    .font(.system(size: 32))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.name)
        }
    }
}

#Preview {
    EmojiPickerSheet { print("picked", $0) }
}
```

- [ ] **Step 2: Build**

Run the Global Constraints app build command. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr add ReTiCAMsgr/EmojiPickerSheet.swift
git -C /Users/ell/development/ios/apps/ReTiCAMsgr commit -m "feat: EmojiPickerSheet — searchable grouped emoji grid" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Wire it into `ChatView` — context menu, badges, Copy, sheet; manual verification

**Files:**
- Modify: `ReTiCAMsgr/ChatView.swift` (whole file shown below)

**Interfaces:**
- Consumes: `store.threadReactions`, `store.reachablePeers`, `store.openPeerHex`, `AppFeature.Action.reactionSelected(messageHash:emoji:)`, `ReactionSummary.Item`, `ReactionPaletteMenu`, `EmojiPickerSheet`.
- Produces: final UI.

- [ ] **Step 1: Implement**

Replace `ReTiCAMsgr/ChatView.swift` with:
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

    private var peerReachable: Bool {
        guard let peer = store.openPeerHex else { return false }
        return store.reachablePeers.contains(peer)
    }

    private var canSend: Bool {
        peerReachable && !store.draft.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            List(store.threadMessages) { message in
                let reactions = store.threadReactions[message.messageHash] ?? []
                MessageBubble(message: message, reactions: reactions)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        if !message.messageHash.isEmpty {
                            ReactionPaletteMenu(
                                current: reactions.first(where: \.includesMe)?.emoji,
                                onSelect: { store.send(.reactionSelected(messageHash: message.messageHash, emoji: $0)) },
                                onMore: { pickerTarget = PickerTarget(messageHash: message.messageHash) }
                            )
                            .disabled(!peerReachable)
                        }
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.body
                        }
                    } preview: {
                        BubbleText(message: message)
                            .padding(8)
                    }
            }
            .listStyle(.plain)

            Divider()

            HStack(spacing: 8) {
                TextField("Message", text: $store.draft)
                    .textFieldStyle(.roundedBorder)
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
}

private struct PickerTarget: Identifiable {
    let messageHash: String
    var id: String { messageHash }
}

struct MessageBubble: View {
    let message: Message
    var reactions: [ReactionSummary.Item] = []

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer() }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                BubbleText(message: message)
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
struct BubbleText: View {
    let message: Message

    var body: some View {
        Text(message.body)
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
Note: the ＋ path sets `pickerTarget` from inside the context-menu action; if the sheet fails to present because the menu is still dismissing (observable in Step 3), wrap the assignment in `Task { @MainActor in try? await Task.sleep(for: .milliseconds(350)); pickerTarget = … }` and note it in the commit.

- [ ] **Step 2: Build**

Run the Global Constraints app build command. Expected: `BUILD SUCCEEDED`. Also run the full core suite — expected all PASS.

- [ ] **Step 3: Manual verification in the simulator (two devices)**

Use the `xcodebuildmcp-cli` or `run` skill. Reactions need a real peer, so run two simulators (or simulator + device) on the same Reticulum network, each with its own identity, and open a conversation between them. Take a screenshot at each check and record pass/fail:
1. Long-press a received bubble → it lifts, background blurs, palette row of six emoji + ＋ on top, Copy below.
2. Tap ❤️ → badge ❤️ with accent border appears under the bubble on this device; on the other device the same bubble on their side shows ❤️ with a neutral border.
3. Long-press again, tap ❤️ → badge disappears on both.
4. Tap 😂 then long-press and tap 👍 → badge shows only 👍 (replaced) on both.
5. ＋ → sheet opens at medium height; search "dog" → 🐶 among results; tap it → sheet dismisses, 🐶 badge on both.
6. Both users react with the same emoji → badge shows the emoji with count 2.
7. Long-press an **outgoing** bubble → palette present; reacting works and shows on the other device.
8. Copy → paste into the draft field shows the message text.
9. Disconnect the peer (stop the other simulator's app) until the Send button disables → the palette row is disabled; Copy still works.
10. Long-press an old incoming message from before this feature (empty hash), if one exists → Copy only, no palette.
11. Whole-cell tap in the emoji sheet: tap the empty space beside a glyph within a cell → it still picks.

Any failure: stop and diagnose (superpowers:systematic-debugging) before continuing.

- [ ] **Step 4: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr add ReTiCAMsgr/ChatView.swift
git -C /Users/ell/development/ios/apps/ReTiCAMsgr commit -m "feat: long-press reactions in chat — palette, badges, Copy, full picker" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
