# Shared Identity Adoption Implementation Plan (ReTiCaMsgr, Part B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ReTiCaMsgr loads its Reticulum identity from the shared Keychain item Nbhd already uses, through `ReTiCAKeychain` only, never minting once messages exist, refusing a changed identity until the user accepts it, and offering Retry and a strict restore from an identity backup.

**Architecture:** The core package's `IdentityStore` becomes a thin seam over `IdentityKeychain` (`load` / `loadOrCreate` / `importIdentity`) with a `LoadPolicy` chosen from "any message row exists". Pure core types (`IdentityAnchor`, `IdentityState`, `LaunchIdentity`, `IdentityRestore`) decide the launch outcome. An `@Observable` `AppRuntime` in the app target opens the database once, resolves the identity, and builds the TCA store only in `ready`; every other state shows `IdentityRecoveryView`. The identity only ever enters the app by building the store.

**Tech Stack:** SwiftUI, TCA (`Store(initialState:reducer:withDependencies:)`), SQLiteData/GRDB, ReTiCA `ReTiCAKeychain` (Part A merged), Swift Testing (core and hosted), XCTest UI tests.

**Spec:** `docs/superpowers/specs/2026-09-29-shared-identity-adoption-design.md` §5 (Part B). Part A (ReTiCA hardening) must be on ReTiCA `main` first; this package resolves ReTiCA by path `../../../pods/ReTiCA`.

## Global Constraints

- Work in the app worktree `/Users/ell/development/ios/apps/ReTiCaMsgr-shared-identity` (branch `feat/shared-identity`).
- Shared location exactly: service `reticulum.identity`, access group `HK6WSAR793.co.lithobyte.reticulum.identity`; entitlement `$(AppIdentifierPrefix)co.lithobyte.reticulum.identity`. `legacy: []` everywhere. The old `KeychainIdentity` type and every `SecItem*` call in this repo are deleted; the shared item is touched only through `ReTiCAKeychain`.
- Never mint under `.loadOnly`; never mint on `.failed`; `hasMessages` throwing counts as "messages exist".
- UserDefaults key `reticamsgr.expectedIdentityHash` (lowercase hex of the 16-byte identity hash). `recordReady` writes only when no anchor exists; only `replace(with:)` (the explicit "Use the new identity") overwrites it.
- No key material in logs or test output; only outcome kinds and hashes.
- Test hosts (hosted XCTest via `XCTestConfigurationFilePath`, UI tests via `RETICAMSGR_TEST_HOST=1`) use an in-memory Keychain, an in-memory database and a suite-named `UserDefaults`.
- Core test command: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-shared-identity/ReTiCaMsgrCore` (add `--filter <prefix>` per task). App build: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr-shared-identity/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination 'id=AF8E1DCF-F093-4978-BBA6-C0F154B43242' build`. Hosted tests: the same with `test -only-testing:ReTiCaMsgrTests`. Never run `swift test` and `xcodebuild` at the same time.
- The app target does not build between Task 1 and Task 4 (the entry point still calls the old `load()`); Tasks 1–3 are gated by the core suite only.
- Every new test follows the mutation protocol: green → mutate production → red → revert by hand → green; masked mutations in separate sub-batches.
- Test prefixes: `identityStore`, `identityLaunch`, `identityRestore`, `appRuntime`, `sharedKeychain`, `testHostScan`.

## Review Focus

1. A message row exists but the Keychain read fails transiently (prewarm before first unlock): the app must show "locked" and never mint — pinned in Task 2 (`resolve` with `.failed(.locked)`) and Task 5 (runtime `.unavailable(.locked)` with `addCount == 0`).
2. Restore while a Retry already loaded an identity must be refused, not write a second item — pinned in Task 5 (`restoreRefusedWhenNotMissing`).
3. A stored anchor that is malformed (not 32 hex chars) must read as "no anchor", not crash or refuse ready — pinned in Task 2 (`identityLaunchAnchorIgnoresMalformedValues`).
4. The 4 KB file cap is checked before the file is read, and a file of exactly 64 bytes passes — pinned in Task 3 (`identityRestoreReadKeyFileRefusesLargeFiles`).
5. The `.task` build runs once per view lifetime and a second `build()` with a store present is a no-op — pinned in Task 5 (`appRuntimeBuildIsIdempotentOnceReady`).

---

### Task 1: `IdentityStore` over `ReTiCAKeychain`

**Files:**
- Modify: `ReTiCaMsgrCore/Package.swift`
- Modify (rewrite): `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/IdentityStore.swift`
- Modify (rewrite): `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/IdentityStoreTests.swift`

**Interfaces:**
- Consumes: ReTiCA `IdentityKeychain.load/loadOrCreate/importIdentity`, `KeychainOps`, `InMemoryKeychain`, `IdentityKeychain.Failure` (incl. `ambiguousItems`, `synchronizableItem`).
- Produces: `SharedIdentityLocation`, `LoadPolicy`, `IdentityFailureReason`, `IdentityLoad`, `RestoreOutcome`, `IdentityStore(load:restore:)`, `IdentityStore.live(ops:shared:)`, `IdentityStore.reason(for:)`, `lxmfAddressHex` (unchanged).

- [ ] **Step 1: Add the package dependency**

In `ReTiCaMsgrCore/Package.swift`, in the `ReTiCaMsgrCore` target's `dependencies`, add after the `ReTiCANode` product line:

```swift
                .product(name: "ReTiCAKeychain", package: "ReTiCA"),
```

- [ ] **Step 2: Write the failing tests**

Replace `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/IdentityStoreTests.swift` with:

```swift
import Foundation
import Security
import Testing
import ReTiCA
import ReTiCAKeychain
@testable import ReTiCaMsgrCore

private let shared = SharedIdentityLocation.shared

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

@Test func identityStoreTestValueIsStableAndAddressIsDeliveryHash() {
    let store = IdentityStore.testValue
    guard case let .ready(a) = store.load(.loadOnly), case let .ready(b) = store.load(.loadOrCreate) else {
        Issue.record("testValue must be ready under both policies")
        return
    }
    #expect(a == b)
    #expect(lxmfAddressHex(a) == LXMessage.deliveryHash(identityHash: a.hash).hexString)
    #expect(store.restore(Data(repeating: 1, count: 64)) == .identityPresent(service: "test"))
}

@Test func identityStoreSharedLocationIsTheOneNbhdUses() {
    #expect(shared.service == "reticulum.identity")
    #expect(shared.accessGroup == "HK6WSAR793.co.lithobyte.reticulum.identity")
}

@Test func identityStoreLoadOrCreateMintsOnAnEmptyKeychain() {
    let keychain = InMemoryKeychain()
    let store = IdentityStore.live(ops: keychain.ops)
    guard case let .ready(identity) = store.load(.loadOrCreate) else {
        Issue.record("expected ready")
        return
    }
    #expect(keychain.item(at: shared) == identity.privateKey)
    #expect(keychain.addCount == 1)
}

@Test func identityStoreLoadOnlyNeverMints() {
    let keychain = InMemoryKeychain()
    let store = IdentityStore.live(ops: keychain.ops)
    #expect(store.load(.loadOnly) == .absent)
    #expect(store.load(.loadOnly) == .absent)
    #expect(keychain.addCount == 0)
    #expect(keychain.item(at: shared) == nil)
}

@Test func identityStoreLoadReturnsTheStoredIdentityUnderBothPolicies() {
    let (identity, data) = makeSeed()
    let keychain = InMemoryKeychain([shared: data])
    let store = IdentityStore.live(ops: keychain.ops)
    #expect(store.load(.loadOnly) == .ready(identity))
    #expect(store.load(.loadOrCreate) == .ready(identity))
    #expect(keychain.addCount == 0)
}

@Test func identityStoreRestoreImportsOnceAndRefusesAfter() {
    let (identity, data) = makeSeed()
    let (_, other) = makeSeed()
    let keychain = InMemoryKeychain()
    let store = IdentityStore.live(ops: keychain.ops)
    #expect(store.restore(Data(repeating: 1, count: 10)) == .invalidKey)
    #expect(keychain.addCount == 0)
    #expect(store.restore(data) == .restored(identity))
    #expect(keychain.item(at: shared) == data)
    #expect(store.restore(other) == .identityPresent(service: "reticulum.identity"))
    #expect(keychain.item(at: shared) == data)
    #expect(keychain.addCount == 1)
}

@Test func identityStoreLoadMapsFailuresToReasons() {
    let (_, data) = makeSeed()
    let locked = InMemoryKeychain()
    locked.failRead(at: shared, status: errSecInteractionNotAllowed)
    #expect(IdentityStore.live(ops: locked.ops).load(.loadOnly) == .failed(.locked))
    #expect(IdentityStore.live(ops: locked.ops).load(.loadOrCreate) == .failed(.locked))
    #expect(locked.addCount == 0)

    let denied = InMemoryKeychain()
    denied.failRead(at: shared, status: errSecMissingEntitlement)
    #expect(IdentityStore.live(ops: denied.ops).load(.loadOrCreate) == .failed(.accessDenied))

    let stray = InMemoryKeychain([IdentityKeychain.Location(service: shared.service, accessGroup: "HK6WSAR793.co.lithobyte.wrong"): data])
    #expect(IdentityStore.live(ops: stray.ops).load(.loadOrCreate) == .failed(.strayItem("reticulum.identity")))
    #expect(stray.addCount == 0)

    let two = InMemoryKeychain([shared: data])
    two.set(data, at: shared, account: "second")
    #expect(IdentityStore.live(ops: two.ops).load(.loadOnly) == .failed(.strayItem("2 items at reticulum.identity")))

    let synced = InMemoryKeychain()
    synced.set(data, at: shared, synchronizable: true)
    #expect(IdentityStore.live(ops: synced.ops).load(.loadOnly) == .failed(.strayItem("synchronizable item at reticulum.identity")))

    let corrupt = InMemoryKeychain([shared: Data(repeating: 0xAB, count: 63)])
    #expect(IdentityStore.live(ops: corrupt.ops).load(.loadOnly) == .failed(.corrupt))
}

@Test func identityStoreReasonMapsEveryFailure() {
    let location = shared
    #expect(IdentityStore.reason(for: .readFailed(location: location, status: errSecInteractionNotAllowed)) == .locked)
    #expect(IdentityStore.reason(for: .readFailed(location: location, status: errSecNotAvailable)) == .locked)
    #expect(IdentityStore.reason(for: .readFailed(location: location, status: errSecMissingEntitlement)) == .accessDenied)
    #expect(IdentityStore.reason(for: .readFailed(location: location, status: -50)) == .other(-50))
    #expect(IdentityStore.reason(for: .addFailed(status: errSecMissingEntitlement)) == .accessDenied)
    #expect(IdentityStore.reason(for: .addFailed(status: -50)) == .other(-50))
    #expect(IdentityStore.reason(for: .verifyFailed(status: -7)) == .other(-7))
    #expect(IdentityStore.reason(for: .verifyFailed(status: nil)) == .other(nil))
    #expect(IdentityStore.reason(for: .mintFailed) == .other(nil))
    #expect(IdentityStore.reason(for: .invalidLocation(location)) == .other(nil))
    #expect(IdentityStore.reason(for: .corrupt(location: location)) == .corrupt)
    #expect(IdentityStore.reason(for: .unexpectedItem(service: "x.identity")) == .strayItem("x.identity"))
    #expect(IdentityStore.reason(for: .ambiguousItems(location: location, count: 3)) == .strayItem("3 items at reticulum.identity"))
    #expect(IdentityStore.reason(for: .synchronizableItem(location: location)) == .strayItem("synchronizable item at reticulum.identity"))
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --package-path <worktree>/ReTiCaMsgrCore --filter identityStore`
Expected: compile errors (`SharedIdentityLocation`, `LoadPolicy`, `live(ops:)`, `reason(for:)` missing; `load()` has no parameter).

- [ ] **Step 4: Rewrite `IdentityStore.swift`**

```swift
import Foundation
import Dependencies
import ReTiCA
import ReTiCAKeychain
import Security

/// The one Keychain item every app on the team reads (spec 2026-09-29 §5.2). Nbhd wrote it first;
/// this app never uses its own `SecItem` code, so its copy collides and dedupes with Nbhd's.
public enum SharedIdentityLocation {
    public static let service = "reticulum.identity"
    /// Must equal `$(AppIdentifierPrefix)co.lithobyte.reticulum.identity` in ReTiCaMsgr.entitlements.
    public static let accessGroup = "HK6WSAR793.co.lithobyte.reticulum.identity"
    public static let shared = IdentityKeychain.Location(service: service, accessGroup: accessGroup)
}

/// Whether launch may mint (spec §5.3).
public enum LoadPolicy: Sendable, Equatable {
    /// No local state tied to an identity: a fresh install may mint.
    case loadOrCreate
    /// Messages exist: never mint; `.absent` means the key was lost.
    case loadOnly
}

/// User-facing class of a Keychain failure. Public facts only, never key material.
public enum IdentityFailureReason: Sendable, Equatable {
    /// errSecInteractionNotAllowed / errSecNotAvailable: e.g. a prewarm launch before first unlock.
    case locked
    /// errSecMissingEntitlement on read or add: a signing or configuration problem.
    case accessDenied
    /// An item exists where it should not, or several do, or one is iCloud-synchronizable.
    case strayItem(String)
    case corrupt
    case other(Int32?)
}

public enum IdentityLoad: Sendable, Equatable {
    case ready(Identity)
    /// Nothing exists anywhere. Only under `.loadOnly` (`.loadOrCreate` would have minted).
    case absent
    case failed(IdentityFailureReason)
}

public enum RestoreOutcome: Sendable, Equatable {
    case restored(Identity)
    case identityPresent(service: String)
    case invalidKey
    case failed(IdentityFailureReason)
}

/// The single seam to the shared identity: load under a policy, or restore a backup.
public struct IdentityStore: Sendable {
    public var load: @Sendable (LoadPolicy) -> IdentityLoad
    public var restore: @Sendable (_ privateKey: Data) -> RestoreOutcome

    public init(load: @escaping @Sendable (LoadPolicy) -> IdentityLoad,
                restore: @escaping @Sendable (_ privateKey: Data) -> RestoreOutcome) {
        self.load = load
        self.restore = restore
    }

    /// `IdentityKeychain` over the given ops. `shared` is overridable only so a hosted test can
    /// use a test-prefixed service in the real access group.
    public static func live(ops: KeychainOps, shared: IdentityKeychain.Location = SharedIdentityLocation.shared) -> IdentityStore {
        IdentityStore(
            load: { policy in
                switch policy {
                case .loadOrCreate:
                    switch IdentityKeychain.loadOrCreate(shared: shared, legacy: [], ops: ops) {
                    case let .loaded(identity), let .created(identity), let .migrated(identity):
                        return .ready(identity)
                    case let .failed(failure):
                        return .failed(reason(for: failure))
                    }
                case .loadOnly:
                    switch IdentityKeychain.load(shared: shared, legacy: [], ops: ops) {
                    case let .loaded(identity), let .migrated(identity):
                        return .ready(identity)
                    case .absent:
                        return .absent
                    case let .failed(failure):
                        return .failed(reason(for: failure))
                    }
                }
            },
            restore: { privateKey in
                switch IdentityKeychain.importIdentity(privateKey: privateKey, shared: shared, legacy: [], ops: ops) {
                case let .imported(identity): return .restored(identity)
                case let .identityPresent(service): return .identityPresent(service: service)
                case .invalidKey: return .invalidKey
                case let .failed(failure): return .failed(reason(for: failure))
                }
            }
        )
    }

    /// Pure mapping, mirroring Nbhd's so both apps read the same way (spec §5.2).
    public static func reason(for failure: IdentityKeychain.Failure) -> IdentityFailureReason {
        switch failure {
        case let .readFailed(_, status):
            switch status {
            case errSecMissingEntitlement: return .accessDenied
            case errSecInteractionNotAllowed, errSecNotAvailable: return .locked
            default: return .other(status)
            }
        case let .addFailed(status):
            return status == errSecMissingEntitlement ? .accessDenied : .other(status)
        case let .verifyFailed(status):
            return .other(status)
        case .mintFailed, .invalidLocation:
            return .other(nil)
        case .corrupt:
            return .corrupt
        case let .unexpectedItem(service):
            return .strayItem(service)
        case let .ambiguousItems(location, count):
            return .strayItem("\(count) items at \(location.service)")
        case let .synchronizableItem(location):
            return .strayItem("synchronizable item at \(location.service)")
        }
    }
}

/// The user's shareable LXMF address = their lxmf.delivery destination hash, hex-encoded.
public func lxmfAddressHex(_ identity: Identity) -> String {
    LXMessage.deliveryHash(identityHash: identity.hash).hexString
}

extension IdentityStore: DependencyKey {
    public static var liveValue: IdentityStore { live(ops: .live) }
    public static var testValue: IdentityStore {
        // Deterministic-enough for tests: a fixed in-process identity, never the Keychain.
        let identity = Identity()
        return IdentityStore(load: { _ in .ready(identity) }, restore: { _ in .identityPresent(service: "test") })
    }
}

public extension DependencyValues {
    var identityStore: IdentityStore {
        get { self[IdentityStore.self] }
        set { self[IdentityStore.self] = newValue }
    }
}
```

`KeychainIdentity` and the `#if canImport(Security)` blocks are gone.

- [ ] **Step 5: Run to verify pass**

Run: `swift test --package-path <worktree>/ReTiCaMsgrCore --filter identityStore` → PASS. Then the whole core suite → PASS (the app target is expected NOT to build until Task 4).

- [ ] **Step 6: Mutation check**

Batch A: in `live` `.loadOnly`, map `.absent` to `loadOrCreate`'s mint (call `loadOrCreate` instead of `load`) → `identityStoreLoadOnlyNeverMints` fails; in `reason`, map `errSecNotAvailable` to `.other` → `identityStoreReasonMapsEveryFailure` fails; in `.ambiguousItems` use `location.accessGroup ?? ""` instead of `service` → the "2 items" expectations fail.
Batch B: in `restore`, map `.identityPresent` to `.restored(Identity())`-equivalent (`.invalidKey`) → `identityStoreRestoreImportsOnceAndRefusesAfter` fails; in `testValue` return `.absent` for `.loadOnly` → `identityStoreTestValueIsStable…` fails.
Revert by hand; PASS.

- [ ] **Step 7: Commit** — `feat: IdentityStore loads the shared identity through ReTiCAKeychain` (stage `ReTiCaMsgrCore/Package.swift`, the source and the test file).

---

### Task 2: Policy, anchor, state and the launch resolver

**Files:**
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/Database.swift` (add `hasMessages`)
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/IdentityLaunch.swift`
- Create: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/IdentityLaunchTests.swift`

**Interfaces:**
- Consumes: Task 1's `IdentityStore`, `LoadPolicy`, `IdentityLoad`, `IdentityFailureReason`; `AppDatabase.makeInMemory`; `Message`.
- Produces: `AppDatabase.hasMessages(_:)`, `LoadPolicy.forLaunch(database:)`, `IdentityAnchor`, `IdentityState`, `LaunchIdentity.resolve(policy:anchor:store:)`, `shortID(_:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import GRDB
import ReTiCA
import ReTiCAKeychain
@testable import ReTiCaMsgrCore

private func insertOneMessage(_ db: any DatabaseWriter) throws {
    let m = Message(id: UUID(), peerHex: String(repeating: "ab", count: 16), isOutgoing: true, body: "hi",
                    timestamp: Date(timeIntervalSince1970: 1), status: MessageStatus.sending, validated: true,
                    messageHash: String(repeating: "cd", count: 32))
    try db.write { try Message.insert { m }.execute($0) }
}

private func freshDefaults() -> UserDefaults {
    let name = "identityLaunchTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

@Test func identityLaunchPolicyIsLoadOrCreateOnlyWithoutMessages() throws {
    let db = try AppDatabase.makeInMemory()
    #expect(try AppDatabase.hasMessages(db) == false)
    #expect(LoadPolicy.forLaunch(database: db) == .loadOrCreate)
    try insertOneMessage(db)
    #expect(try AppDatabase.hasMessages(db) == true)
    #expect(LoadPolicy.forLaunch(database: db) == .loadOnly)
}

/// A failed count is "unknown", never "fresh install".
@Test func identityLaunchPolicyIsLoadOnlyWhenTheCountThrows() throws {
    let queue = try DatabaseQueue()
    // No migration ran: the messages table does not exist, so the count throws.
    #expect(throws: (any Error).self) { try AppDatabase.hasMessages(queue) }
    #expect(LoadPolicy.forLaunch(database: queue) == .loadOnly)
}

@Test func identityLaunchAnchorIsWriteOnceUntilReplaced() {
    let anchor = IdentityAnchor(defaults: freshDefaults())
    let a = Data(repeating: 0x11, count: 16)
    let b = Data(repeating: 0x22, count: 16)
    #expect(anchor.expected() == nil)
    anchor.recordReady(a)
    #expect(anchor.expected() == a)
    anchor.recordReady(b)
    #expect(anchor.expected() == a)
    anchor.replace(with: b)
    #expect(anchor.expected() == b)
}

@Test func identityLaunchAnchorIgnoresMalformedValues() {
    let defaults = freshDefaults()
    let anchor = IdentityAnchor(defaults: defaults)
    defaults.set("not-hex", forKey: IdentityAnchor.key)
    #expect(anchor.expected() == nil)
    defaults.set("abcd", forKey: IdentityAnchor.key)      // too short
    #expect(anchor.expected() == nil)
    defaults.set(String(repeating: "ab", count: 16), forKey: IdentityAnchor.key)
    #expect(anchor.expected() == Data(repeating: 0xAB, count: 16))
}

@Test func identityLaunchResolveFreshInstallIsReadyAndWritesTheAnchor() {
    let (identity, data) = makeSeed()
    let keychain = InMemoryKeychain([SharedIdentityLocation.shared: data])
    let anchor = IdentityAnchor(defaults: freshDefaults())
    let result = LaunchIdentity.resolve(policy: .loadOrCreate, anchor: anchor, store: .live(ops: keychain.ops))
    #expect(result.state == .ready(identity.hash))
    #expect(result.identity == identity)
    #expect(anchor.expected() == identity.hash)
}

@Test func identityLaunchResolveMatchingAnchorIsReady() {
    let (identity, data) = makeSeed()
    let keychain = InMemoryKeychain([SharedIdentityLocation.shared: data])
    let anchor = IdentityAnchor(defaults: freshDefaults())
    anchor.recordReady(identity.hash)
    let result = LaunchIdentity.resolve(policy: .loadOnly, anchor: anchor, store: .live(ops: keychain.ops))
    #expect(result.state == .ready(identity.hash))
    #expect(result.identity == identity)
}

@Test func identityLaunchResolveDifferingAnchorRefusesReadyAndKeepsTheAnchor() {
    let (identity, data) = makeSeed()
    let other = Data(repeating: 0x33, count: 16)
    let keychain = InMemoryKeychain([SharedIdentityLocation.shared: data])
    let anchor = IdentityAnchor(defaults: freshDefaults())
    anchor.recordReady(other)
    let result = LaunchIdentity.resolve(policy: .loadOnly, anchor: anchor, store: .live(ops: keychain.ops))
    #expect(result.state == .identityChanged(expected: other, got: identity.hash))
    #expect(result.identity == nil)
    #expect(anchor.expected() == other)
}

@Test func identityLaunchResolveAbsentIsMissingWithTheAnchor() {
    let expected = Data(repeating: 0x44, count: 16)
    let keychain = InMemoryKeychain()
    let anchor = IdentityAnchor(defaults: freshDefaults())
    anchor.recordReady(expected)
    let result = LaunchIdentity.resolve(policy: .loadOnly, anchor: anchor, store: .live(ops: keychain.ops))
    #expect(result.state == .missing(expected: expected))
    #expect(result.identity == nil)
    #expect(keychain.addCount == 0)
    let noAnchor = LaunchIdentity.resolve(policy: .loadOnly, anchor: IdentityAnchor(defaults: freshDefaults()), store: .live(ops: keychain.ops))
    #expect(noAnchor.state == .missing(expected: nil))
}

@Test func identityLaunchResolveFailureIsUnavailableAndMintsNothing() {
    let keychain = InMemoryKeychain()
    keychain.failRead(at: SharedIdentityLocation.shared, status: -25308)
    let result = LaunchIdentity.resolve(policy: .loadOrCreate, anchor: IdentityAnchor(defaults: freshDefaults()), store: .live(ops: keychain.ops))
    #expect(result.state == .unavailable(.locked))
    #expect(result.identity == nil)
    #expect(keychain.addCount == 0)
}

@Test func identityLaunchShortIDIsTheFirstEightHexChars() {
    #expect(shortID(Data(repeating: 0xAB, count: 16)) == "abababab")
}
```

- [ ] **Step 2: Run to verify failure** — `--filter identityLaunch`: compile errors.

- [ ] **Step 3: Implement**

`Database.swift`, inside `AppDatabase`:

```swift
    /// Any row in `messages`: the local state tied to this device's identity (every peer in a
    /// conversation knows this address). Throws when the table cannot be read.
    public static func hasMessages(_ database: any DatabaseWriter) throws -> Bool {
        try database.read { try Message.fetchCount($0) > 0 }
    }
```

`IdentityLaunch.swift`:

```swift
import Foundation
import GRDB
import ReTiCA

public extension LoadPolicy {
    /// Messages exist → never mint. A failed count is "unknown", which is never a fresh install.
    static func forLaunch(database: any DatabaseWriter) -> LoadPolicy {
        let hasMessages = (try? AppDatabase.hasMessages(database)) ?? true
        return hasMessages ? .loadOnly : .loadOrCreate
    }
}

/// The identity hash this device's conversations belong to (spec §5.3). Public, not secret. It
/// survives exactly the restores that lose the Keychain (an unencrypted backup keeps defaults).
public struct IdentityAnchor: @unchecked Sendable {
    public static let key = "reticamsgr.expectedIdentityHash"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// nil when unset or malformed (anything but 32 hex chars).
    public func expected() -> Data? {
        guard let hex = defaults.string(forKey: Self.key), let data = Data(hexString: hex), data.count == 16 else { return nil }
        return data
    }

    /// Writes only when no anchor exists. A differing anchor is kept: the caller refuses ready.
    public func recordReady(_ hash: Data) {
        guard expected() == nil else { return }
        defaults.set(hash.hexString, forKey: Self.key)
    }

    /// The explicit "Use the new identity" path.
    public func replace(with hash: Data) {
        defaults.set(hash.hexString, forKey: Self.key)
    }
}

public enum IdentityState: Equatable, Sendable {
    case loading
    case ready(Data)
    /// `load` returned `.absent` with messages present: the key was lost.
    case missing(expected: Data?)
    /// The shared item holds a different identity from the anchor.
    case identityChanged(expected: Data, got: Data)
    case unavailable(IdentityFailureReason)
}

public enum LaunchIdentity {
    /// One decision for launch, Retry and Restore. Returns the identity only in `.ready`.
    public static func resolve(policy: LoadPolicy, anchor: IdentityAnchor, store: IdentityStore) -> (state: IdentityState, identity: Identity?) {
        switch store.load(policy) {
        case let .failed(reason):
            return (.unavailable(reason), nil)
        case .absent:
            return (.missing(expected: anchor.expected()), nil)
        case let .ready(identity):
            guard let expected = anchor.expected() else {
                anchor.recordReady(identity.hash)
                return (.ready(identity.hash), identity)
            }
            guard expected == identity.hash else {
                return (.identityChanged(expected: expected, got: identity.hash), nil)
            }
            return (.ready(identity.hash), identity)
        }
    }
}

/// The first 8 hex characters of an identity hash, as every recovery screen shows it.
public func shortID(_ hash: Data) -> String {
    String(hash.hexString.prefix(8))
}
```

- [ ] **Step 4: Run to verify pass** — `--filter identityLaunch` PASS; whole core suite PASS.

- [ ] **Step 5: Mutation check**

Batch A: `forLaunch` maps a throw to `.loadOrCreate` → `…WhenTheCountThrows` fails; `recordReady` always writes → `…WriteOnceUntilReplaced` fails; `resolve` returns `.ready` on a differing anchor → `…DifferingAnchorRefusesReady…` fails.
Batch B: `expected()` drops the `count == 16` guard → `…IgnoresMalformedValues` ("abcd") fails; `resolve` skips `recordReady` on fresh → `…FreshInstall…` fails; `shortID` takes 6 → its test fails.
Revert by hand; PASS.

- [ ] **Step 6: Commit** — `feat: load policy, identity anchor and the launch resolver`.

---

### Task 3: `IdentityRestore`

**Files:**
- Create: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/IdentityRestore.swift`
- Create: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/IdentityRestoreTests.swift`

**Interfaces:**
- Consumes: ReTiCA `IdentityBackup.decodeBase32`, `Identity.keySize`, `Identity(privateKey:)`; Task 1's `IdentityFailureReason`.
- Produces: `IdentityRestore` (`Rejection`, `maxFileBytes`, `key(fromText:)`, `key(fromFile:)`, `validate(privateKey:expected:)`, `readKeyFile(at:maxBytes:)`, `describe(_:)`), `RestoreRefusal`, `RestoreResult`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import ReTiCA
import ReTiCAKeychain
@testable import ReTiCaMsgrCore

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

@Test func identityRestoreTextFormAcceptsPaddedUnpaddedAndWhitespace() {
    let (_, data) = makeSeed()
    let padded = IdentityBackup.base32(data)
    let unpadded = String(padded.filter { $0 != "=" })
    #expect(IdentityRestore.key(fromText: padded) == .success(data))
    #expect(IdentityRestore.key(fromText: unpadded) == .success(data))
    #expect(IdentityRestore.key(fromText: "  \n\(padded)\n") == .success(data))
    #expect(IdentityRestore.key(fromText: padded.lowercased()) == .failure(.badEncoding))
    #expect(IdentityRestore.key(fromText: "MZXW6===") == .failure(.wrongLength(3)))
}

@Test func identityRestoreFileFormIsExactly64Bytes() {
    let (_, data) = makeSeed()
    #expect(IdentityRestore.key(fromFile: data) == .success(data))
    #expect(IdentityRestore.key(fromFile: data + Data([0])) == .failure(.wrongLength(65)))
    #expect(IdentityRestore.key(fromFile: Data()) == .failure(.wrongLength(0)))
}

@Test func identityRestoreValidateIsStrict() {
    let (identity, data) = makeSeed()
    let (other, _) = makeSeed()
    #expect(IdentityRestore.validate(privateKey: data, expected: identity.hash) == .success(identity))
    #expect(IdentityRestore.validate(privateKey: data, expected: other.hash) == .failure(.mismatch(got: identity.hash, expected: other.hash)))
    #expect(IdentityRestore.validate(privateKey: data, expected: nil) == .failure(.noExpectedIdentity))
    #expect(IdentityRestore.validate(privateKey: Data(repeating: 1, count: 10), expected: identity.hash) == .failure(.wrongLength(10)))
}

@Test func identityRestoreReadKeyFileRefusesLargeFiles() throws {
    let (_, data) = makeSeed()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("identityRestore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let small = dir.appendingPathComponent("identity")
    try data.write(to: small)
    #expect(IdentityRestore.readKeyFile(at: small) == data)
    let big = dir.appendingPathComponent("big")
    try Data(repeating: 0, count: IdentityRestore.maxFileBytes + 1).write(to: big)
    #expect(IdentityRestore.readKeyFile(at: big) == nil)
    let exact = dir.appendingPathComponent("exact")
    try Data(repeating: 0, count: IdentityRestore.maxFileBytes).write(to: exact)
    #expect(IdentityRestore.readKeyFile(at: exact)?.count == IdentityRestore.maxFileBytes)
    #expect(IdentityRestore.readKeyFile(at: dir.appendingPathComponent("missing")) == nil)
}

@Test func identityRestoreDescribeIsLogSafe() {
    let got = Data(repeating: 0xAB, count: 16)
    let expected = Data(repeating: 0xCD, count: 16)
    #expect(IdentityRestore.describe(.badEncoding) == "badEncoding")
    #expect(IdentityRestore.describe(.wrongLength(7)) == "wrongLength 7")
    #expect(IdentityRestore.describe(.invalidKey) == "invalidKey")
    #expect(IdentityRestore.describe(.mismatch(got: got, expected: expected)) == "mismatch got=\(got.hexString) expected=\(expected.hexString)")
    #expect(IdentityRestore.describe(.noExpectedIdentity) == "noExpectedIdentity")
}
```

- [ ] **Step 2: Run to verify failure** — `--filter identityRestore`: compile errors.

- [ ] **Step 3: Implement** `IdentityRestore.swift`:

```swift
import Foundation
import ReTiCA
import ReTiCAKeychain

/// Restore input handling (spec §5.3). Pure. Key material passes through as arguments and
/// results only — never stored, never logged (`describe` prints kinds and hashes).
public enum IdentityRestore {
    public enum Rejection: Error, Equatable, Sendable {
        case badEncoding
        case wrongLength(Int)
        case invalidKey
        case mismatch(got: Data, expected: Data)
        /// No anchor: nothing to match against, so nothing is accepted.
        case noExpectedIdentity
    }

    /// Far above the 64-byte identity file; anything bigger isn't a backup and isn't read.
    public static let maxFileBytes = 4096

    /// The Sideband / `rnid -B` text form: base32 (padding optional), surrounding whitespace ignored.
    public static func key(fromText text: String) -> Result<Data, Rejection> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = IdentityBackup.decodeBase32(trimmed) else { return .failure(.badEncoding) }
        guard data.count == Identity.keySize else { return .failure(.wrongLength(data.count)) }
        return .success(data)
    }

    /// The raw `identity` file (NomadNet / `rnid -i`): exactly 64 bytes.
    public static func key(fromFile data: Data) -> Result<Data, Rejection> {
        guard data.count == Identity.keySize else { return .failure(.wrongLength(data.count)) }
        return .success(data)
    }

    /// Strict: the key's identity must equal the anchor. No override.
    public static func validate(privateKey: Data, expected: Data?) -> Result<Identity, Rejection> {
        guard privateKey.count == Identity.keySize else { return .failure(.wrongLength(privateKey.count)) }
        guard let identity = Identity(privateKey: privateKey) else { return .failure(.invalidKey) }
        guard let expected else { return .failure(.noExpectedIdentity) }
        guard identity.hash == expected else { return .failure(.mismatch(got: identity.hash, expected: expected)) }
        return .success(identity)
    }

    /// Reads a user-picked file (security-scoped when it comes from `fileImporter`), refusing
    /// anything larger than `maxBytes` before reading it. nil when unreadable or too large.
    public static func readKeyFile(at url: URL, maxBytes: Int = IdentityRestore.maxFileBytes) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Log-safe: kinds and public hashes only.
    public static func describe(_ rejection: Rejection) -> String {
        switch rejection {
        case .badEncoding: return "badEncoding"
        case let .wrongLength(count): return "wrongLength \(count)"
        case .invalidKey: return "invalidKey"
        case let .mismatch(got, expected): return "mismatch got=\(got.hexString) expected=\(expected.hexString)"
        case .noExpectedIdentity: return "noExpectedIdentity"
        }
    }
}

public enum RestoreRefusal: Equatable, Sendable {
    /// The identity is no longer `.missing` (e.g. Retry already loaded one).
    case notMissing
    /// An identity item appeared somewhere (e.g. Nbhd wrote the shared item): nothing written.
    case identityPresent(service: String)
}

public enum RestoreResult: Equatable, Sendable {
    case restored(Data)
    case rejected(IdentityRestore.Rejection)
    case refused(RestoreRefusal)
    case failed(IdentityFailureReason)
}
```

- [ ] **Step 4: Run to verify pass** — `--filter identityRestore` PASS; whole core suite PASS.

- [ ] **Step 5: Mutation check**

Batch A: `validate` skips the `expected` nil guard (treat nil as match) → `…ValidateIsStrict` fails; `readKeyFile` compares `size < maxBytes` → the exact-size case fails; `key(fromText:)` skips trimming → the whitespace case fails.
Batch B: `validate` compares `identity.hash != expected` inverted → match and mismatch cases fail; `describe(.mismatch)` prints `shortID` → its test fails.
Revert by hand; PASS.

- [ ] **Step 6: Commit** — `feat: strict identity restore validation and log-safe descriptions`.

---

### Task 4: `AppRuntime`, entitlements, entry point and the recovery UI

**Files:**
- Create: `ReTiCaMsgr/ReTiCaMsgr.entitlements`, `ReTiCaMsgrTests/ReTiCaMsgrTests.entitlements`
- Modify: `ReTiCaMsgr.xcodeproj/project.pbxproj` (four build-configuration blocks)
- Create: `ReTiCaMsgr/AppRuntime.swift`, `ReTiCaMsgr/IdentityRecoveryView.swift`, `ReTiCaMsgr/RestoreIdentitySheet.swift`, `ReTiCaMsgr/IdentityRecoveryText.swift`
- Modify: `ReTiCaMsgr/ReTiCaMsgrApp.swift`, `ReTiCaMsgr/ContentView.swift`
- Create: `ReTiCaMsgrUITests/TestApp.swift`; Modify: `ReTiCaMsgrUITests/ReTiCaMsgrUITests.swift`, `ReTiCaMsgrUITests/ReTiCaMsgrUITestsLaunchTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3; TCA `Store(initialState:reducer:withDependencies:)`; `AppFeature.State(identity:)`, `.onLaunch`, `.foregrounded`, `AppFeature.publicKeyRequestPath`, `RequestResponder`.
- Produces: `AppRuntime` (`Environment`, `state`, `store`, `isBuilding`, `build()`, `retry()`, `restore(privateKey:)`, `acceptNewIdentity()`, `Environment.isTestHost`, `.forProcess()`, `.testHost()`), `IdentityRecoveryText`, `IdentityRecoveryView`, `RestoreIdentitySheet`, `TestApp.make()`.

Gate for this task: the app builds (`xcodebuild … build`) and the core suite is green. Behavioural tests come in Task 5 (hosted), because they need the built app as host.

- [ ] **Step 1: Entitlements files**

`ReTiCaMsgr/ReTiCaMsgr.entitlements` and `ReTiCaMsgrTests/ReTiCaMsgrTests.entitlements`, identical content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)co.lithobyte.reticulum.identity</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: Project settings**

In `project.pbxproj`, add a line directly ABOVE `CODE_SIGN_STYLE = Automatic;` in each of these four `buildSettings` blocks (use the Edit tool with enough surrounding context to hit exactly one block each time — the `PRODUCT_BUNDLE_IDENTIFIER` line in the same block disambiguates):
- `49C39951301E7A5B003D6278 /* Debug */` and `49C39952301E7A5B003D6278 /* Release */` (app, `PRODUCT_BUNDLE_IDENTIFIER = co.lithobyte.ReTiCaMsgr`): `CODE_SIGN_ENTITLEMENTS = ReTiCaMsgr/ReTiCaMsgr.entitlements;`
- `49C39954301E7A5B003D6278 /* Debug */` and `49C39955301E7A5B003D6278 /* Release */` (tests, `co.lithobyte.ReTiCaMsgrTests`): `CODE_SIGN_ENTITLEMENTS = ReTiCaMsgrTests/ReTiCaMsgrTests.entitlements;`

- [ ] **Step 3: `IdentityRecoveryText.swift`** (pure strings, so Task 5 can test them without a view)

```swift
import Foundation
import ReTiCaMsgrCore

/// Plain wording per identity state and restore outcome (spec §5.5). Public facts only.
enum IdentityRecoveryText {
    struct Screen: Equatable {
        var title: String
        var message: String
        var detail: String?          // behind the "Details" disclosure
        var showsRestore: Bool
        var showsAccept: Bool
    }

    static func screen(for state: IdentityState) -> Screen {
        switch state {
        case .loading, .ready:
            return Screen(title: "", message: "", detail: nil, showsRestore: false, showsAccept: false)
        case let .unavailable(reason):
            return unavailable(reason)
        case let .missing(expected):
            if let expected {
                return Screen(
                    title: "Identity key missing",
                    message: "Your conversations are here, but your identity key isn't. This happens after restoring from an unencrypted backup. Restore it from an identity backup.",
                    detail: "Expected ID: \(shortID(expected))",
                    showsRestore: true, showsAccept: false)
            }
            return Screen(
                title: "Identity key missing",
                message: "Your conversations are here, but your identity key isn't. Restore isn't possible: this device has no record of which identity your conversations used.",
                detail: nil, showsRestore: false, showsAccept: false)
        case let .identityChanged(expected, got):
            return Screen(
                title: "Identity changed",
                message: "The identity on this device is different from the one your conversations used.",
                detail: "Expected \(shortID(expected)), found \(shortID(got)).",
                showsRestore: false, showsAccept: true)
        }
    }

    static func unavailable(_ reason: IdentityFailureReason) -> Screen {
        switch reason {
        case .locked:
            return Screen(title: "Identity locked", message: "Your identity is locked. Unlock your device, then tap Retry.", detail: nil, showsRestore: false, showsAccept: false)
        case let .strayItem(detail):
            return Screen(title: "Unexpected identity item", message: "Another Reticulum identity item is in an unexpected place on this device. ReTiCaMsgr won't guess which one to use.", detail: detail, showsRestore: false, showsAccept: false)
        case .corrupt:
            return Screen(title: "Identity unreadable", message: "The identity stored on this device can't be read.", detail: "The stored item is not a 64-byte identity.", showsRestore: false, showsAccept: false)
        case .accessDenied:
            return Screen(title: "Identity access denied", message: "ReTiCaMsgr isn't allowed to read the identity. This is a signing or configuration problem, not your data.", detail: "errSecMissingEntitlement (-34018): check the keychain-access-groups entitlement and the team prefix.", showsRestore: false, showsAccept: false)
        case let .other(status):
            return Screen(title: "Identity unavailable", message: "Your identity couldn't be loaded.", detail: status.map { "OSStatus \($0)" } ?? "No status was reported.", showsRestore: false, showsAccept: false)
        }
    }

    static let acceptConfirmation = "Your existing conversations were sent from the old identity. Peers will see you as a new address."

    static func restore(_ result: RestoreResult) -> String? {
        switch result {
        case .restored:
            return nil
        case let .rejected(rejection):
            switch rejection {
            case .badEncoding: return "That isn't an identity backup. Paste the text form or choose the identity file."
            case let .wrongLength(n): return "That file is \(n) bytes; an identity is 64."
            case .invalidKey: return "That key can't form an identity."
            case let .mismatch(got, expected): return "That backup is identity \(shortID(got)), but your conversations belong to \(shortID(expected))."
            case .noExpectedIdentity: return "Restore isn't possible: this device has no record of which identity your conversations used."
            }
        case .refused(.identityPresent):
            return "Another Reticulum identity already exists on this device, so ReTiCaMsgr won't replace it. Nothing was changed."
        case .refused(.notMissing):
            return nil
        case let .failed(reason):
            return unavailable(reason).message
        }
    }
}
```

- [ ] **Step 4: `AppRuntime.swift`**

```swift
import Foundation
import Observation
import ComposableArchitecture
import SQLiteData
import GRDB
import ReTiCA
import ReTiCAKeychain
import ReTiCaMsgrCore

/// Owns the database, resolves the identity, and builds the store ONLY in `.ready` (spec §5.4).
/// The identity enters the app by building the store and never changes afterwards.
@MainActor @Observable
final class AppRuntime {
    struct Environment {
        var database: any DatabaseWriter
        var identityStore: IdentityStore
        var anchor: IdentityAnchor
        var now: () -> Date = Date.init

        static func live() -> Environment {
            let dbPath = URL.documentsDirectory.appending(path: "reticamsgr.sqlite").path()
            return Environment(
                database: try! AppDatabase.makeOnDisk(path: dbPath),
                identityStore: .liveValue,
                anchor: IdentityAnchor(defaults: .standard))
        }

        /// Hosted XCTest runs and UI-test launches never touch the real Keychain, database or
        /// defaults: an in-memory Keychain pre-planted with a fixed identity, an in-memory
        /// database, and a throwaway defaults suite.
        static func testHost() -> Environment {
            let keychain = InMemoryKeychain()
            let identity = Identity()
            keychain.set(identity.privateKey!, at: SharedIdentityLocation.shared)
            let suite = "reticamsgr.testhost"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return Environment(
                database: try! AppDatabase.makeInMemory(),
                identityStore: .live(ops: keychain.ops),
                anchor: IdentityAnchor(defaults: defaults))
        }

        static var isTestHost: Bool {
            let env = ProcessInfo.processInfo.environment
            return env["XCTestConfigurationFilePath"] != nil || env["RETICAMSGR_TEST_HOST"] == "1"
        }

        static func forProcess() -> Environment {
            isTestHost ? testHost() : live()
        }
    }

    static let retryInterval: TimeInterval = 1

    private(set) var state: IdentityState = .loading
    private(set) var store: StoreOf<AppFeature>?
    private(set) var isBuilding = false
    private let environment: Environment
    private var lastRetry: Date?

    init(environment: Environment) {
        self.environment = environment
    }

    /// Launch, Retry, Restore and Accept all come through here. A no-op once a store exists.
    func build() {
        guard store == nil else { return }
        isBuilding = true
        defer { isBuilding = false }
        let policy = LoadPolicy.forLaunch(database: environment.database)
        let resolved = LaunchIdentity.resolve(policy: policy, anchor: environment.anchor, store: environment.identityStore)
        state = resolved.state
        guard let identity = resolved.identity else { return }
        let database = environment.database
        let store = Store(initialState: AppFeature.State(identity: identity)) {
            AppFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            // Answer peers' /publicKey requests with our own 64-byte public key. The link the
            // request arrives on is already authenticated, and the key is public (every announce
            // carries it), so answering unconditionally is safe.
            $0.requestResponder = RequestResponder { path, _, _ in
                guard path == AppFeature.publicKeyRequestPath else { return nil }
                return identity.publicKey
            }
        }
        self.store = store
        store.send(.onLaunch)
    }

    /// Rate-limited to once per `retryInterval`. Returns whether a build ran.
    @discardableResult
    func retry() -> Bool {
        guard store == nil else { return false }
        let now = environment.now()
        if let last = lastRetry, now.timeIntervalSince(last) < Self.retryInterval { return false }
        lastRetry = now
        build()
        return true
    }

    /// Only in `.missing`. Validates strictly against the anchor, imports add-only, then builds.
    func restore(privateKey: Data) -> RestoreResult {
        guard case let .missing(expected) = state else { return .refused(.notMissing) }
        if case let .failure(rejection) = IdentityRestore.validate(privateKey: privateKey, expected: expected) {
            return .rejected(rejection)
        }
        switch environment.identityStore.restore(privateKey) {
        case let .restored(identity):
            build()
            return .restored(identity.hash)
        case let .identityPresent(service):
            return .refused(.identityPresent(service: service))
        case .invalidKey:
            return .rejected(.invalidKey)
        case let .failed(reason):
            return .failed(reason)
        }
    }

    /// The explicit "Use the new identity": rewrites the anchor and builds.
    func acceptNewIdentity() {
        guard case let .identityChanged(_, got) = state else { return }
        environment.anchor.replace(with: got)
        build()
    }

    func foregrounded() {
        store?.send(.foregrounded)
    }
}
```

- [ ] **Step 5: Entry point and root**

`ReTiCaMsgrApp.swift` becomes:

```swift
import SwiftUI
import ReTiCaMsgrCore

@main
struct ReTiCaMsgrApp: App {
    @State private var runtime = AppRuntime(environment: .forProcess())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(runtime: runtime)
                .task { runtime.build() }
        }
        // iOS suspends the app in the background and the TCP socket does not survive it. Nothing
        // else re-dials: `.task` runs once per view lifetime, and the interface's reconnect backoff
        // cannot run while the process is suspended. Without this the only way back was to kill the
        // app, which is exactly what "stuck on Disconnected" looked like on device.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            runtime.foregrounded()
        }
    }
}
```

`ContentView.swift` becomes:

```swift
import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

struct RootView: View {
    let runtime: AppRuntime

    var body: some View {
        if let store = runtime.store, case .ready = runtime.state {
            TabView {
                ConversationListView(store: store)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                AnnounceListView(store: store)
                    .tabItem { Label("Announces", systemImage: "antenna.radiowaves.left.and.right") }
                SettingsView(store: store)
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
        } else if case .loading = runtime.state {
            ProgressView()
        } else {
            IdentityRecoveryView(runtime: runtime)
        }
    }
}
```

- [ ] **Step 6: `IdentityRecoveryView.swift`**

```swift
import SwiftUI
import ReTiCaMsgrCore

struct IdentityRecoveryView: View {
    let runtime: AppRuntime
    @State private var showRestore = false
    @State private var confirmAccept = false

    var body: some View {
        let screen = IdentityRecoveryText.screen(for: runtime.state)
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(screen.message)
                    .font(.body)
                if let detail = screen.detail {
                    DisclosureGroup("Details") {
                        Text(detail)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(spacing: 12) {
                    if screen.showsRestore {
                        Button("Restore from backup") { showRestore = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(runtime.isBuilding)
                    }
                    if screen.showsAccept {
                        Button("Use the new identity") { confirmAccept = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(runtime.isBuilding)
                    }
                    Button("Retry") { runtime.retry() }
                        .buttonStyle(.bordered)
                        .disabled(runtime.isBuilding)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
            .padding()
            .navigationTitle(screen.title)
            .sheet(isPresented: $showRestore) {
                RestoreIdentitySheet(runtime: runtime)
            }
            .confirmationDialog("Use the new identity?", isPresented: $confirmAccept, titleVisibility: .visible) {
                Button("Use the new identity", role: .destructive) { runtime.acceptNewIdentity() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(IdentityRecoveryText.acceptConfirmation)
            }
        }
    }
}
```

- [ ] **Step 7: `RestoreIdentitySheet.swift`**

```swift
import SwiftUI
import UniformTypeIdentifiers
import ReTiCaMsgrCore

/// Paste the base32 text form or pick the 64-byte identity file (spec §5.5). Input lives only
/// here and is cleared on success, cancel, dismiss and rejection. Nothing is logged.
struct RestoreIdentitySheet: View {
    let runtime: AppRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var pendingKey: Data?
    @State private var summary: String?
    @State private var message: String?
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        take(IdentityRestore.key(fromText: text), summary: "Pasted text")
                    }
                    Button("Choose identity file") { showImporter = true }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Paste the text form from Nbhd's Identity Export (or Sideband), or choose the 64-byte identity file.")
                }
                if let summary {
                    Section {
                        HStack {
                            Text(summary)
                            Spacer()
                            Button("Clear") { clear() }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Restore identity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { clear(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") { restore() }
                        .disabled(pendingKey == nil || runtime.isBuilding)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in
                guard case let .success(urls) = result, let url = urls.first else { return }
                guard let data = IdentityRestore.readKeyFile(at: url) else {
                    clear()
                    message = "That file couldn't be read, or it is larger than \(IdentityRestore.maxFileBytes) bytes."
                    return
                }
                take(IdentityRestore.key(fromFile: data), summary: url.lastPathComponent)
            }
            .onDisappear { clear() }
        }
    }

    private func take(_ result: Result<Data, IdentityRestore.Rejection>, summary: String) {
        switch result {
        case let .success(key):
            pendingKey = key
            self.summary = summary
            message = nil
        case let .failure(rejection):
            clear()
            message = IdentityRecoveryText.restore(.rejected(rejection))
        }
    }

    private func restore() {
        guard let key = pendingKey else { return }
        let result = runtime.restore(privateKey: key)
        clear()
        switch result {
        case .restored, .refused(.notMissing):
            dismiss()
        default:
            message = IdentityRecoveryText.restore(result)
        }
    }

    private func clear() {
        pendingKey = nil
        summary = nil
    }
}
```

- [ ] **Step 8: UI-test helper and launches**

`ReTiCaMsgrUITests/TestApp.swift`:

```swift
import XCTest

/// The only place a UI test launches the app: the flag makes the app use an in-memory Keychain,
/// database and defaults, so no test run can mint or read a real identity.
enum TestApp {
    @MainActor static func make() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RETICAMSGR_TEST_HOST"] = "1"
        return app
    }
}
```

In `ReTiCaMsgrUITests.swift` replace both `XCUIApplication()` with `TestApp.make()`. In `ReTiCaMsgrUITestsLaunchTests.swift` do the same for its `XCUIApplication()`.

- [ ] **Step 9: Build and run the core suite**

Run the app build (Global Constraints command) → `** BUILD SUCCEEDED **`. Then the core suite → PASS. Also `xcodebuild … build-for-testing` to confirm the test targets compile with their entitlements.

- [ ] **Step 10: Commit** — `feat: AppRuntime resolves the shared identity and shows recovery when it is not ready`. Stage the entitlements, pbxproj, the new and modified app files, and the UI-test files.

---

### Task 5: Hosted tests — runtime behaviour, the real access group, and the test-host guard

**Files:**
- Create: `ReTiCaMsgrTests/AppRuntimeTests.swift`, `ReTiCaMsgrTests/SharedKeychainTests.swift`, `ReTiCaMsgrTests/TestHostScanTests.swift`, `ReTiCaMsgrTests/IdentityRecoveryTextTests.swift`
- Delete: the template `ReTiCaMsgrTests/ReTiCaMsgrTests.swift`

**Interfaces:**
- Consumes: Task 4's `AppRuntime`, `IdentityRecoveryText`; `InMemoryKeychain`, `KeychainOps.live`, `IdentityStore.live(ops:shared:)`.

Test command: `xcodebuild -project <worktree>/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination 'id=AF8E1DCF-F093-4978-BBA6-C0F154B43242' test -only-testing:ReTiCaMsgrTests` (boot the simulator first with `xcrun simctl boot AF8E1DCF-F093-4978-BBA6-C0F154B43242`; ignore "already booted").

- [ ] **Step 1: Write the tests**

`AppRuntimeTests.swift`:

```swift
import Foundation
import Testing
import GRDB
import ReTiCA
import ReTiCAKeychain
import ReTiCaMsgrCore
@testable import ReTiCaMsgr

private let shared = SharedIdentityLocation.shared

@MainActor
private struct Fixture {
    let keychain = InMemoryKeychain()
    let database: any DatabaseWriter
    let defaults: UserDefaults
    let runtime: AppRuntime

    init(messages: Int = 0, planted: Data? = nil, anchor: Data? = nil) throws {
        database = try AppDatabase.makeInMemory()
        let suite = "appRuntimeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let planted { keychain.set(planted, at: shared) }
        if let anchor { defaults.set(anchor.hexString, forKey: IdentityAnchor.key) }
        for i in 0..<messages {
            let m = Message(id: UUID(), peerHex: String(repeating: "ab", count: 16), isOutgoing: true, body: "m\(i)",
                            timestamp: Date(timeIntervalSince1970: Double(i)), status: MessageStatus.sending, validated: true,
                            messageHash: String(repeating: "cd", count: 32))
            try database.write { try Message.insert { m }.execute($0) }
        }
        let clock = Clock()
        runtime = AppRuntime(environment: .init(
            database: database,
            identityStore: .live(ops: keychain.ops),
            anchor: IdentityAnchor(defaults: defaults),
            now: { clock.now }))
        self.clock = clock
    }

    let clock: Clock
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
}

private func makeSeed() -> (Identity, Data) {
    let identity = Identity()
    return (identity, identity.privateKey!)
}

@MainActor
@Test func appRuntimeFreshInstallMintsAndBuildsTheStore() throws {
    let f = try Fixture()
    f.runtime.build()
    guard case let .ready(hash) = f.runtime.state else { return Issue.record("expected ready: \(f.runtime.state)") }
    #expect(f.runtime.store != nil)
    #expect(f.keychain.addCount == 1)
    #expect(IdentityAnchor(defaults: f.defaults).expected() == hash)
}

@MainActor
@Test func appRuntimeMessagesPresentAndKeychainEmptyIsMissingAndMintsNothing() throws {
    let expected = Data(repeating: 0x55, count: 16)
    let f = try Fixture(messages: 1, anchor: expected)
    f.runtime.build()
    #expect(f.runtime.state == .missing(expected: expected))
    #expect(f.runtime.store == nil)
    #expect(f.keychain.addCount == 0)
}

@MainActor
@Test func appRuntimeLockedIsUnavailableAndRetryRecovers() throws {
    let (identity, data) = makeSeed()
    let f = try Fixture(messages: 1, planted: data, anchor: identity.hash)
    f.keychain.failRead(at: shared, status: -25308)
    f.runtime.build()
    #expect(f.runtime.state == .unavailable(.locked))
    #expect(f.keychain.addCount == 0)
    // Rate limit: the first retry runs (still locked), the second within a second does not.
    #expect(f.runtime.retry() == true)
    #expect(f.runtime.retry() == false)
    f.keychain.clearFailures()
    #expect(f.runtime.retry() == false)
    f.clock.now = f.clock.now.addingTimeInterval(1)
    #expect(f.runtime.retry() == true)
    #expect(f.runtime.state == .ready(identity.hash))
    #expect(f.runtime.store != nil)
}

@MainActor
@Test func appRuntimeRestoreRightKeyReachesReady() throws {
    let (identity, data) = makeSeed()
    let f = try Fixture(messages: 1, anchor: identity.hash)
    f.runtime.build()
    #expect(f.runtime.state == .missing(expected: identity.hash))
    #expect(f.runtime.restore(privateKey: data) == .restored(identity.hash))
    #expect(f.runtime.state == .ready(identity.hash))
    #expect(f.runtime.store != nil)
    #expect(f.keychain.item(at: shared) == data)
}

@MainActor
@Test func appRuntimeRestoreWrongKeyIsRejectedAndWritesNothing() throws {
    let (identity, _) = makeSeed()
    let (other, otherData) = makeSeed()
    let f = try Fixture(messages: 1, anchor: identity.hash)
    f.runtime.build()
    #expect(f.runtime.restore(privateKey: otherData) == .rejected(.mismatch(got: other.hash, expected: identity.hash)))
    #expect(f.runtime.state == .missing(expected: identity.hash))
    #expect(f.keychain.addCount == 0)
}

@MainActor
@Test func appRuntimeRestoreRefusedWhenNotMissing() throws {
    let (identity, data) = makeSeed()
    let f = try Fixture(planted: data, anchor: identity.hash)
    f.runtime.build()
    #expect(f.runtime.state == .ready(identity.hash))
    #expect(f.runtime.restore(privateKey: data) == .refused(.notMissing))
    #expect(f.keychain.addCount == 0)
}

@MainActor
@Test func appRuntimeRestoreRefusedWhenAnIdentityAppeared() throws {
    let (identity, data) = makeSeed()
    let (_, otherData) = makeSeed()
    let f = try Fixture(messages: 1, anchor: identity.hash)
    f.runtime.build()
    f.keychain.set(otherData, at: shared)     // Nbhd wrote the shared item meanwhile
    #expect(f.runtime.restore(privateKey: data) == .refused(.identityPresent(service: "reticulum.identity")))
    #expect(f.runtime.state == .missing(expected: identity.hash))
    #expect(f.keychain.item(at: shared) == otherData)
}

@MainActor
@Test func appRuntimeIdentityChangedRefusesReadyUntilAccepted() throws {
    let (identity, data) = makeSeed()
    let old = Data(repeating: 0x66, count: 16)
    let f = try Fixture(messages: 1, planted: data, anchor: old)
    f.runtime.build()
    #expect(f.runtime.state == .identityChanged(expected: old, got: identity.hash))
    #expect(f.runtime.store == nil)
    #expect(IdentityAnchor(defaults: f.defaults).expected() == old)
    f.runtime.acceptNewIdentity()
    #expect(f.runtime.state == .ready(identity.hash))
    #expect(f.runtime.store != nil)
    #expect(IdentityAnchor(defaults: f.defaults).expected() == identity.hash)
}

@MainActor
@Test func appRuntimeBuildIsIdempotentOnceReady() throws {
    let f = try Fixture()
    f.runtime.build()
    let first = f.runtime.store
    f.runtime.build()
    #expect(f.runtime.store === first)
    #expect(f.keychain.addCount == 1)
    #expect(f.runtime.retry() == false)
}

@MainActor
@Test func appRuntimeTestHostEnvironmentNeverTouchesTheRealKeychain() {
    #expect(AppRuntime.Environment.isTestHost)   // hosted XCTest sets XCTestConfigurationFilePath
    let runtime = AppRuntime(environment: .testHost())
    runtime.build()
    guard case .ready = runtime.state else { return Issue.record("expected ready: \(runtime.state)") }
}
```

`SharedKeychainTests.swift` (the real Keychain, test-prefixed service in the real group):

```swift
import Foundation
import Testing
import ReTiCA
import ReTiCAKeychain
import ReTiCaMsgrCore
@testable import ReTiCaMsgr

/// Deletes only test-owned services. Refuses the production service outright.
private enum TestKeychain {
    static let prefix = "reticamsgrtests.identity."
    static func location() -> IdentityKeychain.Location {
        IdentityKeychain.Location(service: prefix + UUID().uuidString, accessGroup: SharedIdentityLocation.accessGroup)
    }
    static func cleanUp(_ location: IdentityKeychain.Location) {
        precondition(location.service.hasPrefix(prefix), "refusing to delete a non-test service")
        _ = KeychainOps.live.delete(location)
    }
}

@Test func sharedKeychainRoundTripsATestServiceInTheRealAccessGroup() {
    let production = KeychainOps.live.read(SharedIdentityLocation.shared)
    let location = TestKeychain.location()
    defer { TestKeychain.cleanUp(location) }
    let identity = Identity()
    let data = identity.privateKey!
    let store = IdentityStore.live(ops: .live, shared: location)
    #expect(store.load(.loadOnly) == .absent)
    #expect(store.restore(data) == .restored(identity))
    #expect(store.load(.loadOnly) == .ready(identity))
    #expect(store.restore(Identity().privateKey!) == .identityPresent(service: location.service))
    #expect(KeychainOps.live.read(SharedIdentityLocation.shared) == production)
}
```

`IdentityRecoveryTextTests.swift`:

```swift
import Foundation
import Testing
import ReTiCaMsgrCore
@testable import ReTiCaMsgr

@Test func identityRecoveryTextPerState() {
    let expected = Data(repeating: 0xAB, count: 16)
    let got = Data(repeating: 0xCD, count: 16)
    let missing = IdentityRecoveryText.screen(for: .missing(expected: expected))
    #expect(missing.showsRestore && !missing.showsAccept)
    #expect(missing.detail == "Expected ID: abababab")
    let noAnchor = IdentityRecoveryText.screen(for: .missing(expected: nil))
    #expect(!noAnchor.showsRestore)
    #expect(noAnchor.message.contains("no record"))
    let changed = IdentityRecoveryText.screen(for: .identityChanged(expected: expected, got: got))
    #expect(changed.showsAccept && !changed.showsRestore)
    #expect(changed.detail == "Expected abababab, found cdcdcdcd.")
    let locked = IdentityRecoveryText.screen(for: .unavailable(.locked))
    #expect(locked.message.contains("Unlock your device"))
    #expect(!locked.showsRestore && !locked.showsAccept)
    let stray = IdentityRecoveryText.screen(for: .unavailable(.strayItem("2 items at reticulum.identity")))
    #expect(stray.detail == "2 items at reticulum.identity")
    #expect(IdentityRecoveryText.screen(for: .unavailable(.accessDenied)).message.contains("not your data"))
    #expect(IdentityRecoveryText.screen(for: .unavailable(.other(-50))).detail == "OSStatus -50")
    #expect(IdentityRecoveryText.restore(.rejected(.mismatch(got: got, expected: expected)))
            == "That backup is identity cdcdcdcd, but your conversations belong to abababab.")
    #expect(IdentityRecoveryText.restore(.rejected(.wrongLength(65))) == "That file is 65 bytes; an identity is 64.")
    #expect(IdentityRecoveryText.restore(.refused(.identityPresent(service: "x")))?.contains("Nothing was changed") == true)
    #expect(IdentityRecoveryText.restore(.restored(got)) == nil)
    #expect(IdentityRecoveryText.restore(.refused(.notMissing)) == nil)
}
```

`TestHostScanTests.swift`:

```swift
import Foundation
import Testing
@testable import ReTiCaMsgr

/// Repo root from this file's path (…/ReTiCaMsgrTests/TestHostScanTests.swift).
private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

private func swiftFiles(under folder: String) throws -> [(String, String)] {
    let dir = repoRoot.appendingPathComponent(folder)
    let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    return try items.filter { $0.pathExtension == "swift" }.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
}

@Test func testHostScanOnlyTheHelperSetsTheFlag() throws {
    var setters: [String] = []
    var readers: [String] = []
    for folder in ["ReTiCaMsgr", "ReTiCaMsgrTests", "ReTiCaMsgrUITests"] {
        for (name, source) in try swiftFiles(under: folder) {
            if source.contains("launchEnvironment") { setters.append("\(folder)/\(name)") }
            if source.contains("RETICAMSGR_TEST_HOST") { readers.append("\(folder)/\(name)") }
        }
    }
    // This file names both strings in its own source, so it appears in both lists.
    #expect(Set(setters) == ["ReTiCaMsgrUITests/TestApp.swift", "ReTiCaMsgrTests/TestHostScanTests.swift"])
    #expect(Set(readers) == ["ReTiCaMsgr/AppRuntime.swift", "ReTiCaMsgrUITests/TestApp.swift", "ReTiCaMsgrTests/TestHostScanTests.swift"])
}

@Test func testHostScanEntitlementsNameTheSharedGroup() throws {
    let url = repoRoot.appendingPathComponent("ReTiCaMsgr/ReTiCaMsgr.entitlements")
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
    let groups = plist?["keychain-access-groups"] as? [String]
    #expect(groups == ["$(AppIdentifierPrefix)co.lithobyte.reticulum.identity"])
    #expect(ReTiCaMsgrCore.SharedIdentityLocation.accessGroup == "HK6WSAR793.co.lithobyte.reticulum.identity")
    #expect(ReTiCaMsgrCore.SharedIdentityLocation.accessGroup.hasSuffix(String(groups![0].dropFirst("$(AppIdentifierPrefix)".count))))
    let tests = repoRoot.appendingPathComponent("ReTiCaMsgrTests/ReTiCaMsgrTests.entitlements")
    let testPlist = try PropertyListSerialization.propertyList(from: Data(contentsOf: tests), format: nil) as? [String: Any]
    #expect(testPlist?["keychain-access-groups"] as? [String] == groups)
}
```

(`TestHostScanTests.swift` needs `import ReTiCaMsgrCore` for the second test.) Delete `ReTiCaMsgrTests/ReTiCaMsgrTests.swift`.

- [ ] **Step 2: Run** — boot the simulator, then the hosted test command. Expected: PASS (the `QRCodeImageTests` still pass).

- [ ] **Step 3: Mutation check** (each a single `xcodebuild test` run; revert by hand between batches)

Batch A: `AppRuntime.build` skips `guard store == nil` → `appRuntimeBuildIsIdempotentOnceReady` fails; `retry` ignores the interval → `…LockedIsUnavailableAndRetryRecovers` fails; `restore` skips the `.missing` guard → `…RefusedWhenNotMissing` fails; `acceptNewIdentity` skips `anchor.replace` → `…IdentityChangedRefusesReadyUntilAccepted` fails (still `identityChanged`).
Batch B: `Environment.isTestHost` returns false → `…TestHostEnvironmentNeverTouchesTheRealKeychain` fails; `IdentityRecoveryText.screen(.missing(nil))` sets `showsRestore: true` → `identityRecoveryTextPerState` fails; `IdentityStore.live` ignores the `shared` parameter → `sharedKeychainRoundTrips…` fails on `identityPresent(service:)` (and the production snapshot check would catch a write to the real service — read that assertion's result carefully and clean up by hand if it ever fails); `TestApp.make` drops the flag → `testHostScanOnlyTheHelperSetsTheFlag` fails on `readers`.
Revert by hand; PASS.

- [ ] **Step 4: Commit** — `test: hosted runtime, real access-group and test-host guard tests`.

---

## Final whole-branch review

After Task 5: core suite green, app build green, hosted tests green, then the final Opus review over `main..HEAD`, one fix wave, one re-review. Then the simulator smoke (§5.7 manual steps 1–2 at least: launch and see the Address view), the rebase onto app main, and the user's approval to merge.
