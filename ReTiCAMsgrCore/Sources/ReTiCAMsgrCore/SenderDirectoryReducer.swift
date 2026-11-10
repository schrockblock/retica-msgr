import Foundation
import ComposableArchitecture
import GRDB
import os
import ReTiCAPushCore

/// Writes the app-group sender directory the Notification Service Extension reads (spec
/// 2026-11-05 §4). The live writer is enabled on iOS only: macOS has no Notification Service
/// Extension, so nothing there would read the directory. Disabled in tests by default, so suites
/// that don't opt in never see the effect.
struct SenderDirectoryWriter: Sendable {
    var isEnabled: Bool
    var write: @Sendable (SenderDirectoryStore, [String: SenderDirectory.Input]) throws -> Void
}

extension SenderDirectoryWriter: DependencyKey {
    #if os(iOS)
    static let liveValue = SenderDirectoryWriter(isEnabled: true) { try $0.save($1) }
    #else
    static let liveValue = SenderDirectoryWriter(isEnabled: false) { try $0.save($1) }
    #endif
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
        let known = state.node.client.router.knownIdentities
        for hex in state.senderDirectoryCandidates(groupMembers: Array(state.senderDirectoryGroupMembers)) {
            // A presence check, not `senderPublicKey`, which would build a 64-byte key per peer.
            let hasKey = Data(hexString: hex).map { known[$0] != nil } ?? false
            candidates[hex] = Candidate(name: state.peerDisplayName(hex), hasKey: hasKey)
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
                } catch is CancellationError {
                    // Superseded by a newer write: nothing to report.
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

    /// Everything one write needs, resolved from state in the reducer (values only).
    struct WriteSnapshot: Sendable {
        var candidates: Set<String>
        var me: String
        var blocked: Set<String>
        var names: [String: String]
        var keys: [String: Data]
        var profiles: [String: PeerProfile]
        var links: [String: ContactLink]
        var cards: [String: ContactCard]

        init(_ state: AppFeature.State) {
            candidates = state.senderDirectoryCandidates(groupMembers: Array(state.senderDirectoryGroupMembers))
            names = [:]
            keys = [:]
            profiles = [:]
            for hex in candidates {
                names[hex] = state.peerDisplayName(hex)
                keys[hex] = state.senderPublicKey(hex)
                profiles[hex] = state.peerProfiles[hex]
            }
            me = state.myAddressHex
            blocked = state.blockedPeers
            links = state.contactLinks
            cards = state.contactCards
        }
    }

    /// Resolves names, keys and picture sources from `state` now, then reads photo files, fetches
    /// missing contact thumbnails and writes, off the reducer.
    private func writeEffect(_ state: State) -> Effect<Action> {
        let snapshot = WriteSnapshot(state)
        let store = state.push.storage.senderDirectory
        return .run { [writer, avatarStore, contactsClient] _ in
            await Self.writeDirectory(snapshot, to: store, writer: writer, avatarStore: avatarStore,
                                      contacts: contactsClient)
        }
        .cancellable(id: CancelID.write, cancelInFlight: true)
    }

    /// The write effect's body. Cancelling the effect does not interrupt the Contacts fetch or the
    /// image encoding, so cancellation is checked right before the write: a superseded write must
    /// not land after a newer one (its orphan sweep would delete the newer images). Write errors
    /// are logged; a cancellation is not an error.
    static func writeDirectory(_ snapshot: WriteSnapshot, to store: SenderDirectoryStore, writer: SenderDirectoryWriter,
                               avatarStore: AvatarStore, contacts: ContactsClient) async {
        let thumbnails = await contactThumbnails(links: snapshot.links, cards: snapshot.cards,
                                                 profiles: snapshot.profiles, candidates: snapshot.candidates,
                                                 contacts: contacts)
        let inputs = SenderDirectoryBuilder.inputs(
            candidates: snapshot.candidates, me: snapshot.me, blocked: snapshot.blocked,
            name: { snapshot.names[$0] }, publicKey: { snapshot.keys[$0] },
            picture: { hex in
                picture(profile: snapshot.profiles[hex], contactThumbnail: thumbnails[hex], avatarStore: avatarStore)
            })
        do {
            try Task.checkCancellation()
            try writer.write(store, inputs)
        } catch is CancellationError {
            // Superseded by a newer write.
        } catch {
            log.error("sender directory write failed: \(String(describing: error), privacy: .public)")
        }
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
