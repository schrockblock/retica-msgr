import Foundation

/// What a peer's avatar draws, in precedence order: the photo they sent us, then the photo on the
/// contact we linked them to, then their LXMF icon, then initials.
public enum AvatarSource: Equatable, Sendable {
    /// A received photo: `photoPath` relative to `AvatarStore`.
    case photo(path: String)
    /// The linked contact's thumbnail JPEG/PNG data.
    case contact(Data)
    case icon(IconAppearance)
    case initials

    public static func resolve(profile: PeerProfile?, contactThumbnail: Data?) -> AvatarSource {
        if let path = profile?.photoPath { return .photo(path: path) }
        if let contactThumbnail { return .contact(contactThumbnail) }
        if let profile, let name = profile.iconName, let fg = profile.iconFg, let bg = profile.iconBg {
            return .icon(IconAppearance(name: name, fg: fg, bg: bg))
        }
        return .initials
    }
}

extension Array where Element == Message {
    /// Group threads show the sender's avatar once per consecutive run of their incoming bubbles,
    /// on the run's last bubble. True for an incoming non-event message whose next message is
    /// absent, outgoing, an event/timer line, or from another sender.
    public func showsSenderAvatar(at index: Int) -> Bool {
        guard indices.contains(index) else { return false }
        let message = self[index]
        guard !message.isOutgoing, !message.isGroupEvent, !message.isTimerChange else { return false }
        let nextIndex = index + 1
        guard indices.contains(nextIndex) else { return true }
        let next = self[nextIndex]
        return next.isOutgoing || next.isGroupEvent || next.isTimerChange || next.peerHex != message.peerHex
    }
}
