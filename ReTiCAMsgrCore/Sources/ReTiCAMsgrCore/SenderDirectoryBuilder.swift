import Foundation
import ReTiCA
import ReTiCAPushCore

/// Chooses which peers go in the app-group sender directory and builds each one's
/// `SenderDirectory.Input`. Pure: the caller supplies the lookups.
enum SenderDirectoryBuilder {
    /// Every hex is lowercased. Excludes `me`, `blocked`, peers with no known public key, and
    /// peers with neither a name nor a picture.
    static func inputs(
        candidates: Set<String>,
        me: String,
        blocked: Set<String>,
        name: (String) -> String?,
        publicKey: (String) -> Data?,
        picture: (String) -> Data?
    ) -> [String: SenderDirectory.Input] {
        let me = me.lowercased()
        let blocked = Set(blocked.map { $0.lowercased() })
        var out: [String: SenderDirectory.Input] = [:]
        for candidate in candidates {
            let hex = candidate.lowercased()
            guard hex != me, !blocked.contains(hex), let key = publicKey(hex) else { continue }
            let displayName = name(hex)
            let image = picture(hex)
            guard displayName != nil || image != nil else { continue }
            out[hex] = SenderDirectory.Input(name: displayName, publicKey: key, imageData: image)
        }
        return out
    }
}

extension AppFeature.State {
    /// `.peer` conversations, contact-linked peers, and `groupMembers` (the caller reads the
    /// `GroupMember` table). Group conversation keys are not peers.
    func senderDirectoryCandidates(groupMembers: [String]) -> Set<String> {
        var out = Set(conversations.filter { $0.kind == .peer }.map { $0.peerHex.lowercased() })
        out.formUnion(contactLinks.keys.map { $0.lowercased() })
        out.formUnion(groupMembers.map { $0.lowercased() })
        return out
    }

    /// The peer's public key if the router has learned its identity.
    func senderPublicKey(_ hex: String) -> Data? {
        guard let hash = Data(hexString: hex) else { return nil }
        return node.client.router.knownIdentities[hash]?.publicKey
    }
}
