# ReTiCAPush Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new Swift package, `ReTiCAPush`, that gives an iOS app everything it needs to be woken by a push-capable Reticulum hub: push-payload decoding, a shared inbox, a proof builder, a signed registration API client, a TCA `PushFeature` reducer, and a Notification Service Extension handler that proves pushed packets back to the hub. Plus the server contract document.

**Architecture:** Three library targets. `ReTiCAPushCore` (no TCA) holds the pure pieces and the HTTP client. `ReTiCAPush` (TCA) holds `PushFeature`, which owns the toggle, the APNs token and the registration lifecycle, and emits a delegate action with packets for the host app to inject. `ReTiCAPushExtension` (no TCA) holds `PushServiceHandler`, the one function the app's service extension calls: stash the packets, sign a proof for each one addressed to us, write the proofs to the hub over one short TCP connection. Nothing here touches ReTiCA's transport; the host app does the injection.

**Tech Stack:** Swift 6 language mode, swift-tools 6.0, ReTiCA (`Packet`, `Identity`, `HDLC`, `Destination`, `LXMessage.deliveryHash`, `IdentityKeychain`, `InMemoryKeychain`), ComposableArchitecture 1.15+ (TCA, `@Shared(.appStorage)`), Swift Testing, Network.framework (`NWConnection`, `NWListener`), URLSession.

**Spec:** `/Users/ell/development/ios/apps/ReTiCaMsgr/docs/superpowers/specs/2026-10-01-push-relay-design.md`. Read §1 and §2 before starting. It is binding. Where this plan resolves something the spec leaves open, the resolution is listed under "Spec resolutions" below.

## Global Constraints

**Where you work**
- The package is a NEW git repository at `/Users/ell/development/ios/pods/ReTiCAPush`, on branch `main`. Task 1 creates it. All work happens there.
- Never touch `/Users/ell/development/ios/pods/ReTiCA`: no edits, no git, no builds inside it. Another agent works there. The package depends on it by path (`../ReTiCA`), which also resolves ReTiCA's own `../FCB` dependency because both live under `pods/`.
- Never commit in `/Users/ell/development/ios/apps/ReTiCaMsgr` from this plan. The app plan is separate.
- **ReTiCA drift:** the package builds ReTiCA from its live checkout, and it may change mid-run. If a build or test failure traces into ReTiCA source, stop and report it. Do not work around it. A stale `.build` directory in the package may be deleted if it causes a build failure.

**Shell**
- One command per Bash call. No `|`, `&&`, `||`, `;`, `$(...)` or `xargs`.
- No inline interpreters (`python -c`, `swift -e`, heredocs into interpreters, and so on). Scripts and scratch files go under `/tmp/ReTiCAPush/`. Create that directory once with `mkdir -p /tmp/ReTiCAPush`.

**Commits**
- Stage explicit paths only: `git -C /Users/ell/development/ios/pods/ReTiCAPush add <path> <path> ...`. Never `git add -A` or `git add .`.
- **Each task writes its commit message to its own file**, `/tmp/ReTiCAPush/msg-task-N.txt` (N = the task number), with the **Write** tool, then runs `git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-N.txt`. Never reuse another task's file.
- No semicolons anywhere in a commit message.
- End every commit message with these two trailer lines, at column 0, after a blank line. Put the name of the model that actually wrote the commit in the first line (for example `Claude Opus 5.5`):
  ```
  Co-Authored-By: <model name> <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
  ```

**Tests**
- Command: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter X`. Full suite: the same without `--filter`.
- The package must compile at the end of every task. Swift 6 language mode is on: every type crossing an `async` boundary must be `Sendable`.
- Each task's new tests share a unique name prefix, so one `--filter` selects exactly them:

  | Task | Prefix | New tests | Suite total after |
  |---|---|---|---|
  | 1 | `hex` | 3 | 3 |
  | 3 | `pushPayload` | 9 | 12 |
  | 4 | `pushInbox` | 6 | 18 |
  | 5 | `proofBuilder` / `deliveryHash` | 8 | 26 |
  | 6 | `pushRegistration` | 8 | 34 |
  | 7 | `registrationClient` | 5 | 39 |
  | 8 | `sharedPushSettings` / `pushStorage` | 4 | 43 |
  | 9 | `pushFeatureEnable` | 5 | 48 |
  | 10 | `pushFeatureToken` | 7 | 55 |
  | 11 | `pushFeatureLifecycle` | 7 | 62 |
  | 12 | `pushServiceHandler` / `proofFrameSender` | 9 | 71 |

**Mutation verification (mandatory for every task with tests)**
1. The new tests go green.
2. Apply the task's listed batch of production mutations, all at once. Run the task's filter and confirm that EVERY new test is red. The batch table names, per test, the mutation that must turn it red.
3. Revert every mutation BY HAND with the Edit tool. Never use `git checkout -- <file>`, `git restore` or `git stash`. Then run `git -C /Users/ell/development/ios/pods/ReTiCAPush diff` and confirm that only the intended task changes remain.
4. The new tests are green again, then the full suite is green.
- Each batch below has been checked so that no mutation hides another's effect, none crashes the test process, and each changes the value under test on the fixture used.
- If any new test survives the batch, that test is not testing what it claims. Fix the test and restart from step 1.
- Tasks 2 and 13 have no unit tests and are exempt.

**Test style**
- Swift Testing only (`import Testing`, `@Test`, `#expect`, `#require`). No XCTest.
- TCA `TestStore` with `store.exhaustivity = .off` unless a test asserts the absence of an action, in which case it turns exhaustivity `.on` for that window. Never call `skipInFlightEffects` while exhaustivity is `.on`.
- Tests that touch the filesystem use a fresh directory under `FileManager.default.temporaryDirectory` named with a `UUID`. Tests that touch `UserDefaults` use a fresh suite named with a `UUID` and call `removePersistentDomain` first. Nothing writes to the real Keychain, the real app group, or outside temp.
- The suite must end with zero known issues.

**Values from the spec, copied verbatim**
```
Package location:        /Users/ell/development/ios/pods/ReTiCAPush
Targets:                 ReTiCAPushCore (no TCA), ReTiCAPush (TCA), ReTiCAPushExtension (no TCA)
Platforms:               iOS 17 / macOS 14, swift-tools 6.0
Inbox capacity:          256 entries, oldest evicted first
Push payload max:        8 packets per push, each ≤ Packet.mtu (500 bytes)
Registration domains:    "retica-push-register-v1" (POST), "retica-push-unregister-v1" (DELETE)
Registration path:       {base}/v1/registrations
Signing layout:          domain UTF-8 ‖ publicKey(64) ‖ UInt16 BE token length ‖ token ‖
                         UInt8 platform length ‖ platform ‖ UInt8 environment length ‖ environment ‖
                         UInt8 bundle_id length ‖ bundle_id ‖ UInt64 BE issued_at
JSON keys:               v, identity_public_key (base64), push_token (hex), platform, environment,
                         bundle_id, issued_at (int), signature (base64)
Re-registration rule:    skip the POST when the same token was registered within 24 hours
Denied-permission text:  "Notifications are off for ReTiCaMsgr in Settings"
Invalid URL text:        "Invalid registration URL"
Extension deadline:      20 s overall, 10 s for the TCP write
Proof packet:            header1, .proof, broadcast, single, destinationHash = packetHash.prefix(16),
                         payload = identity.sign(packetHash), HDLC-framed
Settings defaults keys:  namespaced retica.push.*
```

**Spec resolutions**
- The spec's `pushInbox` and `pushSettings` dependencies are replaced by a value in `PushFeature.State`: `PushStorage` (an inbox directory plus a defaults suite name). Both processes derive it from the same app-group container through `PushStorage.init(containerURL:appGroupID:)`, so the app and the extension cannot disagree about where the inbox is. Effects construct `PushInbox` and `SharedPushSettingsStore` from it. Tests set a temporary `PushStorage`.
- `PushPlatform.liveValue` is a no-op placeholder (`PushPlatform.noop`). The app supplies the UIKit implementation through `withDependencies` when it builds its store. The doc comment on `liveValue` says so.
- `SignedRegistration` keeps the `domain` it was signed under so `verify()` needs no parameter. The domain is not part of the JSON; the HTTP method carries it.
- The registration URL must parse and have an `http` or `https` scheme. Anything else is "Invalid registration URL".
- Status text for the settings screen lives on `PushFeature.State.Status` as `displayText`, so the app's view has nothing to compute.

## Review Focus

Inputs the spec implies but no task's tests exercised until this list was written. Each line's test has been added to the owning task.

1. A push whose `rns.packets` entry is valid base64 but decodes to zero bytes. `PushPayload` must reject it, not hand `ProofBuilder` an empty packet. → Task 3, `pushPayloadRejectsAnEmptyEntry`.
2. The inbox directory exists but one file inside is unreadable or empty. `drain` must skip it, not throw away the rest. → Task 4, `pushInboxDrainSkipsAnUnreadableEntry`.
3. A registration whose push token is longer than 65535 bytes cannot be length-prefixed. `signed` must return nil, not truncate. → Task 6, `pushRegistrationRejectsAnOversizeToken`.
4. The server answers 2xx but with an unexpected body. The client must treat 2xx as success regardless of body. → Task 7, `registrationClientTreats204AsSuccess`.
5. `setEnabled(true)` while already enabled must not request permission a second time. → Task 9, `pushFeatureEnableIsIdempotent`.

---

### Task 1: Package scaffold, hex helpers, first commit

**Files:**
- Create: `Package.swift`
- Create: `Sources/ReTiCAPushCore/Data+Hex.swift`
- Create: `Sources/ReTiCAPush/Exports.swift`
- Create: `Sources/ReTiCAPushExtension/Exports.swift`
- Create: `Tests/ReTiCAPushCoreTests/DataHexTests.swift`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `extension Data { var hexString: String; init?(hexString: String) }` (internal to `ReTiCAPushCore`, used by every later Core task), the package layout every later task adds to.

- [ ] **Step 1: Create the repository**

```bash
mkdir -p /Users/ell/development/ios/pods/ReTiCAPush
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush init -b main
```
```bash
mkdir -p /tmp/ReTiCAPush
```

- [ ] **Step 2: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReTiCAPush",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReTiCAPushCore", targets: ["ReTiCAPushCore"]),
        .library(name: "ReTiCAPush", targets: ["ReTiCAPush"]),
        .library(name: "ReTiCAPushExtension", targets: ["ReTiCAPushExtension"]),
    ],
    dependencies: [
        .package(path: "../ReTiCA"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.15.0"),
    ],
    targets: [
        // Pure pieces plus the HTTP client. No TCA, so the service extension can link it.
        .target(
            name: "ReTiCAPushCore",
            dependencies: [
                .product(name: "ReTiCA", package: "ReTiCA"),
                .product(name: "ReTiCAKeychain", package: "ReTiCA"),
            ]
        ),
        // The TCA feature the host app scopes in.
        .target(
            name: "ReTiCAPush",
            dependencies: [
                "ReTiCAPushCore",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        // What the Notification Service Extension links: stash, prove, return.
        .target(
            name: "ReTiCAPushExtension",
            dependencies: ["ReTiCAPushCore"]
        ),
        .testTarget(
            name: "ReTiCAPushCoreTests",
            dependencies: [
                "ReTiCAPushCore",
                .product(name: "ReTiCATransport", package: "ReTiCA"),
                .product(name: "ReTiCANode", package: "ReTiCA"),
                .product(name: "ReTiCAInterfaces", package: "ReTiCA"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 3: Write `.gitignore`**

```
.build/
.swiftpm/
*.xcodeproj
xcuserdata/
```

- [ ] **Step 4: Write the two export shims so the empty targets compile**

`Sources/ReTiCAPush/Exports.swift`:
```swift
@_exported import ReTiCAPushCore
```

`Sources/ReTiCAPushExtension/Exports.swift`:
```swift
@_exported import ReTiCAPushCore
```

- [ ] **Step 5: Write the failing tests**

`Tests/ReTiCAPushCoreTests/DataHexTests.swift`:
```swift
import Testing
import Foundation
@testable import ReTiCAPushCore

@Test func hexRoundTripsLowercase() {
    #expect(Data([0xDE, 0xAD, 0x01]).hexString == "dead01")
    #expect(Data(hexString: "dead01") == Data([0xDE, 0xAD, 0x01]))
}

@Test func hexRejectsOddLength() {
    #expect(Data(hexString: "abc") == nil)
}

@Test func hexRejectsNonHexCharacters() {
    #expect(Data(hexString: "zz") == nil)
}
```

- [ ] **Step 6: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter hex`
Expected: compile error, `hexString` not found.

- [ ] **Step 7: Write `Sources/ReTiCAPushCore/Data+Hex.swift`**

```swift
import Foundation

// ReTiCA's Data+Hex extensions are internal to the ReTiCA module (BLEEndpoint.swift:11 notes the
// same problem). This is the package's own copy.
extension Data {
    /// Lowercase, non-delimited hex representation (matches Python `bytes.hex()`).
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Parse a non-delimited hex string (even length, [0-9a-fA-F]) into bytes.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = chars.startIndex
        while index < chars.endIndex {
            guard let high = chars[index].hexDigitValue,
                  let low = chars[index + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(high << 4 | low))
            index += 2
        }
        self = Data(bytes)
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter hex`
Expected: 3 tests pass. The first run resolves and builds ReTiCA and TCA; allow several minutes.

- [ ] **Step 9: Mutation check**

| Test | Mutation (in `Data+Hex.swift`) |
|---|---|
| `hexRoundTripsLowercase` | `"%02x"` → `"%02X"` |
| `hexRejectsOddLength` | `guard chars.count % 2 == 0 else { return nil }` → `else { self = Data(); return }` |
| `hexRejectsNonHexCharacters` | the `guard let high … low … else { return nil }` → `else { bytes.append(0); index += 2; continue }` |

Apply all three, run the filter, all 3 red. Revert by hand, run again, all 3 green.

- [ ] **Step 10: Commit**

Write `/tmp/ReTiCAPush/msg-task-1.txt`:
```
chore: scaffold the ReTiCAPush package with hex helpers

Three library targets (Core, TCA feature, Extension) depending on ../ReTiCA,
and the package-local Data hex helpers that ReTiCA keeps internal.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add Package.swift .gitignore Sources/ReTiCAPushCore/Data+Hex.swift Sources/ReTiCAPush/Exports.swift Sources/ReTiCAPushExtension/Exports.swift Tests/ReTiCAPushCoreTests/DataHexTests.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-1.txt
```

---

### Task 2: Server contract and README

**Files:**
- Create: `docs/server-contract.md`
- Create: `README.md`

**Interfaces:**
- Consumes: spec §2.
- Produces: the contract every later task's byte layouts and JSON keys must match. Tasks 3, 6 and 7 cite it.

- [ ] **Step 1: Write `docs/server-contract.md`**

```markdown
# ReTiCA push hub — server contract (v1)

A push hub is a Reticulum transport node that can wake an iOS client with an Apple push when
the client's socket is down. The client (`ReTiCAPush`) never uploads messages: the hub already
sits on every path to the client, so it pushes the very bytes it would have written to the
client's socket. The client proves them back over a fresh socket, and the hub routes the proof
to the sender the standard way.

Everything here is normative for a hub a `ReTiCAPush` client can talk to.

## 1. Registration API

Two endpoints, same JSON body, same signing scheme, different domain string.

- `POST {base}/v1/registrations` — create or replace a registration.
- `DELETE {base}/v1/registrations` — remove it.

`{base}` is whatever the user typed as the registration URL, for example
`https://hub.example.net/push`. Trailing slashes are ignored.

### 1.1 Body

| key | type | notes |
|---|---|---|
| `v` | int | always `1` |
| `identity_public_key` | base64 | 64 bytes: X25519 public key ‖ Ed25519 public key, the Reticulum identity serialisation |
| `push_token` | hex | the APNs device token bytes, lowercase hex |
| `platform` | string | `"ios"` |
| `environment` | string | `"production"` or `"sandbox"` |
| `bundle_id` | string | the registering app's bundle identifier |
| `issued_at` | int | Unix seconds at signing time |
| `signature` | base64 | 64-byte Ed25519 signature over the signing bytes (§1.2) |

### 1.2 Signing bytes

Concatenate, with no separators:

1. the domain as UTF-8: `retica-push-register-v1` for POST, `retica-push-unregister-v1` for DELETE
2. the 64 public-key bytes
3. the push-token length as a big-endian UInt16, then the token bytes
4. the `platform` UTF-8 length as a UInt8, then the bytes
5. the `environment` UTF-8 length as a UInt8, then the bytes
6. the `bundle_id` UTF-8 length as a UInt8, then the bytes
7. `issued_at` as a big-endian UInt64

Sign with the Ed25519 half of the identity (the last 32 bytes of the private key). The signature
is the standard 64-byte Ed25519 signature.

### 1.3 Server rules

- Verify `signature` with the Ed25519 half of `identity_public_key`. Reject with 401 otherwise.
  **This check is mandatory.** Without it anyone can register their own token for someone else's
  destination and receive that person's wake-ups and encrypted packets.
- Reject with 400 when `issued_at` is more than 300 seconds from server time, when `v` is not 1,
  or when any field is missing or malformed.
- Derive the client's LXMF delivery destination hash yourself:
  `identity_hash = SHA-256(identity_public_key)[:16]`,
  `destination_hash = SHA-256(SHA-256("lxmf.delivery")[:10] ‖ identity_hash)[:16]`.
  This is `RNS.Destination.hash(identity, "lxmf", "delivery")`.
- POST stores `destination_hash → (push_token, environment, bundle_id, issued_at)`, replacing an
  existing entry for that hash, and answers 200 with
  `{"destination_hash": "<hex>", "expires_at": <unix seconds>}`.
  A registration expires 30 days after the last POST.
- DELETE removes the entry and the client's dormant interface (§2) and answers 204. An unknown
  hash also answers 204.
- An APNs `410 Unregistered` or `BadDeviceToken` response drops the entry and its dormant
  interface.
- The server never needs the client's private key, its messages, or its socket address.

## 2. Transport behaviour

The hub runs a Reticulum transport node. Its TCP server interface is the hub the client dials
(the same host and port the client has configured as its node connection).

- **Binding.** When an announce whose destination hash is a registered `destination_hash`
  arrives on a spawned client interface, that interface is bound to the registration. A later
  announce for the same hash on a different spawned interface rebinds to the new one and retires
  the old one, dormant or not.
- **Dormancy.** When a bound interface's socket closes, the interface stays attached to the
  transport, so the path table, the reverse table and the link table entries that reference it
  remain valid, and it becomes dormant. An unbound spawned interface behaves as stock: detached
  on close.
- **Pushing.** For every outgoing buffer the transport hands a dormant interface: if the
  packet's destination hash equals the bound `destination_hash` (this covers DATA and
  LINKREQUEST packets to the client's delivery destination), push the bytes **exactly as they
  would have hit the socket, after IFAC masking and before HDLC framing**. Drop any other buffer
  (announces, path requests, link packets addressed by link id, packets for other destinations),
  as the dead socket would have.
- **Proof return.** The client returns proofs on a fresh TCP connection that may never
  announce. Proofs must route by the reverse table regardless of ingress interface. Stock RNS
  does this.
- **Retries.** A sender retries a single-packet message every 10 s up to five times, each with a
  distinct packet hash, and its receipt for each attempt lives only 6 s plus 6 s per hop. Push
  every attempt. Use `apns-collapse-id` (§3) so the user sees one banner. A per-destination rate
  limit (suggested: 20 pushes per minute) protects the APNs quota.
- **Lifetime.** A dormant interface lives as long as its registration.

## 3. Push shape

Headers: `apns-push-type: alert`, `apns-priority: 10`, `apns-topic: <bundle_id>`,
`apns-collapse-id: <destination_hash hex>`. Send to the APNs environment the registration named.

```json
{
  "aps": {
    "alert": { "title": "New message" },
    "mutable-content": 1,
    "content-available": 1
  },
  "rns": {
    "v": 1,
    "packets": ["<base64 raw packet>", "..."]
  }
}
```

- `aps.alert.title` is fixed by the server and never carries sender or content information.
  The client's service extension never changes it.
- Each entry of `packets` is one raw Reticulum packet (at most 500 bytes), base64 without line
  breaks.
- Packets to one destination that arrive within 500 ms may be batched into one push: at most 8
  packets and 3500 bytes of base64 in total (the APNs payload limit is 4 KB).
- Pushes for different registrations are never batched.
- `mutable-content: 1` runs the client's service extension, which stashes the packets and
  proves them. `content-available: 1` additionally asks iOS for a best-effort background wake of
  the app, which ingests the packets sooner. Both are required.

## 4. What the client does with a push

For the hub author's mental model, not something the hub depends on:

1. The service extension decodes `rns.packets`, writes each packet to a shared inbox, signs an
   implicit proof (`Ed25519(packet_hash)` addressed to `packet_hash[:16]`) for every DATA packet
   addressed to the client's delivery hash, opens one TCP connection to the hub, writes the
   HDLC-framed proofs, closes. It never decrypts anything and never changes the notification.
2. The app, when it next runs (background wake, tap or launch), reconnects to the hub, announces,
   and feeds the inbox packets into its transport as if the socket had delivered them. That path
   decrypts, dedups and may send a second proof, which the sender ignores.

## 5. Reference implementation note

For the Python reference stack this is a custom `RNS.Interfaces.Interface` subclass: a
push-aware `TCPServerInterface` whose spawned interfaces implement binding and dormancy, with
`process_outgoing` routing to APNs for dormant ones, plus a small HTTP service for §1 and a
token-based APNs client. No change to RNS itself is needed. No code is part of this deliverable.
```

- [ ] **Step 2: Write `README.md`**

```markdown
# ReTiCAPush

Opt-in push wake-ups for a ReTiCA-based iOS messenger, against a push-capable Reticulum hub.

- `ReTiCAPushCore`: payload decoding, shared inbox, proof builder, signed registration, HTTP client.
- `ReTiCAPush`: the TCA `PushFeature` a host app scopes in.
- `ReTiCAPushExtension`: `PushServiceHandler` for a Notification Service Extension.
- `docs/server-contract.md`: what a hub must do.

Design: the host app repo's `docs/superpowers/specs/2026-10-01-push-relay-design.md`.

Tests: `swift test --package-path .`
```

- [ ] **Step 3: Commit**

Write `/tmp/ReTiCAPush/msg-task-2.txt`:
```
docs: server contract v1 and README

Registration API with the signed binary layout, transport behaviour for a
push-aware hub (binding, dormancy, what gets pushed), the push shape, and a
reference-implementation note.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add docs/server-contract.md README.md
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-2.txt
```

---

### Task 3: `PushPayload`

**Files:**
- Create: `Sources/ReTiCAPushCore/PushPayload.swift`
- Create: `Tests/ReTiCAPushCoreTests/PushPayloadTests.swift`

**Interfaces:**
- Consumes: `ReTiCA.Packet.mtu`.
- Produces: `PushPayload.decode(_ userInfo: [AnyHashable: Any]) throws -> [Data]`, `PushPayload.DecodeError`, `PushPayload.version`, `PushPayload.maxPackets`. Tasks 12 and the app's tap handler call `decode`.

- [ ] **Step 1: Write the failing tests**

`Tests/ReTiCAPushCoreTests/PushPayloadTests.swift`:
```swift
import Testing
import Foundation
import ReTiCA
@testable import ReTiCAPushCore

private func userInfo(_ packets: [Any], version: Int = 1) -> [AnyHashable: Any] {
    ["aps": ["alert": ["title": "New message"]], "rns": ["v": version, "packets": packets]]
}

private let a = Data([0x00, 0x00, 0x01, 0x02, 0x03])
private let b = Data([0x00, 0x01, 0x09, 0x08])

@Test func pushPayloadDecodesOnePacket() throws {
    #expect(try PushPayload.decode(userInfo([a.base64EncodedString()])) == [a])
}

@Test func pushPayloadDecodesManyPacketsInOrder() throws {
    #expect(try PushPayload.decode(userInfo([b.base64EncodedString(), a.base64EncodedString()])) == [b, a])
}

@Test func pushPayloadRejectsMissingBlock() {
    #expect(throws: PushPayload.DecodeError.missingBlock) {
        try PushPayload.decode(["aps": ["alert": ["title": "New message"]]])
    }
}

@Test func pushPayloadRejectsUnsupportedVersion() {
    #expect(throws: PushPayload.DecodeError.unsupportedVersion) {
        try PushPayload.decode(userInfo([a.base64EncodedString()], version: 2))
    }
}

@Test func pushPayloadRejectsNonArray() {
    #expect(throws: PushPayload.DecodeError.notAnArray) {
        try PushPayload.decode(["rns": ["v": 1, "packets": a.base64EncodedString()]])
    }
}

@Test func pushPayloadRejectsNonBase64Entry() {
    // A good first entry, then a bad one, so the reported index is 1, not 0.
    #expect(throws: PushPayload.DecodeError.invalidEntry(1)) {
        try PushPayload.decode(userInfo([a.base64EncodedString(), "not base64!"]))
    }
}

@Test func pushPayloadRejectsAnEmptyEntry() {
    #expect(throws: PushPayload.DecodeError.invalidEntry(0)) {
        try PushPayload.decode(userInfo([Data().base64EncodedString()]))
    }
}

@Test func pushPayloadRejectsOversizeEntry() {
    let big = Data(repeating: 0x00, count: Packet.mtu + 1)
    #expect(throws: PushPayload.DecodeError.oversizeEntry(0)) {
        try PushPayload.decode(userInfo([big.base64EncodedString()]))
    }
}

@Test func pushPayloadRejectsTooManyPackets() {
    let nine = Array(repeating: a.base64EncodedString(), count: 9)
    #expect(throws: PushPayload.DecodeError.tooManyPackets) {
        try PushPayload.decode(userInfo(nine))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushPayload`
Expected: compile error, `PushPayload` not found.

- [ ] **Step 3: Write `Sources/ReTiCAPushCore/PushPayload.swift`**

```swift
import Foundation
import ReTiCA

/// The `rns` block of a push from a ReTiCA push hub (docs/server-contract.md §3): a version and a
/// list of base64 raw Reticulum packets. Pure and synchronous, so the service extension can call
/// it before anything crosses an actor boundary (`[AnyHashable: Any]` is not Sendable).
public enum PushPayload {
    public static let version = 1
    public static let maxPackets = 8

    public enum DecodeError: Error, Equatable {
        case missingBlock
        case unsupportedVersion
        case notAnArray
        case tooManyPackets
        /// The entry at this index is not a string, not base64, or decodes to zero bytes.
        case invalidEntry(Int)
        /// The entry at this index decodes to more than `Packet.mtu` bytes.
        case oversizeEntry(Int)
    }

    public static func decode(_ userInfo: [AnyHashable: Any]) throws -> [Data] {
        guard let block = userInfo["rns"] as? [String: Any] else { throw DecodeError.missingBlock }
        guard let v = block["v"] as? Int, v == version else { throw DecodeError.unsupportedVersion }
        guard let entries = block["packets"] as? [Any] else { throw DecodeError.notAnArray }
        guard entries.count <= maxPackets else { throw DecodeError.tooManyPackets }
        return try entries.enumerated().map { index, entry in
            guard let string = entry as? String,
                  let raw = Data(base64Encoded: string),
                  !raw.isEmpty
            else { throw DecodeError.invalidEntry(index) }
            guard raw.count <= Packet.mtu else { throw DecodeError.oversizeEntry(index) }
            return raw
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushPayload`
Expected: 9 pass.

- [ ] **Step 5: Mutation check**

| Test | Mutation (in `PushPayload.swift`) |
|---|---|
| `pushPayloadDecodesOnePacket` | `return raw` → `return raw + Data([0])` |
| `pushPayloadDecodesManyPacketsInOrder` | `entries.enumerated()` → `entries.reversed().enumerated()` |
| `pushPayloadRejectsMissingBlock` | `throw DecodeError.missingBlock` → `return []` |
| `pushPayloadRejectsUnsupportedVersion` | `v == version` → `v >= version` |
| `pushPayloadRejectsNonArray` | `throw DecodeError.notAnArray` → `return []` |
| `pushPayloadRejectsNonBase64Entry` | the three-clause `guard … else { throw DecodeError.invalidEntry(index) }` → `else { return Data([0]) }` |
| `pushPayloadRejectsAnEmptyEntry` | delete the `!raw.isEmpty` clause |
| `pushPayloadRejectsOversizeEntry` | `raw.count <= Packet.mtu` → `raw.count <= Packet.mtu + 1` |
| `pushPayloadRejectsTooManyPackets` | `entries.count <= maxPackets` → `entries.count <= maxPackets + 1` |

Note the sixth and seventh rows touch the same guard: apply the sixth (whole `else` replaced) and the seventh (clause deleted) together as one edit that reads `guard let string = entry as? String, let raw = Data(base64Encoded: string) else { return Data([0]) }`. The empty-entry test then gets `[Data()]` instead of a throw, the non-base64 test gets `[a, Data([0])]`, both red. Apply all, run the filter, all 9 red. Revert by hand, all 9 green.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCAPush/msg-task-3.txt`:
```
feat: decode the rns block of a push payload

Version, array and per-entry checks with indexed errors, capped at 8 packets
of at most Packet.mtu bytes each.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add Sources/ReTiCAPushCore/PushPayload.swift Tests/ReTiCAPushCoreTests/PushPayloadTests.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-3.txt
```

---

### Task 4: `PushInbox`

**Files:**
- Create: `Sources/ReTiCAPushCore/PushInbox.swift`
- Create: `Tests/ReTiCAPushCoreTests/PushInboxTests.swift`

**Interfaces:**
- Consumes: `ReTiCA.Crypto.fullHash`, `Data.hexString` (Task 1).
- Produces: `PushInbox(directory: URL, capacity: Int = 256)`, `@discardableResult func append(_ raw: Data) throws -> Bool`, `func drain() throws -> [Data]`, `func count() throws -> Int`. Tasks 11, 12 and the app use it.

- [ ] **Step 1: Write the failing tests**

`Tests/ReTiCAPushCoreTests/PushInboxTests.swift`:
```swift
import Testing
import Foundation
@testable import ReTiCAPushCore

private func freshDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ReTiCAPushTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func packet(_ n: UInt8) -> Data { Data([0x00, 0x00, n, n &+ 1, n &+ 2]) }

@Test func pushInboxAppendThenDrainReturnsInOrderAndEmpties() throws {
    let inbox = PushInbox(directory: freshDirectory())
    try inbox.append(packet(1))
    try inbox.append(packet(2))
    try inbox.append(packet(3))
    #expect(try inbox.drain() == [packet(1), packet(2), packet(3)])
    #expect(try inbox.drain() == [])
}

@Test func pushInboxReappendOfSameBytesIsANoOp() throws {
    let inbox = PushInbox(directory: freshDirectory())
    #expect(try inbox.append(packet(7)) == true)
    #expect(try inbox.append(packet(7)) == false)
    #expect(try inbox.count() == 1)
}

@Test func pushInboxEvictsOldestBeyondCapacity() throws {
    let inbox = PushInbox(directory: freshDirectory(), capacity: 3)
    for n: UInt8 in 1...4 { try inbox.append(packet(n)) }
    #expect(try inbox.drain() == [packet(2), packet(3), packet(4)])
}

@Test func pushInboxDrainOnMissingDirectoryReturnsEmpty() throws {
    let inbox = PushInbox(directory: freshDirectory())
    #expect(try inbox.drain() == [])
    #expect(try inbox.count() == 0)
}

@Test func pushInboxOrdersByInsertionNotByHash() throws {
    // Eight packets: the chance their hashes happen to sort in insertion order is 1 in 40320.
    let inbox = PushInbox(directory: freshDirectory())
    let packets = (10...17).map { packet(UInt8($0)) }
    for p in packets { try inbox.append(p) }
    #expect(try inbox.drain() == packets)
}

@Test func pushInboxDrainSkipsAnUnreadableEntry() throws {
    let directory = freshDirectory()
    let inbox = PushInbox(directory: directory)
    try inbox.append(packet(1))
    // A stray empty file in the inbox directory, as a killed extension could leave behind.
    try Data().write(to: directory.appending(path: "0000000000000000-deadbeef"))
    try inbox.append(packet(2))
    #expect(try inbox.drain() == [packet(1), packet(2)])
    #expect(try inbox.count() == 0)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushInbox`
Expected: compile error, `PushInbox` not found.

- [ ] **Step 3: Write `Sources/ReTiCAPushCore/PushInbox.swift`**

```swift
import Foundation
import ReTiCA

/// A directory of raw packets handed over from the service extension to the app (spec §1).
///
/// One file per packet, named `<sequence>-<sha256 hex>`. The sequence is microseconds since the
/// epoch, bumped past any existing entry so two appends in the same microsecond still order by
/// insertion. The hash suffix makes re-appending the same bytes a no-op, so a push whose
/// extension ran and whose tap handler then also stashes it costs nothing.
///
/// Files are written with no file protection on iOS: the extension may run before first unlock,
/// and the bytes are already encrypted to our identity.
public struct PushInbox: Sendable {
    public static let defaultCapacity = 256

    public let directory: URL
    public let capacity: Int

    public init(directory: URL, capacity: Int = PushInbox.defaultCapacity) {
        self.directory = directory
        self.capacity = capacity
    }

    /// Writes `raw` unless an entry with the same bytes exists. Returns whether a file was written.
    /// Evicts the oldest entries so at most `capacity` remain.
    @discardableResult
    public func append(_ raw: Data) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = Crypto.fullHash(raw).hexString
        let existing = try entryNames()
        guard !existing.contains(where: { $0.hasSuffix("-" + hash) }) else { return false }
        let micros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let maxExisting = existing.compactMap(Self.sequence(of:)).max() ?? 0
        let sequence = max(micros, maxExisting + 1)
        let name = String(format: "%020llu-%@", sequence, hash)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.noFileProtection)
        #endif
        try raw.write(to: directory.appending(path: name), options: options)
        let names = try entryNames()
        if names.count > capacity {
            for stale in names.prefix(names.count - capacity) {
                try? FileManager.default.removeItem(at: directory.appending(path: stale))
            }
        }
        return true
    }

    /// Every entry in insertion order, then deletes them all. Empty or unreadable files are
    /// deleted and skipped. A missing directory is an empty inbox.
    public func drain() throws -> [Data] {
        var packets: [Data] = []
        for name in try entryNames() {
            let url = directory.appending(path: name)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                packets.append(data)
            }
            try? FileManager.default.removeItem(at: url)
        }
        return packets
    }

    public func count() throws -> Int { try entryNames().count }

    /// Entry file names sorted by sequence (the zero-padded prefix sorts lexically).
    private func entryNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path()) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path())
            .filter { $0.contains("-") }
            .sorted()
    }

    private static func sequence(of name: String) -> UInt64? {
        guard let dash = name.firstIndex(of: "-") else { return nil }
        return UInt64(name[name.startIndex..<dash])
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushInbox`
Expected: 6 pass.

- [ ] **Step 5: Mutation check**

| Test | Mutation (in `PushInbox.swift`) |
|---|---|
| `pushInboxAppendThenDrainReturnsInOrderAndEmpties` | in `drain`, delete the line `try? FileManager.default.removeItem(at: url)` |
| `pushInboxReappendOfSameBytesIsANoOp` | delete the `guard !existing.contains(…) else { return false }` line |
| `pushInboxEvictsOldestBeyondCapacity` | `names.count > capacity` → `names.count > capacity + 1` |
| `pushInboxDrainOnMissingDirectoryReturnsEmpty` | in `entryNames`, `guard … else { return [] }` → `else { return ["0-x"] }` (then `drain` skips the unreadable name but `count()` reports 1) |
| `pushInboxOrdersByInsertionNotByHash` | `.sorted()` → `.sorted(by: >)` |
| `pushInboxDrainSkipsAnUnreadableEntry` | in `drain`, `if let data = try? Data(contentsOf: url), !data.isEmpty` → `if let data = try? Data(contentsOf: url)` |

The first and the fifth both affect the first test; that is fine, each test has its own row. Apply all, run the filter, all 6 red. Revert by hand, all 6 green.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCAPush/msg-task-4.txt`:
```
feat: shared inbox of pushed packets

Sequence-named files with a hash suffix so re-appends are no-ops, oldest-first
eviction at 256, drain in insertion order, no file protection on iOS.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add Sources/ReTiCAPushCore/PushInbox.swift Tests/ReTiCAPushCoreTests/PushInboxTests.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-4.txt
```

---

### Task 5: `ProofBuilder` and the delivery hash

**Files:**
- Create: `Sources/ReTiCAPushCore/ProofBuilder.swift`
- Create: `Sources/ReTiCAPushCore/Identity+Delivery.swift`
- Create: `Tests/ReTiCAPushCoreTests/ProofBuilderTests.swift`

**Interfaces:**
- Consumes: `ReTiCA.Packet`, `Identity`, `HDLC`, `LXMessage.deliveryHash(identityHash:)`.
- Produces: `ProofBuilder.proof(for raw: Data, identity: Identity, deliveryHash: Data) -> Data?` (HDLC-framed proof, or nil), `extension Identity { var lxmfDeliveryHash: Data }`. Task 12 uses both.

- [ ] **Step 1: Write the failing tests**

`Tests/ReTiCAPushCoreTests/ProofBuilderTests.swift`:
```swift
import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport
import ReTiCANode
@testable import ReTiCAPushCore

private let ifID = InterfaceID("tcp-hub")

/// A HEADER_1 DATA packet encrypted to `me`'s lxmf.delivery destination.
private func dataPacket(to me: Identity, plaintext: String = "hello") -> (raw: Data, hash: Data) {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    let packet = Packet.data(to: dest, plaintext: Data(plaintext.utf8))
    return (try! packet.packed(), packet.packetHash)
}

private func deframe(_ framed: Data) -> Data? {
    var deframer = HDLCDeframer()
    return deframer.ingest(framed).first
}

@Test func proofBuilderProvesADataPacketToOurDeliveryHash() throws {
    let me = Identity()
    let (raw, hash) = dataPacket(to: me)
    let framed = try #require(ProofBuilder.proof(for: raw, identity: me, deliveryHash: me.lxmfDeliveryHash))
    let proof = try #require(Packet(raw: try #require(deframe(framed))))
    #expect(proof.packetType == .proof)
    #expect(proof.destinationType == .single)
    #expect(proof.destinationHash == hash.prefix(16))
    #expect(proof.payload.count == 64)
    #expect(me.validate(signature: proof.payload, message: hash))
}

@Test @MainActor func proofBuilderProofConfirmsASenderReceiptInTransport() async throws {
    // Pins the builder to ReTiCA's real validator: a sender holding a receipt for this packet
    // must see `singlePacketDelivered` when our proof arrives.
    let me = Identity()
    let (raw, hash) = dataPacket(to: me)
    let token = Data("message-hash".utf8)
    var initial = Transport.State()
    initial.interfaces[ifID] = .default
    initial.pendingReceipts[Data(hash.prefix(16))] = Transport.State.PendingReceipt(
        packetHash: hash, token: token, identity: Identity(publicKey: me.publicKey)!,
        expiresAt: .distantFuture)
    let store = TestStore(initialState: initial) { Transport() }
    let framed = try #require(ProofBuilder.proof(for: raw, identity: me, deliveryHash: me.lxmfDeliveryHash))
    let frame = try #require(deframe(framed))
    await store.send(.received(ifID, frame)) { $0.pendingReceipts = [:] }
    await store.receive(.delegate(.singlePacketDelivered(token: token)))
}

@Test func proofBuilderIgnoresAPacketForAnotherDestination() {
    let me = Identity()
    let (raw, _) = dataPacket(to: Identity())
    #expect(ProofBuilder.proof(for: raw, identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func proofBuilderIgnoresANonDataPacket() throws {
    let me = Identity()
    let announce = Packet(packetType: .announce, destinationType: .single,
                          destinationHash: me.lxmfDeliveryHash, payload: Data(repeating: 1, count: 40))
    #expect(ProofBuilder.proof(for: try announce.packed(), identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func proofBuilderIgnoresAnIFACFlaggedPacket() {
    let me = Identity()
    var (raw, _) = dataPacket(to: me)
    raw[0] |= 0x80
    #expect(ProofBuilder.proof(for: raw, identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func proofBuilderIgnoresGarbage() {
    let me = Identity()
    #expect(ProofBuilder.proof(for: Data([0x00]), identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func proofBuilderNeedsAPrivateKey() {
    let me = Identity()
    let (raw, _) = dataPacket(to: me)
    let publicOnly = Identity(publicKey: me.publicKey)!
    #expect(ProofBuilder.proof(for: raw, identity: publicOnly, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test @MainActor func deliveryHashMatchesWhatReTiCARegisters() async throws {
    let me = Identity()
    let store = TestStore(
        initialState: LXMFNode.State(identity: me, endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)
    #expect(try #require(store.state.deliveryDestinationHash) == me.lxmfDeliveryHash)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter "proofBuilder|deliveryHash"`
Expected: compile error, `ProofBuilder` and `lxmfDeliveryHash` not found.

- [ ] **Step 3: Write `Sources/ReTiCAPushCore/Identity+Delivery.swift`**

```swift
import Foundation
import ReTiCA

public extension Identity {
    /// Our `lxmf.delivery` destination hash: what a push hub registers and what pushed DATA
    /// packets are addressed to. Same derivation as `LXMFNode.registerDelivery`.
    var lxmfDeliveryHash: Data { LXMessage.deliveryHash(identityHash: hash) }
}
```

- [ ] **Step 4: Write `Sources/ReTiCAPushCore/ProofBuilder.swift`**

```swift
import Foundation
import ReTiCA

/// Builds the proof the service extension sends for a pushed packet, exactly as
/// `Transport.proveSingle` would (Transport.swift:1083-1090): an unencrypted HEADER_1 PROOF to
/// the packet's proof destination (`packetHash[:16]`), carrying the 64-byte implicit proof
/// `identity.sign(packetHash)`, HDLC-framed for the hub's TCP interface.
public enum ProofBuilder {
    /// nil unless `raw` is an unflagged, parseable, single-destination DATA packet addressed to
    /// `deliveryHash` and `identity` can sign. Nothing is decrypted.
    public static func proof(for raw: Data, identity: Identity, deliveryHash: Data) -> Data? {
        guard identity.privateKey != nil else { return nil }
        // An IFAC-flagged packet needs the interface key to unmask. We have none, so the app
        // proves it on drain instead (spec §1).
        guard let first = raw.first, first & 0x80 == 0 else { return nil }
        guard let packet = Packet(raw: raw) else { return nil }
        guard packet.packetType == .data,
              packet.destinationType == .single,
              packet.destinationHash == deliveryHash
        else { return nil }
        let packetHash = packet.packetHash
        let proof = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                           destinationType: .single, context: .none, contextFlag: false, hops: 0,
                           destinationHash: Data(packetHash.prefix(Packet.addressLength)),
                           transportId: nil, payload: identity.sign(packetHash))
        guard let packed = try? proof.packed() else { return nil }
        return HDLC.frame(packed)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter "proofBuilder|deliveryHash"`
Expected: 8 pass.

- [ ] **Step 6: Mutation check**

| Test | Mutation |
|---|---|
| `proofBuilderProvesADataPacketToOurDeliveryHash` | `payload: identity.sign(packetHash)` → `payload: identity.sign(Data(packetHash.prefix(16)))` |
| `proofBuilderProofConfirmsASenderReceiptInTransport` | `destinationHash: Data(packetHash.prefix(Packet.addressLength))` → `Data(packetHash.suffix(Packet.addressLength))` |
| `proofBuilderIgnoresAPacketForAnotherDestination` | delete the clause `packet.destinationHash == deliveryHash` |
| `proofBuilderIgnoresANonDataPacket` | `packet.packetType == .data` → `packet.packetType != .proof` |
| `proofBuilderIgnoresAnIFACFlaggedPacket` | delete the `guard let first = raw.first, first & 0x80 == 0 else { return nil }` line (`Packet(raw:)` ignores bit 7, so the packet then proves) |
| `proofBuilderIgnoresGarbage` | `guard let packet = Packet(raw: raw) else { return nil }` → `guard let packet = Packet(raw: raw) ?? Packet(raw: Data([0, 0]) + deliveryHash + Data([0]) + raw) else { return nil }` |
| `proofBuilderNeedsAPrivateKey` | `guard identity.privateKey != nil else { return nil }` → `else { return Data() }` (never remove this guard: `sign` traps without a key) |
| `deliveryHashMatchesWhatReTiCARegisters` | in `Identity+Delivery.swift`, `LXMessage.deliveryHash(identityHash: hash)` → `Destination.hash(identityHash: hash, appName: "lxmf", aspects: ["delivery", "push"])` |

Apply all, run the filter, all 8 red. Revert by hand, all 8 green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCAPush/msg-task-5.txt`:
```
feat: build a framed implicit proof for a pushed data packet

Mirrors Transport.proveSingle. Nil for flagged, foreign, non-data or
unparseable packets and for an identity without a private key. Pinned to
ReTiCA's validator by a Transport TestStore round trip.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add Sources/ReTiCAPushCore/ProofBuilder.swift Sources/ReTiCAPushCore/Identity+Delivery.swift Tests/ReTiCAPushCoreTests/ProofBuilderTests.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-5.txt
```

---

### Task 6: `PushRegistration` and `SignedRegistration`

**Files:**
- Create: `Sources/ReTiCAPushCore/PushRegistration.swift`
- Create: `Tests/ReTiCAPushCoreTests/PushRegistrationTests.swift`

**Interfaces:**
- Consumes: `Identity.sign`, `Identity.validate`, `Identity(publicKey:)`, `Data.hexString`, `Data(hexString:)`.
- Produces:
  ```swift
  public struct PushRegistration: Equatable, Sendable {
      public enum Domain: String, Sendable { case register, unregister }
      public enum Environment: String, Sendable, Codable { case production, sandbox }
      public var publicKey: Data; public var pushToken: Data; public var platform: String
      public var environment: Environment; public var bundleID: String; public var issuedAt: UInt64
      public init(publicKey:pushToken:platform:environment:bundleID:issuedAt:)
      public func signingBytes(domain: Domain) -> Data?
      public func signed(with identity: Identity, domain: Domain) -> SignedRegistration?
  }
  public struct SignedRegistration: Equatable, Sendable {
      public var registration: PushRegistration; public var domain: PushRegistration.Domain; public var signature: Data
      public func verify() -> Bool
      public func jsonData() throws -> Data
      public static func fromJSON(_ data: Data, domain: PushRegistration.Domain) throws -> SignedRegistration
  }
  ```
  Tasks 7 and 10 use these.

- [ ] **Step 1: Write the failing tests**

`Tests/ReTiCAPushCoreTests/PushRegistrationTests.swift`:
```swift
import Testing
import Foundation
import ReTiCA
@testable import ReTiCAPushCore

private let fixedKey = Data(repeating: 0x11, count: 64)
private let token = Data([0xAA, 0xBB, 0xCC])

private func registration(publicKey: Data = fixedKey, bundleID: String = "co.example.app") -> PushRegistration {
    PushRegistration(publicKey: publicKey, pushToken: token, platform: "ios", environment: .sandbox,
                     bundleID: bundleID, issuedAt: 1_700_000_000)
}

@Test func pushRegistrationSigningBytesMatchTheDocumentedLayout() throws {
    var expected = Data("retica-push-register-v1".utf8)
    expected.append(fixedKey)
    expected.append(contentsOf: [0x00, 0x03])
    expected.append(token)
    expected.append(0x03)
    expected.append(Data("ios".utf8))
    expected.append(0x07)
    expected.append(Data("sandbox".utf8))
    expected.append(0x0E)
    expected.append(Data("co.example.app".utf8))
    expected.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x65, 0x53, 0xF1, 0x00])
    #expect(try #require(registration().signingBytes(domain: .register)) == expected)
}

@Test func pushRegistrationSignatureVerifies() throws {
    let me = Identity()
    let signed = try #require(registration(publicKey: me.publicKey).signed(with: me, domain: .register))
    #expect(signed.verify())
}

@Test func pushRegistrationTamperedTokenFailsVerification() throws {
    let me = Identity()
    var signed = try #require(registration(publicKey: me.publicKey).signed(with: me, domain: .register))
    signed.registration.pushToken = Data([0xAA, 0xBB, 0xCD])
    #expect(!signed.verify())
}

@Test func pushRegistrationUnregisterDomainDoesNotVerifyAsRegister() throws {
    let me = Identity()
    var signed = try #require(registration(publicKey: me.publicKey).signed(with: me, domain: .unregister))
    signed.domain = .register
    #expect(!signed.verify())
}

@Test func pushRegistrationJSONUsesTheContractKeys() throws {
    let me = Identity()
    let signed = try #require(registration(publicKey: me.publicKey).signed(with: me, domain: .register))
    let object = try #require(try JSONSerialization.jsonObject(with: signed.jsonData()) as? [String: Any])
    #expect(Set(object.keys) == ["v", "identity_public_key", "push_token", "platform", "environment",
                                 "bundle_id", "issued_at", "signature"])
    #expect(object["v"] as? Int == 1)
    #expect(object["push_token"] as? String == "aabbcc")
    #expect(object["platform"] as? String == "ios")
    #expect(object["environment"] as? String == "sandbox")
    #expect(object["bundle_id"] as? String == "co.example.app")
    #expect(object["issued_at"] as? Int == 1_700_000_000)
    #expect(Data(base64Encoded: try #require(object["identity_public_key"] as? String)) == me.publicKey)
    #expect(Data(base64Encoded: try #require(object["signature"] as? String)) == signed.signature)
}

@Test func pushRegistrationJSONRoundTrips() throws {
    let me = Identity()
    let signed = try #require(registration(publicKey: me.publicKey).signed(with: me, domain: .unregister))
    let back = try SignedRegistration.fromJSON(try signed.jsonData(), domain: .unregister)
    #expect(back == signed)
    #expect(back.verify())
}

@Test func pushRegistrationRejectsAnOversizeBundleID() {
    let me = Identity()
    let long = String(repeating: "a", count: 256)
    #expect(registration(publicKey: me.publicKey, bundleID: long).signed(with: me, domain: .register) == nil)
}

@Test func pushRegistrationRejectsAnOversizeToken() {
    let me = Identity()
    var r = registration(publicKey: me.publicKey)
    r.pushToken = Data(repeating: 0, count: 65_536)
    #expect(r.signed(with: me, domain: .register) == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushRegistration`
Expected: compile error, `PushRegistration` not found.

- [ ] **Step 3: Write `Sources/ReTiCAPushCore/PushRegistration.swift`**

```swift
import Foundation
import ReTiCA

/// The registration request of docs/server-contract.md §1, before signing.
public struct PushRegistration: Equatable, Sendable {
    public enum Domain: String, Sendable {
        case register = "retica-push-register-v1"
        case unregister = "retica-push-unregister-v1"
    }

    public enum Environment: String, Sendable, Codable {
        case production
        case sandbox
    }

    public static let version = 1

    public var publicKey: Data
    public var pushToken: Data
    public var platform: String
    public var environment: Environment
    public var bundleID: String
    public var issuedAt: UInt64

    public init(publicKey: Data, pushToken: Data, platform: String = "ios",
                environment: Environment, bundleID: String, issuedAt: UInt64) {
        self.publicKey = publicKey
        self.pushToken = pushToken
        self.platform = platform
        self.environment = environment
        self.bundleID = bundleID
        self.issuedAt = issuedAt
    }

    /// Contract §1.2. nil when a field cannot be length-prefixed (token > 65535 bytes, or a
    /// string field > 255 UTF-8 bytes) or the key is not 64 bytes.
    public func signingBytes(domain: Domain) -> Data? {
        guard publicKey.count == Identity.keySize, pushToken.count <= Int(UInt16.max) else { return nil }
        let platformBytes = Data(platform.utf8)
        let environmentBytes = Data(environment.rawValue.utf8)
        let bundleBytes = Data(bundleID.utf8)
        for field in [platformBytes, environmentBytes, bundleBytes] where field.count > Int(UInt8.max) {
            return nil
        }
        var out = Data(domain.rawValue.utf8)
        out.append(publicKey)
        out.append(UInt8(pushToken.count >> 8))
        out.append(UInt8(pushToken.count & 0xFF))
        out.append(pushToken)
        out.append(UInt8(platformBytes.count))
        out.append(platformBytes)
        out.append(UInt8(environmentBytes.count))
        out.append(environmentBytes)
        out.append(UInt8(bundleBytes.count))
        out.append(bundleBytes)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((issuedAt >> UInt64(shift)) & 0xFF))
        }
        return out
    }

    /// nil when the layout is invalid (see `signingBytes`) or `identity` has no private key.
    public func signed(with identity: Identity, domain: Domain) -> SignedRegistration? {
        guard identity.privateKey != nil, let bytes = signingBytes(domain: domain) else { return nil }
        return SignedRegistration(registration: self, domain: domain, signature: identity.sign(bytes))
    }
}

/// A registration plus the Ed25519 signature over its signing bytes. `domain` is remembered so
/// `verify()` can rebuild the bytes; it is not part of the JSON (the HTTP method carries it).
public struct SignedRegistration: Equatable, Sendable {
    public var registration: PushRegistration
    public var domain: PushRegistration.Domain
    public var signature: Data

    public init(registration: PushRegistration, domain: PushRegistration.Domain, signature: Data) {
        self.registration = registration
        self.domain = domain
        self.signature = signature
    }

    /// Server-side check, reproduced here so tests and the host app can assert what they send.
    public func verify() -> Bool {
        guard let identity = Identity(publicKey: registration.publicKey),
              let bytes = registration.signingBytes(domain: domain)
        else { return false }
        return identity.validate(signature: signature, message: bytes)
    }

    public enum JSONError: Error, Equatable {
        case malformed
    }

    /// Contract §1.1. Keys in a stable order, bytes base64, the token hex.
    public func jsonData() throws -> Data {
        let object: [String: Any] = [
            "v": PushRegistration.version,
            "identity_public_key": registration.publicKey.base64EncodedString(),
            "push_token": registration.pushToken.hexString,
            "platform": registration.platform,
            "environment": registration.environment.rawValue,
            "bundle_id": registration.bundleID,
            "issued_at": registration.issuedAt,
            "signature": signature.base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func fromJSON(_ data: Data, domain: PushRegistration.Domain) throws -> SignedRegistration {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == PushRegistration.version,
              let keyString = object["identity_public_key"] as? String,
              let publicKey = Data(base64Encoded: keyString),
              let tokenHex = object["push_token"] as? String,
              let pushToken = Data(hexString: tokenHex),
              let platform = object["platform"] as? String,
              let environmentString = object["environment"] as? String,
              let environment = PushRegistration.Environment(rawValue: environmentString),
              let bundleID = object["bundle_id"] as? String,
              let issuedAt = object["issued_at"] as? UInt64,
              let signatureString = object["signature"] as? String,
              let signature = Data(base64Encoded: signatureString)
        else { throw JSONError.malformed }
        let registration = PushRegistration(publicKey: publicKey, pushToken: pushToken, platform: platform,
                                            environment: environment, bundleID: bundleID, issuedAt: issuedAt)
        return SignedRegistration(registration: registration, domain: domain, signature: signature)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushRegistration`
Expected: 8 pass. If `object["issued_at"] as? UInt64` fails on your Foundation (NSNumber bridging to UInt64 is sometimes refused), use `(object["issued_at"] as? NSNumber)?.uint64Value` there and nowhere else.

- [ ] **Step 5: Mutation check**

| Test | Mutation (in `PushRegistration.swift`) |
|---|---|
| `pushRegistrationSigningBytesMatchTheDocumentedLayout` | delete the line `out.append(UInt8(pushToken.count >> 8))` |
| `pushRegistrationSignatureVerifies` | in `signed`, `identity.sign(bytes)` → `identity.sign(bytes + Data([0]))` |
| `pushRegistrationTamperedTokenFailsVerification` | delete the line `out.append(pushToken)` (the length prefix stays, so the layout test also goes red, which is fine) |
| `pushRegistrationUnregisterDomainDoesNotVerifyAsRegister` | `case unregister = "retica-push-unregister-v1"` → `case unregister = "retica-push-register-v1"` |
| `pushRegistrationJSONUsesTheContractKeys` | `"bundle_id": registration.bundleID` → `"bundleId": registration.bundleID` (and the same key in `fromJSON`, so the round trip still passes) |
| `pushRegistrationJSONRoundTrips` | in `fromJSON`, `issuedAt: issuedAt` → `issuedAt: issuedAt &- 1` |
| `pushRegistrationRejectsAnOversizeBundleID` | `field.count > Int(UInt8.max)` → `field.count > 1024` |
| `pushRegistrationRejectsAnOversizeToken` | `pushToken.count <= Int(UInt16.max)` → `pushToken.count <= Int(UInt32.max)` |

Apply all, run the filter, all 8 red. Revert by hand, all 8 green.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCAPush/msg-task-6.txt`:
```
feat: signed push registration with the contract's byte layout and JSON

Fixed binary signing layout per domain, Ed25519 signature, verify, and the
contract's JSON keys both ways.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add Sources/ReTiCAPushCore/PushRegistration.swift Tests/ReTiCAPushCoreTests/PushRegistrationTests.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-6.txt
```

---

### Task 7: `RegistrationClient`

**Files:**
- Create: `Sources/ReTiCAPushCore/RegistrationClient.swift`
- Create: `Tests/ReTiCAPushCoreTests/RegistrationClientTests.swift`

**Interfaces:**
- Consumes: `SignedRegistration.jsonData()`.
- Produces:
  ```swift
  public struct RegistrationClient: Sendable {
      public enum Failure: Error, Equatable { case server(status: Int, body: String); case transport(String) }
      public var register: @Sendable (SignedRegistration, URL) async throws -> Void
      public var unregister: @Sendable (SignedRegistration, URL) async throws -> Void
      public init(register:unregister:)
      public static func live(session: URLSession = .shared) -> RegistrationClient
      public static let registrationsPath = "v1/registrations"
  }
  ```
  Task 9 wraps it as a TCA dependency; Task 10 calls it.

- [ ] **Step 1: Write the failing tests**

`Tests/ReTiCAPushCoreTests/RegistrationClientTests.swift`:
```swift
import Testing
import Foundation
import ReTiCA
@testable import ReTiCAPushCore

/// Intercepts every request of a session built with `stubbedSession()`. Serialized because the
/// handler is process-global.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func ok(_ status: Int, _ body: String = "") -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
    { request in
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }
}

private func signed(_ domain: PushRegistration.Domain) -> SignedRegistration {
    let me = Identity()
    return PushRegistration(publicKey: me.publicKey, pushToken: Data([1, 2, 3]), environment: .sandbox,
                            bundleID: "co.example.app", issuedAt: 1_700_000_000).signed(with: me, domain: domain)!
}

private let base = URL(string: "https://hub.example.net/push/")!

@Suite(.serialized) struct RegistrationClientTests {
    @Test func registrationClientPostsJSONToTheRegistrationsPath() async throws {
        StubURLProtocol.handler = ok(200, "{\"destination_hash\":\"00\"}")
        let client = RegistrationClient.live(session: stubbedSession())
        let request = signed(.register)
        try await client.register(request, base)
        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://hub.example.net/push/v1/registrations")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try SignedRegistration.fromJSON(try #require(StubURLProtocol.lastBody), domain: .register)
        #expect(body == request)
    }

    @Test func registrationClientUnregisterUsesDELETE() async throws {
        StubURLProtocol.handler = ok(204)
        let client = RegistrationClient.live(session: stubbedSession())
        try await client.unregister(signed(.unregister), base)
        #expect(StubURLProtocol.lastRequest?.httpMethod == "DELETE")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://hub.example.net/push/v1/registrations")
    }

    @Test func registrationClientThrowsOnNon2xx() async {
        StubURLProtocol.handler = ok(401, "nope")
        let client = RegistrationClient.live(session: stubbedSession())
        await #expect(throws: RegistrationClient.Failure.server(status: 401, body: "nope")) {
            try await client.register(signed(.register), base)
        }
    }

    @Test func registrationClientWrapsTransportErrors() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let client = RegistrationClient.live(session: stubbedSession())
        await #expect(throws: RegistrationClient.Failure.transport(URLError(.notConnectedToInternet).localizedDescription)) {
            try await client.register(signed(.register), base)
        }
    }

    @Test func registrationClientTreats204AsSuccess() async throws {
        StubURLProtocol.handler = ok(204, "unexpected body")
        let client = RegistrationClient.live(session: stubbedSession())
        try await client.register(signed(.register), base)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter registrationClient`
Expected: compile error, `RegistrationClient` not found.

- [ ] **Step 3: Write `Sources/ReTiCAPushCore/RegistrationClient.swift`**

```swift
import Foundation

/// HTTP client for docs/server-contract.md §1. A struct of closures, like ReTiCA's `TCPConnection`,
/// so tests and the TCA dependency can replace it. The TCA `DependencyKey` conformance lives in
/// the `ReTiCAPush` target; this target has no TCA.
public struct RegistrationClient: Sendable {
    public enum Failure: Error, Equatable {
        /// A non-2xx answer. `body` is the response body as UTF-8, truncated to 200 characters.
        case server(status: Int, body: String)
        /// No HTTP answer at all (offline, DNS, TLS).
        case transport(String)
    }

    public static let registrationsPath = "v1/registrations"
    public static let timeout: TimeInterval = 15

    public var register: @Sendable (SignedRegistration, URL) async throws -> Void
    public var unregister: @Sendable (SignedRegistration, URL) async throws -> Void

    public init(register: @escaping @Sendable (SignedRegistration, URL) async throws -> Void,
                unregister: @escaping @Sendable (SignedRegistration, URL) async throws -> Void) {
        self.register = register
        self.unregister = unregister
    }

    public static func live(session: URLSession = .shared) -> RegistrationClient {
        RegistrationClient(
            register: { signed, base in try await send(signed, to: base, method: "POST", session: session) },
            unregister: { signed, base in try await send(signed, to: base, method: "DELETE", session: session) }
        )
    }

    private static func send(_ signed: SignedRegistration, to base: URL, method: String,
                             session: URLSession) async throws {
        var request = URLRequest(url: base.appending(path: registrationsPath), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try signed.jsonData()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.server(status: status, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter registrationClient`
Expected: 5 pass. `URL.appending(path:)` on a base ending in `/` yields a single slash, which the first test checks.

- [ ] **Step 5: Mutation check**

| Test | Mutation (in `RegistrationClient.swift`) |
|---|---|
| `registrationClientPostsJSONToTheRegistrationsPath` | `registrationsPath = "v1/registrations"` → `"v1/registration"` |
| `registrationClientUnregisterUsesDELETE` | in `live`, the unregister closure's `method: "DELETE"` → `method: "POST"` |
| `registrationClientThrowsOnNon2xx` | `(200..<300).contains(status)` → `(200..<500).contains(status)` |
| `registrationClientWrapsTransportErrors` | in the `catch`, `throw Failure.transport(error.localizedDescription)` → `throw error` |
| `registrationClientTreats204AsSuccess` | `(200..<300).contains(status)` → `status == 200` (apply together with the third row as the single expression `status == 200 || (300..<500).contains(status)`: 401 passes and 204 fails, both red) |

Apply all, run the filter, all 5 red. Revert by hand, all 5 green.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCAPush/msg-task-7.txt`:
```
feat: URLSession client for the registration API

POST and DELETE v1/registrations with the signed JSON body, 2xx is success,
non-2xx and transport errors are typed failures.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add Sources/ReTiCAPushCore/RegistrationClient.swift Tests/ReTiCAPushCoreTests/RegistrationClientTests.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-7.txt
```

---

### Task 8: `SharedPushSettings` and `PushStorage`

**Files:**
- Create: `Sources/ReTiCAPushCore/SharedPushSettings.swift`
- Create: `Sources/ReTiCAPushCore/PushStorage.swift`
- Create: `Tests/ReTiCAPushCoreTests/SharedPushSettingsTests.swift`

**Interfaces:**
- Consumes: Foundation only.
- Produces:
  ```swift
  public struct RegistrationRecord: Equatable, Sendable, Codable { public var tokenHex: String; public var registeredAt: Date }
  public struct SharedPushSettings: Equatable, Sendable, Codable {
      public var hubHost: String; public var hubPort: Int
      public var keychainService: String; public var keychainAccessGroup: String?
      public var lastRegistration: RegistrationRecord?
      public init(hubHost:hubPort:keychainService:keychainAccessGroup:lastRegistration:)   // all defaulted
  }
  public struct SharedPushSettingsStore: Sendable {
      public static let key = "retica.push.settings"
      public init(suiteName: String?)
      public func load() -> SharedPushSettings
      public func save(_ settings: SharedPushSettings)
  }
  public struct PushStorage: Equatable, Sendable {
      public var inboxDirectory: URL; public var settingsSuiteName: String?
      public init(inboxDirectory:settingsSuiteName:)
      public init(containerURL: URL, appGroupID: String)
      public static func appGroup(_ id: String) -> PushStorage?
      public static func temporary() -> PushStorage
  }
  ```
  Tasks 9 to 12 use all of these.

- [ ] **Step 1: Write the failing tests**

`Tests/ReTiCAPushCoreTests/SharedPushSettingsTests.swift`:
```swift
import Testing
import Foundation
@testable import ReTiCAPushCore

private func freshSuite() -> String {
    let suite = "ReTiCAPushTests.\(UUID().uuidString)"
    UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    return suite
}

@Test func sharedPushSettingsRoundTripThroughDefaults() {
    let store = SharedPushSettingsStore(suiteName: freshSuite())
    let settings = SharedPushSettings(
        hubHost: "hub.example.net", hubPort: 4242,
        keychainService: "reticulum.identity", keychainAccessGroup: "TEAM.co.example.identity",
        lastRegistration: RegistrationRecord(tokenHex: "aabb", registeredAt: Date(timeIntervalSince1970: 1_700_000_000)))
    store.save(settings)
    #expect(store.load() == settings)
}

@Test func sharedPushSettingsLoadReturnsDefaultsWhenAbsent() {
    let store = SharedPushSettingsStore(suiteName: freshSuite())
    #expect(store.load() == SharedPushSettings())
}

@Test func sharedPushSettingsLoadReturnsDefaultsWhenCorrupt() {
    let suite = freshSuite()
    UserDefaults(suiteName: suite)!.set(Data("not json".utf8), forKey: SharedPushSettingsStore.key)
    #expect(SharedPushSettingsStore(suiteName: suite).load() == SharedPushSettings())
}

@Test func pushStorageAppGroupDerivesInboxAndSuite() {
    let storage = PushStorage(containerURL: URL(filePath: "/containers/group"), appGroupID: "group.co.example.app")
    #expect(storage.inboxDirectory.path() == "/containers/group/ReTiCAPush/inbox/")
    #expect(storage.settingsSuiteName == "group.co.example.app")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter "sharedPushSettings|pushStorage"`
Expected: compile error.

- [ ] **Step 3: Write `Sources/ReTiCAPushCore/SharedPushSettings.swift`**

```swift
import Foundation

/// The last successful registration, so a relaunch can skip an identical POST (spec §1).
public struct RegistrationRecord: Equatable, Sendable, Codable {
    public var tokenHex: String
    public var registeredAt: Date
    public init(tokenHex: String, registeredAt: Date) {
        self.tokenHex = tokenHex
        self.registeredAt = registeredAt
    }
}

/// What the app writes for the service extension to read: where the hub is (so a proof goes to
/// the right socket) and where the identity is (the Keychain location). Stored as one JSON blob
/// in the app-group defaults suite under `SharedPushSettingsStore.key`.
public struct SharedPushSettings: Equatable, Sendable, Codable {
    public var hubHost: String
    public var hubPort: Int
    public var keychainService: String
    public var keychainAccessGroup: String?
    public var lastRegistration: RegistrationRecord?

    public init(hubHost: String = "", hubPort: Int = 0, keychainService: String = "",
                keychainAccessGroup: String? = nil, lastRegistration: RegistrationRecord? = nil) {
        self.hubHost = hubHost
        self.hubPort = hubPort
        self.keychainService = keychainService
        self.keychainAccessGroup = keychainAccessGroup
        self.lastRegistration = lastRegistration
    }
}

public struct SharedPushSettingsStore: Sendable {
    public static let key = "retica.push.settings"

    /// The app-group suite. nil means `UserDefaults.standard` (never what the extension reads).
    public let suiteName: String?

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// Defaults when nothing is stored or the blob does not decode.
    public func load() -> SharedPushSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(SharedPushSettings.self, from: data)
        else { return SharedPushSettings() }
        return settings
    }

    public func save(_ settings: SharedPushSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
```

- [ ] **Step 4: Write `Sources/ReTiCAPushCore/PushStorage.swift`**

```swift
import Foundation

/// Where the inbox and the shared settings live. Both processes build it from the same app
/// group, so they cannot disagree (spec resolution in the plan).
public struct PushStorage: Equatable, Sendable {
    public var inboxDirectory: URL
    public var settingsSuiteName: String?

    public init(inboxDirectory: URL, settingsSuiteName: String?) {
        self.inboxDirectory = inboxDirectory
        self.settingsSuiteName = settingsSuiteName
    }

    /// `<container>/ReTiCAPush/inbox` and the app group id as the defaults suite.
    public init(containerURL: URL, appGroupID: String) {
        self.init(inboxDirectory: containerURL.appending(path: "ReTiCAPush/inbox", directoryHint: .isDirectory),
                  settingsSuiteName: appGroupID)
    }

    /// nil when the process has no container for `id` (missing entitlement).
    public static func appGroup(_ id: String) -> PushStorage? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
        else { return nil }
        return PushStorage(containerURL: container, appGroupID: id)
    }

    /// A throwaway location for tests and previews.
    public static func temporary() -> PushStorage {
        let suite = "ReTiCAPush.temporary.\(UUID().uuidString)"
        return PushStorage(
            inboxDirectory: FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory),
            settingsSuiteName: suite)
    }

    public var inbox: PushInbox { PushInbox(directory: inboxDirectory) }
    public var settings: SharedPushSettingsStore { SharedPushSettingsStore(suiteName: settingsSuiteName) }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter "sharedPushSettings|pushStorage"`
Expected: 4 pass.

- [ ] **Step 6: Mutation check**

| Test | Mutation |
|---|---|
| `sharedPushSettingsRoundTripThroughDefaults` | in `save`, `defaults.set(data, forKey: Self.key)` → `defaults.set(data, forKey: Self.key + ".v2")` |
| `sharedPushSettingsLoadReturnsDefaultsWhenAbsent` | in `load`, the `else { return SharedPushSettings() }` → `else { return SharedPushSettings(hubPort: 1) }` (also reddens the corrupt test, which has its own row) |
| `sharedPushSettingsLoadReturnsDefaultsWhenCorrupt` | `try? JSONDecoder().decode(…)` → `(try? JSONDecoder().decode(…)) ?? SharedPushSettings(hubHost: "corrupt")` |
| `pushStorageAppGroupDerivesInboxAndSuite` | `"ReTiCAPush/inbox"` → `"inbox"` |

Apply all, run the filter, all 4 red. Revert by hand, all 4 green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCAPush/msg-task-8.txt`:
```
feat: shared settings blob and storage locations for app and extension

One JSON blob in the app-group suite (hub host and port, Keychain location,
last registration) and PushStorage deriving the inbox and suite from the
app-group container.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add Sources/ReTiCAPushCore/SharedPushSettings.swift Sources/ReTiCAPushCore/PushStorage.swift Tests/ReTiCAPushCoreTests/SharedPushSettingsTests.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-8.txt
```

---

### Task 9: `PushFeature` — dependencies, state, enabling

**Files:**
- Modify: `Package.swift` (add the `ReTiCAPushTests` test target)
- Create: `Sources/ReTiCAPush/Dependencies.swift`
- Create: `Sources/ReTiCAPush/PushFeature.swift`
- Create: `Tests/ReTiCAPushTests/PushFeatureEnableTests.swift`
- Create: `Tests/ReTiCAPushTests/PushFeatureTestSupport.swift`

**Interfaces:**
- Consumes: `PushStorage`, `SharedPushSettingsStore`, `RegistrationClient`, `PushRegistration`, `Identity`.
- Produces:
  ```swift
  public struct PushPlatform: Sendable {
      public var requestAuthorization: @Sendable () async -> Bool
      public var registerForRemoteNotifications: @Sendable () async -> Void
      public var unregisterForRemoteNotifications: @Sendable () async -> Void
      public static let noop: PushPlatform
  }
  DependencyValues.pushPlatform, DependencyValues.registrationClient
  @Reducer public struct PushFeature {
      public struct State: Equatable {
          public enum Status: Equatable, Sendable { case idle, awaitingPermission, awaitingToken, registering, registered(Date), failed(String); public var displayText: String }
          public var identity: Identity; public var bundleID: String; public var environment: PushRegistration.Environment; public var storage: PushStorage
          @Shared(.appStorage("pushEnabled")) public var enabled: Bool
          @Shared(.appStorage("pushRegistrationURL")) public var registrationURL: String
          public var hubHost: String; public var hubPort: Int; public var deviceToken: Data?; public var status: Status; public var lastRegistration: RegistrationRecord?
          public init(identity:bundleID:environment:storage:keychainService:keychainAccessGroup:)
      }
      public enum Action: Equatable, BindableAction {
          case setEnabled(Bool), hubChanged(host: String, port: Int), appLaunched
          case permissionResolved(granted: Bool), deviceTokenReceived(Data), deviceTokenFailed(String)
          case registrationFinished(Result<Date, RegistrationFailure>), unregisterFinished
          case drainInbox, inboxDrained([Data]), delegate(Delegate), binding(BindingAction<State>)
          public enum Delegate: Equatable { case inject(packets: [Data]) }
      }
  }
  public struct RegistrationFailure: Error, Equatable, Sendable { public var message: String }
  ```
  Tasks 10 and 11 fill in the remaining cases. The app plan scopes `PushFeature` and supplies `pushPlatform`.

- [ ] **Step 1: Add the test target to `Package.swift`**

In the `targets:` array, after the `ReTiCAPushCoreTests` entry, add:
```swift
        .testTarget(
            name: "ReTiCAPushTests",
            dependencies: [
                "ReTiCAPush",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
```

- [ ] **Step 2: Write the test support file**

`Tests/ReTiCAPushTests/PushFeatureTestSupport.swift`:
```swift
import Foundation
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPush

let testNow = Date(timeIntervalSince1970: 1_700_000_000)

/// Counts calls to the three platform verbs and answers permission with `granted`.
final class PlatformSpy: Sendable {
    let authorizations = LockIsolated(0)
    let registers = LockIsolated(0)
    let unregisters = LockIsolated(0)
    let granted: Bool

    init(granted: Bool = true) { self.granted = granted }

    var platform: PushPlatform {
        PushPlatform(
            requestAuthorization: { self.authorizations.withValue { $0 += 1 }; return self.granted },
            registerForRemoteNotifications: { self.registers.withValue { $0 += 1 } },
            unregisterForRemoteNotifications: { self.unregisters.withValue { $0 += 1 } })
    }
}

/// Records every registration call and answers with `result` (nil = success).
final class RegistrationSpy: Sendable {
    let registered = LockIsolated<[(SignedRegistration, URL)]>([])
    let unregistered = LockIsolated<[(SignedRegistration, URL)]>([])
    let failure: RegistrationClient.Failure?

    init(failure: RegistrationClient.Failure? = nil) { self.failure = failure }

    var client: RegistrationClient {
        RegistrationClient(
            register: { signed, url in
                self.registered.withValue { $0.append((signed, url)) }
                if let failure = self.failure { throw failure }
            },
            unregister: { signed, url in
                self.unregistered.withValue { $0.append((signed, url)) }
            })
    }
}

@MainActor
func makePushStore(identity: Identity = Identity(),
                   platform: PlatformSpy = PlatformSpy(),
                   registration: RegistrationSpy = RegistrationSpy(),
                   storage: PushStorage = .temporary(),
                   configure: ((inout PushFeature.State) -> Void)? = nil) -> TestStoreOf<PushFeature> {
    var initial = PushFeature.State(identity: identity, bundleID: "co.example.app", environment: .sandbox,
                                    storage: storage, keychainService: "reticulum.identity",
                                    keychainAccessGroup: "TEAM.co.example.identity")
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        PushFeature()
    } withDependencies: {
        $0.pushPlatform = platform.platform
        $0.registrationClient = registration.client
        $0.date = .constant(testNow)
    }
    store.exhaustivity = .off
    return store
}
```

- [ ] **Step 3: Write the failing tests**

`Tests/ReTiCAPushTests/PushFeatureEnableTests.swift`:
```swift
import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPush

@Test @MainActor func pushFeatureEnableRequestsPermissionAndRegistersWhenGranted() async {
    let platform = PlatformSpy(granted: true)
    let store = makePushStore(platform: platform)
    await store.send(.setEnabled(true)) {
        $0.$enabled.withLock { $0 = true }
        $0.status = .awaitingPermission
    }
    await store.receive(.permissionResolved(granted: true)) { $0.status = .awaitingToken }
    await store.finish()
    #expect(platform.authorizations.value == 1)
    #expect(platform.registers.value == 1)
}

@Test @MainActor func pushFeatureEnableDeniedKeepsTheToggleOnWithAFailure() async {
    let platform = PlatformSpy(granted: false)
    let store = makePushStore(platform: platform)
    await store.send(.setEnabled(true)) {
        $0.$enabled.withLock { $0 = true }
        $0.status = .awaitingPermission
    }
    await store.receive(.permissionResolved(granted: false)) {
        $0.status = .failed("Notifications are off for ReTiCaMsgr in Settings")
    }
    await store.finish()
    #expect(store.state.enabled == true)
    #expect(platform.registers.value == 0)
}

@Test @MainActor func pushFeatureEnableWritesHubAndKeychainToSharedSettings() async {
    let storage = PushStorage.temporary()
    let store = makePushStore(storage: storage) { state in
        state.hubHost = "hub.example.net"
        state.hubPort = 4242
    }
    await store.send(.setEnabled(true))
    await store.skipReceivedActions(strict: false)
    let saved = storage.settings.load()
    #expect(saved.hubHost == "hub.example.net")
    #expect(saved.hubPort == 4242)
    #expect(saved.keychainService == "reticulum.identity")
    #expect(saved.keychainAccessGroup == "TEAM.co.example.identity")
}

@Test @MainActor func pushFeatureEnableIsIdempotent() async {
    let platform = PlatformSpy(granted: true)
    let store = makePushStore(platform: platform) { state in
        state.$enabled.withLock { $0 = true }
        state.status = .awaitingToken
    }
    await store.send(.setEnabled(true))
    await store.finish()
    #expect(platform.authorizations.value == 0)
    #expect(store.state.status == .awaitingToken)
}

@Test func pushFeatureEnableStatusTextDescribesEachCase() {
    typealias Status = PushFeature.State.Status
    #expect(Status.idle.displayText == "Off")
    #expect(Status.awaitingPermission.displayText == "Waiting for permission…")
    #expect(Status.awaitingToken.displayText == "Waiting for a device token…")
    #expect(Status.registering.displayText == "Registering…")
    #expect(Status.registered(testNow).displayText.hasPrefix("Registered "))
    #expect(Status.failed("boom").displayText == "boom")
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushFeatureEnable`
Expected: compile error, `PushFeature` not found.

- [ ] **Step 5: Write `Sources/ReTiCAPush/Dependencies.swift`**

```swift
import Foundation
import ComposableArchitecture
import ReTiCAPushCore

/// The three UIKit calls `PushFeature` needs. The host app supplies the real one through
/// `withDependencies` when it builds its store (`UNUserNotificationCenter.requestAuthorization`,
/// `UIApplication.registerForRemoteNotifications`, `unregisterForRemoteNotifications`). The
/// `liveValue` here is a no-op placeholder: without the app's override, enabling push silently
/// waits for a token that never comes.
public struct PushPlatform: Sendable {
    public var requestAuthorization: @Sendable () async -> Bool
    public var registerForRemoteNotifications: @Sendable () async -> Void
    public var unregisterForRemoteNotifications: @Sendable () async -> Void

    public init(requestAuthorization: @escaping @Sendable () async -> Bool,
                registerForRemoteNotifications: @escaping @Sendable () async -> Void,
                unregisterForRemoteNotifications: @escaping @Sendable () async -> Void) {
        self.requestAuthorization = requestAuthorization
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.unregisterForRemoteNotifications = unregisterForRemoteNotifications
    }

    public static let noop = PushPlatform(requestAuthorization: { false },
                                          registerForRemoteNotifications: {},
                                          unregisterForRemoteNotifications: {})
}

extension PushPlatform: DependencyKey {
    public static let liveValue = PushPlatform.noop
    public static let testValue = PushPlatform(
        requestAuthorization: unimplemented("PushPlatform.requestAuthorization", placeholder: false),
        registerForRemoteNotifications: unimplemented("PushPlatform.registerForRemoteNotifications"),
        unregisterForRemoteNotifications: unimplemented("PushPlatform.unregisterForRemoteNotifications"))
}

extension RegistrationClient: DependencyKey {
    public static var liveValue: RegistrationClient { .live() }
    public static let testValue = RegistrationClient(
        register: unimplemented("RegistrationClient.register"),
        unregister: unimplemented("RegistrationClient.unregister"))
}

public extension DependencyValues {
    var pushPlatform: PushPlatform {
        get { self[PushPlatform.self] }
        set { self[PushPlatform.self] = newValue }
    }

    var registrationClient: RegistrationClient {
        get { self[RegistrationClient.self] }
        set { self[RegistrationClient.self] = newValue }
    }
}
```

- [ ] **Step 6: Write `Sources/ReTiCAPush/PushFeature.swift`**

The reducer body handles only this task's actions; Tasks 10 and 11 add the rest. Cases not yet handled return `.none` under `default`, which Task 11 removes.

```swift
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAPushCore

/// Why a registration POST failed, as shown in Settings.
public struct RegistrationFailure: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Opt-in push wake-ups (spec §1). Owns the toggle, the APNs token and the registration
/// lifecycle, and drains the shared inbox into `delegate(.inject)` for the host app to feed its
/// transport. Never touches ReTiCA's node.
@Reducer
public struct PushFeature {
    public static let deniedText = "Notifications are off for ReTiCaMsgr in Settings"
    public static let invalidURLText = "Invalid registration URL"
    /// A POST is skipped when the same token was registered more recently than this.
    public static let reregistrationInterval: TimeInterval = 24 * 60 * 60

    @ObservableState
    public struct State: Equatable {
        public enum Status: Equatable, Sendable {
            case idle
            case awaitingPermission
            case awaitingToken
            case registering
            case registered(Date)
            case failed(String)

            public var displayText: String {
                switch self {
                case .idle: "Off"
                case .awaitingPermission: "Waiting for permission…"
                case .awaitingToken: "Waiting for a device token…"
                case .registering: "Registering…"
                case let .registered(date): "Registered " + date.formatted(.relative(presentation: .named))
                case let .failed(reason): reason
                }
            }
        }

        public var identity: Identity
        public var bundleID: String
        public var environment: PushRegistration.Environment
        public var storage: PushStorage
        public var keychainService: String
        public var keychainAccessGroup: String?

        @Shared(.appStorage("pushEnabled")) public var enabled: Bool = false
        @Shared(.appStorage("pushRegistrationURL")) public var registrationURL: String = ""

        /// Mirrored from the host app's hub settings by `hubChanged`.
        public var hubHost: String = ""
        public var hubPort: Int = 0
        public var deviceToken: Data? = nil
        public var status: Status = .idle
        public var lastRegistration: RegistrationRecord? = nil

        public init(identity: Identity, bundleID: String, environment: PushRegistration.Environment,
                    storage: PushStorage, keychainService: String, keychainAccessGroup: String?) {
            self.identity = identity
            self.bundleID = bundleID
            self.environment = environment
            self.storage = storage
            self.keychainService = keychainService
            self.keychainAccessGroup = keychainAccessGroup
            self.lastRegistration = storage.settings.load().lastRegistration
        }

        /// What the extension reads. Built from state so every writer agrees.
        var sharedSettings: SharedPushSettings {
            SharedPushSettings(hubHost: hubHost, hubPort: hubPort, keychainService: keychainService,
                               keychainAccessGroup: keychainAccessGroup, lastRegistration: lastRegistration)
        }
    }

    public enum Action: Equatable, BindableAction {
        case setEnabled(Bool)
        case hubChanged(host: String, port: Int)
        case appLaunched
        case permissionResolved(granted: Bool)
        case deviceTokenReceived(Data)
        case deviceTokenFailed(String)
        case registrationFinished(Result<Date, RegistrationFailure>)
        case unregisterFinished
        case drainInbox
        case inboxDrained([Data])
        case delegate(Delegate)
        case binding(BindingAction<State>)

        @CasePathable
        public enum Delegate: Equatable {
            case inject(packets: [Data])
        }
    }

    @Dependency(\.pushPlatform) var platform
    @Dependency(\.registrationClient) var registrationClient
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .setEnabled(true):
                // Idempotent: a second tap while already on must not re-prompt.
                guard !state.enabled else { return .none }
                state.$enabled.withLock { $0 = true }
                state.status = .awaitingPermission
                let settings = state.sharedSettings
                let store = state.storage.settings
                return .run { [platform] send in
                    store.save(settings)
                    let granted = await platform.requestAuthorization()
                    await send(.permissionResolved(granted: granted))
                }

            case .permissionResolved(granted: false):
                state.status = .failed(Self.deniedText)
                return .none

            case .permissionResolved(granted: true):
                state.status = .awaitingToken
                return .run { [platform] _ in await platform.registerForRemoteNotifications() }

            default:
                return .none
            }
        }
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushFeatureEnable`
Expected: 5 pass. If `date.formatted(.relative(presentation: .named))` is unavailable on the macOS test host, use `date.formatted(date: .abbreviated, time: .shortened)` instead and keep the `"Registered "` prefix.

- [ ] **Step 8: Mutation check**

| Test | Mutation (in `PushFeature.swift`) |
|---|---|
| `pushFeatureEnableRequestsPermissionAndRegistersWhenGranted` | in `.permissionResolved(granted: true)`, delete the `.run` and `return .none` |
| `pushFeatureEnableDeniedKeepsTheToggleOnWithAFailure` | in `.permissionResolved(granted: false)`, add `state.$enabled.withLock { $0 = false }` |
| `pushFeatureEnableWritesHubAndKeychainToSharedSettings` | in `sharedSettings`, `hubPort: hubPort` → `hubPort: 0` |
| `pushFeatureEnableIsIdempotent` | delete the `guard !state.enabled else { return .none }` line |
| `pushFeatureEnableStatusTextDescribesEachCase` | `case .idle: "Off"` → `case .idle: "Disabled"` |

Apply all, run the filter, all 5 red. Revert by hand, all 5 green.

- [ ] **Step 9: Commit**

Write `/tmp/ReTiCAPush/msg-task-9.txt`:
```
feat: PushFeature state, dependencies and the enable flow

PushPlatform and RegistrationClient as TCA dependencies, the feature's state
with persisted toggle and URL, status display text, and enabling: write the
shared settings, ask permission, register for a token when granted.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add Package.swift Sources/ReTiCAPush/Dependencies.swift Sources/ReTiCAPush/PushFeature.swift Tests/ReTiCAPushTests/PushFeatureEnableTests.swift Tests/ReTiCAPushTests/PushFeatureTestSupport.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-9.txt
```

---

### Task 10: `PushFeature` — token and registration

**Files:**
- Modify: `Sources/ReTiCAPush/PushFeature.swift`
- Create: `Tests/ReTiCAPushTests/PushFeatureTokenTests.swift`

**Interfaces:**
- Consumes: Task 9's state and actions, `PushRegistration.signed`, `RegistrationClient`.
- Produces: handling of `deviceTokenReceived`, `deviceTokenFailed`, `registrationFinished`.

- [ ] **Step 1: Write the failing tests**

`Tests/ReTiCAPushTests/PushFeatureTokenTests.swift`:
```swift
import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPush

private let token = Data([0x01, 0x02, 0x03, 0x04])
private let hours: TimeInterval = 60 * 60

@Test @MainActor func pushFeatureTokenRegistersAndRecordsOnSuccess() async throws {
    let me = Identity()
    let registration = RegistrationSpy()
    let storage = PushStorage.temporary()
    let store = makePushStore(identity: me, registration: registration, storage: storage) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
        state.status = .awaitingToken
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registering
    }
    await store.receive(.registrationFinished(.success(testNow))) {
        $0.status = .registered(testNow)
        $0.lastRegistration = RegistrationRecord(tokenHex: "01020304", registeredAt: testNow)
    }
    let (sent, url) = try #require(registration.registered.value.first)
    #expect(url.absoluteString == "https://hub.example.net/push")
    #expect(sent.domain == .register)
    #expect(sent.verify())
    #expect(sent.registration.publicKey == me.publicKey)
    #expect(sent.registration.pushToken == token)
    #expect(sent.registration.bundleID == "co.example.app")
    #expect(sent.registration.environment == .sandbox)
    #expect(sent.registration.issuedAt == 1_700_000_000)
    #expect(storage.settings.load().lastRegistration == RegistrationRecord(tokenHex: "01020304", registeredAt: testNow))
}

@Test @MainActor func pushFeatureTokenSkipsWhenSameTokenRegisteredWithin24h() async {
    let registration = RegistrationSpy()
    let earlier = testNow.addingTimeInterval(-1 * hours)
    let store = makePushStore(registration: registration) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
        state.lastRegistration = RegistrationRecord(tokenHex: "01020304", registeredAt: earlier)
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registered(earlier)
    }
    await store.finish()
    #expect(registration.registered.value.isEmpty)
}

@Test @MainActor func pushFeatureTokenReregistersAfter24h() async {
    let registration = RegistrationSpy()
    let store = makePushStore(registration: registration) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
        state.lastRegistration = RegistrationRecord(tokenHex: "01020304", registeredAt: testNow.addingTimeInterval(-25 * hours))
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registering
    }
    await store.receive(.registrationFinished(.success(testNow)))
    #expect(registration.registered.value.count == 1)
}

@Test @MainActor func pushFeatureTokenReregistersWhenTokenChanges() async {
    let registration = RegistrationSpy()
    let store = makePushStore(registration: registration) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
        state.lastRegistration = RegistrationRecord(tokenHex: "ffffffff", registeredAt: testNow.addingTimeInterval(-1 * hours))
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registering
    }
    await store.receive(.registrationFinished(.success(testNow)))
    #expect(registration.registered.value.count == 1)
}

@Test @MainActor func pushFeatureTokenRegistrationFailureKeepsOldRecord() async {
    let registration = RegistrationSpy(failure: .server(status: 401, body: "nope"))
    let old = RegistrationRecord(tokenHex: "ffffffff", registeredAt: testNow.addingTimeInterval(-1 * hours))
    let store = makePushStore(registration: registration) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
        state.lastRegistration = old
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registering
    }
    await store.receive(.registrationFinished(.failure(RegistrationFailure("Server returned 401: nope")))) {
        $0.status = .failed("Server returned 401: nope")
    }
    #expect(store.state.lastRegistration == old)
}

@Test @MainActor func pushFeatureTokenInvalidURLFailsWithoutPosting() async {
    let registration = RegistrationSpy()
    let store = makePushStore(registration: registration) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "ftp://hub.example.net/push" }
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .failed("Invalid registration URL")
    }
    await store.finish()
    #expect(registration.registered.value.isEmpty)
}

@Test @MainActor func pushFeatureTokenFailureSurfacesTheSystemReason() async {
    let store = makePushStore { state in
        state.$enabled.withLock { $0 = true }
        state.status = .awaitingToken
    }
    await store.send(.deviceTokenFailed("no valid aps-environment entitlement")) {
        $0.status = .failed("no valid aps-environment entitlement")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushFeatureToken`
Expected: the tests compile but fail: `deviceTokenReceived` falls into `default` and changes no state.

- [ ] **Step 3: Add the handling to `PushFeature.swift`**

Add these cases above `default:` in the `Reduce`:

```swift
            case let .deviceTokenReceived(token):
                state.deviceToken = token
                let tokenHex = token.hexString
                if let record = state.lastRegistration,
                   record.tokenHex == tokenHex,
                   date.now.timeIntervalSince(record.registeredAt) < Self.reregistrationInterval {
                    state.status = .registered(record.registeredAt)
                    return .none
                }
                guard let url = Self.registrationURL(from: state.registrationURL) else {
                    state.status = .failed(Self.invalidURLText)
                    return .none
                }
                state.status = .registering
                let registration = PushRegistration(
                    publicKey: state.identity.publicKey, pushToken: token, environment: state.environment,
                    bundleID: state.bundleID, issuedAt: UInt64(max(0, date.now.timeIntervalSince1970)))
                guard let signed = registration.signed(with: state.identity, domain: .register) else {
                    state.status = .failed("Could not sign the registration")
                    return .none
                }
                return .run { [registrationClient, date] send in
                    do {
                        try await registrationClient.register(signed, url)
                        await send(.registrationFinished(.success(date.now)))
                    } catch {
                        await send(.registrationFinished(.failure(Self.failure(for: error))))
                    }
                }

            case let .deviceTokenFailed(reason):
                state.status = .failed(reason)
                return .none

            case let .registrationFinished(.success(at)):
                state.status = .registered(at)
                if let token = state.deviceToken {
                    state.lastRegistration = RegistrationRecord(tokenHex: token.hexString, registeredAt: at)
                }
                let settings = state.sharedSettings
                let store = state.storage.settings
                return .run { _ in store.save(settings) }

            case let .registrationFinished(.failure(failure)):
                state.status = .failed(failure.message)
                return .none
```

Add these helpers inside `PushFeature`, after `public init() {}`:

```swift
    /// http(s) only. `URL(string:)` accepts far more than that.
    static func registrationURL(from string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    static func failure(for error: Error) -> RegistrationFailure {
        switch error {
        case let RegistrationClient.Failure.server(status, body):
            RegistrationFailure("Server returned \(status): \(body)")
        case let RegistrationClient.Failure.transport(message):
            RegistrationFailure(message)
        default:
            RegistrationFailure(error.localizedDescription)
        }
    }
```

`token.hexString` needs the hex helper from `ReTiCAPushCore`, which is internal there. Add to `Sources/ReTiCAPushCore/Data+Hex.swift` a public wrapper and use it instead:

```swift
public extension Data {
    /// Public spelling of `hexString` for the other targets of this package.
    var pushHex: String { hexString }
}
```

and in `PushFeature.swift` write `token.pushHex` wherever `token.hexString` appears above (two places).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushFeatureToken`
Expected: 7 pass.

- [ ] **Step 5: Mutation check**

| Test | Mutation (in `PushFeature.swift`) |
|---|---|
| `pushFeatureTokenRegistersAndRecordsOnSuccess` | in `.registrationFinished(.success)`, `return .run { _ in store.save(settings) }` → `return .none` |
| `pushFeatureTokenSkipsWhenSameTokenRegisteredWithin24h` | `reregistrationInterval: TimeInterval = 24 * 60 * 60` → `= 0` |
| `pushFeatureTokenReregistersAfter24h` | `reregistrationInterval` → `48 * 60 * 60` (apply this one in a **second sub-batch** after reverting the previous row: the two cannot be applied at once) |
| `pushFeatureTokenReregistersWhenTokenChanges` | delete the clause `record.tokenHex == tokenHex,` |
| `pushFeatureTokenRegistrationFailureKeepsOldRecord` | in `.registrationFinished(.failure)`, add `state.lastRegistration = nil` |
| `pushFeatureTokenInvalidURLFailsWithoutPosting` | in `registrationURL(from:)`, delete the clause `let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",` |
| `pushFeatureTokenFailureSurfacesTheSystemReason` | `.deviceTokenFailed(reason)`: `state.status = .failed(reason)` → `state.status = .failed("Token registration failed")` |

Sub-batch A: all rows except the third; run the filter; 6 red (the third test stays green in this batch, which is expected). Revert by hand. Sub-batch B: the third row alone; run the filter; `pushFeatureTokenReregistersAfter24h` red (the second test also goes red, which is fine). Revert by hand. All 7 green.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCAPush/msg-task-10.txt`:
```
feat: PushFeature token handling and registration

Skip the POST for a token registered within 24 h, otherwise sign and POST to
an http(s) registration URL, record success in state and shared settings,
surface failures without touching the last record.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add Sources/ReTiCAPush/PushFeature.swift Sources/ReTiCAPushCore/Data+Hex.swift Tests/ReTiCAPushTests/PushFeatureTokenTests.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-10.txt
```

---

### Task 11: `PushFeature` — disable, hub changes, launch, drain

**Files:**
- Modify: `Sources/ReTiCAPush/PushFeature.swift`
- Create: `Tests/ReTiCAPushTests/PushFeatureLifecycleTests.swift`

**Interfaces:**
- Consumes: Tasks 9 and 10.
- Produces: handling of `setEnabled(false)`, `hubChanged`, `appLaunched`, `drainInbox`, `inboxDrained`, `unregisterFinished`, and the `delegate(.inject)` emission the app plan consumes. Removes the `default:` arm.

- [ ] **Step 1: Write the failing tests**

`Tests/ReTiCAPushTests/PushFeatureLifecycleTests.swift`:
```swift
import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPush

private let token = Data([0x01, 0x02, 0x03, 0x04])
private func packet(_ n: UInt8) -> Data { Data([0x00, 0x00, n, n &+ 1, n &+ 2]) }

@Test @MainActor func pushFeatureLifecycleDisableUnregistersAndClears() async throws {
    let platform = PlatformSpy()
    let registration = RegistrationSpy()
    let storage = PushStorage.temporary()
    let record = RegistrationRecord(tokenHex: "01020304", registeredAt: testNow)
    storage.settings.save(SharedPushSettings(lastRegistration: record))
    let store = makePushStore(platform: platform, registration: registration, storage: storage) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
        state.deviceToken = token
        state.status = .registered(testNow)
        state.lastRegistration = record
    }
    await store.send(.setEnabled(false)) {
        $0.$enabled.withLock { $0 = false }
        $0.deviceToken = nil
        $0.status = .idle
        $0.lastRegistration = nil
    }
    await store.receive(.unregisterFinished)
    #expect(platform.unregisters.value == 1)
    let (sent, _) = try #require(registration.unregistered.value.first)
    #expect(sent.domain == .unregister)
    #expect(sent.verify())
    #expect(storage.settings.load().lastRegistration == nil)
}

@Test @MainActor func pushFeatureLifecycleAppLaunchedEnabledRegistersAndDrains() async {
    let platform = PlatformSpy()
    let store = makePushStore(platform: platform) { state in
        state.$enabled.withLock { $0 = true }
    }
    await store.send(.appLaunched)
    await store.receive(.inboxDrained([]))
    await store.finish()
    #expect(platform.registers.value == 1)
}

@Test @MainActor func pushFeatureLifecycleAppLaunchedDisabledOnlyDrains() async {
    let platform = PlatformSpy()
    let store = makePushStore(platform: platform)
    await store.send(.appLaunched)
    await store.receive(.inboxDrained([]))
    await store.finish()
    #expect(platform.registers.value == 0)
}

@Test @MainActor func pushFeatureLifecycleHubChangedWhileEnabledRewritesSettings() async {
    let storage = PushStorage.temporary()
    let store = makePushStore(storage: storage) { state in
        state.$enabled.withLock { $0 = true }
    }
    await store.send(.hubChanged(host: "new.example.net", port: 4243)) {
        $0.hubHost = "new.example.net"
        $0.hubPort = 4243
    }
    await store.finish()
    #expect(storage.settings.load().hubHost == "new.example.net")
    #expect(storage.settings.load().hubPort == 4243)
}

@Test @MainActor func pushFeatureLifecycleHubChangedWhileDisabledLeavesSettings() async {
    let storage = PushStorage.temporary()
    let store = makePushStore(storage: storage)
    await store.send(.hubChanged(host: "new.example.net", port: 4243)) {
        $0.hubHost = "new.example.net"
        $0.hubPort = 4243
    }
    await store.finish()
    #expect(storage.settings.load().hubHost == "")
}

@Test @MainActor func pushFeatureLifecycleDrainWithPacketsEmitsInject() async throws {
    let storage = PushStorage.temporary()
    try storage.inbox.append(packet(1))
    try storage.inbox.append(packet(2))
    let store = makePushStore(storage: storage)
    await store.send(.drainInbox)
    await store.receive(.inboxDrained([packet(1), packet(2)]))
    await store.receive(.delegate(.inject(packets: [packet(1), packet(2)])))
    #expect(try storage.inbox.count() == 0)
}

@Test @MainActor func pushFeatureLifecycleDrainEmptyEmitsNothing() async {
    let store = makePushStore()
    store.exhaustivity = .on
    await store.send(.drainInbox)
    await store.receive(.inboxDrained([]))
    await store.finish()
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushFeatureLifecycle`
Expected: compile, then failures: the actions fall into `default`.

- [ ] **Step 3: Add the handling to `PushFeature.swift`**

Replace the `default: return .none` arm with these cases:

```swift
            case .setEnabled(false):
                // Sign the DELETE over the token we are giving up, before clearing it.
                let tokenForUnregister = state.deviceToken ?? Data()
                state.$enabled.withLock { $0 = false }
                state.deviceToken = nil
                state.status = .idle
                state.lastRegistration = nil
                let settings = state.sharedSettings
                let store = state.storage.settings
                let url = Self.registrationURL(from: state.registrationURL)
                let registration = PushRegistration(
                    publicKey: state.identity.publicKey, pushToken: tokenForUnregister,
                    environment: state.environment, bundleID: state.bundleID,
                    issuedAt: UInt64(max(0, date.now.timeIntervalSince1970)))
                let signed = registration.signed(with: state.identity, domain: .unregister)
                return .run { [platform, registrationClient] send in
                    store.save(settings)
                    await platform.unregisterForRemoteNotifications()
                    if let url, let signed {
                        // Best effort: the server also expires registrations on its own.
                        try? await registrationClient.unregister(signed, url)
                    }
                    await send(.unregisterFinished)
                }

            case .unregisterFinished:
                return .none

            case let .hubChanged(host, port):
                state.hubHost = host
                state.hubPort = port
                guard state.enabled else { return .none }
                let settings = state.sharedSettings
                let store = state.storage.settings
                return .run { _ in store.save(settings) }

            case .appLaunched:
                let enabled = state.enabled
                return .merge(
                    .run { [platform] _ in if enabled { await platform.registerForRemoteNotifications() } },
                    .send(.drainInbox)
                )

            case .drainInbox:
                let inbox = state.storage.inbox
                return .run { send in
                    let packets = (try? inbox.drain()) ?? []
                    await send(.inboxDrained(packets))
                }

            case let .inboxDrained(packets):
                guard !packets.isEmpty else { return .none }
                return .send(.delegate(.inject(packets: packets)))

            case .delegate, .binding:
                return .none
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter pushFeatureLifecycle`
Expected: 7 pass. Then run the full suite: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush` and expect every test green with zero known issues.

- [ ] **Step 5: Mutation check**

| Test | Mutation (in `PushFeature.swift`) |
|---|---|
| `pushFeatureLifecycleDisableUnregistersAndClears` | in `.setEnabled(false)`, delete `state.lastRegistration = nil` |
| `pushFeatureLifecycleAppLaunchedEnabledRegistersAndDrains` | in `.appLaunched`, `if enabled { … }` → `if !enabled { … }` |
| `pushFeatureLifecycleAppLaunchedDisabledOnlyDrains` | same mutation as the row above (one edit reddens both: enabled stops registering, disabled starts) |
| `pushFeatureLifecycleHubChangedWhileEnabledRewritesSettings` | in `.hubChanged`, `return .run { _ in store.save(settings) }` → `return .none` |
| `pushFeatureLifecycleHubChangedWhileDisabledLeavesSettings` | in `.hubChanged`, `guard state.enabled else { return .none }` → delete the line (apply together with the row above as the single change: delete the guard and keep the save, then the enabled test passes but the disabled test fails. To redden both at once, instead change the guard to `guard !state.enabled else { return .none }`) |
| `pushFeatureLifecycleDrainWithPacketsEmitsInject` | in `.inboxDrained`, `.inject(packets: packets)` → `.inject(packets: Array(packets.dropLast()))` |
| `pushFeatureLifecycleDrainEmptyEmitsNothing` | in `.inboxDrained`, delete the `guard !packets.isEmpty else { return .none }` line |

Use these five edits: rows 1, 2 (covers 3), 5's inverted guard (covers 4), 6, 7. Apply all, run the filter, all 7 red. Revert by hand, all 7 green.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCAPush/msg-task-11.txt`:
```
feat: PushFeature disable, hub changes, launch and inbox drain

Disable clears the record and unregisters best-effort, hub changes rewrite the
shared settings while enabled, launch re-requests the token and drains, and a
non-empty drain emits delegate(.inject) for the host app.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add Sources/ReTiCAPush/PushFeature.swift Tests/ReTiCAPushTests/PushFeatureLifecycleTests.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-11.txt
```

---

### Task 12: `PushServiceHandler`, `ProofFrameSender`, Keychain loader

**Files:**
- Modify: `Package.swift` (add the `ReTiCAPushExtensionTests` test target)
- Create: `Sources/ReTiCAPushExtension/PushServiceHandler.swift`
- Create: `Sources/ReTiCAPushExtension/ProofFrameSender.swift`
- Create: `Sources/ReTiCAPushExtension/KeychainIdentityLoader.swift`
- Create: `Tests/ReTiCAPushExtensionTests/PushServiceHandlerTests.swift`
- Create: `Tests/ReTiCAPushExtensionTests/ProofFrameSenderTests.swift`

**Interfaces:**
- Consumes: `PushPayload`, `PushInbox`, `ProofBuilder`, `Identity.lxmfDeliveryHash`, `SharedPushSettings`, `IdentityKeychain`, `KeychainOps`.
- Produces:
  ```swift
  public struct PushServiceHandler: Sendable {
      public init(inbox: PushInbox, settings: SharedPushSettings,
                  loadIdentity: @escaping @Sendable () -> Identity?,
                  sendFrames: @escaping @Sendable (_ host: String, _ port: Int, _ frames: [Data]) async -> Void,
                  deadline: Duration = .seconds(20))
      public static func live(storage: PushStorage) -> PushServiceHandler
      public func handle(userInfo: [AnyHashable: Any]) async
  }
  public enum ProofFrameSender { public static func send(host: String, port: Int, frames: [Data], timeout: Duration = .seconds(10)) async }
  public enum KeychainIdentityLoader { public static func loader(service: String, accessGroup: String?, ops: KeychainOps = .live) -> @Sendable () -> Identity? }
  ```
  The app's Notification Service Extension calls `PushServiceHandler.live(storage:).handle(userInfo:)`.

- [ ] **Step 1: Add the test target to `Package.swift`**

After the `ReTiCAPushTests` entry:
```swift
        .testTarget(
            name: "ReTiCAPushExtensionTests",
            dependencies: [
                "ReTiCAPushExtension",
                .product(name: "ReTiCAKeychain", package: "ReTiCA"),
                // Tests only, for `LockIsolated`. The extension target itself stays TCA-free.
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
```

- [ ] **Step 2: Write the failing tests**

`Tests/ReTiCAPushExtensionTests/PushServiceHandlerTests.swift`:
```swift
import Testing
import Foundation
import Security
import ComposableArchitecture
import ReTiCA
import ReTiCAKeychain
@testable import ReTiCAPushExtension

private func freshDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ReTiCAPushExtTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func dataPacket(to me: Identity) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    return try! Packet.data(to: dest, plaintext: Data("hi".utf8)).packed()
}

private func userInfo(_ packets: [Data]) -> [AnyHashable: Any] {
    ["aps": ["alert": ["title": "New message"]],
     "rns": ["v": 1, "packets": packets.map { $0.base64EncodedString() }]]
}

/// Records what was sent and optionally hangs.
private final class SenderSpy: Sendable {
    let calls = LockIsolated<[(host: String, port: Int, frames: [Data])]>([])
    let hang: Duration?
    init(hang: Duration? = nil) { self.hang = hang }
    var send: @Sendable (String, Int, [Data]) async -> Void {
        { host, port, frames in
            self.calls.withValue { $0.append((host, port, frames)) }
            if let hang = self.hang { try? await Task.sleep(for: hang) }
        }
    }
}

private let settings = SharedPushSettings(hubHost: "hub.example.net", hubPort: 4242,
                                          keychainService: "reticulum.identity", keychainAccessGroup: "TEAM.g")

private func handler(inbox: PushInbox, identity: Identity?, sender: SenderSpy,
                     deadline: Duration = .seconds(20)) -> PushServiceHandler {
    PushServiceHandler(inbox: inbox, settings: settings, loadIdentity: { identity },
                       sendFrames: sender.send, deadline: deadline)
}

@Test func pushServiceHandlerStashesAndProvesADataPacket() async throws {
    let me = Identity()
    let inbox = PushInbox(directory: freshDirectory())
    let sender = SenderSpy()
    let raw = dataPacket(to: me)
    await handler(inbox: inbox, identity: me, sender: sender).handle(userInfo: userInfo([raw]))
    #expect(try inbox.drain() == [raw])
    let call = try #require(sender.calls.value.first)
    #expect(call.frames.count == 1)
    var deframer = HDLCDeframer()
    let proof = try #require(Packet(raw: try #require(deframer.ingest(call.frames[0]).first)))
    #expect(proof.packetType == .proof)
    #expect(me.validate(signature: proof.payload, message: Packet(raw: raw)!.packetHash))
}

@Test func pushServiceHandlerUsesTheConfiguredHub() async throws {
    let me = Identity()
    let sender = SenderSpy()
    await handler(inbox: PushInbox(directory: freshDirectory()), identity: me, sender: sender)
        .handle(userInfo: userInfo([dataPacket(to: me)]))
    let call = try #require(sender.calls.value.first)
    #expect(call.host == "hub.example.net")
    #expect(call.port == 4242)
}

@Test func pushServiceHandlerStashesButDoesNotProveForeignOrFlaggedPackets() async throws {
    let me = Identity()
    let inbox = PushInbox(directory: freshDirectory())
    let sender = SenderSpy()
    let foreign = dataPacket(to: Identity())
    let announce = try Packet(packetType: .announce, destinationType: .single,
                              destinationHash: me.lxmfDeliveryHash, payload: Data(repeating: 1, count: 40)).packed()
    var flagged = dataPacket(to: me)
    flagged[0] |= 0x80
    await handler(inbox: inbox, identity: me, sender: sender).handle(userInfo: userInfo([foreign, announce, flagged]))
    #expect(try inbox.count() == 3)
    #expect(sender.calls.value.isEmpty)
}

@Test func pushServiceHandlerWithoutIdentityStashesOnly() async throws {
    let me = Identity()
    let inbox = PushInbox(directory: freshDirectory())
    let sender = SenderSpy()
    await handler(inbox: inbox, identity: nil, sender: sender).handle(userInfo: userInfo([dataPacket(to: me)]))
    #expect(try inbox.count() == 1)
    #expect(sender.calls.value.isEmpty)
}

@Test func pushServiceHandlerMalformedPayloadDoesNothing() async throws {
    let inbox = PushInbox(directory: freshDirectory())
    let sender = SenderSpy()
    await handler(inbox: inbox, identity: Identity(), sender: sender).handle(userInfo: ["aps": ["alert": "x"]])
    #expect(try inbox.count() == 0)
    #expect(sender.calls.value.isEmpty)
}

@Test func pushServiceHandlerReturnsWhenTheSenderHangs() async {
    let me = Identity()
    let sender = SenderSpy(hang: .seconds(10))
    let clock = ContinuousClock()
    let start = clock.now
    await handler(inbox: PushInbox(directory: freshDirectory()), identity: me, sender: sender, deadline: .milliseconds(200))
        .handle(userInfo: userInfo([dataPacket(to: me)]))
    #expect(clock.now - start < .seconds(2))
}

@Test func pushServiceHandlerKeychainLoaderReturnsTheStoredIdentity() {
    let me = Identity()
    let location = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAM.g")
    let keychain = InMemoryKeychain([location: me.privateKey!])
    let load = KeychainIdentityLoader.loader(service: "reticulum.identity", accessGroup: "TEAM.g", ops: keychain.ops)
    #expect(load() == me)
}

@Test func pushServiceHandlerKeychainLoaderLockedReturnsNil() {
    let location = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAM.g")
    let keychain = InMemoryKeychain([location: Identity().privateKey!])
    keychain.failRead(at: location, status: errSecInteractionNotAllowed)
    let load = KeychainIdentityLoader.loader(service: "reticulum.identity", accessGroup: "TEAM.g", ops: keychain.ops)
    #expect(load() == nil)
}
```

`Tests/ReTiCAPushExtensionTests/ProofFrameSenderTests.swift`:
```swift
import Testing
import Foundation
import Network
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPushExtension

/// A loopback listener that collects everything one connection writes.
private final class Collector: @unchecked Sendable {
    let listener: NWListener
    let received = LockIsolated(Data())
    let queue = DispatchQueue(label: "collector")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            read(connection)
        }
        listener.start(queue: queue)
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, done, _ in
            if let data { received.withValue { $0.append(data) } }
            if !done { read(connection) }
        }
    }

    var port: Int {
        var p: UInt16 = 0
        for _ in 0..<50 where p == 0 {
            if let actual = listener.port?.rawValue { p = actual } else { Thread.sleep(forTimeInterval: 0.05) }
        }
        return Int(p)
    }
}

@Test func proofFrameSenderWritesFramesOverLoopback() async throws {
    let collector = try Collector()
    let a = HDLC.frame(Data(repeating: 0xA1, count: 25))
    let b = HDLC.frame(Data(repeating: 0xB2, count: 30))
    await ProofFrameSender.send(host: "127.0.0.1", port: collector.port, frames: [a, b], timeout: .seconds(5))
    for _ in 0..<50 where collector.received.value.count < a.count + b.count {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(collector.received.value == a + b)
    collector.listener.cancel()
}
```

Nine tests across the two files.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter "pushServiceHandler|proofFrameSender"`
Expected: compile error.

- [ ] **Step 4: Write `Sources/ReTiCAPushExtension/KeychainIdentityLoader.swift`**

```swift
import Foundation
import ReTiCA
import ReTiCAKeychain

/// Loads the shared identity the app stores (the same `IdentityKeychain.Location` the app uses,
/// read from `SharedPushSettings`). Never mints: `loadOrCreate` would rotate the identity if the
/// item is unreadable. nil for absent, locked (before first unlock) or any failure.
public enum KeychainIdentityLoader {
    public static func loader(service: String, accessGroup: String?,
                              ops: KeychainOps = .live) -> @Sendable () -> Identity? {
        let location = IdentityKeychain.Location(service: service, accessGroup: accessGroup)
        return { IdentityKeychain.load(shared: location, legacy: [], ops: ops).identity }
    }
}
```

- [ ] **Step 5: Write `Sources/ReTiCAPushExtension/ProofFrameSender.swift`**

```swift
import Foundation
import Network

/// One short TCP connection to the hub: write every frame, wait for the writes to complete,
/// close. The hub's TCP server interface deframes HDLC and routes the proofs by its reverse
/// table (docs/server-contract.md §2). Errors and timeouts are swallowed: the app proves again
/// on drain, and the sender's retries give several chances.
public enum ProofFrameSender {
    public static func send(host: String, port: Int, frames: [Data], timeout: Duration = .seconds(10)) async {
        guard !frames.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await write(frames, over: connection) }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
            connection.cancel()
        }
    }

    private static func write(_ frames: [Data], over connection: NWConnection) async {
        let queue = DispatchQueue(label: "ReTiCAPush.ProofFrameSender")
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumed = LockedFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if resumed.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        guard ready else { return }
        for frame in frames {
            let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                })
            }
            if !ok { return }
        }
    }
}

/// A once-only flag so a continuation resumes exactly once across state callbacks.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
```

- [ ] **Step 6: Write `Sources/ReTiCAPushExtension/PushServiceHandler.swift`**

```swift
import Foundation
import ReTiCA
import ReTiCAPushCore

/// What the Notification Service Extension does with a push (spec §1): stash every packet in the
/// shared inbox, sign a proof for each DATA packet addressed to our delivery hash, write the
/// proofs to the hub over one short connection. Nothing is decrypted and the notification is
/// never changed, so the extension always hands back the original content afterwards.
///
/// Every step is best-effort under `deadline`. A locked Keychain (before first unlock) means the
/// packets are stashed and nothing is proved.
public struct PushServiceHandler: Sendable {
    public let inbox: PushInbox
    public let settings: SharedPushSettings
    public let loadIdentity: @Sendable () -> Identity?
    public let sendFrames: @Sendable (_ host: String, _ port: Int, _ frames: [Data]) async -> Void
    public let deadline: Duration

    public init(inbox: PushInbox, settings: SharedPushSettings,
                loadIdentity: @escaping @Sendable () -> Identity?,
                sendFrames: @escaping @Sendable (_ host: String, _ port: Int, _ frames: [Data]) async -> Void,
                deadline: Duration = .seconds(20)) {
        self.inbox = inbox
        self.settings = settings
        self.loadIdentity = loadIdentity
        self.sendFrames = sendFrames
        self.deadline = deadline
    }

    /// The real thing: inbox and settings from `storage`, identity from the shared Keychain,
    /// proofs over `ProofFrameSender`.
    public static func live(storage: PushStorage) -> PushServiceHandler {
        let settings = storage.settings.load()
        return PushServiceHandler(
            inbox: storage.inbox,
            settings: settings,
            loadIdentity: KeychainIdentityLoader.loader(service: settings.keychainService,
                                                        accessGroup: settings.keychainAccessGroup),
            sendFrames: { host, port, frames in
                await ProofFrameSender.send(host: host, port: port, frames: frames)
            })
    }

    public func handle(userInfo: [AnyHashable: Any]) async {
        // Decode before anything crosses an actor boundary: `[AnyHashable: Any]` is not Sendable.
        let packets: [Data]
        do {
            packets = try PushPayload.decode(userInfo)
        } catch {
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await process(packets) }
            group.addTask { try? await Task.sleep(for: deadline) }
            await group.next()
            group.cancelAll()
        }
    }

    private func process(_ packets: [Data]) async {
        for raw in packets {
            try? inbox.append(raw)
        }
        guard let identity = loadIdentity() else { return }
        let deliveryHash = identity.lxmfDeliveryHash
        let frames = packets.compactMap { ProofBuilder.proof(for: $0, identity: identity, deliveryHash: deliveryHash) }
        guard !frames.isEmpty else { return }
        await sendFrames(settings.hubHost, settings.hubPort, frames)
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush --filter "pushServiceHandler|proofFrameSender"`
Expected: 9 pass. The loopback test needs no network permission on macOS. If it is flaky under parallel execution, mark `ProofFrameSenderTests` with `@Suite(.serialized)` around the one test.

- [ ] **Step 8: Mutation check**

| Test | Mutation |
|---|---|
| `pushServiceHandlerStashesAndProvesADataPacket` | in `process`, `try? inbox.append(raw)` → `try? inbox.append(raw + Data([0]))` (the drained bytes differ) |
| `pushServiceHandlerUsesTheConfiguredHub` | `await sendFrames(settings.hubHost, settings.hubPort, frames)` → `await sendFrames(settings.hubHost, settings.hubPort + 1, frames)` |
| `pushServiceHandlerStashesButDoesNotProveForeignOrFlaggedPackets` | `packets.compactMap { ProofBuilder.proof(…) }` → `packets.map { ProofBuilder.proof(…) ?? Data() }` |
| `pushServiceHandlerWithoutIdentityStashesOnly` | `guard let identity = loadIdentity() else { return }` → `else { await sendFrames(settings.hubHost, settings.hubPort, []); return }` |
| `pushServiceHandlerMalformedPayloadDoesNothing` | in `handle`, the `catch { return }` → `catch { try? inbox.append(Data([0])); return }` |
| `pushServiceHandlerReturnsWhenTheSenderHangs` | in `handle`, replace the whole `withTaskGroup` block with `await process(packets)` |
| `pushServiceHandlerKeychainLoaderReturnsTheStoredIdentity` | in `KeychainIdentityLoader`, `.identity }` → `.identity.map { _ in Identity() } }` |
| `pushServiceHandlerKeychainLoaderLockedReturnsNil` | in `KeychainIdentityLoader`, `.identity }` → `.identity ?? Identity() }` (apply in a **second sub-batch** after reverting the row above: the two edit the same expression) |
| `proofFrameSenderWritesFramesOverLoopback` | in `write`, `for frame in frames {` → `for frame in frames.prefix(1) {` |

Sub-batch A: every row except the eighth; run the filter; 8 red (the locked-loader test stays green). Revert by hand. Sub-batch B: the eighth row alone; run the filter; `pushServiceHandlerKeychainLoaderLockedReturnsNil` red. Revert by hand. All 9 green.

- [ ] **Step 9: Commit**

Write `/tmp/ReTiCAPush/msg-task-12.txt`:
```
feat: service extension handler, proof sender and Keychain loader

Stash every pushed packet, prove the ones addressed to us, write the framed
proofs to the hub over one NWConnection under a deadline. Never decrypts.

Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush add Package.swift Sources/ReTiCAPushExtension/PushServiceHandler.swift Sources/ReTiCAPushExtension/ProofFrameSender.swift Sources/ReTiCAPushExtension/KeychainIdentityLoader.swift Tests/ReTiCAPushExtensionTests/PushServiceHandlerTests.swift Tests/ReTiCAPushExtensionTests/ProofFrameSenderTests.swift
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCAPush commit -F /tmp/ReTiCAPush/msg-task-12.txt
```

---

### Task 13: Final verification

**Files:** none new.

- [ ] **Step 1: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCAPush`
Expected: every test green, zero known issues. The count is 71.

- [ ] **Step 2: iOS build**

The package must also build for iOS, where `Data.WritingOptions.noFileProtection` and `FileManager.containerURL` matter:
```bash
xcodebuild -scheme ReTiCAPush-Package -destination "generic/platform=iOS Simulator" -skipPackagePluginValidation build
```
Run that from `/Users/ell/development/ios/pods/ReTiCAPush` (use `-project` only if Xcode refuses the bare scheme; the package directory alone is enough for `xcodebuild` to find the scheme). Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Clean tree**

Run: `git -C /Users/ell/development/ios/pods/ReTiCAPush status --short`
Expected: empty. If `.swiftpm/` or `.build/` show up, they are ignored by Task 1's `.gitignore`; anything else is a leftover to inspect.

- [ ] **Step 4: Report**

Report the final test count, the iOS build result, and the commit list (`git -C /Users/ell/development/ios/pods/ReTiCAPush log --oneline`). The app plan (`2026-10-01-push-app.md`) starts from here.
