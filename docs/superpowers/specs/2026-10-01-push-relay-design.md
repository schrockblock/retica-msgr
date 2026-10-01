# Push notifications via a push-capable hub — design

**Date:** 2026-10-01. **Scope:** a new SPM package `ReTiCAPush` (sibling of ReTiCA, its own
repo), the ReTiCaMsgr app (settings, AppDelegate, a Notification Service Extension, entitlements)
and a server contract document that lives in the package. **Depends on:** nothing new in ReTiCA.
Everything the client needs is already public: `Packet`, `Identity.sign`, `HDLC.frame`,
`Destination.hash`, `IdentityKeychain`, and `Transport.Action.received` (reachable from the app as
`.node(.client(.endpoint(.transport(.received(id, raw)))))`, and already accepting bytes for an
interface that has not registered yet when that interface is plain, Transport.swift:424-443).
**Server and APNs are out of scope**; the contract in §2 is the deliverable for them.

## Goal

Let a ReTiCaMsgr user opt in to being woken by a push when a message arrives for them while the
app is not connected, with the message delivered through ReTiCA's ordinary receive path, a
content-free "New message" banner, and the sender receiving a regular Reticulum delivery proof
through the existing path. Off by default. The sender needs nothing and never knows push was
involved.

## Decisions taken while brainstorming

- **The push server is a Reticulum transport node, and push is a one-way transport**, not a
  message relay. The server is the client's normal TCP hub. A per-client spawned interface for a
  registered client stays attached when its socket dies and goes dormant; what it would have
  written to the socket goes out as an APNs push instead. Paths and reverse-path entries at the
  server stay valid, so a proof the client sends back over a new socket routes to the sender the
  standard way. Earlier alternatives (per-message HTTP upload of propagation-format bytes, or
  relaying the opportunistic wire packet with a longer receipt lifetime) were rejected: the
  first can never be proved, the second needs ReTiCA changes and only covers single-packet
  messages.
- **Why a proof cannot come from a relayed copy on its own:** ReTiCA's transport routes a proof
  only against its own `pendingReceipts` (Transport.swift:762-785); reference RNS forwards proofs
  by reverse-table entries that the data packet left when it crossed each node. A packet that
  crossed nothing leaves nothing to route along. ReTiCA also forbids re-sending a message hash.
- **Timing budget this has to fit:** a sender's single-packet receipt lives
  `receiptTimeoutBase + receiptTimeoutPerHop × max(1, hops)` = 6 s + 6 s/hop
  (Transport.swift:1252-1253), with five attempts 10 s apart (`LXMFDelivery`). The push, the
  extension's proof, and the server's reverse-table forward must fit in that window. APNs
  alert pushes at priority 10 normally land in seconds, so the first or second attempt gets
  proved. Past the window the receiver still has the message; the sender's row ends `failed`,
  as today.
- **Notification Service Extension, not a silent push.** A silent (`content-available` only)
  push is throttled, deferred in Low Power Mode, and never delivered to a force-quit app. A
  visible push with `mutable-content: 1` runs the extension every time, in its own process,
  regardless of app state, with about 30 s and 24 MB. The extension is the reliable path for
  the proof and for stashing the packet. `content-available: 1` is added as well so the app also
  gets a best-effort background wake.
- **Fallback-only banner.** The extension never decrypts and never changes the notification. The
  banner always reads "New message" (opsec: no sender, no content, even on the lock screen).
- **Registration needs a side channel.** One signed HTTP call carries the identity public key and
  the APNs token. The server derives the LXMF delivery hash itself. This is the only HTTP in the
  package.
- **Package placement:** `/Users/ell/development/ios/pods/ReTiCAPush`, own git repo, depends on
  `../ReTiCA` by path, the way ReTiCA depends on `../FCB`. The app depends on it by path like it
  does ReTiCA. The feature is kept out of ReTiCA because it departs from Reticulum's design and
  would pull HTTP and APNs concerns into the library; it may later become an optional plugin for
  the reference implementation.

## 1. Package layout and components

```
ReTiCAPush/
  Package.swift              swift-tools 6.0, iOS 17 / macOS 14, depends on ../ReTiCA
  Sources/
    ReTiCAPushCore/          no TCA. Depends on ReTiCA (core) and ReTiCAKeychain.
    ReTiCAPush/              TCA. Depends on ReTiCAPushCore, ComposableArchitecture.
    ReTiCAPushExtension/     no TCA. Depends on ReTiCAPushCore. Network.framework for the proof.
  Tests/
    ReTiCAPushCoreTests/     also depends on ReTiCATransport for the proof cross-check
    ReTiCAPushTests/
    ReTiCAPushExtensionTests/
  docs/server-contract.md
```

### `ReTiCAPushCore`

- `PushPayload` — decodes the `rns` block of an APNs `userInfo` dictionary into `[Data]` raw
  packets. Rejects a missing or unknown version, a non-array, non-base64 entries, entries over
  `Packet` MTU, and more than 8 entries. Pure, synchronous.
- `PushInbox` — a directory in the app-group container. `append(_ raw: Data)` writes one file named
  by the SHA-256 hex of `raw` with `FileProtectionType.none` (the bytes are already encrypted to
  our identity and the extension may run before first unlock). Re-appending an existing hash is a
  no-op. Capped at 256 entries, oldest by modification date evicted first. `drain() -> [Data]`
  returns entries in modification-date order and deletes them. `init(containerURL:)`; the app and
  the extension both construct it from `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.
- `ProofBuilder` — `static func proof(for raw: Data, identity: Identity, deliveryHash: Data) -> Data?`.
  Returns nil unless `Packet(raw:)` parses, `raw.first & 0x80 == 0` (no IFAC flag),
  `packetType == .data`, `destinationType == .single`, `destinationHash == deliveryHash`. Otherwise
  builds the proof exactly as `Transport.proveSingle` does (Transport.swift:1083-1090): header 1,
  `.proof`, broadcast, single, `destinationHash = packetHash.prefix(16)`, payload
  `identity.sign(packetHash)`, and returns `HDLC.frame(packed)`.
- `DeliveryHash` — `static func delivery(for identity: Identity) -> Data` =
  `Destination.hash(identityHash: identity.hash, appName: "lxmf", aspects: ["delivery"])`.
- `PushRegistration` — the signed request. Fields: `version` (1), `publicKey` (64 bytes),
  `pushToken` (bytes), `platform` ("ios"), `environment` ("production" | "sandbox"), `bundleID`,
  `issuedAt` (Unix seconds, UInt64). `signingBytes(domain:)` is the fixed layout in §2.1.
  `signed(with identity: Identity, domain: Domain, now: Date) -> SignedRegistration` (fields +
  `signature`). `Domain` is `.register` / `.unregister`. `SignedRegistration` is `Codable` with the
  JSON key names of §2.1 and byte fields base64.
- `RegistrationClient` — `struct` of two `@Sendable` closures, `register(SignedRegistration, URL) async throws`
  and `unregister(SignedRegistration, URL) async throws`, plus `static func live(session: URLSession)`.
  Non-2xx throws `RegistrationError.server(status:body:)`. This is a plain struct; the TCA
  `DependencyKey` conformance lives in `ReTiCAPush`.
- `SharedPushSettings` — the app-group `UserDefaults` suite the app writes and the extension reads:
  `hubHost`, `hubPort`, `keychainService`, `keychainAccessGroup`, and the last registration record
  (`token` hex, `registeredAt`). Keys are namespaced `retica.push.*`.

### `ReTiCAPush` — `PushFeature`

**State.**

| field | kind | notes |
|---|---|---|
| `identity` | `Identity` | injected at init, like `AppFeature.State` |
| `bundleID`, `environment` | `String` | injected at init by the app |
| `enabled` | `@Shared(.appStorage("pushEnabled"))` Bool | default false |
| `registrationURL` | `@Shared(.appStorage("pushRegistrationURL"))` String | base URL, user-entered |
| `hubHost`, `hubPort` | `String`, `Int` | mirrored from the app's hub settings by the parent on every change; written to `SharedPushSettings` when enabling |
| `deviceToken` | `Data?` | session only |
| `status` | enum | `.idle`, `.awaitingPermission`, `.awaitingToken`, `.registering`, `.registered(Date)`, `.failed(String)` |
| `lastRegistration` | `RegistrationRecord?` | token hex + date, persisted in `SharedPushSettings` |

**Actions.** `setEnabled(Bool)`, `binding` (for `registrationURL`), `hubChanged(host:port:)`,
`appLaunched`, `permissionResolved(granted: Bool)`, `deviceTokenReceived(Data)`,
`deviceTokenFailed(String)`, `registrationFinished(Result<Date, RegistrationFailure>)`,
`unregisterFinished`, `drainInbox`, `inboxDrained([Data])`, `delegate(Delegate)` with
`Delegate.inject(packets: [Data])`.

**Dependencies** (each a struct of `@Sendable` closures with `liveValue` and an `unimplemented`
`testValue`, following `TCPConnection`):

- `pushPlatform`: `requestAuthorization() async -> Bool`, `registerForRemoteNotifications()`,
  `unregisterForRemoteNotifications()`. Live value is supplied by the app (UIKit), not the package.
- `registrationClient`: `RegistrationClient` from Core, `liveValue = .live(session: .shared)`.
- `pushInbox`: `append(Data)`, `drain() -> [Data]`. Live value wraps a `PushInbox` at the app-group
  container; the app supplies the container URL through `SharedPushSettings`.
- `pushSettings`: read/write `SharedPushSettings`.
- `date`, `continuousClock`.

**Reducer behaviour.**

- `setEnabled(true)`: persist the flag, write hub host/port and keychain location to
  `pushSettings`, status `.awaitingPermission`, run `requestAuthorization`. Granted → status
  `.awaitingToken`, `registerForRemoteNotifications()`. Denied → `.failed("Notifications are off
  for ReTiCaMsgr in Settings")`; the flag stays on so the user can fix it in iOS Settings and
  relaunch.
- `deviceTokenReceived(token)`: store it. If `lastRegistration` has the same token hex and
  `registeredAt` is within 24 h, status `.registered(registeredAt)` and stop. Otherwise, status
  `.registering`, build `PushRegistration.signed(with: identity, domain: .register, now:)`, POST
  to `registrationURL` (an unparsable URL fails immediately with `.failed("Invalid registration
  URL")`). Success → `.registered(now)`, persist the record. Failure → `.failed(description)`,
  record left as it was.
- `deviceTokenFailed(reason)`: status `.failed(reason)`.
- `appLaunched`: if `enabled`, `registerForRemoteNotifications()` (iOS returns the cached token
  promptly, and the 24-hour rule above decides whether to POST). Also `drainInbox`.
- `setEnabled(false)`: persist the flag off, status `.idle`, clear `deviceToken` and
  `lastRegistration` (and the persisted record), `unregisterForRemoteNotifications()`, and a
  best-effort DELETE with `domain: .unregister` whose result is ignored (`unregisterFinished`).
- `hubChanged`: update state; if enabled, rewrite `pushSettings` so the extension proves to the
  right hub.
- `drainInbox`: `drain()` in an effect → `inboxDrained(packets)`; empty → nothing; otherwise
  `.delegate(.inject(packets:))`.

### `ReTiCAPushExtension` — `PushServiceHandler`

One entry point for the NSE:

```swift
public struct PushServiceHandler {
    public init(inbox: PushInbox, settings: SharedPushSettings,
                loadIdentity: @Sendable () -> Identity?,
                sendFrames: @Sendable (_ host: String, _ port: Int, _ frames: [Data]) async -> Void,
                deadline: Duration = .seconds(20))
    public func handle(userInfo: [AnyHashable: Any]) async
}
```

Steps, each best-effort, all within `deadline`:

1. `PushPayload.decode(userInfo)`. Malformed → return.
2. `inbox.append` each packet.
3. `loadIdentity()` (live: `IdentityKeychain` at the shared `Location` from `settings`). nil
   (locked before first unlock, or missing) → return.
4. For each packet, `ProofBuilder.proof(for:identity:deliveryHash:)`; collect the frames.
5. If any frames, `sendFrames(settings.hubHost, settings.hubPort, frames)`. Live `sendFrames`
   opens one `NWConnection` (TCP, no TLS, as the hub interface), writes all frames, waits for the
   sends to complete, cancels. Ten-second timeout, errors swallowed.

The NSE itself (in the app repo) calls `handle` and then always passes the **original**
`bestAttemptContent` to the content handler, also from `serviceExtensionTimeWillExpire`.

Documented limits: link-request packets are stashed but not answered (a link handshake needs the
full transport; the app's background wake reconnects so the sender's next attempt runs over the
socket). IFAC-flagged packets are stashed but not proved by the extension (the extension has no
IFAC key); the app proves them on drain. Neither is in the v1 contract's guarantees.

## 2. Server contract (`docs/server-contract.md`)

### 2.1 Registration API

`POST {base}/v1/registrations` and `DELETE {base}/v1/registrations`, JSON body:

| key | type | notes |
|---|---|---|
| `v` | int | 1 |
| `identity_public_key` | base64 | 64 bytes: X25519 public key ‖ Ed25519 public key (Reticulum identity order) |
| `push_token` | hex | APNs device token bytes |
| `platform` | string | `"ios"` |
| `environment` | string | `"production"` or `"sandbox"` |
| `bundle_id` | string | the registering app's bundle id |
| `issued_at` | int | Unix seconds |
| `signature` | base64 | Ed25519 over the signing bytes below |

Signing bytes, in order, no separators: domain string as UTF-8 (`"retica-push-register-v1"` for
POST, `"retica-push-unregister-v1"` for DELETE), the 64 public-key bytes, the push-token bytes
length as UInt16 big-endian then the bytes, `platform` length as UInt8 then UTF-8,
`environment` length as UInt8 then UTF-8, `bundle_id` length as UInt8 then UTF-8, `issued_at`
as UInt64 big-endian.

Server rules:

- Verify `signature` with the Ed25519 half of `identity_public_key`. Reject otherwise (401).
  **This check is mandatory**: without it anyone can register their own token for someone else's
  destination and receive that person's wake-ups and encrypted packets.
- Reject `issued_at` more than 300 s from server time (400).
- Derive `identity_hash = SHA-256(identity_public_key)[:16]` and
  `destination_hash = SHA-256(SHA-256("lxmf.delivery")[:10] ‖ identity_hash)[:16]`, which is
  `RNS.Destination.hash(identity, "lxmf", "delivery")`.
- POST stores `destination_hash → (push_token, environment, bundle_id, issued_at)`, replacing any
  existing entry for that hash, and answers 200 `{"destination_hash": "<hex>", "expires_at": <unix>}`.
  Registrations expire 30 days after the last POST.
- DELETE removes the entry and the dormant interface, answers 204; unknown hash also 204.
- An APNs 410 (Unregistered) or `BadDeviceToken` drops the entry and its dormant interface.

### 2.2 Transport behaviour

The server runs a Reticulum transport node. Its TCP server interface is the hub the client's app
dials (same host/port the app has under Node Connection). Required behaviour:

- **Binding.** When an announce whose destination hash is a registered `destination_hash` is
  received on a spawned client interface, that interface is bound to the registration. A later
  announce for the same hash on a different spawned interface rebinds to the new one and retires
  the old (dormant or not).
- **Dormancy.** When a bound interface's socket closes, the interface stays attached to the
  transport (paths, reverse table and link table entries that reference it remain valid) and
  becomes dormant. An unbound spawned interface behaves as stock (detached on close).
- **Pushing.** For every outgoing buffer the transport hands a dormant interface: if the packet's
  destination hash equals the bound `destination_hash` (this covers DATA and LINKREQUEST packets
  to the client's delivery destination), push the bytes **exactly as they would have hit the
  socket: after IFAC masking, before HDLC framing**. Any other buffer (announces, path requests,
  link packets addressed by link id, packets for other destinations) is dropped, as the dead
  socket would have dropped it.
- **Proof return.** The client returns proofs on a fresh TCP connection that may never announce.
  Proofs must route by the reverse table regardless of ingress interface. Stock RNS does this.
- **Retries.** A sender retries a single-packet message every 10 s up to five times, each with a
  distinct packet hash. Push every one (the extension proves each; receipts live only 6 s + 6 s/hop),
  but use `apns-collapse-id` so the user sees one banner. A per-destination rate limit (suggested:
  20 pushes/minute) protects the APNs quota.
- **Lifetime.** Dormant interfaces live as long as the registration.

### 2.3 Push shape

Headers: `apns-push-type: alert`, `apns-priority: 10`, `apns-topic: <bundle_id>`,
`apns-collapse-id: <destination_hash hex>`. Environment from the registration.

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
- Packets to one destination that arrive within 500 ms may be batched into one push, at most 8
  packets and 3500 bytes of base64 in total (APNs payload limit is 4 KB).
- Pushes for different registrations are never batched.

### 2.4 Reference implementation note

One paragraph: for the Python stack this is a custom `RNS.Interfaces.Interface` subclass
(a push-aware `TCPServerInterface` whose spawned interfaces implement binding and dormancy, with
`process_outgoing` routing to APNs for dormant ones) plus a small HTTP service for §2.1 and a
token-based APNs client. No change to RNS itself. No code in this deliverable.

## 3. App integration

### 3.1 `AppFeature`

- `State.push: PushFeature.State`, initialised with the identity, bundle id and environment
  (`#if DEBUG` sandbox, else production — the APNs environment follows the signing profile, and
  the app's debug builds use development profiles).
- `Action.push(PushFeature.Action)`, `Scope(state: \.push, action: \.push)`.
- `.push(.delegate(.inject(packets)))`: for each packet,
  `.send(.node(.client(.endpoint(.transport(.received(interfaceID, raw))))))`, where
  `interfaceID = state.node.client.endpoint.tcpClient?.interfaceID ?? InterfaceID("push")`.
  The transport unmasks (plain), dedups on packet hash, decrypts, and `LXMFNode` proves (a no-op
  when the interface is not connected) then routes; the existing `messageReceived` handler stores
  the row. A second proof for a packet the extension already proved is dropped by the sender's
  transport because the receipt is gone.
- `onLaunch`: after the endpoint start effect, `.send(.push(.appLaunched))`.
- `foregrounded`: additionally `.send(.push(.drainInbox))`.
- New `Action.pushWake`: same TCP re-dial as `foregrounded`, then `.send(.push(.drainInbox))`.
- `syncEndpointHostPort` (and wherever `host`/`port` change) also sends
  `.push(.hubChanged(host:port:))`.
- New `Action.pushDeviceToken(Data)` / `pushDeviceTokenFailed(String)` forward to the child.

### 3.2 AppDelegate and runtime

- `ReTiCaMsgrApp` gains `@UIApplicationDelegateAdaptor(AppDelegate.self)`. `AppDelegate` owns the
  `AppRuntime` (built with `.forProcess()`), and the App struct reads `delegate.runtime`.
  `RootView` is unchanged.
- `AppDelegate` implements:
  - `didRegisterForRemoteNotificationsWithDeviceToken` → `store.send(.pushDeviceToken(token))`;
    `didFailToRegisterForRemoteNotificationsWithError` → `.pushDeviceTokenFailed`.
  - `didReceiveRemoteNotification(_:fetchCompletionHandler:)`: `runtime.build()` if no store
    (`build()` is view-independent: AppRuntime.swift:68-96); if there is still no store (Keychain
    `.locked`, identity missing) complete `.noData`. Otherwise `store.send(.pushWake)`, wait up to
    20 s via the continuous clock, complete `.newData`.
  - `UNUserNotificationCenterDelegate.willPresent`: when the app is `.active`, return `[]` and
    `store.send(.push(.drainInbox))`; otherwise return `[.banner, .list, .sound]`.
  - `didReceive(response)`: decode the payload with `PushPayload`, append each packet to the inbox
    (idempotent, so an extension that already stashed them changes nothing), `runtime.build()` if
    needed, `store.send(.pushWake)`. This covers a push whose extension never ran.
- `PushPlatform.liveValue` lives in the app target: `UNUserNotificationCenter.requestAuthorization([.alert, .sound])`,
  `UIApplication.shared.registerForRemoteNotifications()` / `unregisterForRemoteNotifications()`.

### 3.3 Settings

New section **Push Notifications** between Relay and Run as Propagation Node:

- `Toggle("Wake me with push")` bound to `Binding(get: store.push.enabled, set: { store.send(.push(.setEnabled($0))) })`.
- `TextField("Registration URL")` bound to `$store.push.registrationURL`, `.keyboardType(.URL)`,
  no autocapitalisation.
- A status line from `status`: "Off", "Waiting for permission…", "Registering…",
  "Registered <relative date>", or the failure text in red.
- Caption: "Your hub must support ReTiCA push. Notifications only ever say "New message"; nothing
  about the sender or the content leaves the device unencrypted."

### 3.4 Project changes

- `ReTiCaMsgrCore/Package.swift`: add `.package(path: "../../../pods/ReTiCAPush")` and the
  `ReTiCAPush` product to the core target; the core test target also gets `ReTiCAPushCore` for
  building test packets.
- New Xcode target `ReTiCaMsgrNotificationService` (Notification Service Extension, bundle id
  `co.lithobyte.ReTiCaMsgr.NotificationService`), linking the `ReTiCAPushExtension` product of
  the same package. Its `NotificationService.swift` builds `PushServiceHandler` with the live
  Keychain loader and the live `NWConnection` sender and always returns the original content.
- Entitlements:
  - App: `aps-environment` (`development` in the file; Xcode flips it to `production` on
    distribution), `com.apple.security.application-groups = [group.co.lithobyte.ReTiCaMsgr]`,
    existing keychain access group unchanged.
  - Extension: the same application group and the same keychain access group
    `$(AppIdentifierPrefix)co.lithobyte.reticulum.identity`.
- `ReTiCaMsgr/Info.plist`: `UIBackgroundModes` gains `remote-notification`.
- `AppRuntime.Environment` gains the app-group container URL (nil under `.testHost()`).

### 3.5 What does not change

Message rows and `MessageStatus`, `arrivalMethod` (push-delivered packets arrive as
`.opportunistic` through the normal path), the thread and conversation UI, the send path,
propagation sync, the unused `.backgrounded` action, Diagnostics.

### 3.6 Errors

| situation | behaviour |
|---|---|
| Permission denied | status failed with guidance; toggle stays on |
| Token registration fails (no network, no entitlement) | status failed with the system message |
| Registration URL unparsable or server non-2xx | status failed; last record untouched; retried on next launch or token change |
| Push arrives before first unlock | extension stashes only; banner shows; app ingests after unlock on next launch |
| Extension exceeds time or memory | iOS shows the original payload ("New message"); whatever was stashed before the kill is kept |
| Background wake not granted | message is ingested on tap or next launch; proof already sent by the extension |
| Push for a packet the app already received over the socket | transport packet-hash dedup drops it |
| Hub host/port changed while enabled | shared settings rewritten; extension proves to the new hub |

## 4. Testing

Every new test is mutation-verified in one batch per task with a named mutation per test, per the
global rule. All Swift Testing; TestStore with `exhaustivity = .off` unless a test asserts absence.

### `ReTiCAPushCoreTests`

- `PushPayload`: decodes one and many packets; rejects missing `rns`, wrong version, non-array,
  non-base64 entry, oversize entry, more than 8 entries.
- `PushInbox`: append then drain returns in order and empties; re-append of the same bytes is a
  no-op; 257th append evicts the oldest; drain on an empty or missing directory returns `[]`.
- `ProofBuilder`: returns nil for a non-data packet, another destination, an IFAC-flagged first
  byte, and garbage; for a valid packet the unframed proof fed as `.received` into a ReTiCA
  `Transport` TestStore that holds a `PendingReceipt` for that packet yields
  `singlePacketDelivered(token)` (pins the builder to the real validator).
- `DeliveryHash` matches the hash ReTiCA registers for the same identity (`registerDelivery` on an
  `LXMFNode` TestStore, read `deliveryDestinationHash`).
- `PushRegistration`: signing bytes are the documented layout for a fixed fixture; the signature
  verifies with `Identity.validate`; changing any field breaks verification; JSON keys match §2.1.
- `RegistrationClient.live` against a `URLProtocol` stub: 200 succeeds, 401 throws `.server`.

### `ReTiCAPushTests` (`PushFeature`)

- enable → permission granted → `registerForRemoteNotifications` called, status awaiting token.
- enable → permission denied → status failed, `enabled` still true.
- token received, no record → registers, status registered, record persisted.
- token received, same token registered 1 h ago → no POST, status registered with the old date.
- token received, same token registered 25 h ago → POST.
- token changed → POST.
- registration failure → status failed, record unchanged.
- invalid URL → status failed, no POST.
- `appLaunched` enabled → `registerForRemoteNotifications` and drain; disabled → only drain.
- disable → DELETE attempted, unregister called, record cleared, status idle.
- `hubChanged` while enabled rewrites shared settings; while disabled does not.
- drain with packets → `delegate(.inject)`; drain empty → no delegate.

### `ReTiCAPushExtensionTests` (`PushServiceHandler`)

- data packet to our hash: stashed and one framed proof sent to the configured hub.
- packet to another hash, a non-data packet, an IFAC-flagged packet: stashed, nothing sent.
- identity loader returns nil: stashed, nothing sent.
- malformed payload: nothing stashed, nothing sent.
- the frame sender throws or hangs past the deadline: `handle` still returns.

### `ReTiCaMsgrCoreTests` (`AppFeature`)

- `push(.delegate(.inject))` with a packet built for the test identity reaches `messageReceived`
  and a `received` row is stored.
- `pushWake` re-dials TCP when disconnected and drains.
- `onLaunch` sends `push(.appLaunched)`; `foregrounded` drains.
- host/port change forwards `hubChanged`.

### App target and manual

- `AppRuntimeTests`: `build()` from a background-wake path with no scene produces a store.
- Simulator: `xcrun simctl push` with a payload built from a test-generated packet exercises the
  extension (stash and proof attempt) and the drain on tap, with no server.
- Device against a real push-capable hub is the end-to-end check and depends on the server
  existing.

## Out of scope

Server implementation and APNs credentials. Decrypting or summarising content in the extension.
Proving link requests or IFAC-masked packets from the extension. Badge counts. A "via push" marker
on message info. Anything on the sender side. Android or the reference client.
