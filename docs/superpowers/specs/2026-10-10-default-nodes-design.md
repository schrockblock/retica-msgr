# Default node, multiple nodes, and the push identity — design

**Date:** 2026-10-10. **Scope:** a ReTiCA change (the endpoint grows from one TCP client slot to a
set) merged first, then the ReTiCaMsgr app (Core package plus SwiftUI), then Nbhd's mechanical
switch updates. **Follows:** the push-relay spec `2026-10-01-push-relay-design.md` (the push hub
contract) and the group-chats work merged 2026-10-10 (main 74d9cb9).

## Goal

A fresh install works with no setup: it connects to the developer's hub at `gaefu.ddns.net` and
uses that hub's push identity. Users can add their own nodes, connect to several at once, and
turn the default off, but nobody has to run or know a node of their own.

## Decisions taken while brainstorming

- **Several nodes at once, not a chooser.** Reticulum runs any number of interfaces; ReTiCA's
  endpoint allowed exactly one TCP client. That slot becomes a set. The user chose this over a
  one-active-node list.
- **The push identity belongs to a node.** The notification extension proves pushed packets over
  its own socket to the hub's host and port, and a hub accepts registrations only over its own TCP
  server's spawned connections (server contract §1.4, `not_direct`). So a push hub is a node entry
  with a destination hex, and exactly one enabled entry is the push node at a time. The separate
  "Push hub destination" field goes away.
- **The default push hex is Gaefu's current registration destination**
  `ef92bcaeb90947a9fc2228affabdce13` (post 2026-10-03), confirmed by the user.
- **Gaefu runs no propagation node today** (checked 2026-10-10: only `rnsd` runs; `lxmd` is
  installed but unconfigured). The user will stand one up separately. The app ships a default
  propagation slot that is empty until that node announces; nothing here waits on it.
- **Node list persistence:** a JSON file through `@Shared(.fileStorage)`, not a database table.
- **The built-in entry can be disabled but not deleted or edited.**
- **Order:** ReTiCA first on its own worktree and merged to its `main`; the app second against the
  merged pod (path dependency); Nbhd third (one line per exhaustive switch, as before).

## 1. ReTiCA: a set of TCP client drivers

In `Sources/ReTiCANode/TransportEndpoint.swift`:

- `State.tcpClient: TCPEndpoint.State?` becomes `tcpClients: IdentifiedArrayOf<TCPEndpoint.State>`.
  `TCPEndpoint.State` conforms to `Identifiable` with `id == interfaceID`.
- `Action.tcpClient(TCPEndpoint.Action)` becomes `tcpClients(IdentifiedActionOf<TCPEndpoint>)`,
  composed with `.forEach(\.tcpClients, action: \.tcpClients) { TCPEndpoint() }` in place of `ifLet`.
- Wiring generalises by id:
  - `.start` sends `.connect` to every client; `.stop` sends `.disconnect` to every client.
  - `.tcpClients(.element(id, .interface(.delegate(.packetReceived(data)))))` →
    `.transport(.received(id, data))`.
  - `.tcpClients(.element(id, .interface(.connectionEvent(.connected))))` → register `id` with the
    driver's profile, plus the maintenance-start effect.
  - `.tcpClients(.element(id, .interface(.connectionEvent(.disconnected))))` and the explicit
    `.tcpClients(.element(id, .disconnect))` arm → deregister that one id from the router and the
    link plane (the explicit arm only when `transport.interfaces[id] != nil`), plus the
    maintenance-stop effect for that id.
  - `transmit` looks `txID` up in `tcpClients` and sends `.tcpClients(.element(id, .interface(.send(masked))))`.
- The shared router, link plane, maintenance loop, IFAC masking, server slot and BLE slot are
  untouched: they already handle N interfaces.
- `TCPEndpoint.State.init` keeps `interfaceID:` but drops its `"tcp"` default; every caller passes
  a distinct id. The app uses `InterfaceID("tcp:<host>:<port>")`, so "is this node up" is a lookup
  in `transport.interfaces`.
- `State.tcp(_ driver:)` stays as a one-client factory. `tcpServer(_:)` and `ble(_:)` are unchanged.
- Per-driver semantics stay: reconnect on drop is per client; an explicit disconnect deregisters
  only that interface; paths and links are per interface.
- Call sites that move to the set: the app's `AppFeature.swift` and `DiagnosticsSnapshot.swift`,
  Nbhd's `MeshClientLive.swift` and `MeshRootTests.swift`.

### ReTiCA tests (`TransportEndpointTests`)

Two clients connect and both register with the router; a packet received on one arrives tagged
with its id; `transmit` routes to the owning client; one client's explicit disconnect deregisters
only its interface and closes only its links; the maintenance loop stops only when the last
interface across all drivers departs; the `tcp(_:)` factory yields a one-element set.

## 2. Node entries and defaults (app, Core)

### `NodeEntry`

`Codable`, `Identifiable`, `Equatable`, `Sendable`:

| field | type | notes |
|---|---|---|
| `id` | UUID | fixed for the built-in entry |
| `name` | String | |
| `host` | String | non-empty |
| `port` | Int | 1…65535 |
| `enabled` | Bool | |
| `isBuiltIn` | Bool | true only for the default entry |
| `pushHubHex` | String? | 32 hex when present; at most one enabled entry has one |

`var interfaceID: InterfaceID { InterfaceID("tcp:\(host):\(port)") }`.

Persisted as a JSON array at `<Application Support>/nodes.json` through
`@Shared(.fileStorage(...))` on `AppFeature.State` (`nodes: [NodeEntry]`).

### `DefaultNode` (Core constants)

- `id`: a fixed UUID literal.
- `name` `Gaefu`, `host` `gaefu.ddns.net`, `port` 4242, `pushHubHex` `ef92bcaeb90947a9fc2228affabdce13`.
- `entry`: the `NodeEntry` built from those, `enabled: true`, `isBuiltIn: true`.
- `propagationHex: String? = nil` until Gaefu's propagation node announces; then its LXMF address.

### Rules

- The built-in entry is in every list. A fresh install's list is `[DefaultNode.entry]`. It can be
  disabled but never deleted or edited (only `enabled` changes).
- User entries: added with name, host, port and an optional push hex; edited; disabled; deleted.
- **One push node:** setting a push hex on one entry clears it on every other entry.
- **The push node** is the enabled entry whose `pushHubHex` is non-nil. Its host and port feed the
  push feature's `hubChanged`, its hex feeds `setHubHex`. With no such entry, push is off and the
  Settings row says so.
- **Propagation node:** the global `propagationNodeHex` stays, plus a new
  `usePropagationDefault: Bool` (app storage, default true) that only has effect while
  `DefaultNode.propagationHex` is non-nil: then the default is used and the stored hex is ignored.

### Upgrade migration

Runs once, at launch, when `nodes.json` does not exist:

1. Start with `[DefaultNode.entry]`.
2. Read the old `host`/`port` app-storage keys. If they differ from the built-in and from
   `127.0.0.1:4242`, append a user entry named after the host, enabled.
3. Read the old `pushHubHex`. If non-empty and not the default hex, attach it to the user entry
   from step 2, or to a new entry `host:port` from step 2's values if none was created there (a
   custom hex with the default host means the user's hub is Gaefu itself: attach it to the built-in
   entry instead, replacing the default hex for that user).
4. Write the list. The old keys are never read again.

## 3. Reducer wiring (app)

- **Endpoint sync.** `syncEndpointHostPort` becomes `syncEndpointNodes`: for every enabled entry
  ensure a client slot with its `interfaceID` exists (built as
  `TCPEndpoint.State(host:port:reconnectOnDrop: true, interfaceID:)`); remove slots whose entry is
  gone, disabled or edited, sending each an explicit `.disconnect` first; keep matching live
  slots as they are so a re-dial never tears down a live socket. Listener and BLE handling unchanged.
- **Connect, launch, foreground.** `.onLaunch` and `.connectTapped` sync then `.start`.
  `.foregrounded`'s `redialIfTCPDown` becomes per node: every enabled entry whose `interfaceID` is
  absent from `connectedInterfaces` gets `.tcpClients(.element(id, .connect))`; live ones are left
  alone. `.backgrounded` disconnects every client slot.
- **Connection state.** `connection` stays "any interface up". Settings shows a dot per node from
  `connectedInterfaces`.
- **Push.** The push node's host and port feed `hubChanged`; the registration guard waits for the
  push node's interface id instead of "the TCP interface"; the push inject fallback prefers the
  push node's id when its slot exists, else `pushFallbackInterface`. Any change of the push node
  (toggle, edit, delete, hex change) re-sends `hubChanged` and `setHubHex`; the existing "registers
  on next launch" rule applies.
- **Node actions.** `addNode(name:host:port:pushHubHex:)`, `updateNode(NodeEntry)`,
  `removeNode(id)`, `setNodeEnabled(id, Bool)`. Each validates (non-empty host, port 1…65535, hex
  32 characters when present; the built-in entry accepts only `setNodeEnabled`), writes the list,
  enforces one push node, re-syncs the endpoint (connecting a newly enabled node at once,
  disconnecting a disabled or removed one), and re-points push when the push node changed.
- **Reachability seeding** is already per interface on `interfaceConnected`; the group dispatcher
  and the push drain keep working per interface. Nothing changes there.
- **Diagnostics** lists every client slot with its state instead of one host.

## 4. UI (app)

- **Settings "Nodes" section** replaces "Node Connection": one row per entry with a connection
  dot, the name, `host:port` beneath, a "Push" tag on the push node, and an enabled toggle. The
  built-in row reads "Gaefu (default)" and has only the toggle. Tapping a user row opens the edit
  form; swipe to delete. "Add node" opens the form blank. Connect and Disconnect stay below the
  list and act on all enabled nodes. Footer when no node is enabled: the app reaches peers only
  over Bluetooth or direct connections.
- **Node form:** name, host, port, optional "Push hub destination (32 hex)" with the existing
  explanatory text, Save disabled until valid; saving a hex says it replaces the current push node.
- **Push section:** the hex field goes; shows the push node's name with the status line, or "No
  push node. Add a push hub destination to a node to enable wake-ups." with the toggle disabled.
- **Propagation Node section:** gains "Use the default node's propagation node", shown only when
  `DefaultNode.propagationHex` is set, above the hex field, which is disabled while the toggle is on.
- **Diagnostics:** each node's interface and state.
- The UI rule holds: every custom tappable row carries `.frame(maxWidth: .infinity, alignment:
  .leading)` and `.contentShape(Rectangle())`.

## 5. Testing

- **ReTiCA:** as in §1.
- **Core tests:** `NodeEntry` JSON round-trip; `DefaultNode.entry` has the fixed id, host, port and
  hex; the migration creates a user entry from a custom host and attaches a custom hex, skips
  `127.0.0.1:4242`, attaches a custom hex with the default host to the built-in entry, and never
  runs twice; one-push-node enforcement; validation rejects an empty host, port 0 and 70000, and a
  31-character hex; the built-in entry refuses edit and delete; `syncEndpointNodes` adds a slot per
  enabled entry, keeps a matching live slot, removes a disabled one with a disconnect first; the
  foreground re-dial connects only nodes that are down; `backgrounded` disconnects every client;
  the push node's host, port and hex reach the push feature and clearing it disables push; the
  propagation toggle takes effect only when the default exists.
- **Mutation coverage:** one named mutation per test, listed in the plan, per the project rule.
- **App target:** build plus a Simulator check of the Nodes section, the form, and the push row.

## Order of work

1. ReTiCA on a worktree and branch, merged to ReTiCA `main`.
2. The app on a worktree against the merged pod (`CORE/Package.swift` resolves `../../../pods/ReTiCA`).
3. Nbhd: the exhaustive-switch lines its build needs after the ReTiCA merge.
4. Separately: `lxmd` as a propagation node on Gaefu, one command at a time with a verification
   read between steps (see the 2026-10-03 incident in memory). When it announces, set
   `DefaultNode.propagationHex` in a follow-up commit.

## Out of scope

- More than one push node at a time.
- Per-node propagation nodes.
- Editing the built-in entry's host, port or hex.
- Discovering nodes from announces.
- IFAC per node.
- Removing the old `host`/`port`/`pushHubHex` storage keys (they are simply no longer read).

## Amendments at planning time (2026-10-10)

Found while writing `docs/superpowers/plans/2026-10-10-default-nodes.md` against the code. Each
records a departure from, or a resolution of, the text above.

- **A1. One socket per client.** `TCPConnection.liveValue` builds ONE `NWConnectionActor` and
  captures it in `open`/`send`/`close`; `open` tears down the previous connection. Two
  `TCPClientInterface`s sharing that value would close each other's socket and `send` to
  whichever dialed last. ReTiCA gains a `TCPConnectionPool` dependency (`\.tcpConnectionPool`)
  keyed by `TCPClientInterface.State.connectionKey` (`"host:port"`); the live pool memoizes one
  live `TCPConnection` per key, and the test default forwards every key to the injected
  `\.tcpConnection`, so every existing single-client mock keeps working unchanged.
- **A2. Slot removal is a ReTiCA verb.** `TransportEndpoint.Action.removeTCPClient(InterfaceID)`
  deregisters the interface from the router and link plane (when registered, with the maintenance
  rule), removes the element (TCA 1.26's `forEach` cancels the element's effects itself: the
  connection stream, the reconnect timer and the writer), and closes that client's socket through
  the pool. The app's `syncEndpointNodes` sends it for every slot whose entry is gone, disabled or
  edited, and `.concatenate`s those sends before any `.start`/`.connect`, so a removal is reduced
  before a dial can reach the departing slot. §1's "explicit disconnect" arm stays for `.stop`
  and `.backgrounded`.
- **A3. `TCPEndpoint.State.init` keeps its `interfaceID: InterfaceID("tcp")` default.** Dropping
  it would touch 57 construction sites (ReTiCA tests, Nbhd) for a nudge the app does not need:
  the app builds every id from `host:port`, and an `IdentifiedArray` literal traps on a duplicate.
- **A4. Test fan-out in ReTiCA.** About 140 lines in 20 ReTiCA test files match the
  `.tcpClient(...)` action shape; they are rewritten mechanically (plan Task R2 lists the rules).
- **A5. Migration trigger.** With `@Shared(.fileStorage)` the observable is the loaded list, so
  the migration runs when `nodes.isEmpty`. The built-in entry is in every written list, so empty
  means "never written".
- **A6. Legacy keys.** `AppFeature.State.host`/`port` become internal `legacyHost`/`legacyPort`
  (same `@Shared(.appStorage)` keys, read only by the migration); `State.init(host:port:)` loses
  those parameters. `PushFeature.State.hubHex` stays the push feature's own storage; the migration
  reads the legacy hex from it, and the app keeps it equal to the push node's hex through
  `setHubHex`. A legacy hex is attached only when it is 32 hex characters.
- **A7. Push wiring is a sync, not a diff.** After launch, connect, a re-dial and every node
  action, the app sends `hubChanged(host:port:)` for the push node (`""`/`0` when there is none)
  and `setHubHex` only when the push node's hex differs from what the push feature holds (every
  `setHubHex` counts as a hub change there). With no push node the hex is cleared, so the push
  feature fails closed ("Invalid push hub address"); the stored `pushEnabled` is left alone.
- **A8. The endpoint starts with no TCP client.** `State.init` builds the service node over
  `TransportEndpoint.State()`; `syncEndpointNodes` populates the set at launch, connect, foreground
  and after node actions.
- **A9. Default propagation hex as a dependency.** `\.defaultPropagationHex` (live value
  `DefaultNode.propagationHex`, test value nil) feeds `State.effectivePropagationNodeHex`, so the
  toggle rule is testable with and without a default. Turning the default off with an empty stored
  hex leaves the router on its current node until relaunch (there is no clear verb), as today.
- **A10. Foreground connection state.** The re-dial sets `connection = .connecting` only when no
  interface is up, so a live node or BLE peer keeps the app "connected" while another node
  re-dials. (§3 "any interface up" applied consistently; the old code set connecting regardless.)
- **A11. Diagnostics socket rows.** One row per client slot, `node <host:port>` with its status,
  `nodes (none enabled)` when the set is empty; the disagreement reason reads
  `app reports X, nodes report host:port=status, …`.
- **A12. Link plane on disconnect.** `LinkPlane.interfaceDisconnected` does not close links; it
  marks that interface's links `rehomePermitted`. §1's test asserts that, per interface.

## Amendments at the final review (2026-10-11)

Rulings made by the executing session on the whole-branch review's two Important findings;
the user can revert either.

- **A13. The built-in entry regains its hex.** When no entry carries a push hex (the user deleted
  their push node or cleared its hex), the app gives the built-in entry `DefaultNode.pushHubHex`
  back. The user still never edits the built-in entry; the app restores it. A disabled entry that
  still carries a hex counts as carrying one, so disabling one's own push node does not hand push
  to Gaefu, deleting it does. Without this, saving a hex on any user node cleared Gaefu's hex for
  good and there was no visible way back to the default push identity.
- **A14. Push turns off with its node.** When the push node disappears while push is enabled, the
  app sends `setEnabled(false)` before it clears the hub hex (§2 "with no such entry, push is
  off"), which unregisters from APNs so wakes stop and makes a best-effort `/unregister` with the
  old hub. The Settings toggle is disabled only when there is no push node AND push is already
  off, so it can always be turned off. A push-node switch to another hub does not unregister from
  the old hub; it expires on its own (deferred).
