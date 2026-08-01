# ReTiCaMsgr Slice 2 — Multiple Conversations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the one-conversation MVP into a multi-conversation messenger — a conversation list, per-peer threads, and a compose entry point to start a conversation by peer address — keeping delivery opportunistic.

**Architecture:** All logic stays in the single `AppFeature` reducer (in local SPM package `ReTiCaMsgrCore`) scoping `LXMFNode`. Conversations are *derived* from the distinct `peerHex` values in the existing `messages` table (no `Contact` table, no DB migration). Reachability is session-only in-memory state. Three SwiftUI screens in a TabView, with the Chat tab now a `NavigationStack` (list → thread).

**Tech Stack:** Swift 6, TCA (ComposableArchitecture), SQLiteData (`@Table`/StructuredQueries) + GRDB, ReTiCANode/ReTiCA (LXMF), SwiftUI.

## Global Constraints

- **Code repo = `/Users/ell/development/ios/apps/ReTiCaMsgr`** (the app repo, NOT the ReTiCA pods repo). Commit via `git -C /Users/ell/development/ios/apps/ReTiCaMsgr`.
- **Commit directly to `main`.**
- **Commit message trailers, verbatim, at COLUMN 0 (no leading whitespace):**
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
  Commit with `git commit -F <file>` (NEVER `-m` — the trailers contain `;`). After each commit verify the trailer parses: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'` must print the URL. Indented trailers are silently unparsed — if it prints empty, `git commit --amend -F <file>` to fix.
- **No compound shell commands:** one command per invocation; no `&&`/`||`/`;`/pipes/`xargs`/inline interpreter scripts. A single `>` redirect of a real command's output IS allowed. Write files with editor tools, never `echo`/heredoc.
- **Temp files** under `/tmp/ReTiCaMsgr/` (create if missing).
- **Three-step mutation verification for every new/changed test** (per the user's global instruction): (a) run the changed tests, confirm all pass; (b) in one batch, mutate the production code each test exercises so it *should* fail (invert a return, drop a guard, wrong constant — not a syntax break), run once, confirm each fails; (c) revert all mutations, run again, confirm all pass. Only then commit.
- **SQLiteData API gotchas (verified in slice 1):** StructuredQueries `==` is `@unavailable` → use `.eq()` in predicates. `UUID(0)` is not re-exported → use `UUID(uuidString:)!` for deterministic ids in tests. `@FetchAll` captures `\.defaultDatabase` at struct-init before TestStore's `withDependencies` → do NOT use it in TCA state; use plain arrays reloaded via a `.run` `database.read` effect. GRDB reads/writes are `try await database.read/write { ... }`. Query forms: `Message.insert { row }.execute($0)`, `Message.where { $0.col.eq(x) }.order(by: \.timestamp).fetchAll($0)`, `Message.where { … }.update { $0.status = MessageStatus.failed }.execute($0)`.
- **Test target already depends on** `ReTiCAInterfaces` (for `TCPConnection`) and `ReTiCATransport`. `InterfaceID("tcp")` has no default init. Standard test dependency block (copy verbatim into each new test):
  ```swift
  $0.defaultDatabase = db
  $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
  $0.uuid = .incrementing
  $0.continuousClock = TestClock()
  $0.tcpConnection = TCPConnection(
      open: { _, _ in AsyncStream { _ in } },
      send: { _ in },
      close: { }
  )
  ```
- **Verified delegate/action signatures** (from ReTiCANode): `LXMFNode.Action.send(destinationHash: Data, title: Data, content: Data, method: LXMFRouter.DeliveryMethod)`; `.node(.delegate(.messageReceived(message: LXMessage, signatureValidated: Bool)))`; `.node(.delegate(.deliveryFailed(messageHash: Data)))`; `.node(.endpoint(.delegate(.pathLearned(destinationHash: Data, hops: UInt8))))`; `.node(.endpoint(.transport(.interfaceConnected(InterfaceID))))` / `.interfaceDisconnected(InterfaceID)`; `.node(.endpoint(.connect))` / `.disconnect`; `.node(.registerDelivery)`.
- **Test/build commands:** package tests — `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore` (run ONE test with `--filter <name>`). App build (Task 3 only) — `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination 'generic/platform=iOS Simulator' build`.
- **`Message.sourceHash` note:** `LXMessage.sourceHash` is the sender's **lxmf.delivery** hash, so an incoming message's `m.sourceHash.hexString` matches the `peerHex` used when sending to that peer — conversations group correctly.

---

## File Structure

- **Create** `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Conversation.swift` — derived `Conversation` struct + `Conversation.list(from:)` latest-per-peer helper.
- **Modify** `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` — state, actions, wiring.
- **Rewrite** `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` — 1 conversation-helper test + 8 reducer tests.
- **Create** `ReTiCaMsgr/ConversationListView.swift` — list + compose sheet.
- **Modify** `ReTiCaMsgr/ChatView.swift` — render `threadMessages`, per-peer Send gate.
- **Modify** `ReTiCaMsgr/SettingsView.swift` — remove the peer-address section.
- **Modify** `ReTiCaMsgr/ContentView.swift` (`RootView`) — Chat tab hosts `ConversationListView`.
- **No change** to `Message.swift`, `Database.swift`, `IdentityStore.swift`, `Data+Hex.swift`, `Package.swift`, the DB migration.

---

## Task 1: `Conversation` derived type + latest-per-peer helper

**Files:**
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Conversation.swift`
- Test: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/ConversationTests.swift`

**Interfaces:**
- Consumes: `Message` (existing `@Table`: `id, peerHex, isOutgoing, body, timestamp, status, validated, messageHash`).
- Produces:
  - `public struct Conversation: Identifiable, Equatable, Sendable` with `peerHex: String`, `lastBody: String`, `lastTimestamp: Date`, `var id: String { peerHex }`, and a memberwise `init(peerHex:lastBody:lastTimestamp:)`.
  - `public static func list(from messages: [Message]) -> [Conversation]` — newest row per `peerHex`, sorted most-recent-first.

- [ ] **Step 1: Write the failing test**

Create `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/ConversationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCaMsgrCore

@Test func conversationListKeepsNewestPerPeerMostRecentFirst() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = Date(timeIntervalSince1970: 2000)
    let t2 = Date(timeIntervalSince1970: 3000)
    func msg(_ peer: String, _ body: String, _ ts: Date) -> Message {
        Message(id: UUID(), peerHex: peer, isOutgoing: true, body: body,
                timestamp: ts, status: MessageStatus.sent, validated: false, messageHash: "")
    }
    let messages = [
        msg("aa", "a-old", t0),
        msg("aa", "a-new", t2),
        msg("bb", "b-mid", t1),
    ]
    let convos = Conversation.list(from: messages)
    #expect(convos.count == 2)
    #expect(convos[0].peerHex == "aa")        // t2 is newest overall
    #expect(convos[0].lastBody == "a-new")    // newest row for aa, not a-old
    #expect(convos[1].peerHex == "bb")
    #expect(convos[1].lastTimestamp == t1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter conversationListKeepsNewestPerPeerMostRecentFirst`
Expected: FAIL to build — `Conversation` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Conversation.swift`:

```swift
import Foundation

/// A derived (never-persisted) summary of one peer's message thread.
/// `peerHex` is the other party's lxmf.delivery hash (hex).
public struct Conversation: Identifiable, Equatable, Sendable {
    public var peerHex: String
    public var lastBody: String
    public var lastTimestamp: Date
    public var id: String { peerHex }

    public init(peerHex: String, lastBody: String, lastTimestamp: Date) {
        self.peerHex = peerHex
        self.lastBody = lastBody
        self.lastTimestamp = lastTimestamp
    }
}

public extension Conversation {
    /// Build the conversation list from all messages: keep the newest row per
    /// `peerHex`, sorted most-recent-first.
    static func list(from messages: [Message]) -> [Conversation] {
        var latest: [String: Message] = [:]
        for m in messages {
            if let existing = latest[m.peerHex] {
                if m.timestamp > existing.timestamp { latest[m.peerHex] = m }
            } else {
                latest[m.peerHex] = m
            }
        }
        return latest.values
            .map { Conversation(peerHex: $0.peerHex, lastBody: $0.body, lastTimestamp: $0.timestamp) }
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore --filter conversationListKeepsNewestPerPeerMostRecentFirst`
Expected: PASS.

- [ ] **Step 5: Mutation-verify** (per Global Constraints). Batch-mutate `Conversation.list(from:)`: change the sort comparator `>` to `<`. Run the test → it must FAIL (order flips: `bb` would sort before `aa`… actually assert the specific failure). Also try replacing the newest-row guard `if m.timestamp > existing.timestamp` with `if false` → `lastBody` would be `a-old` → FAIL. Revert both, rerun → PASS.

- [ ] **Step 6: Commit**

Write the message to `/tmp/ReTiCaMsgr/t1.txt` (editor tool), then:
```
git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Conversation.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/ConversationTests.swift
git -C /Users/ell/development/ios/apps/ReTiCaMsgr commit -F /tmp/ReTiCaMsgr/t1.txt
git -C /Users/ell/development/ios/apps/ReTiCaMsgr log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'
```
Message body (trailers at column 0):
```
feat: Conversation derived type + latest-per-peer helper (slice 2 task 1)

Conversation { peerHex, lastBody, lastTimestamp } derived from messages;
list(from:) keeps newest row per peerHex, most-recent-first. No persistence.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Task 2: `AppFeature` multi-conversation refactor + reducer tests

**Files:**
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` (full rewrite of state/actions/body)
- Rewrite: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`

**Interfaces:**
- Consumes: `Conversation.list(from:)` (Task 1); `Message`; `LXMFNode` action signatures (Global Constraints); `lxmfAddressHex(_:)`, `Data(hexString:)`, `Data.hexString` (existing).
- Produces (state/actions later UI relies on):
  - `AppFeature.State`: `conversations: [Conversation]`, `openPeerHex: String?`, `threadMessages: [Message]`, `reachablePeers: Set<String>`, plus existing `node, identity, myAddressHex, @Shared host, @Shared port, draft, connection`. **Removed:** `peerAddressHex`, `messages`, `peerReachable`.
  - `AppFeature.Action`: `onLaunch`, `connectTapped`, `disconnectTapped`, `openConversation(String)`, `closeConversation`, `startConversation(String)`, `sendTapped`, `conversationsLoaded([Conversation])`, `threadLoaded([Message])`, `node(LXMFNode.Action)`, `binding(BindingAction<State>)`. **Removed:** `setPeer`, `messagesLoaded`.

- [ ] **Step 1: Rewrite the production reducer**

Replace the entire contents of `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` with:

```swift
import Foundation
import ComposableArchitecture
import Sharing
import SQLiteData
import GRDB
import ReTiCA
import ReTiCANode
import ReTiCATransport

@Reducer
public struct AppFeature {
    public enum Connection: Equatable { case disconnected, connecting, connected }

    @ObservableState
    public struct State: Equatable {
        public var node: LXMFNode.State
        public var identity: Identity
        public var myAddressHex: String
        @Shared(.appStorage("host")) public var host: String = "127.0.0.1"
        @Shared(.appStorage("port")) public var port: Int = 4242
        public var connection: Connection = .disconnected
        public var draft = ""
        // Derived list of peers, reloaded after every write.
        public var conversations: [Conversation] = []
        // The peer whose thread is currently open (drives navigation), and its messages.
        public var openPeerHex: String? = nil
        public var threadMessages: [Message] = []
        // Peers with a known path (from pathLearned); gates Send in the UI. Session-only.
        public var reachablePeers: Set<String> = []

        public init(identity: Identity, host: String = "127.0.0.1", port: Int = 4242) {
            self.identity = identity
            self.myAddressHex = lxmfAddressHex(identity)
            self.node = LXMFNode.State(
                identity: identity,
                endpoint: Endpoint.State(host: host, port: UInt16(port), reconnectOnDrop: true)
            )
            _host = Shared(wrappedValue: host, .appStorage("host"))
            _port = Shared(wrappedValue: port, .appStorage("port"))
        }
    }

    public enum Action: Equatable, BindableAction {
        case onLaunch
        case connectTapped
        case disconnectTapped
        case openConversation(String)
        case closeConversation
        case startConversation(String)
        case sendTapped
        case conversationsLoaded([Conversation])
        case threadLoaded([Message])
        case node(LXMFNode.Action)
        case binding(BindingAction<State>)
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.node, action: \.node) { LXMFNode() }
        Reduce { state, action in
            switch action {
            case .onLaunch:
                state.connection = .connecting
                return .merge(
                    .send(.node(.endpoint(.connect))),
                    .run { [database] send in try await reloadConversations(database, send) }
                )

            case .connectTapped:
                state.connection = .connecting
                return .send(.node(.endpoint(.connect)))

            case .disconnectTapped:
                state.connection = .disconnected
                return .send(.node(.endpoint(.disconnect)))

            case .node(.endpoint(.transport(.interfaceConnected(_)))):
                state.connection = .connected
                return .send(.node(.registerDelivery))

            case .node(.endpoint(.transport(.interfaceDisconnected(_)))):
                state.connection = .disconnected
                return .none

            case let .node(.endpoint(.delegate(.pathLearned(h, _)))):
                state.reachablePeers.insert(h.hexString)
                return .none

            case let .openConversation(peerHex):
                state.openPeerHex = peerHex
                return .run { [database] send in try await reloadThread(database, peerHex, send) }

            case .closeConversation:
                state.openPeerHex = nil
                state.threadMessages = []
                return .none

            case let .startConversation(hex):
                guard let data = Data(hexString: hex), data.count == 16 else { return .none }
                state.openPeerHex = hex
                return .run { [database] send in try await reloadThread(database, hex, send) }

            case .sendTapped:
                let text = state.draft
                guard !text.isEmpty,
                      let peerHex = state.openPeerHex,
                      let peer = Data(hexString: peerHex) else { return .none }
                let title = Data()
                let content = Data(text.utf8)
                let msg = LXMessage.create(
                    source: state.identity,
                    destinationHash: peer,
                    timestamp: date.now.timeIntervalSince1970,
                    title: title,
                    content: content
                )
                let row = Message(
                    id: UUID(),
                    peerHex: peerHex,
                    isOutgoing: true,
                    body: text,
                    timestamp: date.now,
                    status: MessageStatus.sending,
                    validated: false,
                    messageHash: msg.hash.hexString
                )
                state.draft = ""
                return .run { [database] send in
                    try await database.write { try Message.insert { row }.execute($0) }
                    try await reloadThread(database, peerHex, send)
                    try await reloadConversations(database, send)
                    await send(.node(.send(
                        destinationHash: peer,
                        title: title,
                        content: content,
                        method: .opportunistic
                    )))
                }

            case let .node(.delegate(.messageReceived(m, validated))):
                let incomingPeer = m.sourceHash.hexString
                let row = Message(
                    id: UUID(),
                    peerHex: incomingPeer,
                    isOutgoing: false,
                    body: String(decoding: m.content, as: UTF8.self),
                    timestamp: date.now,
                    status: MessageStatus.received,
                    validated: validated,
                    messageHash: ""
                )
                let openPeer = state.openPeerHex
                return .run { [database] send in
                    try await database.write { try Message.insert { row }.execute($0) }
                    try await reloadConversations(database, send)
                    if incomingPeer == openPeer {
                        try await reloadThread(database, incomingPeer, send)
                    }
                }

            case let .node(.delegate(.deliveryFailed(hash))):
                let hex = hash.hexString
                let openPeer = state.openPeerHex
                return .run { [database] send in
                    try await database.write {
                        try Message.where { $0.messageHash.eq(hex) }
                            .update { $0.status = MessageStatus.failed }
                            .execute($0)
                    }
                    try await reloadConversations(database, send)
                    if let openPeer {
                        try await reloadThread(database, openPeer, send)
                    }
                }

            case let .conversationsLoaded(rows):
                state.conversations = rows
                return .none

            case let .threadLoaded(rows):
                state.threadMessages = rows
                return .none

            case .node, .binding:
                return .none
            }
        }
    }
}

// Reload helpers (file-scope free functions — no self capture in @Sendable effects).
private func reloadConversations(_ database: any DatabaseWriter, _ send: Send<AppFeature.Action>) async throws {
    let all = try await database.read { try Message.fetchAll($0) }
    await send(.conversationsLoaded(Conversation.list(from: all)))
}

private func reloadThread(_ database: any DatabaseWriter, _ peerHex: String, _ send: Send<AppFeature.Action>) async throws {
    let rows = try await database.read {
        try Message.where { $0.peerHex.eq(peerHex) }.order(by: \.timestamp).fetchAll($0)
    }
    await send(.threadLoaded(rows))
}
```

- [ ] **Step 2: Confirm it compiles**

Run: `swift build --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`
Expected: builds. (Tests still reference removed API and will fail to build until Step 3 — that's next.)

- [ ] **Step 3: Rewrite the reducer tests**

Replace the entire contents of `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` with:

```swift
import Testing
import Foundation
import ComposableArchitecture
import Sharing
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCaMsgrCore

// MARK: - Helpers

private func makeStore(_ db: any DatabaseWriter, identity: Identity) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: AppFeature.State(identity: identity)) {
        AppFeature()
    } withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(
            open: { _, _ in AsyncStream { _ in } },
            send: { _ in },
            close: { }
        )
    }
    store.exhaustivity = .off
    return store
}

private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
}

private func seed(_ db: any DatabaseWriter, _ rows: [Message]) async throws {
    try await db.write { d in
        for r in rows { try Message.insert { r }.execute(d) }
    }
}

private func msg(_ id: Int, _ peer: String, _ body: String, _ ts: TimeInterval,
                 outgoing: Bool = true, status: String = MessageStatus.sent,
                 hash: String = "") -> Message {
    Message(id: uuid(id), peerHex: peer, isOutgoing: outgoing, body: body,
            timestamp: Date(timeIntervalSince1970: ts), status: status,
            validated: false, messageHash: hash)
}

private let peerA = String(repeating: "a", count: 32)   // 16-byte hex
private let peerB = String(repeating: "b", count: 32)

// MARK: - Tests

@MainActor
@Test func onLaunchLoadsConversations() async {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [msg(1, peerA, "to-a", 1000), msg(2, peerB, "to-b", 2000)])
    let store = makeStore(db, identity: Identity())
    await store.send(.onLaunch)
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    #expect(store.state.connection == .connecting)
    #expect(store.state.conversations.count == 2)
    #expect(store.state.conversations.first?.peerHex == peerB)   // ts 2000 newest
}

@MainActor
@Test func openConversationLoadsThatPeersThread() async {
    let db = try! AppDatabase.makeInMemory()
    try! await seed(db, [msg(1, peerA, "a1", 1000), msg(2, peerA, "a2", 1500), msg(3, peerB, "b1", 2000)])
    let store = makeStore(db, identity: Identity())
    await store.send(.openConversation(peerA))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.openPeerHex == peerA)
    #expect(store.state.threadMessages.count == 2)
    #expect(store.state.threadMessages.allSatisfy { $0.peerHex == peerA })
    #expect(store.state.threadMessages.map(\.body) == ["a1", "a2"])   // timestamp order
}

@MainActor
@Test func sendPersistsToOpenPeerAndReloadsBoth() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    store.state.openPeerHex = peerA
    store.state.draft = "hello"
    await store.send(.sendTapped)
    await store.receive { action in
        if case let .node(.send(dest, _, content, method)) = action {
            #expect(dest == Data(hexString: peerA))
            #expect(content == Data("hello".utf8))
            #expect(method == .opportunistic)
            return true
        }
        return false
    }
    let rows = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }
    #expect(rows.count == 1)
    #expect(rows.first?.isOutgoing == true)
    #expect(rows.first?.body == "hello")
    #expect(store.state.threadMessages.contains { $0.body == "hello" })
    #expect(store.state.conversations.first?.peerHex == peerA)
    #expect(store.state.draft == "")
}

@MainActor
@Test func receivedFromOpenPeerReloadsThread() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let senderDeliveryHex = LXMessage.deliveryHash(identityHash: sender.hash).hexString
    let store = makeStore(db, identity: me)
    store.state.openPeerHex = senderDeliveryHex
    let m = LXMessage.create(
        source: sender,
        destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1700000000.5,
        title: Data(),
        content: Data("hi".utf8)
    )
    await store.send(.node(.delegate(.messageReceived(message: m, signatureValidated: true))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.threadMessages.contains { $0.body == "hi" })
}

@MainActor
@Test func receivedFromOtherPeerDoesNotReloadThread() async {
    let db = try! AppDatabase.makeInMemory()
    let me = Identity()
    let sender = Identity()
    let store = makeStore(db, identity: me)
    // A different peer's thread is open, with a sentinel already loaded.
    let sentinel = [msg(1, peerA, "sentinel", 1000)]
    store.state.openPeerHex = peerA
    store.state.threadMessages = sentinel
    let m = LXMessage.create(
        source: sender,
        destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
        timestamp: 1700000000.5,
        title: Data(),
        content: Data("elsewhere".utf8)
    )
    await store.send(.node(.delegate(.messageReceived(message: m, signatureValidated: true))))
    await store.receive { if case .conversationsLoaded = $0 { return true }; return false }
    // No threadLoaded should arrive; the open thread is untouched.
    #expect(store.state.threadMessages == sentinel)
}

@MainActor
@Test func deliveryFailedMarksFailedAndReloads() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    store.state.openPeerHex = peerA
    store.state.draft = "hello"
    await store.send(.sendTapped)
    await store.receive { if case .node(.send(_, _, _, _)) = $0 { return true }; return false }
    let sent = try! await db.read { try Message.where { $0.peerHex.eq(peerA) }.fetchAll($0) }
    let hashHex = sent.first!.messageHash
    let hashData = Data(hexString: hashHex)!
    await store.send(.node(.delegate(.deliveryFailed(messageHash: hashData))))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    let failed = store.state.threadMessages.first { $0.messageHash == hashHex }
    #expect(failed?.status == MessageStatus.failed)
}

@MainActor
@Test func pathLearnedMarksPeerReachable() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    let h = Data(repeating: 0xAB, count: 16)
    await store.send(.node(.endpoint(.delegate(.pathLearned(destinationHash: h, hops: 1)))))
    #expect(store.state.reachablePeers.contains(h.hexString))
}

@MainActor
@Test func startConversationRejectsInvalidHex() async {
    let db = try! AppDatabase.makeInMemory()
    let store = makeStore(db, identity: Identity())
    await store.send(.startConversation("nothex"))
    #expect(store.state.openPeerHex == nil)
    await store.send(.startConversation(String(repeating: "a", count: 10)))   // 5 bytes, too short
    #expect(store.state.openPeerHex == nil)
    // A valid 16-byte hex is accepted.
    await store.send(.startConversation(peerA))
    await store.receive { if case .threadLoaded = $0 { return true }; return false }
    #expect(store.state.openPeerHex == peerA)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`
Expected: all pass (this task's 8 + Task 1's + any older still-valid tests).

Note on `Data.hexString`: it is `internal` to ReTiCaMsgrCore (defined in `Data+Hex.swift`), and the tests `@testable import ReTiCaMsgrCore`, so `h.hexString` / `Data(hexString:)` are in scope. If a test-only helper needs it and it is not visible, that is a signal something changed — do not re-add a private copy; use the existing internal one.

- [ ] **Step 5: Mutation-verify** (per Global Constraints). Batch mutations, each targeting a distinct test, then run the whole suite once:
  - `openConversation`: comment out `state.openPeerHex = peerHex` → `openConversationLoadsThatPeersThread` and `startConversationRejectsInvalidHex` fail.
  - `messageReceived` peer filter: change `if incomingPeer == openPeer` to `if true` → `receivedFromOtherPeerDoesNotReloadThread` fails (thread gets reloaded, sentinel replaced).
  - `deliveryFailed`: change `MessageStatus.failed` to `MessageStatus.sent` in the `.update` → `deliveryFailedMarksFailedAndReloads` fails.
  - `pathLearned`: comment out `state.reachablePeers.insert(h.hexString)` → `pathLearnedMarksPeerReachable` fails.
  - `startConversation` guard: change `data.count == 16` to `data.count >= 0` → `startConversationRejectsInvalidHex` fails (short/invalid accepted).
  - `sendTapped`: change `method: .opportunistic` to `.direct` → `sendPersistsToOpenPeerAndReloadsBoth` and `deliveryFailedMarksFailedAndReloads` fail.
  - `onLaunch`: comment out the `reloadConversations` run in the `.merge` → `onLaunchLoadsConversations` fails.
  Confirm every listed test fails, then revert ALL mutations and rerun → all pass.

- [ ] **Step 6: Commit**

Write the message to `/tmp/ReTiCaMsgr/t2.txt`, then:
```
git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift
git -C /Users/ell/development/ios/apps/ReTiCaMsgr commit -F /tmp/ReTiCaMsgr/t2.txt
git -C /Users/ell/development/ios/apps/ReTiCaMsgr log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'
```
Message body (trailers at column 0):
```
feat: AppFeature multi-conversation reducer (slice 2 task 2)

Replace single-peer model (peerAddressHex/messages/peerReachable) with
conversations[]/openPeerHex/threadMessages/reachablePeers. openConversation
+ startConversation (hex-validated) load per-peer threads; sendTapped targets
openPeerHex + reloads both; messageReceived peer-filters the thread reload;
deliveryFailed + pathLearned generalized per-peer. 8 TestStore tests,
mutation-verified.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Task 3: SwiftUI views — conversation list, compose, per-peer thread

**Files:**
- Create: `ReTiCaMsgr/ConversationListView.swift`
- Modify: `ReTiCaMsgr/ChatView.swift`
- Modify: `ReTiCaMsgr/SettingsView.swift`
- Modify: `ReTiCaMsgr/ContentView.swift`

**Interfaces:**
- Consumes: `AppFeature` state/actions from Task 2 (`conversations`, `openPeerHex`, `threadMessages`, `reachablePeers`, `draft`, `connection`, actions `openConversation`, `closeConversation`, `startConversation`, `sendTapped`). `Conversation` (Task 1). `Message`, `MessageStatus` (existing).
- Produces: the app UI. Verified only by `xcodebuild` (views are not unit-tested, matching slice 1).

- [ ] **Step 1: Add a short-hex helper + `ConversationListView`**

Create `ReTiCaMsgr/ConversationListView.swift`:

```swift
import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

/// Truncate a hex address for display: first 4 + … + last 2.
func shortHex(_ hex: String) -> String {
    guard hex.count > 8 else { return hex }
    return "\(hex.prefix(4))…\(hex.suffix(2))"
}

struct ConversationListView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var showingCompose = false

    var connectionColor: Color {
        switch store.connection {
        case .disconnected: return .red
        case .connecting: return .yellow
        case .connected: return .green
        }
    }

    var body: some View {
        NavigationStack {
            List(store.conversations) { convo in
                Button {
                    store.send(.openConversation(convo.peerHex))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortHex(convo.peerHex))
                            .font(.system(.headline, design: .monospaced))
                        Text(convo.lastBody)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Circle().fill(connectionColor).frame(width: 10, height: 10)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingCompose = true } label: { Image(systemName: "plus") }
                }
            }
            .navigationDestination(
                isPresented: Binding(
                    get: { store.openPeerHex != nil },
                    set: { presented in if !presented { store.send(.closeConversation) } }
                )
            ) {
                ChatView(store: store)
            }
            .sheet(isPresented: $showingCompose) {
                ComposeSheet(store: store, isPresented: $showingCompose)
            }
        }
    }
}

struct ComposeSheet: View {
    @Bindable var store: StoreOf<AppFeature>
    @Binding var isPresented: Bool
    @State private var address: String = ""

    // Uses the public `isValidPeerAddress` helper added in Step 2 (add that
    // helper first — `Data(hexString:)` is internal to the package and NOT
    // visible to the app target).
    private var isValid: Bool { isValidPeerAddress(address) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Peer LXMF address (hex)") {
                    TextField("32 hex characters", text: $address)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                }
                Button("Start conversation") {
                    store.send(.startConversation(address))
                    isPresented = false
                }
                .disabled(!isValid)
            }
            .navigationTitle("New conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}
```

Note: `ConversationListView.swift` above references `isValidPeerAddress` — a public helper added to the core package in Step 2. Add Step 2's helper before expecting this file to compile.

- [ ] **Step 2: Expose a public hex-validation helper from the core package**

The app target cannot see `Data(hexString:)` (internal). Add a small public validator to `ReTiCaMsgrCore` so both the reducer guard and the compose sheet share one definition. In `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Conversation.swift` (or a new `HexAddress.swift`), append:

```swift
/// True iff `hex` decodes to a 16-byte lxmf.delivery hash.
public func isValidPeerAddress(_ hex: String) -> Bool {
    Data(hexString: hex)?.count == 16
}
```

(The reducer's `startConversation` guard may also call `isValidPeerAddress(hex)` for a single source of truth, but that is optional — the existing `Data(hexString:)` guard inside the package already works.)

- [ ] **Step 3: Re-parameterize `ChatView` for the open thread**

Replace the entire contents of `ReTiCaMsgr/ChatView.swift` with:

```swift
import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

struct ChatView: View {
    @Bindable var store: StoreOf<AppFeature>

    private var canSend: Bool {
        guard let peer = store.openPeerHex else { return false }
        return store.reachablePeers.contains(peer) && !store.draft.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            List(store.threadMessages) { message in
                MessageBubble(message: message)
                    .listRowSeparator(.hidden)
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
    }
}

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer() }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(message.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isOutgoing ? Color.blue : Color(.systemGray5))
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
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
```

(`ChatView` no longer owns a `NavigationStack` — it is pushed inside `ConversationListView`'s stack. Its own connection dot moves to the list.)

- [ ] **Step 4: Remove the peer section from `SettingsView`**

Edit `ReTiCaMsgr/SettingsView.swift`: delete the `@State private var peerInput` line and the entire `Section("Peer Address") { … }` block. Keep the `Section("Node Connection")` block and the `.navigationTitle("Settings")`. Result:

```swift
import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

struct SettingsView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        NavigationStack {
            Form {
                Section("Node Connection") {
                    TextField("Host", text: $store.host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", value: $store.port, format: .number)
                        .keyboardType(.numberPad)
                    HStack {
                        Button("Connect") { store.send(.connectTapped) }
                            .buttonStyle(.bordered)
                        Button("Disconnect") { store.send(.disconnectTapped) }
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
```

- [ ] **Step 5: Point the Chat tab at `ConversationListView`**

Edit `ReTiCaMsgr/ContentView.swift`: replace the `ChatView(store: store)` tab child with `ConversationListView(store: store)`. Result:

```swift
import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

struct RootView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        TabView {
            ConversationListView(store: store)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            AddressView(store: store)
                .tabItem { Label("Address", systemImage: "person.crop.circle") }
            SettingsView(store: store)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
```

- [ ] **Step 6: Build the app**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`. (New file `ConversationListView.swift` must be added to the `ReTiCaMsgr` target. The project uses the file-system-synchronized group under `ReTiCaMsgr/`, so a new `.swift` file there is picked up automatically; if the build reports the type missing, add the file reference to the `ReTiCaMsgr` target in `project.pbxproj` alongside the sibling views.)

- [ ] **Step 7: Run the package tests once more**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`
Expected: all pass (the public `isValidPeerAddress` addition and view changes must not have broken the reducer/tests).

- [ ] **Step 8: Commit**

Write the message to `/tmp/ReTiCaMsgr/t3.txt`, then:
```
git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgr/ ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/
git -C /Users/ell/development/ios/apps/ReTiCaMsgr commit -F /tmp/ReTiCaMsgr/t3.txt
git -C /Users/ell/development/ios/apps/ReTiCaMsgr log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'
```
Message body (trailers at column 0):
```
feat: conversation-list UI + per-peer thread views (slice 2 task 3)

Chat tab is now a NavigationStack: ConversationListView (rows = distinct
peers, short-hex + last-message preview, connection dot, + compose sheet)
pushes the re-parameterized ChatView (threadMessages, per-peer reachable
Send gate). SettingsView loses the peer field. Public isValidPeerAddress
helper for the compose validator. xcodebuild BUILD SUCCEEDED.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review (completed)

- **Spec coverage:** Address-only derived conversations → Task 1 + reducer reloads. No `Contact` table / no migration → confirmed (no `Message.swift`/`Database.swift` changes). List→thread + compose → Task 3 `ConversationListView`/`ComposeSheet`. Per-peer reachable gate → `reachablePeers` (Task 2) + `canSend` (Task 3). Peer-filtered `messageReceived` reload → Task 2 `receivedFromOtherPeerDoesNotReloadThread`. Settings loses peer field → Task 3 Step 4. Opportunistic only → `sendTapped` uses `.opportunistic`; no propagation wiring. All 8 spec tests present in Task 2.
- **Placeholder scan:** none — every code step is complete.
- **Type consistency:** `Conversation.list(from:)`, `isValidPeerAddress(_:)`, `shortHex(_:)`, state fields `conversations/openPeerHex/threadMessages/reachablePeers`, and actions `openConversation/closeConversation/startConversation/conversationsLoaded/threadLoaded` are spelled identically across tasks. Delegate signatures match ReTiCANode (`pathLearned(destinationHash:hops:)`, `messageReceived(message:signatureValidated:)`, `deliveryFailed(messageHash:)`, `send(destinationHash:title:content:method:)`).
- **Known integration risk:** `Data(hexString:)` is internal to the package → the app-target compose validator uses the new public `isValidPeerAddress` (Task 3 Step 2), not `Data(hexString:)` directly.
