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
/// last body and time) schedules nothing. `rosterVersion` stands in for the `groupMembers` table
/// (bumped at launch and on every `senderDirectoryGroupsChanged`); the members the last write read
/// are candidates here too, so a group member's later-learned name or key reschedules a write.
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
    /// For each conversation, contact-linked or last-read group peer: its display name and
    /// whether its key is known.
    var candidates: [String: Candidate] = [:]

    init() {}

    init(_ state: AppFeature.State) {
        peerConversations = Set(state.conversations.filter { $0.kind == .peer }.map { $0.peerHex.lowercased() })
        rosterVersion = state.senderDirectoryRosterVersion
        contactLinks = state.contactLinks
        contactCards = state.contactCards
        peerProfiles = state.peerProfiles
        blockedPeers = state.blockedPeers
        for hex in state.senderDirectoryCandidates(groupMembers: Array(state.senderDirectoryGroupMembers)) {
            candidates[hex] = Candidate(name: state.peerDisplayName(hex), hasKey: state.senderPublicKey(hex) != nil)
        }
    }
}

/// Keeps the sender directory current. Composed last in `AppFeature.body`, so it sees the state
/// every other reducer left for this action. A fingerprint change (re)starts a 1 s debounce that
/// only sleeps and sends `senderDirectoryWriteDue`; that reads the open groups' members and sends
/// them back as `senderDirectoryMembersLoaded`, where names, keys and picture sources are resolved
/// from the state current at that moment and the write effect starts.
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

    private enum CancelID { case debounce, write }

    func reduce(into state: inout State, action: Action) -> Effect<Action> {
        // Review focus 1: a disabled writer computes nothing, stores nothing and runs nothing.
        guard writer.isEnabled else { return .none }
        switch action {
        case .senderDirectoryWriteDue:
            return .run { [database] send in
                do {
                    let members = try await database.read { db in try Self.openGroupMembers(db) }
                    await send(.senderDirectoryMembersLoaded(members))
                } catch {
                    Self.log.error("sender directory member read failed: \(String(describing: error), privacy: .public)")
                }
            }
            .cancellable(id: CancelID.write, cancelInFlight: true)

        case let .senderDirectoryMembersLoaded(members):
            state.senderDirectoryGroupMembers = members
            // This write resolves everything from the state as it is now, so it covers every
            // change up to here: store that fingerprint rather than scheduling another write.
            state.senderDirectoryFingerprint = SenderDirectoryFingerprint(state)
            return writeEffect(state)

        case .onLaunch, .senderDirectoryGroupsChanged:
            // Launch: the directory is rewritten once the tables load, groups included.
            state.senderDirectoryRosterVersion &+= 1

        default:
            break
        }
        let fingerprint = SenderDirectoryFingerprint(state)
        guard fingerprint != state.senderDirectoryFingerprint else { return .none }
        state.senderDirectoryFingerprint = fingerprint
        return .run { [clock] send in
            try await clock.sleep(for: Self.debounce)
            await send(.senderDirectoryWriteDue)
        }
        .cancellable(id: CancelID.debounce, cancelInFlight: true)
    }

    /// Members of every group I'm in (spec §4): groups I left, declined or saw dissolved keep their
    /// other members' rows, so only open groups count.
    static func openGroupMembers(_ db: GRDB.Database) throws -> Set<String> {
        let open = try ChatGroup.all.fetchAll(db).filter(\.isOpen).map(\.groupHex)
        guard !open.isEmpty else { return [] }
        return Set(try GroupMember.where { $0.groupHex.in(open) }.fetchAll(db).map { $0.memberHex.lowercased() })
    }

    /// Resolves names, keys and picture sources from `state` now (values only), then reads photo
    /// files, fetches missing contact thumbnails and writes, off the reducer. Errors are logged.
    private func writeEffect(_ state: State) -> Effect<Action> {
        let candidates = state.senderDirectoryCandidates(groupMembers: Array(state.senderDirectoryGroupMembers))
        var names: [String: String] = [:]
        var keys: [String: Data] = [:]
        var profiles: [String: PeerProfile] = [:]
        for hex in candidates {
            names[hex] = state.peerDisplayName(hex)
            keys[hex] = state.senderPublicKey(hex)
            profiles[hex] = state.peerProfiles[hex]
        }
        let me = state.myAddressHex
        let blocked = state.blockedPeers
        let links = state.contactLinks
        let cards = state.contactCards
        let store = state.push.storage.senderDirectory
        return .run { [writer, avatarStore, contactsClient, names, keys, profiles] _ in
            let thumbnails = await Self.contactThumbnails(links: links, cards: cards, profiles: profiles,
                                                          candidates: candidates, contacts: contactsClient)
            let inputs = SenderDirectoryBuilder.inputs(
                candidates: candidates, me: me, blocked: blocked,
                name: { names[$0] }, publicKey: { keys[$0] },
                picture: { hex in
                    Self.picture(profile: profiles[hex], contactThumbnail: thumbnails[hex], avatarStore: avatarStore)
                })
            do {
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
    static func contactThumbnails(links: [String: ContactLink], cards: [String: ContactCard],
                                  profiles: [String: PeerProfile], candidates: Set<String>,
                                  contacts: ContactsClient) async -> [String: Data] {
        var out: [String: Data] = [:]
        for (hex, link) in links {
            let hex = hex.lowercased()
            guard candidates.contains(hex), profiles[hex]?.photoPath == nil else { continue }
            switch cards[link.contactIdentifier] {
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
