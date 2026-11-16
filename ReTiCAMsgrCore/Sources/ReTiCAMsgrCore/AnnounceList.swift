import Foundation
import ReTiCANode

/// The Announces sheet's rows: everyone in the learned-peer table who is not blocked, in the order
/// the sheet froze when it opened, narrowed by the search text and cut to a row limit.
///
/// The table is network-sized (one install held 18,872 peers) and is written on every accepted
/// announce, and a view that reads it runs its body again on each write. The sheet used to derive
/// its rows three times per body, formatting every hash as hex twice each time, and rendered a row
/// per peer: at 19,000 peers each announce held the main thread for 2.6 s (iOS simulator, debug
/// build). So one `init` is one pass over the table: hashes are compared as bytes, and a row and
/// its hex string are built only for a row shown.
public struct AnnounceList: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        /// The destination hash: a row keeps its identity when the peer announces again.
        public let id: Data
        /// Lowercase hex of `id`, the address a chat is started with.
        public let hex: String
        /// The linked contact's name, when the peer is linked and the name is not empty.
        public let contactName: String?
        /// The display name the peer announces.
        public let announcedName: String?
        public let learnedAt: Date
    }

    /// The row order captured when the sheet opens: newest announce first.
    ///
    /// Announces re-arrive every few seconds. Sorting by recency on every one moved rows under the
    /// user's finger, so a tap opened the wrong chat. Peers in the order keep their place; a peer
    /// heard later goes after them.
    public struct Order: Equatable, Sendable {
        public let hashes: [Data]
        let members: Set<Data>

        /// No order yet: every peer counts as heard later, so the list is newest first.
        public init() {
            hashes = []
            members = []
        }

        public init(of state: AppFeature.State) {
            let blocked = AnnounceList.blockedHashes(state)
            hashes = state.node.client.learnedPeers
                .filter { !blocked.contains($0.key) }
                .sorted { AnnounceList.newerFirst(($0.key, $0.value.learnedAt), ($1.key, $1.value.learnedAt)) }
                .map(\.key)
            members = Set(hashes)
        }
    }

    /// How many rows the sheet shows. Past this the list says how many more there are, and the
    /// search, which covers every peer, is how to reach them.
    public static let screenRowLimit = 200

    /// The first `rowLimit` peers that match the search, in order.
    public let rows: [Row]
    /// Peers that are not blocked, whatever the search says. Zero means nobody was heard yet.
    public let known: Int
    /// Peers that match the search. `rows` holds the first of them.
    public let matching: Int
    /// Matching peers left out of `rows` by the limit.
    public var more: Int { matching - rows.count }

    public init(from state: AppFeature.State, order: Order, search: String = "", rowLimit: Int = .max) {
        let peers = state.node.client.learnedPeers
        let blocked = Self.blockedHashes(state)
        // Keyed by hash, so a peer's contact name is a lookup and not a hex string per peer.
        var contactNames: [Data: String] = [:]
        for (hex, link) in state.contactLinks where !link.cachedName.isEmpty {
            if let hash = Data(hexString: hex) { contactNames[hash] = link.cachedName }
        }
        let query = Query(search)
        let limit = max(0, rowLimit)

        var rows: [Row] = []
        var known = 0
        var matching = 0
        func take(_ hash: Data, _ peer: LXMFNode.LearnedPeer) {
            known += 1
            let contactName = contactNames[hash]
            guard query.matches(hash, contactName: contactName, announcedName: peer.displayName) else { return }
            matching += 1
            guard rows.count < limit else { return }
            rows.append(Row(id: hash, hex: hash.hexString, contactName: contactName,
                            announcedName: peer.displayName, learnedAt: peer.learnedAt))
        }

        // The frozen order first. A peer that has since left the table is skipped.
        var stillListed = 0
        for hash in order.hashes {
            guard let peer = peers[hash] else { continue }
            stillListed += 1
            if !blocked.contains(hash) { take(hash, peer) }
        }
        // Then anyone heard since, newest first. Skipped when the table holds nobody else.
        if stillListed < peers.count {
            let later = peers
                .filter { !order.members.contains($0.key) && !blocked.contains($0.key) }
                .sorted { Self.newerFirst(($0.key, $0.value.learnedAt), ($1.key, $1.value.learnedAt)) }
            for (hash, peer) in later { take(hash, peer) }
        }

        self.rows = rows
        self.known = known
        self.matching = matching
    }

    /// Newest first. Equal dates fall back to byte order, so the result does not depend on the
    /// order a dictionary happens to hand its entries out in.
    static func newerFirst(_ lhs: (hash: Data, learnedAt: Date), _ rhs: (hash: Data, learnedAt: Date)) -> Bool {
        if lhs.learnedAt != rhs.learnedAt { return lhs.learnedAt > rhs.learnedAt }
        return lhs.hash.lexicographicallyPrecedes(rhs.hash)
    }

    /// `blockedPeers` as hashes. The set is the user's block list, so it is small.
    static func blockedHashes(_ state: AppFeature.State) -> Set<Data> {
        Set(state.blockedPeers.compactMap { Data(hexString: $0) })
    }

    /// The search text, prepared once for every peer it is tried against.
    struct Query {
        /// The trimmed text; empty matches everyone.
        let text: String
        /// The text as an address: lowercased, with spaces and the `<…>` around a copied address
        /// removed, so a pasted one still matches. Nil when what is left is not hex, since no
        /// address contains it.
        let hex: String?

        init(_ search: String) {
            text = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = text.lowercased().filter { !" <>".contains($0) }
            hex = !stripped.isEmpty && stripped.allSatisfy(\.isHexDigit) ? stripped : nil
        }

        /// Matches the contact name, the announced name, or the address.
        func matches(_ hash: Data, contactName: String?, announcedName: String?) -> Bool {
            guard !text.isEmpty else { return true }
            if contactName?.localizedCaseInsensitiveContains(text) == true { return true }
            if announcedName?.localizedCaseInsensitiveContains(text) == true { return true }
            guard let hex else { return false }
            return hash.hexString.contains(hex)
        }
    }
}
