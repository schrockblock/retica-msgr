import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCANode

/// Appends one line per outbound-send event to a file, so a send that failed (or never fell back to
/// the propagation node) can be explained after the fact: copy the file off the device with
/// `xcrun devicectl device copy from --domain-type appDataContainer … --source Documents/send-trace.log`.
///
/// Observes only, after `AppFeature` has reduced the action, so the state it reads is the state the
/// action left. Compose it beside `AppFeature` where the live store is built; `fileURL: nil` makes it
/// inert. Hashes are shortened to 12 hex characters, enough to match `messages.messageHash` and
/// `peerHex` prefixes in the database.
public struct SendTrace: Reducer {
    public typealias State = AppFeature.State
    public typealias Action = AppFeature.Action

    private let sink: SendTraceSink?

    public init(fileURL: URL?) {
        sink = fileURL.map(SendTraceSink.init)
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            guard let sink, case let .node(.client(nodeAction)) = action,
                  let line = Self.line(for: nodeAction, state.node.client)
            else { return .none }
            sink.write(line)
            return .none
        }
    }

    /// The trace line for `action`, or nil for an action the trace does not record. Path and link
    /// events are recorded only for destinations with outbound work, as `.pathLearned` fires for every
    /// announce on the network. Inbound packets are recorded only when they are PROOFs, against the
    /// receipts still outstanding once Transport has handled them: a matched proof has consumed its
    /// receipt (a `singlePacketDelivered` line follows), a late one finds none, an invalid one leaves
    /// it. `now` dates the receipts' remaining windows.
    static func line(for action: LXMFNode.Action, _ node: LXMFNode.State, now: Date = Date()) -> String? {
        let router = node.router
        let transport = node.endpoint.transport
        func h(_ data: Data) -> String { String(data.hexString.prefix(12)) }
        func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince(now).rounded()) }
        func receipts() -> String {
            let entries = transport.pendingReceipts
                .map { (h($0.key), seconds($0.value.expiresAt)) }
                .sorted { $0.0 < $1.0 }
                .map { "\($0.0)@\($0.1 >= 0 ? "+" : "")\($0.1)s" }
            return "[\(entries.joined(separator: ","))]"
        }
        func receipt(for messageHash: Data) -> String {
            guard let entry = transport.pendingReceipts.first(where: { $0.value.token == messageHash })
            else { return "receipt=none" }
            return "receipt=\(h(entry.key)) expiresIn=\(seconds(entry.value.expiresAt))"
        }
        func destination(_ resend: LXMFRouter.ResendInfo) -> Data {
            switch resend {
            case let .opportunistic(dest, _), let .direct(dest, _, _), let .propagated(dest, _): return dest
            }
        }
        func involved(_ dest: Data) -> Bool {
            router.directLinks[dest] != nil || router.establishAttempts[dest] != nil
                || dest == router.outboundPropagationNode
                || router.pendingDeliveries.values.contains { destination($0.resend) == dest }
        }
        func link(_ dest: Data) -> String {
            switch router.directLinks[dest] {
            case nil: return "none"
            case .awaitingPath: return "awaitingPath"
            case .establishing: return "establishing"
            case let .active(linkID): return "active(\(h(linkID)))"
            }
        }
        func route(_ dest: Data) -> String {
            let learned = transport.learned[dest].map {
                "learned=true hops=\($0.hops) nextHop=\($0.nextHop.map(h) ?? "none")"
            } ?? "learned=false"
            return "knownPath=\(router.knownPaths.contains(dest)) \(learned) "
                + "link=\(link(dest)) establishAttempts=\(router.establishAttempts[dest] ?? 0)"
        }
        func attempts(_ hash: Data, _ leg: LXMFRouter.Leg) -> String {
            router.pendingDeliveries[LXMFRouter.DeliveryKey(messageHash: hash, leg: leg)].map { String($0.attempts) } ?? "-"
        }

        switch action {
        case let .sendMessage(message, fallbackToPropagation):
            let dest = message.destinationHash
            let pn = router.outboundPropagationNode
            let pnLearned = pn.map { node.endpoint.transport.learned[$0] != nil } ?? false
            return "sendMessage msg=\(h(message.hash)) to=\(h(dest)) bytes=\(message.packed.count) "
                + "fallback=\(fallbackToPropagation) pn=\(pn.map(h) ?? "none") pnLearned=\(pnLearned) "
                + "recall=\(node.endpoint.recall(destinationHash: dest) != nil) held=\(router.held) \(route(dest))"

        case let .router(routerAction):
            switch routerAction {
            case let .send(message, method):
                return "router.send msg=\(h(message.hash)) to=\(h(message.destinationHash)) method=\(method) "
                    + route(message.destinationHash)
            case let .sendViaPropagation(message, _):
                return "router.sendViaPropagation msg=\(h(message.hash)) to=\(h(message.destinationHash))"
            case let .markFallbackEligible(hash):
                return "fallbackEligible msg=\(h(hash))"
            case let .propagatedCopyRefused(hash, reason):
                return "propagatedCopyRefused msg=\(h(hash)) reason=\(reason)"
            case let .propagatedCopyFailed(hash):
                return "propagatedCopyFailed msg=\(h(hash))"
            case let .retryDue(hash, leg):
                return "retryDue msg=\(h(hash)) leg=\(leg) attempts=\(attempts(hash, leg))"
            case let .linkEstablished(dest, linkID):
                return "router.linkEstablished to=\(h(dest)) link=\(h(linkID))"
            case let .linkClosed(dest) where involved(dest):
                return "router.linkClosed to=\(h(dest)) \(route(dest))"
            case let .pathLostAndClosed(dest):
                return "router.pathLostAndClosed to=\(h(dest)) \(route(dest))"
            case let .learnedPath(dest) where involved(dest):
                return "router.learnedPath to=\(h(dest)) \(route(dest))"
            case let .pathRequestDeadline(dest):
                return "pathRequestDeadline to=\(h(dest)) \(route(dest))"
            case let .setHold(held):
                return "setHold \(held)"
            case let .delegate(delegate):
                switch delegate {
                case let .requestLink(dest): return "requestLink to=\(h(dest)) \(route(dest))"
                case let .requestPath(dest): return "requestPath to=\(h(dest)) \(route(dest))"
                case let .closeLink(dest): return "closeLink to=\(h(dest))"
                case let .abandonLink(dest): return "abandonLink to=\(h(dest))"
                case let .sendOpportunistic(dest, payload, hash):
                    return "sendOpportunistic msg=\(h(hash)) to=\(h(dest)) bytes=\(payload.count) "
                        + "attempts=\(attempts(hash, .delivery)) \(receipt(for: hash)) \(route(dest))"
                case let .sendDirect(linkID, data, asResource):
                    return "sendDirect link=\(h(linkID)) bytes=\(data.count) resource=\(asResource)"
                case let .sendPropagated(linkID, packed):
                    return "sendPropagated link=\(h(linkID)) bytes=\(packed.count)"
                case let .sendPropagatedPacket(linkID, packed, hash):
                    return "sendPropagatedPacket msg=\(h(hash)) link=\(h(linkID)) bytes=\(packed.count)"
                case let .propagationFallbackDue(hash): return "propagationFallbackDue msg=\(h(hash))"
                case let .propagationRefused(hash, reason): return "propagationRefused msg=\(h(hash)) reason=\(reason)"
                case let .deliveryConfirmed(hash): return "deliveryConfirmed msg=\(h(hash))"
                case let .propagationAccepted(hash): return "propagationAccepted msg=\(h(hash))"
                case let .deliveryFailed(hash): return "deliveryFailed msg=\(h(hash))"
                case let .deliveryRejected(hash): return "deliveryRejected msg=\(h(hash))"
                case let .deliveryCancelled(hash): return "deliveryCancelled msg=\(h(hash))"
                default: return nil
                }
            default:
                return nil
            }

        case let .endpoint(.transport(.received(interfaceID, data))):
            // Hub interfaces carry no IFAC, so the raw bytes parse as-is; a flagged packet is not
            // a proof we could read anyway.
            guard let first = data.first, first & 0x80 == 0,
                  let packet = Packet(raw: data), packet.packetType == .proof
            else { return nil }
            return "proofReceived dest=\(h(packet.destinationHash)) bytes=\(packet.payload.count) "
                + "if=\(interfaceID.rawValue) receipts=\(receipts())"

        case let .endpoint(.transport(.delegate(.singlePacketDelivered(token)))):
            return "singlePacketDelivered token=\(h(token))"

        case let .endpoint(.delegate(delegate)):
            switch delegate {
            case let .linkFailed(dest, reason):
                return "linkFailed to=\(h(dest)) reason=\(reason) \(route(dest))"
            case let .linkEstablished(linkID, dest):
                return "linkEstablished to=\(h(dest)) link=\(h(linkID))"
            case let .linkClosed(linkID, reason):
                return "linkClosed link=\(h(linkID)) reason=\(reason)"
            case let .sendFailed(dest, reason) where involved(dest):
                return "sendFailed to=\(h(dest)) reason=\(reason)"
            case let .pathLearned(dest, hops) where involved(dest):
                return "pathLearned to=\(h(dest)) hops=\(hops) \(route(dest))"
            default:
                return nil
            }

        default:
            return nil
        }
    }
}

/// Appends timestamped lines to a file on a serial queue, moving it aside to `<name>.1.log` once it
/// passes `maxBytes` so it never grows without bound.
final class SendTraceSink: @unchecked Sendable {
    static let maxBytes = 2_000_000

    private let url: URL
    private let rotatedURL: URL
    private let queue = DispatchQueue(label: "com.reticamsgr.send-trace")
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(url: URL) {
        self.url = url
        rotatedURL = url.deletingPathExtension().appendingPathExtension("1.log")
    }

    func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        queue.async { [url, rotatedURL] in
            let fileManager = FileManager.default
            if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > Self.maxBytes {
                try? fileManager.removeItem(at: rotatedURL)
                try? fileManager.moveItem(at: url, to: rotatedURL)
            }
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(stamped.utf8))
        }
    }
}
