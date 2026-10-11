import Foundation

/// The peer the system contact picker is up for, and the source the pick will carry.
public struct LinkPickerTarget: Equatable, Sendable {
    public var peerHex: String
    public var source: String
    public init(peerHex: String, source: String) {
        self.peerHex = peerHex
        self.source = source
    }
}

/// A pick that would break the 1:1 rule, awaiting Replace or Cancel (spec 2026-10-11 §3).
public struct LinkCollision: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// This peer is already linked to another contact.
        case peerAlreadyLinked
        /// This contact is already linked to another peer.
        case contactAlreadyLinked
    }
    public var peerHex: String
    public var identifier: String
    public var name: String
    public var source: String
    public var existing: ContactLink
    public var kind: Kind

    public init(peerHex: String, identifier: String, name: String, source: String, existing: ContactLink, kind: Kind) {
        self.peerHex = peerHex
        self.identifier = identifier
        self.name = name
        self.source = source
        self.existing = existing
        self.kind = kind
    }
}

/// Pure rules behind the link actions, so each is testable on its own.
public enum ContactLinking {
    /// The link a pick creates: verified when the user made it, unverified when it was
    /// discovered or imported.
    public static func newLink(peerHex: String, identifier: String, name: String, source: String, now: Date) -> ContactLink {
        ContactLink(peerHex: peerHex, contactIdentifier: identifier, cachedName: name, source: source,
                    discoveredViaHex: nil, discoveredSessionId: nil, discoveredAt: nil, confirmationsJSON: "[]",
                    verified: source == ContactLinkSource.manual || source == ContactLinkSource.scanned,
                    conflictedAt: nil, conflictPeerHex: nil, createdAt: now, updatedAt: now)
    }

    /// The collision a pick causes, if any: the peer side is checked first, then the contact side.
    public static func collision(peerHex: String, identifier: String, name: String, source: String,
                                 in links: [String: ContactLink]) -> LinkCollision? {
        if let existing = links[peerHex], existing.contactIdentifier != identifier {
            return LinkCollision(peerHex: peerHex, identifier: identifier, name: name, source: source,
                                 existing: existing, kind: .peerAlreadyLinked)
        }
        if let existing = links.values.first(where: { $0.contactIdentifier == identifier && $0.peerHex != peerHex }) {
            return LinkCollision(peerHex: peerHex, identifier: identifier, name: name, source: source,
                                 existing: existing, kind: .contactAlreadyLinked)
        }
        return nil
    }

    /// The cards worth offering for import: a well-formed 32-hex address, not already linked by
    /// peer or by contact, one candidate per contact AND per address (among duplicates the lowest
    /// identifier wins). Nothing already linked is ever touched by an import (spec §3).
    public static func importable(_ found: [ImportCandidate], links: [String: ContactLink]) -> [ImportCandidate] {
        let linkedContacts = Set(links.values.map(\.contactIdentifier))
        var seenContacts = Set<String>()
        var seenAddresses = Set<String>()
        return found
            .sorted { $0.identifier < $1.identifier }
            .filter { candidate in
                guard isValidPeerAddress(candidate.peerHex),
                      links[candidate.peerHex] == nil,
                      !linkedContacts.contains(candidate.identifier),
                      !seenContacts.contains(candidate.identifier),
                      !seenAddresses.contains(candidate.peerHex)
                else { return false }
                seenContacts.insert(candidate.identifier)
                seenAddresses.insert(candidate.peerHex)
                return true
            }
    }
}
