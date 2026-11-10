import Foundation
import ComposableArchitecture
import GRDB
import os
import ReTiCAPushCore

/// Writes the app-group sender directory the Notification Service Extension reads (spec
/// 2026-11-05 §4). Disabled in tests by default, so suites that don't opt in never see the effect.
struct SenderDirectoryWriter: Sendable {
    var isEnabled: Bool
    var write: @Sendable (SenderDirectoryStore, [String: SenderDirectory.Input]) throws -> Void
}

extension SenderDirectoryWriter: DependencyKey {
    static let liveValue = SenderDirectoryWriter(isEnabled: true) { try $0.save($1) }
    static let testValue = SenderDirectoryWriter(isEnabled: false) { _, _ in }
}

extension DependencyValues {
    var senderDirectoryWriter: SenderDirectoryWriter {
        get { self[SenderDirectoryWriter.self] }
        set { self[SenderDirectoryWriter.self] = newValue }
    }
}

/// Only what the directory depends on, so an ordinary message (which changes a conversation's
/// last body and time) schedules nothing. Group members are read from the database inside the
/// write; `rosterVersion` stands in for that table (bumped at launch and on every
/// `senderDirectoryGroupsChanged`).
struct SenderDirectoryFingerprint: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        var name: String?
        var hasKey: Bool
    }

    /// The peers with a one-to-one conversation (a new conversation is a trigger, a new message is not).
    var peerConversations: Set<String> = []
    var rosterVersion = 0
    var contactLinks: [String: ContactLink] = [:]
    var contactCards: [String: ContactCard] = [:]
    var peerProfiles: [String: PeerProfile] = [:]
    var blockedPeers: Set<String> = []
    /// For each conversation or contact-linked peer: its display name and whether its key is known.
    var candidates: [String: Candidate] = [:]

    init() {}

    init(_ state: AppFeature.State) {
        peerConversations = Set(state.conversations.filter { $0.kind == .peer }.map { $0.peerHex.lowercased() })
        rosterVersion = state.senderDirectoryRosterVersion
        contactLinks = state.contactLinks
        contactCards = state.contactCards
        peerProfiles = state.peerProfiles
        blockedPeers = state.blockedPeers
        for hex in state.senderDirectoryCandidates(groupMembers: []) {
            candidates[hex] = Candidate(name: state.peerDisplayName(hex), hasKey: state.senderPublicKey(hex) != nil)
        }
    }
}

/// Keeps the sender directory current. Composed last in `AppFeature.body`, so it sees the state
/// every other reducer left for this action; it compares that state's fingerprint with the one it
/// stored after the previous action, and on a change schedules one debounced whole-directory write.
struct SenderDirectoryReducer: Reducer {
    typealias State = AppFeature.State
    typealias Action = AppFeature.Action

    @Dependency(\.senderDirectoryWriter) var writer
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.avatarStore) var avatarStore
    @Dependency(\.contactsClient) var contactsClient
    @Dependency(\.continuousClock) var clock

    static let debounce: Duration = .seconds(1)
    static let log = Logger(subsystem: "com.reticamsgr", category: "senderDirectory")

    private enum CancelID { case write }

    func reduce(into state: inout State, action: Action) -> Effect<Action> {
        // Review focus 1: a disabled writer computes nothing, stores nothing and runs nothing.
        guard writer.isEnabled else { return .none }
        switch action {
        case .onLaunch, .senderDirectoryGroupsChanged:
            // Launch: the directory is rewritten once the tables load, groups included.
            state.senderDirectoryRosterVersion &+= 1
        default:
            break
        }
        let fingerprint = SenderDirectoryFingerprint(state)
        guard fingerprint != state.senderDirectoryFingerprint else { return .none }
        state.senderDirectoryFingerprint = fingerprint
        // A value copy: the effect resolves names, keys and pictures for group-only members too.
        // `State` is not `Sendable` as a whole, but this copy is never mutated and the effect only
        // reads its value-typed tables (conversations, links, cards, profiles, learned peers, known
        // identities), so handing it across is safe.
        let box = UncheckedSendable(state)
        let store = state.push.storage.senderDirectory
        return .run { [writer, database, avatarStore, contactsClient, clock] _ in
            try await clock.sleep(for: Self.debounce)
            let snapshot = box.value
            do {
                let members = try await database.read { db in try GroupMember.all.fetchAll(db).map(\.memberHex) }
                let candidates = snapshot.senderDirectoryCandidates(groupMembers: members)
                let thumbnails = await Self.contactThumbnails(snapshot, candidates: candidates, contacts: contactsClient)
                let inputs = SenderDirectoryBuilder.inputs(
                    candidates: candidates,
                    me: snapshot.myAddressHex,
                    blocked: snapshot.blockedPeers,
                    name: { snapshot.peerDisplayName($0) },
                    publicKey: { snapshot.senderPublicKey($0) },
                    picture: { hex in
                        Self.picture(profile: snapshot.peerProfiles[hex], contactThumbnail: thumbnails[hex],
                                     avatarStore: avatarStore)
                    })
                try writer.write(store, inputs)
            } catch {
                Self.log.error("sender directory write failed: \(String(describing: error), privacy: .public)")
            }
        }
        .cancellable(id: CancelID.write, cancelInFlight: true)
    }

    /// Each linked candidate's contact thumbnail by peer hex: the loaded card's when there is one,
    /// else fetched now (cards load lazily, when an avatar view appears). A received photo wins
    /// over the contact's, so those peers are skipped.
    static func contactThumbnails(_ state: State, candidates: Set<String>,
                                  contacts: ContactsClient) async -> [String: Data] {
        var out: [String: Data] = [:]
        for (hex, link) in state.contactLinks {
            let hex = hex.lowercased()
            guard candidates.contains(hex), state.peerProfiles[hex]?.photoPath == nil else { continue }
            switch state.contactCards[link.contactIdentifier] {
            case let .available(thumbnail):
                out[hex] = thumbnail
            case .missing:
                continue
            case nil:
                out[hex] = await contacts.thumbnail(link.contactIdentifier)
            }
        }
        return out
    }

    /// The picture rule: a received photo is its stored JPEG, re-encoded as a 256 px avatar only
    /// when it is larger (the wire accepts up to 512 px; spec §4 caps the directory at 256), a
    /// contact thumbnail is always re-encoded, and an icon or initials is no picture (iOS draws
    /// its own monogram).
    static func picture(profile: PeerProfile?, contactThumbnail: Data?, avatarStore: AvatarStore) -> Data? {
        switch AvatarSource.resolve(profile: profile, contactThumbnail: contactThumbnail) {
        case let .photo(path):
            guard let jpeg = try? Data(contentsOf: avatarStore.url(forRelativePath: path)),
                  let size = ImageEncoder.dimensions(of: jpeg) else { return nil }
            guard max(size.width, size.height) > ImageEncoder.avatarPixels else { return jpeg }
            return try? ImageEncoder.encodeAvatar(jpeg).data
        case let .contact(data):
            return try? ImageEncoder.encodeAvatar(data).data
        case .icon, .initials:
            return nil
        }
    }
}
