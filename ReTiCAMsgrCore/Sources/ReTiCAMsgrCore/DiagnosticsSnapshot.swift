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
///   * The MeshCore channel key and its retired keys, in any wrapper: `MeshCoreKeyText`,
///     `MeshCoreSecrets`, or anything `MeshCoreKeyStore` returns, and no fingerprint of any key.
///     `meshCoreLayer` renders only `MeshCoreKeyPresence` and never reads the key store.
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
        var layers = [
            Self.socketLayer(state),
            Self.bleLayer(state),
            Self.meshtasticLayer(state),
        ]
        if state.meshCoreAvailable {
            layers.append(Self.meshCoreLayer(state))
        }
        if state.rnodeAvailable {
            layers.append(Self.rnodeLayer(state))
        }
        layers += [
            Self.identityLayer(state),
            Self.pathsLayer(state),
            Self.peersLayer(state, at: date),
            Self.linksLayer(state, at: date),
            Self.deliveryLayer(state),
        ]
        self.layers = layers
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
        let clients = endpoint.tcpClients
        let app = describe(state.connection)

        var rows = [Row("app connection", app)]
        if clients.isEmpty {
            rows.append(Row("nodes", "(none enabled)"))
        }
        // One row per node slot, in dial order: what the app is dialing and how that socket is.
        for client in clients {
            rows.append(Row("node \(client.interface.host):\(client.interface.port)",
                            describe(client.interface.status)))
        }
        rows.append(Row("interfaces", interfaces.isEmpty
                        ? "(none)"
                        : interfaces
                            .map { "\($0.key.rawValue) (\($0.value.name))" }
                            .sorted()
                            .joined(separator: ", ")))

        // Order matters: a disagreement must be reported AS a disagreement rather than being
        // masked by the milder "connecting" rule below it. "Online" is any node's socket up.
        let interfaceOnline = clients.contains { $0.interface.status == .online }
        let nodesReport = clients.isEmpty
            ? "none"
            : clients.map { "\($0.interface.host):\($0.interface.port)=\(describe($0.interface.status))" }
                     .joined(separator: ", ")
        if (app == "connected") != interfaceOnline {
            return Layer(title: "Socket", health: .problem,
                         reason: "app reports \(app), nodes report \(nodesReport)", rows: rows)
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

// MARK: - Bluetooth

extension DiagnosticsSnapshot {
    /// BLE was invisible on this screen before A4-diagnostics: `endpoint.interfaces` surfaced per-peer
    /// `ble:` interface IDs, but nothing named the adapter state or the connected peers as such. This
    /// layer renders both, and — since S6 — the PRECISE terminal cause (permission denied / no radio)
    /// as a problem with an actionable reason, rather than the old combined "is Bluetooth on?" guess.
    ///
    /// DENY LIST: the only BLE identifiers rendered are session TOKENS (embedded in the `ble:`
    /// interface IDs) — on-wire HELLO handshake values, advertised in the clear by design, NOT key
    /// material. `InterfaceProfile` (which carries `ifac`) is never rendered here.
    static func bleLayer(_ state: AppFeature.State) -> Layer {
        let enabled = state.bleEnabled
        let status = state.node.client.endpoint.ble?.ble.status
        let maxPeers = state.node.client.endpoint.ble?.ble.maxPeers

        // Connected BLE peers are the `ble:`-prefixed registered interfaces (one per online peer).
        let blePeerIDs = state.node.client.endpoint.interfaces.keys
            .map(\.rawValue)
            .filter { $0.hasPrefix("ble:") }
            .sorted()

        var rows = [Row("bluetooth", enabled ? "on" : "off")]
        if enabled {
            rows.append(Row("interface status", status.map(describe) ?? "n/a (starts on Connect)"))
            if let maxPeers { rows.append(Row("peer cap", String(maxPeers))) }
            rows.append(Row("connected peers", blePeerIDs.isEmpty ? "(none)" : String(blePeerIDs.count)))
            rows.append(contentsOf: blePeerIDs.map { Row($0, "connected") })
        }

        guard enabled else {
            // Off by choice is not a fault.
            return Layer(title: "Bluetooth", health: .ok, reason: nil, rows: rows)
        }

        switch status {
        case .unavailable(.unauthorized):
            return Layer(title: "Bluetooth", health: .problem,
                         reason: "Bluetooth permission denied — allow it for this app in Settings",
                         rows: rows)
        case .unavailable(.unsupported):
            return Layer(title: "Bluetooth", health: .problem,
                         reason: "this device has no Bluetooth LE radio", rows: rows)
        case .unavailable:
            // `.poweredOff`/`.other` are transient causes that never reach the terminal status, but
            // the switch is exhaustive rather than defaulted — a new terminal cause must be adjudicated.
            return Layer(title: "Bluetooth", health: .problem,
                         reason: "Bluetooth adapter unavailable", rows: rows)
        case .waitingForAdapter:
            return Layer(title: "Bluetooth", health: .warn,
                         reason: "waiting for the Bluetooth adapter — is Bluetooth turned on?",
                         rows: rows)
        case .stopped, .starting, .online, .none:
            return Layer(title: "Bluetooth", health: .ok, reason: nil, rows: rows)
        }
    }

    static func describe(_ status: BLEInterfaceStatus) -> String {
        switch status {
        case .stopped:                    return "stopped"
        case .starting:                   return "starting"
        case .online:                     return "online"
        case .waitingForAdapter:          return "waiting for adapter"
        case let .unavailable(cause):     return "unavailable (\(describe(cause)))"
        }
    }

    /// Renders the cause NAME only — never the `.other` diagnostic payload, to keep rows bounded and
    /// free of arbitrary text in the shareable export.
    static func describe(_ cause: BLEAdapterUnavailable) -> String {
        switch cause {
        case .poweredOff:   return "powered off"
        case .unauthorized: return "unauthorized"
        case .unsupported:  return "unsupported"
        case .other:        return "other"
        }
    }
}

// MARK: - Meshtastic

extension DiagnosticsSnapshot {
    /// The Meshtastic radio (spec 2026-10-16 §7 lane D), fed from `AppFeature.State.meshtasticStatus`.
    ///
    /// UNTRUSTED TEXT: the radio's advertised name (`meshtasticRadioLabel`) and the `.other`
    /// adapter payload are rendered in ROWS only, which `text` escapes. Never in `reason`, which
    /// it does not (`meshDiagAHostileRadioNameCannotForgeLines`). Unlike `bleLayer`, the `.other`
    /// payload IS shown: Contract 2's loud "ReTiCAMeshtasticLive not installed" lives there.
    static func meshtasticLayer(_ state: AppFeature.State) -> Layer {
        let title = "Meshtastic"
        let enabled = state.meshtasticEnabled
        var rows = [Row("meshtastic", enabled ? "on" : "off")]
        guard enabled else {
            // Off by choice is not a fault.
            return Layer(title: title, health: .ok, reason: nil, rows: rows)
        }

        let status = state.meshtasticStatus
        let radio = state.meshtasticRadioUUID
        rows.append(Row("radio", radio == nil ? "(none chosen)" : state.meshtasticRadioLabel))
        if let radio { rows.append(Row("radio id", radio.uuidString)) }
        rows.append(Row("status", status.online ? "online" : "offline"))
        if let reason = status.offlineReason { rows.append(Row("offline reason", reason)) }
        if let cause = status.adapterUnavailable { rows.append(Row("adapter", describeMeshtastic(cause))) }
        if let node = status.myNodeNum { rows.append(Row("node", meshtasticNodeName(node))) }
        rows.append(Row("preset", meshtasticPresetName(status.modemPreset)))
        let counters = status.counters
        rows.append(contentsOf: [
            Row("reassembled", String(counters.completed)),
            Row("malformed", String(counters.malformed)),
            Row("evicted", String(counters.evicted)),
            Row("timed out", String(counters.timedOut)),
            Row("oversize", String(counters.oversize)),
            Row("queue full", String(counters.queueFull)),
            Row("send failed", String(counters.sendFailed)),
        ])

        return radioLinkLayer(title: title, rows: rows, radioChosen: radio != nil,
                              adapterUnavailable: status.adapterUnavailable != nil, online: status.online)
    }

    /// The health checks every radio layer ends with, first match wins: no radio chosen, then the
    /// Bluetooth path unavailable, then the radio offline, else ok. The reasons are fixed text:
    /// nothing from the radio (its name, an `.other` payload) may reach them.
    private static func radioLinkLayer(title: String, rows: [Row], radioChosen: Bool,
                                       adapterUnavailable: Bool, online: Bool) -> Layer {
        guard radioChosen else {
            return Layer(title: title, health: .warn,
                         reason: "no radio chosen — choose one in Settings", rows: rows)
        }
        if adapterUnavailable {
            return Layer(title: title, health: .problem,
                         reason: "the Bluetooth path to the radio is unavailable", rows: rows)
        }
        guard online else {
            return Layer(title: title, health: .warn, reason: "radio not connected", rows: rows)
        }
        return Layer(title: title, health: .ok, reason: nil, rows: rows)
    }

    /// The cause name, and for `.other` its payload too (see `meshtasticLayer`).
    static func describeMeshtastic(_ cause: BLEAdapterUnavailable) -> String {
        switch cause {
        case .poweredOff:          return "powered off"
        case .unauthorized:        return "unauthorized"
        case .unsupported:         return "unsupported"
        case let .other(detail):   return detail.map { "other: \($0)" } ?? "other"
        }
    }

    /// Meshtastic's own node naming: `!` and 8 lowercase hex digits.
    static func meshtasticNodeName(_ num: UInt32) -> String {
        String(format: "!%08x", num)
    }

    /// The preset's name and raw value. Raw values from spec Contract 3's table
    /// (`Config.LoRaConfig.ModemPreset`). A value this build does not know shows raw.
    static func meshtasticPresetName(_ raw: Int?) -> String {
        guard let raw else { return "unknown" }
        let names = [0: "LongFast", 1: "LongSlow", 3: "MediumSlow", 4: "MediumFast",
                     5: "ShortSlow", 6: "ShortFast", 7: "LongModerate", 8: "ShortTurbo"]
        return names[raw].map { "\($0) (\(raw))" } ?? "unknown (\(raw))"
    }
}

// MARK: - MeshCore

extension DiagnosticsSnapshot {
    /// The MeshCore radio (spec 2026-11-07 §6), fed from `AppFeature.State.meshCoreStatus`. Present
    /// only while the Release gate (`meshCoreAvailable`) is on.
    ///
    /// DENY LIST: the channel key. Only `meshCoreKeyPresence` is rendered; this layer never reads
    /// `MeshCoreKeyStore` (`mcDiagTextCarriesNoChannelKey`).
    ///
    /// UNTRUSTED TEXT: the advertised name from the picker (`meshCoreRadioLabel`), the radio's own
    /// name (`radioName`) and the `.other` adapter payload are rendered in ROWS only, which `text`
    /// escapes. Never in `reason`, which it does not (`mcDiagAHostileRadioNameCannotForgeLines`).
    static func meshCoreLayer(_ state: AppFeature.State) -> Layer {
        let title = "MeshCore"
        let enabled = state.meshCoreEnabled
        let status = state.meshCoreStatus
        var rows = [Row("meshcore", enabled ? "on" : "off")]
        guard enabled else {
            // Off by choice is not a fault. A turn-off that couldn't clear our slot is still worth
            // a row: the radio keeps the channel until the user removes it.
            if status.channelLeftOnRadio { rows.append(Row("channel left on radio", "yes")) }
            return Layer(title: title, health: .ok, reason: nil, rows: rows)
        }

        let presence = state.meshCoreKeyPresence
        let radio = state.meshCoreRadioUUID
        rows.append(Row("channel key", describe(presence)))
        rows.append(Row("radio", radio == nil ? "(none chosen)" : state.meshCoreRadioLabel))
        if let radio { rows.append(Row("radio id", radio.uuidString)) }
        rows.append(Row("status", status.online ? "online" : "offline"))
        rows.append(Row("radio name", status.radioName ?? "unknown"))
        rows.append(Row("LoRa", status.params.map(describe) ?? "unknown"))
        rows.append(Row("firmware code", status.firmwareCode.map { String($0) } ?? "unknown"))
        rows.append(Row("channel slot", status.channelSlot.map { String($0) } ?? "unknown"))
        if let reason = status.offlineReason { rows.append(Row("offline reason", reason)) }
        if let cause = status.adapterUnavailable { rows.append(Row("adapter", describeMeshtastic(cause))) }
        let counters = status.counters
        rows.append(contentsOf: [
            Row("reassembled", String(counters.completed)),
            Row("malformed", String(counters.malformed)),
            Row("not addressed", String(counters.notAddressed)),
            Row("evicted", String(counters.evicted)),
            Row("timed out", String(counters.timedOut)),
            Row("oversize", String(counters.oversize)),
            Row("queue full", String(counters.queueFull)),
            Row("send failed", String(counters.sendFailed)),
            Row("announces limited", String(counters.announcesLimited)),
            Row("path requests limited", String(counters.pathRequestsLimited)),
        ])

        switch presence {
        case .present:
            break
        case .absent:
            return Layer(title: title, health: .warn,
                         reason: "no channel key — set one in Settings", rows: rows)
        case .unreadable:
            return Layer(title: title, health: .warn, reason: "the channel key can't be read", rows: rows)
        }
        return radioLinkLayer(title: title, rows: rows, radioChosen: radio != nil,
                              adapterUnavailable: status.adapterUnavailable != nil, online: status.online)
    }

    static func describe(_ presence: MeshCoreKeyPresence) -> String {
        switch presence {
        case .present:    return "set"
        case .absent:     return "not set"
        case .unreadable: return "can't be read"
        }
    }

    /// `SF10 / 250 kHz / CR5`. A bandwidth that isn't a whole number of kHz keeps its fraction
    /// (`62.5 kHz`).
    static func describe(_ params: MeshCoreStatus.LoRaParams) -> String {
        let hz = params.bandwidthHz
        let khz = hz % 1000 == 0 ? String(hz / 1000) : String(Double(hz) / 1000)
        return "SF\(params.spreadingFactor) / \(khz) kHz / CR\(params.codingRate)"
    }
}

// MARK: - RNode

extension DiagnosticsSnapshot {
    /// The RNode radio (spec 2026-11-08 §6), fed from `AppFeature.State.rnodeStatus` and the stored
    /// settings. Present only while the Release gate (`rnodeAvailable`) is on.
    ///
    /// UNTRUSTED TEXT: the advertised name from the picker (`rnodeRadioLabel`), the radio's own name
    /// (`radioName`), its firmware string and the `.other` adapter payload are rendered in ROWS only,
    /// which `text` escapes. Never in `reason`, which it does not
    /// (`rnDiagAHostileRadioNameCannotForgeLines`).
    static func rnodeLayer(_ state: AppFeature.State) -> Layer {
        let title = "RNode"
        let enabled = state.rnodeEnabled
        var rows = [Row("rnode", enabled ? "on" : "off")]
        guard enabled else {
            // Off by choice is not a fault.
            return Layer(title: title, health: .ok, reason: nil, rows: rows)
        }

        let status = state.rnodeStatus
        let settings = state.rnodeSettings
        let radio = state.rnodeRadioUUID
        rows.append(Row("settings", settings.frequencyHz == nil ? "incomplete" : describe(settings)))
        rows.append(Row("radio", radio == nil ? "(none chosen)" : state.rnodeRadioLabel))
        if let radio { rows.append(Row("radio id", radio.uuidString)) }
        rows.append(Row("status", status.online ? "online" : "offline"))
        rows.append(Row("radio name", status.radioName ?? "unknown"))
        rows.append(Row("firmware", status.firmware ?? "unknown"))
        rows.append(Row("platform", rnodePlatformName(status.platform)))
        rows.append(Row("reported", status.reported.map(describe) ?? "unknown"))
        rows.append(Row("bitrate", status.bitrate.map { "\($0) bps" } ?? "unknown"))
        rows.append(Row("last RSSI", status.lastRSSI.map { "\($0) dBm" } ?? "unknown"))
        rows.append(Row("last SNR", status.lastSNR.map { String(format: "%.2f dB", $0) } ?? "unknown"))
        rows.append(Row("channel load", rnodePercentPair(status.channelLoadShort, status.channelLoadLong)))
        rows.append(Row("airtime", rnodePercentPair(status.airtimeShort, status.airtimeLong)))
        rows.append(Row("noise floor", status.noiseFloor.map { "\($0) dBm" } ?? "unknown"))
        if let reason = status.offlineReason { rows.append(Row("offline reason", reason)) }
        if let cause = status.adapterUnavailable { rows.append(Row("adapter", describeMeshtastic(cause))) }
        if let code = status.lastHardwareError {
            rows.append(Row("last hardware error", rnodeHardwareErrorName(code)))
        }
        let counters = status.counters
        rows.append(contentsOf: [
            Row("received", String(counters.received)),
            Row("sent", String(counters.sent)),
            Row("oversize", String(counters.oversize)),
            Row("queue full", String(counters.queueFull)),
            Row("send failed", String(counters.sendFailed)),
            Row("hardware errors", String(counters.hardwareErrors)),
        ])

        guard state.rnodeSettingsProblems.isEmpty else {
            return Layer(title: title, health: .warn,
                         reason: "radio settings incomplete — set them in Settings", rows: rows)
        }
        return radioLinkLayer(title: title, rows: rows, radioChosen: radio != nil,
                              adapterUnavailable: status.adapterUnavailable != nil, online: status.online)
    }

    /// `868.1 MHz / 62.5 kHz / SF8 / CR6 / 0 dBm`.
    static func describe(_ params: RNodeStatus.Params) -> String {
        "\(RNodeRadioSettings.megahertzText(params.frequencyHz)) MHz"
            + " / \(RNodeRadioSettings.kilohertzText(params.bandwidthHz)) kHz"
            + " / SF\(params.spreadingFactor) / CR\(params.codingRate) / \(params.txPowerDBm) dBm"
    }

    /// The stored settings in `describe(_: RNodeStatus.Params)`'s form; the caller shows `incomplete`
    /// while there is no frequency.
    static func describe(_ settings: RNodeRadioSettings) -> String {
        describe(RNodeStatus.Params(frequencyHz: settings.frequencyHz ?? 0, bandwidthHz: settings.bandwidthHz,
                                    spreadingFactor: settings.spreadingFactor, codingRate: settings.codingRate,
                                    txPowerDBm: settings.txPowerDBm))
    }

    static func rnodePlatformName(_ platform: UInt8?) -> String {
        guard let platform else { return "unknown" }
        switch platform {
        case 0x80: return "ESP32"
        case 0x70: return "nRF52"
        default:   return "unknown (\(rnodeHex(platform)))"
        }
    }

    static func rnodeHardwareErrorName(_ code: UInt8) -> String {
        let names: [UInt8: String] = [0x01: "radio init failed", 0x02: "transmit failed", 0x03: "EEPROM locked",
                                      0x04: "queue full", 0x05: "memory low", 0x06: "modem timeout"]
        return names[code] ?? "code \(rnodeHex(code))"
    }

    /// Uppercase, two digits: `0x0A`.
    static func rnodeHex(_ value: UInt8) -> String {
        String(format: "0x%02X", value)
    }

    /// `2.15% / 0.80%` (short / long); `unknown` when neither is known.
    static func rnodePercentPair(_ short: Double?, _ long: Double?) -> String {
        guard short != nil || long != nil else { return "unknown" }
        func percent(_ value: Double?) -> String {
            value.map { String(format: "%.2f%%", $0) } ?? "unknown"
        }
        return "\(percent(short)) / \(percent(long))"
    }
}

// MARK: - Paths

extension DiagnosticsSnapshot {
    /// F8 cross-check. `Transport.State.learned` is deliberately NON-destructive: losing an
    /// interface does not purge the paths heard on it, so an entry routinely outlives the
    /// interface it names. `Transport.reachableLearned` is the runtime's version of this test,
    /// and `openLink` gates on it — a path whose interface is gone cannot carry a link.
    ///
    /// DENY LIST: `endpoint.interfaces` carries `InterfaceProfile.ifac`, which holds the derived
    /// network `key` and its Ed25519 `seed` — membership credentials for an access-controlled
    /// network. Only `interfaceID.rawValue` is rendered here, and nothing on this layer may ever
    /// widen to the full profile.
    static func pathsLayer(_ state: AppFeature.State) -> Layer {
        let endpoint = state.node.client.endpoint
        let interfaces = endpoint.interfaces
        let learned = endpoint.learned

        // `interfaces` is EMPTY whenever the socket is down — every interface deregisters. So the
        // per-path test below is only meaningful when at least one interface remains: with none,
        // it would mark every learned path unreachable and blame a missing interface, when the
        // truth is that the socket is down (or not yet registered) and Socket has already said so.
        // Reachability is not "no" in that state, it is UNKNOWABLE, and the rows say `?` rather
        // than `NO`.
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
            // but do NOT attribute it to a gone interface. The wording covers both "socket is
            // down" and "socket is online but no interface is registered yet": in both cases the
            // Socket layer already describes the fault; see Socket.
            return Layer(title: "Paths", health: .warn,
                         reason: "no interfaces registered — reachability is unknowable; "
                                 + "see Socket",
                         rows: rows)
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
    /// A stamp cost for display: whole numbers without a trailing ".0" (8 -> "8"), fractional
    /// ones as Swift prints them (8.5 -> "8.5"). Non-finite values print as Swift prints them.
    static func formatStampCost(_ cost: Double) -> String {
        if cost.isFinite, cost == cost.rounded(), abs(cost) < 1e15 {
            return String(Int64(cost))
        }
        return String(cost)
    }

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
                let cost = peer.stampCost.map(formatStampCost) ?? "-"
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
                         reason: "\(pathless) \(pluralize(pathless, "peer", "peers")) "
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
                         reason: "\(stalled) outbound \(pluralize(stalled, "link", "links")) "
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
        var out = "ReTiCAMsgr diagnostics — \(Self.timestamp.string(from: generatedAt))\n"
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
            .map { key, pending -> (String, Row) in
                let (method, dest) = describe(pending.resend)
                let hash = key.messageHash.hexString
                // One message can now have two pending copies (delivery + propagated); sorting by
                // hash then method keeps the row order deterministic.
                return (hash + " " + method, Row(hash,
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
            clauses.append("\(stranded) \(pluralize(stranded, "message", "messages")) pending "
                           + "with no active link to \(stranded == 1 ? "its" : "their") destination")
        }
        if parked > 0 {
            clauses.append("\(parked) \(pluralize(parked, "destination", "destinations")) "
                           + "waiting for a link (awaiting path or establishing)")
        }
        // Opportunistic sends have no delivery receipt — `.delivered` is fed only from
        // `packetDelivered`, i.e. acknowledged link traffic. An opportunistic entry sits in
        // `pendingDeliveries` for the full retry saga whether or not the message arrived, so no
        // rule over this data could distinguish "delivered" from "not yet delivered". Clause 1
        // above correctly EXCLUDES them from the link requirement. The consequence: send a small
        // message to an offline peer and every layer reads green. The rule is right; the silence
        // is not. An informational row — NOT a warn — makes the limitation visible without
        // turning a structurally unobservable state into a false alarm.
        let opportunisticPending = router.pendingDeliveries.values.filter { pending in
            if case .opportunistic = pending.resend { return true }
            return false
        }.count

        var finalRows = rows
        if opportunisticPending > 0 {
            finalRows.append(Row(
                "note",
                "\(opportunisticPending) opportunistic \(pluralize(opportunisticPending, "send", "sends")) "
                + "in flight — opportunistic is unacknowledged; "
                + "green here means no evidence of failure, not confirmed delivery"))
        }

        guard clauses.isEmpty else {
            return Layer(title: "Delivery", health: .warn,
                         reason: clauses.joined(separator: "; "), rows: finalRows)
        }
        return Layer(title: "Delivery", health: .ok, reason: nil, rows: finalRows)
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

// MARK: - Shared helpers

extension DiagnosticsSnapshot {
    /// Returns `singular` when `count == 1`, `plural` otherwise.
    /// Used in layer reason strings to keep plural agreement consistent across layers
    /// — the same mistake (singular pronoun with plural noun) has recurred three times.
    static func pluralize(_ count: Int, _ singular: String, _ plural: String) -> String {
        count == 1 ? singular : plural
    }
}
