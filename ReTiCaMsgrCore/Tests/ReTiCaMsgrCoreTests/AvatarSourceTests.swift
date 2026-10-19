import Testing
import Foundation
@testable import ReTiCaMsgrCore

private let peerA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private let peerB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
private let thumb = Data([0xFF, 0xD8, 0xFF, 0x01])

private func profile(photo: String?, icon: Bool) -> PeerProfile {
    PeerProfile(
        peerHex: peerA,
        photoVersion: photo == nil ? nil : "0123456789abcdef",
        photoPath: photo,
        iconName: icon ? "account" : nil,
        iconFg: icon ? "ffffff" : nil,
        iconBg: icon ? "336699" : nil,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

private func message(_ peer: String, outgoing: Bool = false, event: Bool = false, timer: Bool = false) -> Message {
    Message(
        id: UUID(), peerHex: peer, isOutgoing: outgoing, body: "hi",
        timestamp: Date(timeIntervalSince1970: 0), status: "delivered", validated: true,
        messageHash: "", isTimerChange: timer, groupHex: "cccccccccccccccccccccccccccccccc", isGroupEvent: event
    )
}

@Test func avatarPrefersSentPhoto() {
    let source = AvatarSource.resolve(profile: profile(photo: "a.jpg", icon: true), contactThumbnail: thumb)
    #expect(source == .photo(path: "a.jpg"))
}

@Test func avatarFallsBackToContact() {
    let source = AvatarSource.resolve(profile: profile(photo: nil, icon: true), contactThumbnail: thumb)
    #expect(source == .contact(thumb))
}

@Test func avatarFallsBackToIcon() {
    let source = AvatarSource.resolve(profile: profile(photo: nil, icon: true), contactThumbnail: nil)
    #expect(source == .icon(IconAppearance(name: "account", fg: "ffffff", bg: "336699")))
}

@Test func avatarFallsBackToInitials() {
    #expect(AvatarSource.resolve(profile: nil, contactThumbnail: nil) == .initials)
}

@Test func senderAvatarOnLastOfRun() {
    let thread = [message(peerA), message(peerA), message(peerB), message(peerA)]
    #expect(thread.indices.map { thread.showsSenderAvatar(at: $0) } == [false, true, true, true])
}

@Test func senderAvatarSkipsOutgoingAndEvents() {
    // Every row carries peer A, so only the outgoing, timer and event flags can end a run: the
    // peer-differs check cannot stand in for them.
    let thread = [message(peerA), message(peerA, outgoing: true), message(peerA),
                  message(peerA, timer: true), message(peerA), message(peerA, event: true)]
    #expect(thread.indices.map { thread.showsSenderAvatar(at: $0) } == [true, false, true, false, true, false])
}
