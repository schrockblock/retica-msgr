# Shared Reticulum Identity — Adoption in ReTiCaMsgr (with ReTiCAKeychain hardening)

**Date:** 2026-09-29
**Status:** Approved in brainstorming; awaiting written-spec review
**Scope:** ReTiCA (`ReTiCAKeychain` hardening, Part A) + ReTiCaMsgr (adoption, Part B). Nbhd is out
of scope except for the build note in §6.
**Parent design:** `/Users/ell/development/ios/apps/Nbhd/docs/superpowers/specs/2026-09-26-shared-identity-design.md`
(§7 is the adoption guidance this spec implements) and
`/Users/ell/development/ios/apps/Nbhd/docs/superpowers/specs/2026-09-28-identity-recovery-design.md`
(the recovery shape this spec mirrors).

## 1. Intent

ReTiCaMsgr and Nbhd should use **one Reticulum identity per device**, read from the shared
Keychain item Nbhd already uses (service `reticulum.identity`, access group
`HK6WSAR793.co.lithobyte.reticulum.identity`). ReTiCaMsgr owns `lxmf.delivery`; Nbhd syncs on
`nbhd.sync`. Before ReTiCaMsgr adopts, `ReTiCAKeychain` gains the hardening Nbhd's status lists as
"all BEFORE the messaging app adopts".

**Success:**
- ReTiCA: two items at the shared location, or any synchronizable item, fail closed everywhere; the
  first-launch race no longer surfaces a spurious `unexpectedItem`; `legacyConflicts` reports a
  differing legacy identity without writing; a base32 codec matches Python's.
- ReTiCaMsgr: loads the identity Nbhd wrote (the Address view shows the same hash as Nbhd's
  identity card); a fresh install still mints silently; with messages present and no key anywhere,
  the app shows a restore screen and accepts only the expected identity; a changed shared identity
  is refused until the user accepts it explicitly. Verified on a clone simulator (§5.5).

## 2. Decisions (from brainstorming)

- **Order:** Part A (ReTiCA hardening) first, merged fast-forward into ReTiCA `main` with the
  user's approval; then Part B in an app worktree. Nbhd's own anchor refusal stays an Nbhd
  follow-up (user's choice: "Do the ReTiCA hardening first").
- **New `Failure` cases** (`ambiguousItems`, `synchronizableItem`) rather than folding into
  `unexpectedItem` — precision over Nbhd's two-line compile fix (user: "New cases are fine").
- **No export in this app for now.** Restore accepts Nbhd's backup (same identity, same format).
  Export here is a later slice (user: "Rely on Nbhd's export for now").
- **Legacy:** `legacy: []` per parent §7. The app's old item (service `com.reticamsgr.identity`,
  account `primary`, no group) is never read or deleted; it is harmless because it lives under a
  different service. Do NOT `simctl keychain reset` a simulator that holds Nbhd memberships — that
  would delete Nbhd's shared item too.
- **The base32 codec lives in `ReTiCAKeychain`** (`IdentityBackup`), copied from Nbhd's
  `IdentityExport` so both apps can share it. Nbhd keeps its copy until it chooses to switch.
- **Anchor refusal from day one** in this app (the thing Nbhd still owes): a differing anchor
  refuses ready and offers an explicit "Use the new identity".
- **No store retirement is needed:** a store exists only in `ready`, and `ready` never rebuilds.
  Recovery states have no store, so Retry / Restore / Accept build the store for the first time.

## 3. Current state (facts from exploration)

- ReTiCA `main` (b6a53bf) has `ReTiCAKeychain` with `IdentityKeychain.load` / `loadOrCreate` /
  `importIdentity`, `KeychainOps` (`read` uses `kSecMatchLimitOne`, no synchronizable attribute),
  `InMemoryKeychain` (models groups and accounts, not synchronizable items). Tests:
  `Tests/ReTiCAKeychainTests/{IdentityKeychainTests,IdentityKeychainLoadTests,IdentityKeychainImportTests,KeychainOpsTests,TestSupport}.swift`.
  None of the four hardening items exists (`grep legacyConflicts|SynchronizableAny|matchLimitAll` is empty).
- Nbhd switches exhaustively over `IdentityKeychain.Failure` at
  `Packages/NbhdKernel/Sources/NbhdStore/IdentityStore.swift:103` and `:110`.
- ReTiCaMsgr: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/IdentityStore.swift` reads or mints via its
  own `KeychainIdentity` (`SecItem*`, service `com.reticamsgr.identity`, account `primary`, no
  group, delete-then-add). `ReTiCaMsgr/ReTiCaMsgrApp.swift` builds a static store at init:
  `IdentityStore.liveValue.load()`, then `prepareDependencies` (database at
  `<Documents>/reticamsgr.sqlite`, `requestResponder` answering `/publicKey`), then
  `Store(initialState: AppFeature.State(identity:))`. `RootView` is a `TabView`. The reducer never
  reads `@Dependency(\.identityStore)`; only `IdentityStoreTests` uses `testValue`.
- No entitlements file; no `CODE_SIGN_ENTITLEMENTS`. Team `HK6WSAR793`, bundle
  `co.lithobyte.ReTiCaMsgr`, tests `co.lithobyte.ReTiCaMsgrTests`. Hosted targets:
  `ReTiCaMsgrTests` (`QRCodeImageTests.swift`, `ReTiCaMsgrTests.swift`) and `ReTiCaMsgrUITests`.
- Conversations are derived from messages (`Conversation.list(from:)`); there is no
  `conversations` table. "Local state tied to the identity" is therefore **any row in `messages`**.
- `AppFeature` has `disconnectTapped` and `setNodeMode(Bool)`; there is no shutdown action and
  none is needed (§2).
- Core package depends on ReTiCA by path `../../../pods/ReTiCA` (products `ReTiCANode`,
  `ReTiCAInterfaces`, `ReTiCATransport`).

## 4. Part A — `ReTiCAKeychain` hardening

Work in a ReTiCA worktree (sibling of `/Users/ell/development/ios/pods/ReTiCA`; the user runs a
parallel ReTiCA session there — never commit in the main checkout).

### 4.1 Reads see every item

`KeychainOps.ReadResult` gains:

```swift
public enum ReadRejection: Sendable, Equatable {
    /// More than one item matched the query (e.g. two accounts at the shared location, or the
    /// group-less probe found the service in several groups).
    case multipleItems(count: Int)
    /// At least one matching item is `kSecAttrSynchronizable = true` (an iCloud-synced copy would
    /// split direct LXMF delivery across devices).
    case synchronizableItem
}
case rejected(ReadRejection)
```

`KeychainOps.live.read`:
- query = `baseQuery(location)` + `kSecMatchLimit: kSecMatchLimitAll`,
  `kSecAttrSynchronizable: kSecAttrSynchronizableAny`, `kSecReturnAttributes: true`,
  `kSecReturnData: true`, `kSecReturnPersistentRef: true`. The result is `[[String: Any]]`.
- `mapRead(status:items:)`: `errSecItemNotFound` (or success with an empty array) → `.notFound`;
  any other non-success → `.failed(status)`; success → if any item's `kSecAttrSynchronizable`
  attribute is true → `.rejected(.synchronizableItem)` (checked first: one synced item is enough
  to refuse); else if `items.count > 1` → `.rejected(.multipleItems(count:))`; else the one item
  must carry data and a persistent ref → `.found(data, persistentRef:)`, otherwise
  `.failed(errSecSuccess)` as today.
- `add`, `delete`, `deleteItem` unchanged. `addAttributes` still never sets
  `kSecAttrSynchronizable` (so writes stay device-local); `deleteQuery` unchanged
  (`IdentityKeychain` never calls it).

`IdentityKeychain.Failure` gains:

```swift
/// More than one item at this location. Nothing is read, minted, migrated, deleted or imported.
case ambiguousItems(location: Location, count: Int)
/// An item at this location is iCloud-synchronizable. Fails closed the same way.
case synchronizableItem(location: Location)
```

Mapping, everywhere a read happens (rule 1 shared read, rule 2 legacy reads, `rereadWinner`, the
migrate re-reads, `importIdentity`'s named scans and duplicate re-read, `legacyConflicts`):
`.rejected(.multipleItems(n))` at `L` → `.failed(.ambiguousItems(location: L, count: n))`;
`.rejected(.synchronizableItem)` at `L` → `.failed(.synchronizableItem(location: L))`.
`ImportOutcome.failed` carries them unchanged. `removeLegacyCopies` ignores a rejected read (it
only ever deletes a byte-equal single item).

### 4.2 The probe inherits it

`probeForUnexpectedItems` uses the same `read`, so it now sees synchronizable strays. Its
group-less reads map: `.rejected(.multipleItems)` → `.unexpectedItem(service:)` (several items
under the service somewhere is still "an unexpected item exists"); `.rejected(.synchronizableItem)`
→ `.synchronizableItem(location: <the group-less location>)`; `.failed(status)` →
`.readFailed(location: <group-less>, status:)` as today.

### 4.3 A probe hit on the shared service re-reads

`probeForUnexpectedItems` returns `enum ProbeResult { case clear, hit(service: String), failed(Failure) }`.
In `load`, rule 3:
- `.clear` → `.absent`; `.failed(f)` → `.failed(f)`.
- `.hit(service)` where `service != shared.service` → `.failed(.unexpectedItem(service:))` (unchanged).
- `.hit(service)` where `service == shared.service` → re-read `shared` (named location):
  `.found` + valid → `removeLegacyCopies` then `.loaded(identity)` (the race resolved: the other app
  wrote the shared item between rule 1 and the probe); `.found` + invalid → `.failed(.corrupt(shared))`;
  `.notFound` → `.failed(.unexpectedItem(service:))` (a same-service item in a group we don't
  name — as today); `.failed(status)` → `.failed(.readFailed(location: shared, status:))`;
  `.rejected` → mapped per §4.1.

`importIdentity` step 3 is unchanged in outcome: any hit → `.identityPresent(service:)`. (A
re-read there could only confirm the item exists.)

### 4.4 `legacyConflicts`

```swift
public struct LegacyConflict: Sendable, Equatable {
    public var location: Location
    public var identityHash: Data   // 16 bytes
}
public enum ConflictOutcome: Sendable, Equatable {
    case none
    /// `sharedHash` is the shared item's identity hash, or nil when the shared item is absent and
    /// the reference was the first legacy identity (the one migration would copy).
    case conflicts(sharedHash: Data?, legacy: [LegacyConflict])
    case failed(Failure)
}
public static func legacyConflicts(shared: Location, legacy: [Location] = [], ops: KeychainOps = .live) -> ConflictOutcome
```

Rules, read-only, nothing written or deleted:
0. Any unscoped location → `.failed(.invalidLocation)`. A legacy location equal to `shared` is
   dropped.
1. Read `shared`: `.failed` → `.failed(.readFailed)`; `.rejected` → mapped; `.found` invalid →
   `.failed(.corrupt(shared))`; `.found` valid → `reference = hash`, `sharedHash = hash`;
   `.notFound` → `reference = nil`, `sharedHash = nil`.
2. For each legacy location in order: `.notFound` → continue; `.failed` / `.rejected` → `.failed`;
   `.found` invalid → `.failed(.corrupt(location))`; `.found` valid → if `reference == nil` set
   `reference = hash` (this item would win migration) and continue; else if `hash != reference`
   append `LegacyConflict(location:identityHash:)`.
3. Empty conflicts → `.none`; else `.conflicts(sharedHash:legacy:)`.

The group-less probe is NOT run here (a conflict query names its locations; strays are `load`'s job).

### 4.5 `IdentityBackup` (base32)

```swift
public enum IdentityBackup {
    /// RFC 4648 base32, uppercase, '=' padded — byte-identical to Python's base64.b32encode.
    public static func base32(_ data: Data) -> String
    /// Strict inverse (and of Python's b32decode without casefold): uppercase alphabet only,
    /// padding exactly right or entirely absent, impossible lengths and non-zero trailing bits
    /// rejected, no whitespace trimming (callers do). Never log inputs or outputs.
    public static func decodeBase32(_ text: String) -> Data?
}
```

Copied from Nbhd's `Packages/NbhdKernel/Sources/NbhdKernel/IdentityExport.swift` (the codec only,
not `privateKey(of:)`). RFC 4648 vectors pin it: `""→""`, `"f"→"MY======"`, `"fo"→"MZXQ===="`,
`"foo"→"MZXW6==="`, `"foob"→"MZXW6YQ="`, `"fooba"→"MZXW6YTB"`, `"foobar"→"MZXW6YTBOI======"`.
Decode accepts each with or without padding; rejects lowercase, `MZXW6Y=` (wrong pad count),
`MZXW6YTBO` (impossible length 9→remainder 1), and `MZXW6YR=` (non-zero trailing bits).

### 4.6 `InMemoryKeychain`

- `set(_:at:account:synchronizable:)` gains `synchronizable: Bool = false`; `Stored` carries it.
- `read` returns `.rejected(.synchronizableItem)` if any matching item is synchronizable, else
  `.rejected(.multipleItems(count:))` if more than one matches, else `.found` — the same order as
  live. `add` still keys by account `""` and never stores synchronizable.
- Document the known fidelity gap: an unentitled named group returns `notFound` here where the
  real Keychain returns `-34018`.

### 4.7 Docs

- ReTiCA `docs/superpowers/specs/2026-09-29-keychain-hardening-design.md`: a short pointer to this
  spec's §4 (ReTiCA's spec index stays complete).
- Nbhd build note (§6).

## 5. Part B — ReTiCaMsgr adoption

Work in an app worktree (`ReTiCaMsgr-shared-identity`, branch `feat/shared-identity`), after Part A
is on ReTiCA `main` (the package resolves ReTiCA by path, so no `Package.swift` path change).

### 5.1 Entitlements and project

- `ReTiCaMsgr/ReTiCaMsgr.entitlements`:
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
- `ReTiCaMsgrTests/ReTiCaMsgrTests.entitlements` with the same content (the hosted real-Keychain
  test needs the group).
- `project.pbxproj`: `CODE_SIGN_ENTITLEMENTS = ReTiCaMsgr/ReTiCaMsgr.entitlements;` in both app
  configurations; `CODE_SIGN_ENTITLEMENTS = ReTiCaMsgrTests/ReTiCaMsgrTests.entitlements;` in both
  test configurations. The shared group becomes the app's default group (it has no other); every
  location still names the group explicitly.
- `ReTiCaMsgrCore/Package.swift`: add `.product(name: "ReTiCAKeychain", package: "ReTiCA")` to
  the `ReTiCaMsgrCore` target.

### 5.2 `IdentityStore` (core) — the single seam

`IdentityStore.swift` is rewritten. `KeychainIdentity` and all `SecItem` code are deleted.

```swift
public enum SharedIdentityLocation {
    public static let service = "reticulum.identity"
    /// Must equal `$(AppIdentifierPrefix)co.lithobyte.reticulum.identity` in ReTiCaMsgr.entitlements.
    public static let accessGroup = "HK6WSAR793.co.lithobyte.reticulum.identity"
    public static let shared = IdentityKeychain.Location(service: service, accessGroup: accessGroup)
}

public enum LoadPolicy: Sendable, Equatable {
    /// No local state tied to an identity: a fresh install may mint.
    case loadOrCreate
    /// Messages exist: never mint; `.absent` means the key was lost.
    case loadOnly
}

public enum IdentityFailureReason: Sendable, Equatable {
    case locked                      // errSecInteractionNotAllowed (-25308) / errSecNotAvailable (-25291)
    case accessDenied                // errSecMissingEntitlement (-34018) on read or add
    case strayItem(String)           // unexpectedItem(service) → "service"; ambiguousItems → "N items at service";
                                     // synchronizableItem → "synchronizable item at service"
    case corrupt
    case other(Int32?)
}

public enum IdentityLoad: Sendable, Equatable {
    case ready(Identity)
    case absent                      // only under .loadOnly
    case failed(IdentityFailureReason)
}

public enum RestoreOutcome: Sendable, Equatable {
    case restored(Identity)
    case identityPresent(service: String)
    case invalidKey
    case failed(IdentityFailureReason)
}

public struct IdentityStore: Sendable {
    public var load: @Sendable (LoadPolicy) -> IdentityLoad
    public var restore: @Sendable (_ privateKey: Data) -> RestoreOutcome
    public static func live(ops: KeychainOps) -> IdentityStore
    public static var liveValue: IdentityStore { live(ops: .live) }
    public static var testValue: IdentityStore   // fixed in-process identity: load → .ready(id), restore → .identityPresent("test")
}
```

`live(ops:)`:
- `load(.loadOrCreate)` = `IdentityKeychain.loadOrCreate(shared:legacy: [], ops:)`: `.loaded/.created/.migrated(id)` → `.ready(id)`; `.failed(f)` → `.failed(reason(f))`.
- `load(.loadOnly)` = `IdentityKeychain.load(...)`: `.loaded/.migrated(id)` → `.ready(id)`; `.absent` → `.absent`; `.failed(f)` → `.failed(reason(f))`.
- `restore(pk)` = `IdentityKeychain.importIdentity(privateKey: pk, shared:legacy: [], ops:)`: `.imported(id)` → `.restored(id)`; `.identityPresent(service)` → same; `.invalidKey` → same; `.failed(f)` → `.failed(reason(f))`.
- `reason(_:)` (public, pure, tested): `.readFailed(_, status)`: -34018 → `.accessDenied`; -25308 / -25291 → `.locked`; else `.other(status)`. `.addFailed(status)`: -34018 → `.accessDenied` else `.other(status)`. `.verifyFailed(status)` → `.other(status)`. `.mintFailed` → `.other(nil)`. `.invalidLocation` → `.other(nil)`. `.corrupt` → `.corrupt`. `.unexpectedItem(service)` → `.strayItem(service)`. `.ambiguousItems(location, count)` → `.strayItem("\(count) items at \(location.service)")`. `.synchronizableItem(location)` → `.strayItem("synchronizable item at \(location.service)")`.

`lxmfAddressHex(_:)` is unchanged. `DependencyValues.identityStore` stays (used by tests/previews).

### 5.3 Policy, anchor, state (core)

- `AppDatabase.hasMessages(_ database: any DatabaseWriter) throws -> Bool` — synchronous
  `database.read { try Message.count > 0 }` (any row in `messages`).
  `LoadPolicy.forLaunch(database:) -> LoadPolicy`: `hasMessages` true → `.loadOnly`; false →
  `.loadOrCreate`; **throws → `.loadOnly`** (unknown is never "fresh install").
- `IdentityAnchor` (core): UserDefaults key `reticamsgr.expectedIdentityHash` (hex of the 16-byte
  identity hash; public, not secret), `UserDefaults` injected (`.standard` live, a suite-named
  instance in tests).
  - `expected() -> Data?`
  - `recordReady(_ hash: Data)`: writes only when none exists (an existing differing anchor is
    kept — the caller refuses ready instead).
  - `replace(with hash: Data)`: the explicit "Use the new identity" path.
- `IdentityState` (core, Equatable):
  `.loading`, `.ready(Data)`, `.missing(expected: Data?)`, `.identityChanged(expected: Data, got: Data)`, `.unavailable(IdentityFailureReason)`.
- `LaunchIdentity.resolve(policy:anchor:store:) -> (IdentityState, Identity?)` (core, pure over
  the injected pieces): `store.load(policy)`: `.failed(r)` → `.unavailable(r)`; `.absent` →
  `.missing(expected: anchor.expected())`; `.ready(id)`: if `anchor.expected()` is nil →
  `recordReady(id.hash)` and `.ready(id.hash)`; equal → `.ready`; differs → `.identityChanged(expected:got: id.hash)`
  with no anchor write.
- `IdentityRestore` (core, pure; mirrors Nbhd):
  `Rejection { badEncoding, wrongLength(Int), invalidKey, mismatch(got: Data, expected: Data), noExpectedIdentity }`;
  `maxFileBytes = 4096`; `key(fromText:)` (trim whitespace/newlines → `IdentityBackup.decodeBase32`
  → 64 bytes); `key(fromFile:)` (exactly 64 bytes); `validate(privateKey:expected:)` (64 bytes,
  `Identity(privateKey:)` succeeds, `expected` non-nil else `.noExpectedIdentity`, hash equal else
  `.mismatch`); `readKeyFile(at:maxBytes:)` (security-scoped, size-checked before reading);
  `describe(_:)` log-safe (kinds and hashes only).
- `RestoreResult { restored(Data), rejected(Rejection), refused(RestoreRefusal), failed(IdentityFailureReason) }`,
  `RestoreRefusal { notMissing, identityPresent(service: String) }`.
- `shortID(_ hash: Data) -> String` = first 8 hex chars (used by every screen).

### 5.4 `AppRuntime` and the root (app target)

`@MainActor @Observable final class AppRuntime`:
- `init(environment:)` opens the database ONCE (`AppDatabase.makeOnDisk` at the existing path, or
  in-memory for a test host), keeps `identityStore`, `anchor`, `keychainOps`, `now`.
- `state: IdentityState = .loading`, `store: StoreOf<AppFeature>?` (non-nil only in `.ready`).
- `build()`: `policy = LoadPolicy.forLaunch(database:)`; `(state, identity) = LaunchIdentity.resolve(...)`;
  on `.ready` builds the store once: `Store(initialState: AppFeature.State(identity:)) { AppFeature() } withDependencies: { $0.defaultDatabase = db; $0.requestResponder = <publicKey responder as today> }`
  (no `prepareDependencies`; it may only run once per process and the runtime may build later than init).
- `retry()`: rate-limited to once per second (`lastRetry`), then `build()`. Ignored in `.ready`.
- `restore(privateKey:) -> RestoreResult`: `guard case .missing(let expected) = state else { .refused(.notMissing) }`;
  `IdentityRestore.validate(privateKey:expected:)` → `.rejected`; `identityStore.restore(pk)`:
  `.restored` → `build()` then `.restored(hash)`; `.identityPresent(s)` → `.refused(.identityPresent(service: s))`;
  `.invalidKey` → `.rejected(.invalidKey)`; `.failed(r)` → `.failed(r)`.
- `acceptNewIdentity()`: only in `.identityChanged(_, got)`: `anchor.replace(with: got)` then `build()`.
- **Invariant:** the identity only ever enters the app by building the store; nothing swaps it later.
- Test host: `AppRuntime.Environment.forProcess()` returns the live environment unless
  `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil` or
  `environment["RETICAMSGR_TEST_HOST"] == "1"`; then: `InMemoryKeychain` pre-planted with a fixed
  identity at the shared location, an in-memory database, a suite-named UserDefaults. UI tests set
  `RETICAMSGR_TEST_HOST=1` through one helper (`ReTiCaMsgrUITests/TestApp.swift`), and a
  source-scan test pins that no other file sets `launchEnvironment`.
- `ReTiCaMsgrApp`: `@State private var runtime = AppRuntime(environment: .forProcess())`;
  `RootView(runtime:)`; `.task { runtime.build() }` once; `scenePhase` → `.foregrounded` only when
  a store exists; `.onLaunch` sent when the store is built.
- `RootView`: `switch runtime.state` — `.ready` with a store → today's `TabView`; `.loading` →
  `ProgressView`; anything else → `IdentityRecoveryView(runtime:)`.

### 5.5 Recovery UI (app target)

`IdentityRecoveryView`, plain wording, technical detail behind a `DisclosureGroup("Details")`:

| State | Message (gist) | Actions |
|---|---|---|
| `.unavailable(.locked)` | "Your identity is locked. Unlock your device, then tap Retry." | Retry |
| `.unavailable(.strayItem(d))` | "Another Reticulum identity item is in an unexpected place on this device. ReTiCaMsgr won't guess which one to use." Details: `d`. | Retry, details |
| `.unavailable(.corrupt)` | "The identity stored on this device can't be read." | Retry, details |
| `.unavailable(.accessDenied)` | "ReTiCaMsgr isn't allowed to read the identity. This is a signing or configuration problem, not your data." | Retry, details |
| `.unavailable(.other(s))` | "Your identity couldn't be loaded." Details: the status. | Retry, details |
| `.missing(expected:)` | "Your conversations are here, but your identity key isn't. This happens after restoring from an unencrypted backup. Restore it from an identity backup." + "Expected ID: <short>" (or, with no anchor, "Restore isn't possible: this device has no record of which identity your conversations used.") | Restore from backup (only with an anchor), Retry; with NO anchor also "Create a new identity" → confirmation ("Your existing conversations were sent from an identity this device no longer has. Peers will see you as a new address.") → `createNewIdentity()` (amendment 1) |
| `.identityChanged(expected, got)` | "The identity on this device is different from the one your conversations used." + "Expected <short>, found <short>." | Retry; "Use the new identity" → confirmation dialog ("Your existing conversations were sent from the old identity. Peers will see you as a new address.") → `acceptNewIdentity()` |

Retry is disabled while a rebuild is in flight. `RestoreIdentitySheet`: a `PasteButton(payloadType: String.self)`
(no text field; the clipboard is never read automatically) and a "Choose identity file" button
(`fileImporter`, `[.data, .item]`, `allowsMultipleSelection: false`), a summary line ("Pasted text"
/ the file name) with a Clear button, and Restore. Rejections show plain text: `badEncoding` →
"That isn't an identity backup. Paste the text form or choose the identity file."; `wrongLength(n)`
→ "That file is n bytes; an identity is 64."; `mismatch(got, expected)` → "That backup is identity
<short got>, but your conversations belong to <short expected>."; `noExpectedIdentity` → as above;
`refused(.identityPresent)` → "Another Reticulum identity already exists on this device, so
ReTiCaMsgr won't replace it. Nothing was changed."; `refused(.notMissing)` → dismiss;
`failed(r)` → the recovery screen's text for `r`. Input is cleared on success, cancel, dismiss AND
rejection. No key material is ever logged.

### 5.6 What does not change

`AppFeature`, its `State(identity:)`, the node, the Address view (still `lxmfAddressHex`), Settings.
`IdentityStoreTests` is replaced by the tests in §5.7.

### 5.7 Testing (Part B)

- **Core, in-memory Keychain + temporary database:** `LoadPolicy.forLaunch` (no messages →
  `loadOrCreate`; one message → `loadOnly`; a throwing read → `loadOnly`); `IdentityStore.live`
  mapping for every outcome and `reason(_:)` for every `Failure` case including the two new ones;
  `LaunchIdentity.resolve` (fresh → `ready` and the anchor written; matching anchor → `ready`;
  differing anchor → `identityChanged`, anchor untouched; `absent` → `missing(expected)`; `failed`
  → `unavailable`); `IdentityAnchor` write-once and `replace`; `IdentityRestore` (text with/without
  padding and whitespace, file form, wrong length, bad encoding, mismatch shows both hashes, no
  anchor refused); `shortID`.
- **App target (hosted, `ReTiCaMsgrTests`):** `AppRuntime` with the in-memory environment: launch
  with messages and an empty Keychain → `.missing`, `addCount == 0`; without messages → `.ready`
  and one add; restore of the right key → `.ready(expected)` and a store; a wrong key → `.rejected(.mismatch)`,
  nothing added; `acceptNewIdentity` rewrites the anchor and reaches `.ready(got)`; Retry
  rate-limited (a second call within 1 s is a no-op). One real-Keychain test: a
  `reticamsgrtests.identity.<uuid>` service in the shared group — `importIdentity` into it →
  `.imported`; again → `.identityPresent`; cleanup via `KeychainOps.live.delete` through a helper
  that refuses any service not prefixed `reticamsgrtests.`; the production service is never
  touched (snapshot `read(SharedIdentityLocation.shared)` before and after and assert equal). A
  source-scan test asserts only `ReTiCaMsgrUITests/TestApp.swift` contains `RETICAMSGR_TEST_HOST`.
- **Mutation protocol** (the user's rule) for every new test: green → mutate production → red →
  revert by hand → green; masked mutations in separate sub-batches.
- **Manual, on a disposable clone of a simulator that has Nbhd installed with memberships:**
  1. Launch Nbhd (its identity is the shared one; note the card's short ID).
  2. Install this build; launch; the Address view shows the same short ID; the old
     `com.reticamsgr.identity` item is untouched.
  3. Exchange at least one message so the database has a row. Then, on the CLONE only,
     `xcrun simctl keychain <udid> reset` (it removes every item, Nbhd's included — which is why
     this runs on a disposable clone). Launch THIS app first: expect the restore screen with the
     expected short ID and no mint (the log says `identity keychain absent`).
  4. A wrong backup is rejected with both short IDs; malformed text is rejected; the right backup
     (Nbhd's export of the expected identity) restores without relaunch; relaunch logs `loaded`.
  5. Reset the Keychain once more and launch Nbhd first so it mints a NEW identity; launch this
     app: expect "identity changed" with both IDs; "Use the new identity" continues; the Address
     view shows the new ID.
  6. Device (user): a pre-unlock launch shows "locked"; unlock, Retry reaches home without relaunch.

## 6. Nbhd build note

After Part A merges, Nbhd's `Packages/NbhdKernel/Sources/NbhdStore/IdentityStore.swift` lines 103
and 110 (two exhaustive `switch failure`) need the two new cases: line 103 adds
`.ambiguousItems, .synchronizableItem` to the throw list; line 110's `reason(for:)` maps both to
`.strayItem`-equivalent (`IdentityFailureReason.strayItem(service:)` with the location's service).
A third exhaustive switch, `NbhdTests/SharedIdentityKeychainHostedTests.swift` `TestKeychain.productionState()`
(over `KeychainOps.ReadResult`), needs `case let .rejected(r): "rejected \(r)"`, or Nbhd's hosted test
target fails to compile (final review I1, 2026-09-29).
This work appends that note to Nbhd's `docs/STATUS.md` follow-ups (uncommitted, no other Nbhd change).

## 7. Out of scope

- Identity export in this app; deliberate "start a new identity"; fresh-install restore on first
  launch; Nbhd's own anchor refusal; migrating this app's legacy item; iCloud Keychain sync;
  multi-device identity.
