//
//  AvatarView.swift
//  ReTiCaMsgr
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import ComposableArchitecture
import ReTiCaMsgrCore

/// Decoded avatar images, keyed by something that changes whenever the picture does (a peer's
/// photo path carries its version, mine is keyed by my version, a contact thumbnail by its
/// contact and byte count), so rows in a scrolling list never re-read or re-decode a JPEG.
private enum AvatarImageCache {
    nonisolated(unsafe) static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func image(key: String, load: () -> UIImage?) -> UIImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let image = load() else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

/// A peer's avatar (spec 2026-10-19): the photo they sent, else their linked contact's photo,
/// else their LXMF icon, else initials. A linked peer's contact card is loaded on appear.
struct AvatarView: View {
    let store: StoreOf<AppFeature>
    let peerHex: String
    var size: CGFloat = 40
    /// The name the initials come from; defaults to the contact or announced name.
    var name: String? = nil
    /// False where the host refreshes the card itself (`ContactLinkRow`), so the two don't both send.
    var loadsContactCard = true
    @Dependency(\.avatarStore) private var avatarStore

    private var link: ContactLink? { store.state.contactLinks[peerHex] }

    private var contactThumbnail: Data? {
        guard let link, case let .available(thumbnail?) = store.state.contactCards[link.contactIdentifier]
        else { return nil }
        return thumbnail
    }

    private var initialsName: String { name ?? store.state.peerDisplayName(peerHex) ?? "" }

    var body: some View {
        let source = AvatarSource.resolve(profile: store.state.peerProfiles[peerHex],
                                          contactThumbnail: contactThumbnail)
        content(source)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            // Once per contact per session: a row scrolling back in must not re-read Contacts.
            // `ContactLinkRow` (the info sheet) is what refreshes a loaded card live.
            .task(id: link?.contactIdentifier) {
                guard loadsContactCard, let link,
                      store.state.contactCards[link.contactIdentifier] == nil else { return }
                store.send(.contactRowAppeared(peerHex: peerHex))
            }
    }

    @ViewBuilder
    private func content(_ source: AvatarSource) -> some View {
        switch source {
        case let .photo(path):
            let url = avatarStore.url(forRelativePath: path)
            if let image = AvatarImageCache.image(key: "peer/\(path)", load: { UIImage(contentsOfFile: url.path) }) {
                CircleImage(image: image, size: size)
            } else {
                BrandAvatar(name: initialsName, size: size)
            }
        case let .contact(data):
            let key = "contact/\(link?.contactIdentifier ?? peerHex)/\(data.count)/\(data.hashValue)"
            if let image = AvatarImageCache.image(key: key, load: { UIImage(data: data) }) {
                CircleImage(image: image, size: size)
            } else {
                BrandAvatar(name: initialsName, size: size)
            }
        case let .icon(icon):
            IconAvatar(icon: icon, initialsName: initialsName, size: size)
        case .initials:
            BrandAvatar(name: initialsName, size: size)
        }
    }
}

/// My own avatar: my photo when I have one, else the brand-gradient initials.
struct MyAvatarView: View {
    let store: StoreOf<AppFeature>
    var size: CGFloat = 56
    /// Initials source while the name is being edited; defaults to my saved display name.
    var name: String? = nil
    @Dependency(\.avatarStore) private var avatarStore

    var body: some View {
        let version = store.myPhotoVersion
        Group {
            if !version.isEmpty,
               let image = AvatarImageCache.image(key: "me/\(version)", load: {
                   UIImage(contentsOfFile: avatarStore.myPhotoURL.path)
               }) {
                CircleImage(image: image, size: size)
            } else {
                BrandAvatar(name: name ?? store.displayName, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct CircleImage: View {
    let image: UIImage
    let size: CGFloat

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

/// A Sideband-style icon: the MDI glyph in `fg` on a `bg` circle. A name the bundled font does not
/// know draws initials on `bg` instead.
private struct IconAvatar: View {
    let icon: IconAppearance
    let initialsName: String
    let size: CGFloat

    var body: some View {
        let fg = Color(hex6: icon.fg) ?? .white
        let bg = Color(hex6: icon.bg) ?? .gray
        ZStack {
            Circle().fill(bg)
            if let glyph = MDIIcons.codepoint(for: icon.name) {
                Text(String(glyph))
                    .font(.custom(MDIIcons.fontName, size: size * 0.55))
            } else if let initials = Self.initials(initialsName) {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
            }
        }
        .foregroundStyle(fg)
        .frame(width: size, height: size)
        // The glyph is a private-use codepoint: VoiceOver would read it as noise.
        .accessibilityHidden(true)
    }

    /// Same rule as `BrandAvatar`: the first letter or digit of each of the first two words.
    static func initials(_ name: String) -> String? {
        let initials = name.split(separator: " ")
            .compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
            .prefix(2)
            .map(String.init)
            .joined()
            .uppercased()
        return initials.isEmpty ? nil : initials
    }
}

extension Color {
    /// A 6-char hex colour ("336699"); nil for anything else.
    init?(hex6: String) {
        guard hex6.count == 6, let value = UInt32(hex6, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
