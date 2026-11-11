import Foundation
import GRDB
import ReTiCA
import ReTiCANode
import SQLiteData

/// One peered propagation node, mirrored from the service node's peer table so peering survives a
/// relaunch (`peersChanged` writes it, `.rehydrate(entries:peers:)` reads it back). `peerHex` is the
/// peer's destination hash; `blob` is the whole `PNPeerTable.Peer` as msgpack (see `PNPeerCodec`),
/// including the cached peering key and the handled/unhandled sets. `position` is the peer's index
/// in the table, which the library keeps in order.
@Table("pnPeerRows")
public struct PNPeerRow: Identifiable, Equatable, Sendable {
    public var id: String { peerHex }
    public var peerHex: String
    public var position: Int
    public var blob: Data

    public init(peerHex: String, position: Int, blob: Data) {
        self.peerHex = peerHex; self.position = position; self.blob = blob
    }
}

/// `PNPeerTable.Peer` <-> msgpack. Deterministic (sets are sorted, map keys are fixed) so equal
/// peers produce equal bytes, which is what lets a write skip unchanged rows by comparing blobs.
/// Dates are float64 seconds since 1970, so they round-trip exactly.
public enum PNPeerCodec {
    public static func encode(_ p: PNPeerTable.Peer) -> Data {
        func int(_ v: Int) -> MsgPackValue { v >= 0 ? .uint(UInt64(v)) : .int(Int64(v)) }
        func date(_ d: Date) -> MsgPackValue { .double(d.timeIntervalSince1970) }
        func bin(_ d: Data?) -> MsgPackValue { d.map { .bin($0) } ?? .null }
        func sorted(_ s: Set<Data>) -> MsgPackValue {
            .array(s.sorted { $0.hexString < $1.hexString }.map { .bin($0) })
        }
        let announce: MsgPackValue
        if let a = p.announce {
            announce = .array([int(a.timebase), .bool(a.nodeState), int(a.perTransferLimit), int(a.perSyncLimit),
                               .double(a.targetStampCost), .double(a.stampCostFlexibility),
                               .double(a.peeringCost), a.metadata])
        } else {
            announce = .null
        }
        return MsgPack.encode(.map([
            .init("dest", .bin(p.destinationHash)),
            .init("timebase", int(p.peeringTimebase)),
            .init("alive", .bool(p.alive)),
            .init("lastHeard", date(p.lastHeard)),
            .init("lastSyncAttempt", p.lastSyncAttempt.map(date) ?? .null),
            .init("nextSyncAttempt", date(p.nextSyncAttempt)),
            .init("syncBackoff", .double(p.syncBackoff)),
            .init("syncTransferRate", .double(p.syncTransferRate)),
            .init("announce", announce),
            .init("peeringKey", bin(p.peeringKey)),
            .init("peeringKeyValue", p.peeringKeyValue.map { .double($0) } ?? .null),
            .init("state", .string(stateName(p.state))),
            .init("linkID", bin(p.linkID)),
            .init("handled", sorted(p.handled)),
            .init("unhandled", sorted(p.unhandled)),
            .init("lastOffer", .array(p.lastOffer.map { .bin($0) })),
            .init("transferring", p.transferring.map { .array($0.map { .bin($0) }) } ?? .null),
            .init("offered", int(p.offered)),
            .init("outgoing", int(p.outgoing)),
            .init("incoming", int(p.incoming)),
        ]))
    }

    /// Nil for bytes that are not a peer this build wrote (a corrupt row is skipped, not fatal).
    public static func decode(_ data: Data) -> PNPeerTable.Peer? {
        guard case let .map(pairs)? = MsgPack.decodeValue(data) else { return nil }
        var f: [String: MsgPackValue] = [:]
        for pair in pairs { f[pair.key] = pair.value }

        func int(_ v: MsgPackValue?) -> Int? {
            switch v {
            case let .uint(u)?: return Int(exactly: u)
            case let .int(i)?: return Int(exactly: i)
            default: return nil
            }
        }
        func double(_ v: MsgPackValue?) -> Double? {
            if case let .double(d)? = v { return d }
            return nil
        }
        func bin(_ v: MsgPackValue?) -> Data? {
            if case let .bin(d)? = v { return d }
            return nil
        }
        func optBin(_ v: MsgPackValue?) -> Data?? {
            if case .null? = v { return .some(nil) }
            return bin(v).map { .some($0) }
        }
        func bins(_ v: MsgPackValue?) -> [Data]? {
            guard case let .array(items)? = v else { return nil }
            var out: [Data] = []
            for item in items { guard let d = bin(item) else { return nil }; out.append(d) }
            return out
        }
        func date(_ v: MsgPackValue?) -> Date? { double(v).map { Date(timeIntervalSince1970: $0) } }

        guard let dest = bin(f["dest"]), let timebase = int(f["timebase"]),
              case let .bool(alive)? = f["alive"],
              let lastHeard = date(f["lastHeard"]), let next = date(f["nextSyncAttempt"]),
              let backoff = double(f["syncBackoff"]), let rate = double(f["syncTransferRate"]),
              case let .string(stateText)? = f["state"], let state = state(named: stateText),
              let linkID = optBin(f["linkID"]), let peeringKey = optBin(f["peeringKey"]),
              let handled = bins(f["handled"]), let unhandled = bins(f["unhandled"]),
              let lastOffer = bins(f["lastOffer"]),
              let offered = int(f["offered"]), let outgoing = int(f["outgoing"]), let incoming = int(f["incoming"])
        else { return nil }

        var lastSync: Date?
        if case .null? = f["lastSyncAttempt"] { lastSync = nil }
        else if let d = date(f["lastSyncAttempt"]) { lastSync = d }
        else { return nil }

        var keyValue: Double?
        if case .null? = f["peeringKeyValue"] { keyValue = nil }
        else if let d = double(f["peeringKeyValue"]) { keyValue = d }
        else { return nil }

        var transferring: [Data]?
        if case .null? = f["transferring"] { transferring = nil }
        else if let t = bins(f["transferring"]) { transferring = t }
        else { return nil }

        var announce: PNAnnounce?
        if case .null? = f["announce"] { announce = nil }
        else if case let .array(a)? = f["announce"], a.count == 8,
                let atime = int(a[0]), case let .bool(node) = a[1],
                let transfer = int(a[2]), let sync = int(a[3]),
                let cost = double(a[4]), let flex = double(a[5]), let peering = double(a[6]) {
            announce = PNAnnounce(timebase: atime, nodeState: node, perTransferLimit: transfer,
                                  perSyncLimit: sync, targetStampCost: cost, stampCostFlexibility: flex,
                                  peeringCost: peering, metadata: a[7])
        } else { return nil }

        return PNPeerTable.Peer(
            destinationHash: dest, peeringTimebase: timebase, alive: alive, lastHeard: lastHeard,
            lastSyncAttempt: lastSync, nextSyncAttempt: next, syncBackoff: backoff,
            syncTransferRate: rate, announce: announce, peeringKey: peeringKey,
            peeringKeyValue: keyValue, state: state, linkID: linkID,
            handled: Set(handled), unhandled: Set(unhandled), lastOffer: lastOffer,
            transferring: transferring, offered: offered, outgoing: outgoing, incoming: incoming)
    }

    private static func stateName(_ s: PNPeerTable.PeerState) -> String {
        switch s {
        case .idle: "idle"
        case .keyPending: "keyPending"
        case .linkEstablishing: "linkEstablishing"
        case .linkReady: "linkReady"
        case .requestSent: "requestSent"
        case .transferring: "transferring"
        }
    }

    private static func state(named n: String) -> PNPeerTable.PeerState? {
        switch n {
        case "idle": .idle
        case "keyPending": .keyPending
        case "linkEstablishing": .linkEstablishing
        case "linkReady": .linkReady
        case "requestSent": .requestSent
        case "transferring": .transferring
        default: nil
        }
    }
}

extension PNPeerRow {
    /// The rows for a `peersChanged` list, in table order.
    static func rows(for peers: [PNPeerTable.Peer]) -> [PNPeerRow] {
        peers.enumerated().map { i, p in
            PNPeerRow(peerHex: p.destinationHash.hexString, position: i, blob: PNPeerCodec.encode(p))
        }
    }

    /// Makes the table equal `rows`: upserts the rows that are new or differ, deletes the rest, in
    /// the caller's write transaction. Unchanged rows are not rewritten (`peersChanged` fires on
    /// every peer state change).
    static func sync(_ rows: [PNPeerRow], in db: Database) throws {
        let existing = Dictionary(uniqueKeysWithValues:
            try PNPeerRow.all.fetchAll(db).map { ($0.peerHex, $0) })
        let keep = Set(rows.map(\.peerHex))
        let gone = existing.keys.filter { !keep.contains($0) }
        if !gone.isEmpty {
            try PNPeerRow.where { $0.peerHex.in(gone) }.delete().execute(db)
        }
        for row in rows where existing[row.peerHex] != row {
            if existing[row.peerHex] != nil {
                try PNPeerRow.where { $0.peerHex.eq(row.peerHex) }.delete().execute(db)
            }
            try PNPeerRow.insert { row }.execute(db)
        }
    }
}
