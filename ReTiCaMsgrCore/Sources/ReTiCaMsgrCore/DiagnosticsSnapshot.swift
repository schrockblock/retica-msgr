import Foundation
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport

/// A read-only, point-in-time view of the app's networking state, arranged as layers so the
/// question "which layer is broken?" has a single visible answer.
///
/// **Pure by construction.** Everything is derived from `AppFeature.State` plus an injected
/// date; nothing here reads a clock, touches the network, or mutates. That is what makes the
/// health rules and the shareable `text` unit-testable.
///
/// **Fields are listed by hand, never reflected.** `text` is designed to be pasted into bug
/// reports, and the state it draws from is full of key material. A `Mirror`-based or "render
/// every property" implementation would leak it the first time someone added a field.
///
/// DENY LIST — none of these may ever appear here or in `text`, in any form:
///   * `LinkSession.State.sessionKey` — the negotiated symmetric key for a live link.
///   * `LinkSession.State.ephemeral` — the per-link X25519/Ed25519 keypair (private half).
///   * `LinkSession.State.owningIdentity` — our LONG-TERM local private key for a served
///     destination. Worse to leak than an ephemeral: it does not rotate with the link.
///   * `InterfaceProfile.ifac` — `IFAC` stores the derived network `key` and the Ed25519
///     `seed`. Leaking it hands over membership of an access-controlled network. Reachable
///     from `socketLayer` via `endpoint.interfaces`, which renders only `name`.
///
/// `textCarriesNoKeyMaterialFromAnyLayer` pins the CLASS, not one field: it plants a distinct
/// recognisable pattern in each of the above and asserts none of them — nor their field
/// names — survives into `text`.
public struct DiagnosticsSnapshot: Equatable {
    public enum Health: Equatable { case ok, warn, problem }

    public struct Row: Equatable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Layer: Equatable {
        public let title: String
        public let health: Health
        /// Why the layer is not `.ok`. Always nil when `.ok`, always non-nil otherwise —
        /// a status without a stated reason is the thing this screen exists to avoid.
        public let reason: String?
        public let rows: [Row]
    }

    public let generatedAt: Date
    public let layers: [Layer]

    public init(from state: AppFeature.State, at date: Date) {
        self.generatedAt = date
        self.layers = [
            Self.socketLayer(state),
            Self.identityLayer(state),
            Self.pathsLayer(state),
            Self.peersLayer(state, at: date),
            Self.linksLayer(state, at: date),
            Self.deliveryLayer(state),
        ]
    }
}

// MARK: - Socket

extension DiagnosticsSnapshot {
    /// DENY LIST: `InterfaceProfile` carries `ifac`, and `IFAC` holds the derived network `key`
    /// and its Ed25519 `seed` — membership credentials for an access-controlled network. Only
    /// `name` is rendered here, and nothing on this layer may ever widen to the whole profile.
    static func socketLayer(_ state: AppFeature.State) -> Layer {
        let endpoint = state.node.client.endpoint
        let interfaces = endpoint.interfaces

        var status = "n/a"
        var dialing = "n/a"
        if case let .tcp(tcp) = endpoint {
            status = describe(tcp.interface.status)
            dialing = "\(tcp.interface.host):\(tcp.interface.port)"
        }
        let app = describe(state.connection)

        let rows = [
            Row("app connection", app),
            Row("interface status", status),
            Row("dialing", dialing),
            Row("interfaces", interfaces.isEmpty
                 ? "(none)"
                 : interfaces
                    .map { "\($0.key.rawValue) (\($0.value.name))" }
                    .sorted()
                    .joined(separator: ", ")),
        ]

        // Order matters: a disagreement must be reported AS a disagreement rather than being
        // masked by the milder "connecting" rule below it.
        let interfaceOnline = status == "online"
        if (app == "connected") != interfaceOnline {
            return Layer(title: "Socket", health: .problem,
                         reason: "app reports \(app), interface reports \(status)", rows: rows)
        }
        if interfaceOnline && interfaces.isEmpty {
            return Layer(title: "Socket", health: .problem,
                         reason: "socket is up but Transport has no registered interface", rows: rows)
        }
        if app == "connecting" {
            return Layer(title: "Socket", health: .warn, reason: "connecting", rows: rows)
        }
        if app == "disconnected" {
            return Layer(title: "Socket", health: .warn, reason: "disconnected", rows: rows)
        }
        return Layer(title: "Socket", health: .ok, reason: nil, rows: rows)
    }

    static func describe(_ status: TCPClientInterface.Status) -> String {
        switch status {
        case .disconnected: return "disconnected"
        case .connecting:   return "connecting"
        case .online:       return "online"
        }
    }

    static func describe(_ connection: AppFeature.Connection) -> String {
        switch connection {
        case .disconnected: return "disconnected"
        case .connecting:   return "connecting"
        case .connected:    return "connected"
        }
    }
}

// MARK: - Paths

extension DiagnosticsSnapshot {
    /// F8 cross-check. `Transport.State.learned` is deliberately NON-destructive: losing an
    /// interface does not purge the paths heard on it, so an entry routinely outlives the
    /// interface it names. `Transport.reachableLearned` is the runtime's version of this test,
    /// and `openLink` gates on it — a path whose interface is gone cannot carry a link.
    static func pathsLayer(_ state: AppFeature.State) -> Layer {
        let endpoint = state.node.client.endpoint
        let interfaces = endpoint.interfaces
        let learned = endpoint.learned

        // `interfaces` is EMPTY whenever the socket is down — every interface deregisters. So the
        // per-path test below is only meaningful when at least one interface remains: with none,
        // it would mark every learned path unreachable and blame a missing interface, when the
        // truth is that the socket is down and Socket has already said so. Reachability is not
        // "no" in that state, it is UNKNOWABLE, and the rows say `?` rather than `NO`.
        //
        // The F8 signal with diagnostic value is a path naming a dead interface WHILE OTHERS ARE
        // UP — that is a stale routing entry, which is a different fault with a different fix.
        let interfacesKnown = !interfaces.isEmpty

        let entries = learned
            .map { hash, entry -> (hash: Data, reachable: Bool?, row: Row) in
                let reachable: Bool? = interfacesKnown ? (interfaces[entry.interfaceID] != nil) : nil
                let next = entry.nextHop.map { $0.hexString } ?? "direct"
                return (hash, reachable, Row(
                    hash.hexString,
                    "hops=\(entry.hops) next=\(next) if=\(entry.interfaceID.rawValue) "
                    + "reachable=\(reachable.map { $0 ? "yes" : "NO" } ?? "?")"))
            }
            .sorted { $0.hash.hexString < $1.hash.hexString }

        let rows = entries.isEmpty ? [Row("(none)", "no paths learned this session")]
                                   : entries.map(\.row)

        guard interfacesKnown else {
            // Nothing to say about paths that Socket has not already said better. Report it
            // honestly rather than green — a reader must not read "Paths ok" as "routes fine" —
            // but do NOT attribute it to a gone interface.
            guard entries.isEmpty else {
                return Layer(title: "Paths", health: .warn,
                             reason: "no interfaces registered — reachability is unknowable "
                                     + "until the socket is back; see Socket",
                             rows: rows)
            }
            return Layer(title: "Paths", health: .ok, reason: nil, rows: rows)
        }

        let unreachable = entries.filter { $0.reachable == false }.count
        guard unreachable == 0 else {
            return Layer(title: "Paths", health: .warn,
                         reason: "\(unreachable) path\(unreachable == 1 ? "" : "s") "
                                 + "name\(unreachable == 1 ? "s" : "") an interface that is gone",
                         rows: rows)
        }
        return Layer(title: "Paths", health: .ok, reason: nil, rows: rows)
    }
}

// MARK: - Peers

extension DiagnosticsSnapshot {
    /// F20 cross-check. `learnedPeers` is persisted by the app; the path table that holds the
    /// peer's IDENTITY and route is not. After a cold launch the Announce tab can list peers
    /// the app cannot message — opportunistic send needs the identity, `openLink` needs the
    /// path. This row names that state instead of leaving it to be inferred from a greyed-out
    /// Send button.
    static func peersLayer(_ state: AppFeature.State, at date: Date) -> Layer {
        let learned = state.node.client.endpoint.learned
        let peers = state.node.client.learnedPeers
        let now = date.timeIntervalSince1970

        let entries = peers
            .map { hash, peer -> (hash: Data, hasPath: Bool, row: Row) in
                let hasPath = learned[hash] != nil
                let cost = peer.stampCost.map(String.init) ?? "-"
                // `heard` is the whole point of the cross-check below: it separates "announced
                // 3s ago and we simply have not filed the path yet" from "restored from disk 40
                // days ago and this peer may not exist any more". Derived from the INJECTED
                // date — a `Date()` here would make the export non-deterministic and untestable.
                return (hash, hasPath, Row(
                    peer.displayName ?? "(unnamed)",
                    "\(hash.hexString) heard=\(age(peer.learnedAt.timeIntervalSince1970, now)) "
                    + "cost=\(cost) path=\(hasPath ? "yes" : "NO")"))
            }
            .sorted { $0.hash.hexString < $1.hash.hexString }

        let rows = entries.isEmpty ? [Row("(none)", "no peers detected")] : entries.map(\.row)
        let pathless = entries.filter { !$0.hasPath }.count
        guard pathless == 0 else {
            return Layer(title: "Peers", health: .warn,
                         reason: "\(pathless) peer\(pathless == 1 ? "" : "s") "
                                 + "\(pathless == 1 ? "has" : "have") no path "
                                 + "— known but not reachable",
                         rows: rows)
        }
        return Layer(title: "Peers", health: .ok, reason: nil, rows: rows)
    }
}

// MARK: - Identity

extension DiagnosticsSnapshot {
    static func identityLayer(_ state: AppFeature.State) -> Layer {
        let registered = state.node.client.deliveryDestinationHash != nil
        let rows = [
            Row("address", state.myAddressHex),
            Row("display name", state.displayName.isEmpty ? "(unset)" : state.displayName),
            Row("delivery registered", registered ? "yes" : "no"),
            Row("node mode", state.nodeModeEnabled ? "on" : "off"),
        ]
        guard registered else {
            return Layer(title: "Identity", health: .problem,
                         reason: "no delivery destination registered — nothing can reach us",
                         rows: rows)
        }
        return Layer(title: "Identity", health: .ok, reason: nil, rows: rows)
    }
}

// MARK: - Links

extension DiagnosticsSnapshot {
    /// Renders a hand-picked set of fields. DENY LIST: `LinkSession.State` also carries
    /// `sessionKey`, an `ephemeral` keypair, and `owningIdentity` — our long-term LOCAL private
    /// key for a served destination. None of the three may appear here or in `text`; see the
    /// deny list on `DiagnosticsSnapshot` itself.
    static func linksLayer(_ state: AppFeature.State, at date: Date) -> Layer {
        let links = state.node.client.endpoint.links
        let now = date.timeIntervalSince1970

        let rows = links.map { link -> Row in
            let role = link.role == .initiator ? "initiator" : "responder"
            let rtt = link.rtt.map { String(format: "%.0fms", $0 * 1000) } ?? "-"
            // `lastInbound` advances on ANY link-addressed packet; `lastData` only on traffic
            // that actually decrypted. Both are shown because the difference distinguishes "a
            // peer is talking to us" from "an AUTHENTICATED peer is talking to us" — and
            // `LinkPlane` evicts responder links in order of `lastData`, not `lastInbound`.
            // `req` is the ONLY age a stalled outbound link has. For an initiator that has not
            // been proved yet, `activatedAt`/`lastInbound`/`lastData` are all nil, so without
            // this the row reads `up=- in=- data=-` and cannot distinguish "requested 1s ago,
            // in flight" from "requested 14s ago, about to blow the deadline" — which is
            // precisely the discrimination the warn below exists to support.
            return Row(link.linkID.hexString,
                       "\(role) \(describe(link.status)) dest=\(link.destinationHash.hexString) "
                       + "rtt=\(rtt) transfers=\(link.transfers.count) "
                       + "req=\(age(link.requestedAt, now)) up=\(age(link.activatedAt, now)) "
                       + "in=\(age(link.lastInbound, now)) data=\(age(link.lastData, now))")
        }

        // An initiator link sitting in `.pending` is establishment in flight — or stalled.
        // `LinkSession.establishmentTimeout` bounds it at 15s.
        //
        // `.pending`, NOT `.handshake`: the two statuses are ROLE-DISJOINT. `LinkSession`
        // assigns `.handshake` in exactly one place — inside `case .acceptRequest`, behind
        // `guard state.role == .responder, state.status == .pending` — so no initiator link is
        // ever in `.handshake`. `case .establish` writes `linkID` and `requestedAt`, transmits,
        // and arms the establishment timer WITHOUT touching `status`, which stays `.pending`
        // until a proof sets `.active`. (`LinkSession`'s own establishment-timeout guard reads
        // `status == .pending || status == .handshake` for the same reason: one state per role.)
        //
        // The original `role == .initiator && status == .handshake` was therefore unsatisfiable,
        // and this layer reported GREEN for every stuck outbound link — the single fault it was
        // added to report.
        let stalled = links.filter { $0.role == .initiator && $0.status == .pending }.count
        guard stalled == 0 else {
            return Layer(title: "Links", health: .warn,
                         reason: "\(stalled) outbound link\(stalled == 1 ? "" : "s") "
                                 + "still establishing",
                         rows: rows)
        }
        return Layer(title: "Links", health: .ok, reason: nil,
                     rows: rows.isEmpty ? [Row("(none)", "no live links")] : rows)
    }

    static func describe(_ status: LinkSession.Status) -> String {
        switch status {
        case .pending:   return "pending"
        case .handshake: return "handshake"
        case .active:    return "active"
        case .closed:    return "closed"
        }
    }

    /// Seconds since a unix-timestamp field, rendered compactly. Uses the INJECTED date, never
    /// a live clock — that is what keeps `text` deterministic under test.
    static func age(_ timestamp: Double?, _ now: Double) -> String {
        guard let timestamp else { return "-" }
        let seconds = max(0, now - timestamp)
        if seconds < 90 { return "\(Int(seconds))s" }
        if seconds < 5400 { return "\(Int(seconds / 60))m" }
        // A day tier, because `learnedPeers` is PERSISTED: a peer restored from disk is routinely
        // weeks old, and "960h" is a number the reader has to do arithmetic on to understand.
        if seconds < 172_800 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

// MARK: - Text export

extension DiagnosticsSnapshot {
    /// Plain-text rendering for the share sheet. Identifiers are FULL here — the on-screen view
    /// truncates for legibility, but a pasted dump gets correlated against rnsd logs and the
    /// other end's client, so it needs the whole hash.
    public var text: String {
        var out = "ReTiCaMsgr diagnostics — \(Self.timestamp.string(from: generatedAt))\n"
        for layer in layers {
            let marker: String
            switch layer.health {
            case .ok:      marker = "ok"
            case .warn:    marker = "warn"
            case .problem: marker = "problem"
            }
            out += "\n\(layer.title.uppercased())  [\(marker)]"
            if let reason = layer.reason { out += " \(reason)" }
            out += "\n"
            for row in layer.rows {
                let label = Self.escaped(row.label)
                // Pad by CHARACTERS. `String.padding(toLength:)` counts UTF-16, so
                // `padding(toLength: max(label.count, 20))` silently TRUNCATED any label whose
                // UTF-16 length exceeded its Character count — a 25-emoji display name came out
                // as 12 emoji and a replacement character. Never truncate: this is an export.
                let padded = label.count < 20
                    ? label + String(repeating: " ", count: 20 - label.count)
                    : label
                out += "  \(padded) \(Self.escaped(row.value))\n"
            }
        }
        return out
    }

    /// Escape anything that could forge structure in the export.
    ///
    /// The only free-text field that reaches here is `peersLayer`'s `peer.displayName`, which is
    /// UNAUTHENTICATED announce data — the library flags `LearnedPeer` as "Unauthenticated,
    /// potentially hostile" — and `LXMFAnnounceData` trims it with `.whitespaces`, which does
    /// NOT include newlines. A hostile peer could therefore embed `\n` in its display name and
    /// forge whole lines (a layer header, a health marker, a reason) in an artifact that gets
    /// pasted into bug reports and read as evidence. U+2028/U+2029 and the C0/C1 control ranges
    /// are covered for the same reason.
    static func escaped(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            default:
                let v = scalar.value
                let isControl = v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v)
                let isLineSeparator = v == 0x2028 || v == 0x2029
                if isControl || isLineSeparator {
                    out.append(contentsOf: String(format: "\\u{%04X}", v).unicodeScalars)
                } else {
                    out.append(scalar)
                }
            }
        }
        return String(out)
    }

    nonisolated(unsafe) static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Delivery

extension DiagnosticsSnapshot {
    /// THE RULE, stated once so each clause can be tested on its own:
    ///
    /// 1. **A pending delivery needs a link only if its OWN method needs one.**
    ///    `pendingDeliveries` is armed by *every* send (`LXMFRouter.arm`), including
    ///    `.opportunistic` — which is packet-addressed and needs no link at all.
    ///    `LXMFRouter.closed` makes the same exclusion when it asks whether link work remains.
    ///    This app sends only opportunistic (`LXMFNode.sendMessage` passes
    ///    `method: .opportunistic`) and there is no delivery receipt for it, so a message sits
    ///    in `pendingDeliveries` for the whole retry saga. Counting those painted Delivery
    ///    yellow for ~40-50s after every message on a perfectly healthy app.
    ///
    /// 2. **`.direct` / `.propagated` are correlated against THEIR OWN destination.**
    ///    "Some link somewhere is active" is not an answer: a message stranded to Bob read
    ///    green because an unrelated link to Alice happened to be up. `ResendInfo` carries
    ///    `destinationHash` in all three cases, so the correlation costs nothing.
    ///
    /// 3. **A destination parked in `.awaitingPath` or `.establishing` warns ON ITS OWN.**
    ///    This is the clause that catches the fault the layer exists for. A `.direct` send with
    ///    no active link never enters `pendingDeliveries` — it goes to `outboundQueue` (which
    ///    is `internal` to the library, so invisible from here) and the destination parks in
    ///    `directLinks`. A rule keyed only off `pendingDeliveries` therefore reported GREEN for
    ///    the entire duration of a failing delivery to an unreachable peer: the "I pressed send
    ///    and nothing happened" symptom, with a green board saying it was not the network.
    ///
    /// Deliberately NOT a clause: an opportunistic send with no path. That is the Paths and
    /// Peers cross-checks' job, and the router runs its own pathless-retry saga for it.
    static func deliveryLayer(_ state: AppFeature.State) -> Layer {
        let router = state.node.client.router

        let linkRows = router.directLinks
            .map { dest, status -> (String, Row) in
                let text: String
                switch status {
                case .awaitingPath:       text = "awaitingPath"
                case .establishing:       text = "establishing"
                // `link=<hex>`, not `active (<hex>)`. The view's `shorten` splits on spaces and
                // hex-tests each token; parentheses make the token fail the hex test, so the
                // full 32-char id escaped truncation on screen. Every other layer emits
                // `key=value`, and parentheses elsewhere in this snapshot mean PLACEHOLDER —
                // `(none)`, `(unset)`, `(unnamed)` — so wrapping real data in them was the
                // inconsistency. Fixed here rather than in the view: it removes a special case.
                case let .active(linkID): text = "active link=\(linkID.hexString)"
                }
                return (dest.hexString, Row(dest.hexString, text))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        let pendingRows = router.pendingDeliveries
            .map { hash, pending -> (String, Row) in
                let (method, dest) = describe(pending.resend)
                return (hash.hexString, Row(hash.hexString,
                                            "method=\(method) dest=\(dest.hexString) "
                                            + "attempts=\(pending.attempts)"))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        var rows = [Row("known paths", String(router.knownPaths.count))]
        rows.append(Row("propagation node",
                        router.outboundPropagationNode?.hexString ?? "(none)"))
        rows.append(contentsOf: linkRows)
        rows.append(contentsOf: pendingRows)

        // Clause 1 + 2.
        let stranded = router.pendingDeliveries.values.filter { pending in
            guard needsLink(pending.resend) else { return false }
            let (_, dest) = describe(pending.resend)
            // A PRECISE enum-case match, not `directLinks[dest] != nil`: a destination that is
            // merely `.establishing` has no link to send on yet.
            if case .active = router.directLinks[dest] { return false }
            return true
        }.count

        // Clause 3.
        let parked = router.directLinks.values.filter { status in
            switch status {
            case .awaitingPath, .establishing: return true
            case .active:                      return false
            }
        }.count

        var clauses: [String] = []
        if stranded > 0 {
            clauses.append("\(stranded) message\(stranded == 1 ? "" : "s") pending "
                           + "with no active link to its destination")
        }
        if parked > 0 {
            clauses.append("\(parked) destination\(parked == 1 ? "" : "s") "
                           + "waiting for a link (awaiting path or establishing)")
        }
        guard clauses.isEmpty else {
            return Layer(title: "Delivery", health: .warn,
                         reason: clauses.joined(separator: "; "), rows: rows)
        }
        return Layer(title: "Delivery", health: .ok, reason: nil, rows: rows)
    }

    /// Exhaustive on purpose: a new `ResendInfo` case must be adjudicated here, not defaulted.
    static func describe(_ resend: LXMFRouter.ResendInfo) -> (method: String, destination: Data) {
        switch resend {
        case let .opportunistic(dest, _): return ("opportunistic", dest)
        case let .direct(dest, _, _):     return ("direct", dest)
        case let .propagated(dest, _):    return ("propagated", dest)
        }
    }

    /// Does this send need a link before it can go out? Exhaustive for the same reason.
    static func needsLink(_ resend: LXMFRouter.ResendInfo) -> Bool {
        switch resend {
        case .opportunistic:       return false   // packet-addressed; no link involved
        case .direct, .propagated: return true
        }
    }
}
