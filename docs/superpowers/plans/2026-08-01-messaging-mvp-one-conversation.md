# ReTiCaMsgr MVP — One Conversation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iOS app where two devices, each connected to the same Reticulum TCP hub, add each other by LXMF address and exchange opportunistic messages in a single chat screen, with a persistent identity and message history.

**Architecture:** All logic lives in a local SPM package `ReTiCaMsgrCore` (an `AppFeature` TCA `@Reducer` scoping `LXMFNode` from the `ReTiCA` package, `Message` persistence via SharingGRDB, an `IdentityStore` Keychain client). The Xcode app target links only `ReTiCaMsgrCore` and holds the SwiftUI views + `App` entry. Tasks 1–4 are verified headlessly with `swift test`; Task 5 wires the Xcode shell (verified with `xcodebuild`).

**Tech Stack:** Swift, Point-Free Composable Architecture (TCA), SharingGRDB (`pointfreeco/sharing-grdb`), the local `ReTiCA` package (`ReTiCANode`), SwiftUI, iOS 26.4.

## Global Constraints

- **App repo:** `/Users/ell/development/ios/apps/ReTiCaMsgr`. Commit to its `main` branch. (This is NOT the ReTiCA repo.)
- **No compound shell commands** — one command per invocation; no `&&`/`||`/`;`/`|`-chains/`xargs`/inline interpreter scripts. A single `>` redirect is allowed. Write files with the editor, not echo/heredoc.
- **Temp files** go in `/tmp/ReTiCaMsgr/`.
- **Commit trailers, verbatim, at COLUMN 0 (no leading whitespace)**, via `git commit -F <file>` (never `-m`):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
  Verify after commit: `git -C <repo> log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'` must print the URL.
- **ReTiCA package path** from the app repo: `../../pods/ReTiCA` (i.e. `/Users/ell/development/ios/pods/ReTiCA`).
- **Live dependencies:** production uses ReTiCA's live `tcpConnection` (real `NWConnection`), `date`, `uuid`, `randomBytes`, `continuousClock`. Tests inject mocks.
- **Three-step mutation verification** for every new test (run pass → mutate to force fail + confirm → revert + confirm pass). One mutation at a time. (For the Xcode task, "test" = `xcodebuild build` succeeding.)
- **Delivery is opportunistic/best-effort** — no delivered receipt; sent messages are `.sent` optimistically, `.failed` only on `deliveryFailed`.
- If a Swift build shows a stale cross-module link error, run `swift package clean` in the core package then retry.

---

### Task 1: Scaffold the `ReTiCaMsgrCore` SPM package

Create the local package and confirm all three external dependencies resolve and a trivial test runs. This de-risks the dependency graph before any logic.

**Files:**
- Create: `ReTiCaMsgrCore/Package.swift`
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/ReTiCaMsgrCore.swift`
- Create: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/SmokeTests.swift`

**Interfaces:**
- Produces: the `ReTiCaMsgrCore` library target (depends on `ReTiCANode` + `ComposableArchitecture` + `SharingGRDB`), usable by the Xcode app.

- [ ] **Step 1: Write `Package.swift`.**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReTiCaMsgrCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReTiCaMsgrCore", targets: ["ReTiCaMsgrCore"]),
    ],
    dependencies: [
        .package(path: "../../../pods/ReTiCA"),
        .package(url: "https://github.com/pointfreeco/sharing-grdb", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "ReTiCaMsgrCore",
            dependencies: [
                .product(name: "ReTiCANode", package: "ReTiCA"),
                .product(name: "SharingGRDB", package: "sharing-grdb"),
            ]
        ),
        .testTarget(
            name: "ReTiCaMsgrCoreTests",
            dependencies: ["ReTiCaMsgrCore"]
        ),
    ]
)
```

NOTE: `.macOS(.v14)` lets tests run headlessly on the Mac. The `from:` version for `sharing-grdb` is a floor — if resolution reports a different available version, use the latest resolved; do NOT pin to an unavailable version. `.package(path:)` is relative to `ReTiCaMsgrCore/` so `../../../pods/ReTiCA` reaches `/Users/ell/development/ios/pods/ReTiCA`.

- [ ] **Step 2: Write a placeholder source + a smoke test.**

`Sources/ReTiCaMsgrCore/ReTiCaMsgrCore.swift`:
```swift
public enum ReTiCaMsgrCore {
    public static let version = "0.1.0"
}
```
`Tests/ReTiCaMsgrCoreTests/SmokeTests.swift`:
```swift
import Testing
@testable import ReTiCaMsgrCore

@Test func coreVersionIsSet() {
    #expect(ReTiCaMsgrCore.version == "0.1.0")
}
```

- [ ] **Step 3: Resolve + build + test.**

Run (each its own command, from `/Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore`):
- `swift package resolve`
- `swift build`
- `swift test --filter coreVersionIsSet`

Expected: dependencies resolve (ReTiCA + SharingGRDB + their transitive deps incl. `swift-composable-architecture`, `GRDB`, `swift-sharing`); build succeeds; the test passes. If resolution fails on the `sharing-grdb` version floor, adjust to the resolved latest and retry. If ReTiCA fails to resolve at `../../../pods/ReTiCA`, STOP and report the exact path error (do not guess a different path).

- [ ] **Step 4: Commit.** (column-0 trailers; verify parse after)

Write `/tmp/ReTiCaMsgr/commit-msg-t1.txt`, then:
```bash
git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgrCore
git -C /Users/ell/development/ios/apps/ReTiCaMsgr commit -F /tmp/ReTiCaMsgr/commit-msg-t1.txt
```
Subject: `feat: scaffold ReTiCaMsgrCore package (ReTiCANode + SharingGRDB)`

---

### Task 2: `Message` table + database

Define the persisted message model and a database factory (a shared in-memory maker for tests, a file-backed maker for the app), and prove insert/fetch.

**Files:**
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Message.swift`
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Database.swift`
- Create: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/DatabaseTests.swift`

**Interfaces:**
- Consumes: `SharingGRDB` (`@Table`, `@FetchAll`, `defaultDatabase` dependency, GRDB `DatabaseQueue`/migrator).
- Produces: `Message` (a `@Table` struct with fields below), `AppDatabase.makeInMemory() throws -> any DatabaseWriter`, `AppDatabase.makeOnDisk(path:) throws -> any DatabaseWriter`, and a `MessageStatus` string constants set.

- [ ] **Step 1: Define `Message` and `MessageStatus`.**

`Message.swift`:
```swift
import Foundation
import SharingGRDB

/// A single chat message row. `peerHex` is the other party's lxmf.delivery hash (hex);
/// `messageHash` is the LXMessage.hash of an outgoing message (hex), used to correlate deliveryFailed.
@Table
public struct Message: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var peerHex: String
    public var isOutgoing: Bool
    public var body: String
    public var timestamp: Date
    public var status: String        // MessageStatus.*
    public var validated: Bool       // incoming: signature validated
    public var messageHash: String   // outgoing: LXMessage.hash hex ("" for incoming)
}

public enum MessageStatus {
    public static let sending = "sending"
    public static let sent = "sent"
    public static let failed = "failed"
    public static let received = "received"
}
```

IMPORTANT: `@Table` is a SharingGRDB macro. Confirm its exact usage (macro name, whether a `columns`/`draft` companion is generated, how the primary key is declared) against the resolved `SharingGRDB` package's README/source (added in Task 1) and adjust the declaration to compile. The FIELD SET and their meanings are load-bearing and must not change.

- [ ] **Step 2: Database factory + migration.**

`Database.swift`:
```swift
import Foundation
import GRDB
import SharingGRDB

public enum AppDatabase {
    /// GRDB migrator creating the `messages` table.
    static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("createMessages") { db in
            try db.create(table: "messages") { t in
                t.primaryKey("id", .text).notNull()
                t.column("peerHex", .text).notNull()
                t.column("isOutgoing", .boolean).notNull()
                t.column("body", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("validated", .boolean).notNull()
                t.column("messageHash", .text).notNull()
            }
        }
        return m
    }

    public static func makeInMemory() throws -> any DatabaseWriter {
        let queue = try DatabaseQueue()
        try migrator().migrate(queue)
        return queue
    }

    public static func makeOnDisk(path: String) throws -> any DatabaseWriter {
        let queue = try DatabaseQueue(path: path)
        try migrator().migrate(queue)
        return queue
    }
}
```

NOTE: confirm the SharingGRDB table name that `@Table` expects for `Message` (it may derive `messages` from the type, or need an explicit name). Make the migration's table name + column names match what `@FetchAll`/`@Table` query against, or fetches return nothing. Reconcile against the package; the schema shape (these 8 columns) is fixed.

- [ ] **Step 3: Write the failing test.**

`DatabaseTests.swift`:
```swift
import Testing
import Foundation
import GRDB
import SharingGRDB
@testable import ReTiCaMsgrCore

@Test func messageInsertAndFetchByPeer() throws {
    let db = try AppDatabase.makeInMemory()
    let peer = "aa" + String(repeating: "00", count: 15)
    let m = Message(id: UUID(0), peerHex: peer, isOutgoing: true, body: "hi",
                    timestamp: Date(timeIntervalSince1970: 1), status: MessageStatus.sent,
                    validated: false, messageHash: "abcd")
    try db.write { try Message.insert { m }.execute($0) }
    let rows = try db.read { try Message.where { $0.peerHex == peer }.order(by: \.timestamp).fetchAll($0) }
    #expect(rows == [m])
}
```

NOTE: the insert/fetch call syntax (`Message.insert { … }`, `Message.where { … }`, `.fetchAll`) is SharingGRDB/StructuredQueries API — confirm the exact spelling against the resolved package and adjust so it compiles; the assertion (`rows == [m]`) is load-bearing. `UUID(0)` uses the deterministic-UUID init from ComposableArchitecture/Dependencies (available transitively) — if not, use a fixed `UUID(uuidString:)`.

- [ ] **Step 4: Run → fail → (Steps 1-2 make it pass) → run → pass.**

Run: `swift test --filter messageInsertAndFetchByPeer`
Expected: PASS after the model + DB compile.

- [ ] **Step 5: Mutation-verify.** Change the migration to omit the `peerHex` column (or the fetch filter to a wrong column) → the test must FAIL (fetch returns nothing / errors). Revert → PASS.

- [ ] **Step 6: Commit.** (column-0 trailers)
```bash
git -C /Users/ell/development/ios/apps/ReTiCaMsgr add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Message.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Database.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/DatabaseTests.swift
git -C /Users/ell/development/ios/apps/ReTiCaMsgr commit -F /tmp/ReTiCaMsgr/commit-msg-t2.txt
```
Subject: `feat: Message @Table + GRDB database factory`

---

### Task 3: `IdentityStore` client + address helper

A dependency that loads/persists the user's `Identity` (Keychain live, in-memory for tests), plus the LXMF address helper.

**Files:**
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/IdentityStore.swift`
- Create: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/IdentityStoreTests.swift`

**Interfaces:**
- Consumes: `ReTiCA.Identity` (`init()`, `init?(privateKey:)`, `.privateKey: Data?`, `.hash`), `LXMessage.deliveryHash(identityHash:)`, TCA `@Dependency`/`DependencyKey`.
- Produces: `IdentityStore` client (`load: () -> Identity`), a `\.identityStore` dependency, and `func lxmfAddressHex(_ identity: Identity) -> String` (= delivery-hash hex).

- [ ] **Step 1: Define the client + address helper.**

`IdentityStore.swift`:
```swift
import Foundation
import Dependencies
import ReTiCA
#if canImport(Security)
import Security
#endif

/// Loads the persistent user Identity: from Keychain if present, else generates + stores one.
public struct IdentityStore: Sendable {
    public var load: @Sendable () -> Identity
}

/// The user's shareable LXMF address = their lxmf.delivery destination hash, hex-encoded.
public func lxmfAddressHex(_ identity: Identity) -> String {
    LXMessage.deliveryHash(identityHash: identity.hash).hexString
}

extension IdentityStore: DependencyKey {
    public static var liveValue: IdentityStore {
        IdentityStore(load: {
            #if canImport(Security)
            if let data = KeychainIdentity.read(), let id = Identity(privateKey: data) { return id }
            let id = Identity()
            if let pk = id.privateKey { KeychainIdentity.write(pk) }
            return id
            #else
            return Identity()
            #endif
        })
    }
    public static var testValue: IdentityStore {
        // Deterministic-enough for tests: a fixed in-process identity.
        let id = Identity()
        return IdentityStore(load: { id })
    }
}

public extension DependencyValues {
    var identityStore: IdentityStore {
        get { self[IdentityStore.self] }
        set { self[IdentityStore.self] = newValue }
    }
}

#if canImport(Security)
enum KeychainIdentity {
    static let service = "com.reticamsgr.identity"
    static let account = "primary"
    static func read() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    static func write(_ data: Data) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}
#endif
```

NOTE: `Data.hexString` is used elsewhere in ReTiCA (`Identity.hexHash`). Confirm it is public/importable; if not, add a tiny local `hexString` helper. The Keychain `liveValue` is NOT unit-tested (Keychain needs a host app); it's verified manually in the app. Tests use `testValue`.

- [ ] **Step 2: Write the failing test.**

`IdentityStoreTests.swift`:
```swift
import Testing
import Foundation
import Dependencies
import ReTiCA
@testable import ReTiCaMsgrCore

@Test func identityStoreTestValueIsStableAndAddressIsDeliveryHash() {
    let store = IdentityStore.testValue
    let a = store.load(); let b = store.load()
    #expect(a.hash == b.hash)                                   // stable within a run
    #expect(lxmfAddressHex(a) == LXMessage.deliveryHash(identityHash: a.hash).hexString)
}

@Test func identityRoundTripsThroughPrivateKey() {
    let id = Identity()
    let restored = Identity(privateKey: id.privateKey!)
    #expect(restored?.hash == id.hash)                          // persistence round-trip (what Keychain does)
}
```

- [ ] **Step 3: Run → pass; mutation-verify.**

Run: `swift test --filter identity`
Expected: PASS. Mutation: make `lxmfAddressHex` return `identity.hash.hexString` (identity hash, not delivery hash) → the first test FAILS. Revert → PASS.

- [ ] **Step 4: Commit.** Subject: `feat: IdentityStore (Keychain) client + LXMF address helper`

---

### Task 4: `AppFeature` reducer

The composed reducer wiring `LXMFNode` to connection/send/receive/persistence, with `TestStore` tests.

**Files:**
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift`
- Create: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`

**Interfaces:**
- Consumes: `LXMFNode` (`.State(identity:endpoint:)`, actions `.registerDelivery`, `.send(destinationHash:title:content:method:)`, `.endpoint(Endpoint.Action)`, delegates `.messageReceived(message:signatureValidated:)`, `.deliveryFailed(messageHash:)`); `Endpoint.State(host:port:reconnectOnDrop:)`, `Endpoint.Action.connect`/`.disconnect`, `.transport(.interfaceConnected(_))`/`.transport(.interfaceDisconnected(_))`, `.delegate(.pathLearned(destinationHash:hops:))`; `LXMFRouter.DeliveryMethod.opportunistic`; `LXMessage.create`/`.deliveryHash`/`.hash`; `Message`, `MessageStatus`, `AppDatabase`, `IdentityStore`, `lxmfAddressHex`.
- Produces: `AppFeature` reducer + `AppFeature.State(identity:host:port:)`.

- [ ] **Step 1: Write the reducer.**

`AppFeature.swift`:
```swift
import Foundation
import ComposableArchitecture
import SharingGRDB
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
        @Shared(.appStorage("peerAddressHex")) public var peerAddressHex: String = ""
        @Shared(.appStorage("host")) public var host: String = "127.0.0.1"
        @Shared(.appStorage("port")) public var port: Int = 4242
        public var peerReachable = false
        public var connection: Connection = .disconnected
        public var draft = ""
        @FetchAll public var messages: [Message]

        public init(identity: Identity, host: String = "127.0.0.1", port: Int = 4242) {
            self.identity = identity
            self.myAddressHex = lxmfAddressHex(identity)
            self.node = LXMFNode.State(identity: identity,
                                       endpoint: Endpoint.State(host: host, port: UInt16(port), reconnectOnDrop: true))
            _host = Shared(wrappedValue: host, .appStorage("host"))
            _port = Shared(wrappedValue: port, .appStorage("port"))
            let peer = self.peerAddressHex
            _messages = FetchAll(Message.where { $0.peerHex == peer }.order(by: \.timestamp))
        }
    }

    public enum Action: Equatable, BindableAction {
        case onLaunch
        case connectTapped
        case disconnectTapped
        case setPeer(String)
        case sendTapped
        case node(LXMFNode.Action)
        case binding(BindingAction<State>)
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date
    public init() {}

    var peerHash: Data? {
        // peerAddressHex is the peer's lxmf.delivery hash, hex.
        Data(hexString:)   // resolved below
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.node, action: \.node) { LXMFNode() }
        Reduce { state, action in
            switch action {
            case .onLaunch:
                state.connection = .connecting
                return .send(.node(.endpoint(.connect)))

            case .connectTapped:
                state.connection = .connecting
                return .send(.node(.endpoint(.connect)))

            case .disconnectTapped:
                state.connection = .disconnected
                return .send(.node(.endpoint(.disconnect)))

            case .node(.endpoint(.transport(.interfaceConnected))):
                state.connection = .connected
                return .send(.node(.registerDelivery))

            case .node(.endpoint(.transport(.interfaceDisconnected))):
                state.connection = .disconnected
                return .none

            case let .node(.endpoint(.delegate(.pathLearned(h, _)))):
                if let peer = Data(hexString: state.peerAddressHex), h == peer { state.peerReachable = true }
                return .none

            case let .setPeer(hex):
                state.$peerAddressHex.withLock { $0 = hex }
                state.peerReachable = false
                return .none

            case .sendTapped:
                let text = state.draft
                guard !text.isEmpty, let peer = Data(hexString: state.peerAddressHex) else { return .none }
                let title = Data(); let content = Data(text.utf8)
                let msg = LXMessage.create(source: state.identity, destinationHash: peer,
                                           timestamp: date.now.timeIntervalSince1970, title: title, content: content)
                let row = Message(id: UUID(), peerHex: state.peerAddressHex, isOutgoing: true, body: text,
                                  timestamp: date.now, status: MessageStatus.sending, validated: false,
                                  messageHash: msg.hash.hexString)
                state.draft = ""
                return .run { [database] send in
                    try database.write { try Message.insert { row }.execute($0) }
                    await send(.node(.send(destinationHash: peer, title: title, content: content, method: .opportunistic)))
                }

            case let .node(.delegate(.messageReceived(m, validated))):
                let row = Message(id: UUID(), peerHex: m.sourceHash.hexString, isOutgoing: false,
                                  body: String(decoding: m.content, as: UTF8.self), timestamp: date.now,
                                  status: MessageStatus.received, validated: validated, messageHash: "")
                return .run { [database] _ in try database.write { try Message.insert { row }.execute($0) } }

            case let .node(.delegate(.deliveryFailed(hash))):
                let hex = hash.hexString
                return .run { [database] _ in
                    try database.write { try Message.where { $0.messageHash == hex }.update { $0.status = MessageStatus.failed }.execute($0) }
                }

            case .node, .binding:
                return .none
            }
        }
    }
}
```

NOTE (reconcile against resolved packages — the WIRING and behavior below are fixed, the exact SharingGRDB/Sharing spelling may differ):
- `Data(hexString:)` — ReTiCA exposes hex⇄Data (used by `Identity.hexHash`/`hexString`). Use ReTiCA's hex init if public; else add a local `Data(hexString:)` + `Data.hexString`. Delete the stray `var peerHash` stub — the reducer parses `Data(hexString: state.peerAddressHex)` inline.
- `@Shared(.appStorage(...))` and `@FetchAll` are from `swift-sharing`/`SharingGRDB`. Confirm the initializer spellings (`Shared(wrappedValue:_:)`, `FetchAll(_:)`, `$peerAddressHex.withLock`) against the resolved packages; the STATE FIELDS and their persistence intent are fixed.
- `Message.insert { … }.execute` / `Message.where { … }.update { … }` — StructuredQueries API; reconcile the exact spelling so it compiles.
- `interfaceConnected`/`interfaceDisconnected` carry an `InterfaceID` payload — match with `.transport(.interfaceConnected)` (ignore payload) as shown; confirm the case path exists on `Endpoint.Action` → `Transport.Action` (it is used in ReTiCA's `EndpointTests` as `\.transport.interfaceConnected`).

- [ ] **Step 2: Write the failing tests.**

`AppFeatureTests.swift`:
```swift
import Testing
import Foundation
import ComposableArchitecture
import SharingGRDB
import ReTiCA
import ReTiCANode
import ReTiCATransport
@testable import ReTiCaMsgrCore

@MainActor
@Test func onLaunchConnectsThenRegistersOnInterfaceUp() async {
    let db = try! AppDatabase.makeInMemory()
    let identity = Identity()
    let store = TestStore(initialState: AppFeature.State(identity: identity)) { AppFeature() }
    withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    await store.send(.onLaunch)
    await store.receive { if case .node(.endpoint(.connect)) = $0 { return true }; return false }
    #expect(store.state.connection == .connecting)
    await store.send(.node(.endpoint(.transport(.interfaceConnected(InterfaceID())))))   // simulate interface up
    #expect(store.state.connection == .connected)
    await store.receive { if case .node(.registerDelivery) = $0 { return true }; return false }
}

@MainActor
@Test func sendPersistsOutgoingAndDispatchesNodeSend() async {
    let db = try! AppDatabase.makeInMemory()
    let identity = Identity()
    let peerHex = "aa" + String(repeating: "bb", count: 15)
    var initial = AppFeature.State(identity: identity)
    initial.$peerAddressHex.withLock { $0 = peerHex }
    initial.draft = "hello"
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    await store.send(.sendTapped)
    await store.receive { action in
        if case let .node(.send(dest, _, content, method)) = action {
            #expect(dest == Data(hexString: peerHex)); #expect(content == Data("hello".utf8)); #expect(method == .opportunistic)
            return true
        }
        return false
    }
    let rows = try! db.read { try Message.where { $0.peerHex == peerHex }.fetchAll($0) }
    #expect(rows.count == 1); #expect(rows.first?.isOutgoing == true); #expect(rows.first?.body == "hello")
}

@MainActor
@Test func receivedMessagePersistsIncomingRow() async {
    let db = try! AppDatabase.makeInMemory()
    let sender = Identity(); let me = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                               timestamp: 1700000000.5, title: Data(), content: Data("incoming".utf8))
    let store = TestStore(initialState: AppFeature.State(identity: me)) { AppFeature() } withDependencies: {
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    await store.send(.node(.delegate(.messageReceived(message: msg, signatureValidated: true))))
    let rows = try! db.read { try Message.fetchAll($0) }
    #expect(rows.count == 1); #expect(rows.first?.isOutgoing == false); #expect(rows.first?.body == "incoming")
    #expect(rows.first?.validated == true)
}
```

NOTE: reconcile the `TCPConnection(open:send:close:)` mock init + `AsyncStream` shape against ReTiCA's `TCPConnection` (see any ReTiCA test using it, e.g. `LXMFNodeOpportunisticTests`); `InterfaceID()` construction against `ReTiCAInterfaces`. The assertions are load-bearing.

- [ ] **Step 3: Run → pass; mutation-verify (one at a time).**

Run: `swift test --filter AppFeature`
- Mutation A — in `.interfaceConnected`, don't send `.registerDelivery` → `onLaunchConnectsThenRegistersOnInterfaceUp` FAILS. Revert → PASS.
- Mutation B — in `.sendTapped`, don't insert the row (skip the `database.write`) → `sendPersistsOutgoingAndDispatchesNodeSend` FAILS (0 rows). Revert → PASS.
- Mutation C — in `.messageReceived`, set `isOutgoing: true` → `receivedMessagePersistsIncomingRow` FAILS. Revert → PASS.

- [ ] **Step 4: Run the full core suite.** `swift test`. Expected: all PASS.

- [ ] **Step 5: Commit.** Subject: `feat: AppFeature reducer (connect/register/send/receive/persist)`

---

### Task 5: Xcode app shell (link core, App entry, SwiftUI views)

Wire the Xcode app target to `ReTiCaMsgrCore`, add the `App` entry (identity load + database + Store) and the three SwiftUI screens, and verify the app builds.

**Files:**
- Modify: `ReTiCaMsgr.xcodeproj/project.pbxproj` (add a local-package dependency on `ReTiCaMsgrCore` + link its product to the app target)
- Modify: `ReTiCaMsgr/ReTiCaMsgrApp.swift`
- Replace: `ReTiCaMsgr/ContentView.swift` → chat + address + settings views
- Create: `ReTiCaMsgr/ChatView.swift`, `ReTiCaMsgr/SettingsView.swift`, `ReTiCaMsgr/AddressView.swift`

**Interfaces:**
- Consumes: `ReTiCaMsgrCore.AppFeature`, `AppDatabase`, `IdentityStore`, `Message`, `MessageStatus`, `lxmfAddressHex`, SharingGRDB `prepareDependencies`/`defaultDatabase`, `@FetchAll`.

- [ ] **Step 1: Link `ReTiCaMsgrCore` to the app target.**

Add `ReTiCaMsgrCore` as a local Swift package to `ReTiCaMsgr.xcodeproj` and link its `ReTiCaMsgrCore` product to the `ReTiCaMsgr` app target. Prefer editing `project.pbxproj` to add: an `XCLocalSwiftPackageReference` with `relativePath = ReTiCaMsgrCore;`, an `XCSwiftPackageProductDependency` (`productName = ReTiCaMsgrCore`), a `PBXBuildFile` referencing it, its inclusion in the target's `Frameworks` build phase, and the `packageReferences`/`packageProductDependencies` arrays.

IF hand-editing `project.pbxproj` is not reliably achievable (the file does not round-trip cleanly), STOP and report NEEDS_CONTEXT with a one-line instruction for the human to add it in Xcode: *File ▸ Add Package Dependencies… ▸ Add Local… ▸ select `ReTiCaMsgrCore`, then add the `ReTiCaMsgrCore` library to the `ReTiCaMsgr` target.* Do not fake the linkage.

- [ ] **Step 2: App entry.**

`ReTiCaMsgrApp.swift`:
```swift
import SwiftUI
import ComposableArchitecture
import SharingGRDB
import ReTiCA
import ReTiCaMsgrCore

@main
struct ReTiCaMsgrApp: App {
    static let store: StoreOf<AppFeature> = {
        let identity = IdentityStore.liveValue.load()
        let dbPath = URL.documentsDirectory.appending(path: "reticamsgr.sqlite").path()
        prepareDependencies { $0.defaultDatabase = try! AppDatabase.makeOnDisk(path: dbPath) }
        return Store(initialState: AppFeature.State(identity: identity)) { AppFeature() }
    }()

    var body: some Scene {
        WindowGroup {
            RootView(store: Self.store).task { Self.store.send(.onLaunch) }
        }
    }
}
```

- [ ] **Step 3: Views.**

Replace `ContentView.swift` with a `RootView` (a `TabView` of Chat / Address / Settings) and create the three view files. Chat: a `List` over `@FetchAll` messages (bubbles by `isOutgoing`), a bottom composer (`TextField` bound to a local draft → `store.send(.binding(...))` for `draft`, a Send button calling `.sendTapped`, disabled unless `store.peerReachable`), and a small connection dot from `store.connection`. Address: `store.myAddressHex` in a selectable/`textSelection(.enabled)` label + a `ShareLink`. Settings: `TextField`s for host/port (bound via `@Shared`/bindings) with Connect/Disconnect buttons, and a peer-address `TextField` with a "Save peer" button calling `.setPeer`.

Keep views minimal — plain SwiftUI, no design system. (Concrete view code is left to the implementer; the load-bearing contract is: Chat reads `@FetchAll` messages and sends `.sendTapped`; Settings drives host/port + `.setPeer` + connect/disconnect; Address shows `myAddressHex`.)

- [ ] **Step 4: Build the app.**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination 'generic/platform=iOS' build`
Expected: BUILD SUCCEEDED. (First build resolves packages; may be slow.) If the scheme name differs, list schemes with `xcodebuild -list -project …` and use the app scheme. If the build fails on the package link, revisit Step 1.

- [ ] **Step 5: Commit.** (column-0 trailers)
```bash
git -C /Users/ell/development/ios/apps/ReTiCaMsgr add -A
git -C /Users/ell/development/ios/apps/ReTiCaMsgr commit -F /tmp/ReTiCaMsgr/commit-msg-t5.txt
```
Subject: `feat: Xcode app shell — link core, App entry, chat/address/settings views`

---

## Self-Review

**Spec coverage:**
- Package linkage (ReTiCA + SharingGRDB) via SPM core → Task 1. ✅
- Persistent identity (Keychain) + address helper → Task 3; used in App entry Task 5. ✅
- Message persistence (SharingGRDB `@Table` + `@FetchAll`) → Task 2 (model/DB), Task 4 (writes + fetch in state). ✅
- Configurable connection (host/port, default local) → Task 4 (`@Shared` host/port), Task 5 (Settings). ✅
- register + announce → Task 4 (`interfaceConnected → registerDelivery`). ✅
- Add peer by delivery-hash + `peerReachable` via `pathLearned` → Task 4. ✅
- Opportunistic send + best-effort status + `deliveryFailed → .failed` → Task 4. ✅
- Receive → persist incoming → Task 4. ✅
- Three screens (chat/address/settings) → Task 5. ✅
- AppFeature TestStore wiring tests + in-memory DB → Task 4. ✅

**Placeholder scan:** the external-library-specific spellings (SharingGRDB `@Table`/`@FetchAll`/StructuredQueries, `@Shared` inits, hex helpers, `TCPConnection` mock, `InterfaceID`) are marked "reconcile against the resolved package" with the load-bearing behavior fixed — this is honest guidance for external APIs I cannot pin exactly, not deferred work. Task 5's view bodies are intentionally described-not-coded (thin SwiftUI); their contract is stated. All reducer wiring, model shape, and tests are concrete.

**Type consistency:** `Message` fields, `MessageStatus.*`, `AppDatabase.makeInMemory/makeOnDisk`, `IdentityStore.load`, `lxmfAddressHex`, `AppFeature.State(identity:host:port:)`, and the `LXMFNode`/`Endpoint` action paths are consistent across tasks and match ReTiCA's actual surface (`LXMFNode.send(destinationHash:title:content:method:)`, `.delegate(.messageReceived(message:signatureValidated:))`, `.delegate(.deliveryFailed(messageHash:))`, `Endpoint.State(host:port:reconnectOnDrop:)`, `.transport(.interfaceConnected)`, `.delegate(.pathLearned(destinationHash:hops:))`, `DeliveryMethod.opportunistic`).
