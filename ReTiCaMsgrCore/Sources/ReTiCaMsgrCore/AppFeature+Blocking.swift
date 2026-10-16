import Foundation
import ComposableArchitecture
import GRDB
import ReTiCAPushCore

/// The blocking and report arms of `AppFeature` (spec 2026-10-15 §2, §3), composed into
/// `AppFeature.body` after `ContactLinksReducer`; the main reducer treats every action handled
/// here as a no-op. The `blockedPeers` table is the truth: each arm tells the node first (it cannot
/// fail), then writes the row, then mirrors the hex set into the app-group `BlockedSenderStore`;
/// tests read the mirror after the effect finishes.
struct BlockingReducer: Reducer {
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date

    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            switch action {
            case let .blockPeer(raw):
                let hex = raw.lowercased()
                guard let hash = Data(hexString: hex), hash.count == 16 else { return .none }
                // A7: never block yourself (a self-chat or a shared identity would drop your own traffic).
                // A7: never block yourself (a self-chat or a shared identity would drop your own traffic).
                guard hex != state.myAddressHex.lowercased() else { return .none }
                guard !state.blockedPeers.contains(hex) else { return .none }
                state.blockedPeers.insert(hex)
                let row = BlockedPeer(peerHex: hex, blockedAt: date.now)
                state.blockedPeerRows.insert(row, at: 0)
                let mirror = state.blockedPeers
                let store = state.push.storage.blockedSenders
                return .run { [database] send in
                    await send(.node(.client(.ignoreDestination(hash))))
                    try await database.write { try BlockedPeer.insertIfAbsent(row, $0) }
                    store.save(mirror)
                }

            case let .unblockPeer(raw):
                let hex = raw.lowercased()
                guard let hash = Data(hexString: hex), hash.count == 16 else { return .none }
                state.blockedPeers.remove(hex)
                state.blockedPeerRows.removeAll { $0.peerHex == hex }
                let mirror = state.blockedPeers
                let store = state.push.storage.blockedSenders
                return .run { [database] send in
                    await send(.node(.client(.unignoreDestination(hash))))
                    try await database.write { try BlockedPeer.delete(peerHex: hex, $0) }
                    store.save(mirror)
                }

            case let .blockedPeersLoaded(rows):
                // State and mirror only. The node's rehydrate is sent by `reloadBlockedPeers`
                // right after this action, inside the launch effect that runs ahead of the node
                // start and the inbox drain (spec A5).
                state.blockedPeerRows = rows.map { var row = $0; row.peerHex = row.peerHex.lowercased(); return row }
                state.blockedPeers = Set(state.blockedPeerRows.map(\.peerHex))
                let mirror = state.blockedPeers
                let store = state.push.storage.blockedSenders
                return .run { _ in store.save(mirror) }

            case let .reportPeer(raw):
                let hex = raw.lowercased()
                let announcedName = state.peerAnnounceName(hex)
                let now = date.now
                return .run { [database] send in
                    let (rows, attachments) = try await database.read { db -> ([Message], [Attachment]) in
                        let rows = try Message.where { $0.peerHex.eq(hex) }.fetchAll(db)
                        let ids = rows.map(\.id)
                        let attachments = ids.isEmpty ? [] : try Attachment.where { $0.messageId.in(ids) }.fetchAll(db)
                        return (rows, attachments)
                    }
                    let names = Dictionary(attachments.map { ($0.messageId, $0.name) }, uniquingKeysWith: { first, _ in first })
                    await send(.reportDraftReady(ReportDraft.compose(peerHex: hex, announcedName: announcedName,
                                                                     messages: rows, attachmentNames: names,
                                                                     composedAt: now)))
                }

            case let .reportDraftReady(draft):
                state.reportDraft = draft
                return .none

            case .reportDismissed:
                state.reportDraft = nil
                return .none

            default:
                return .none
            }
        }
    }
}

/// Reads every block, hands it to the reducer, then gives the node the whole set, in that order
/// and before the caller's next effect runs (the launch concatenates this ahead of everything).
func reloadBlockedPeers(_ database: any DatabaseWriter, _ send: Send<AppFeature.Action>) async throws {
    let rows = try await database.read { try BlockedPeer.all($0) }
    await send(.blockedPeersLoaded(rows))
    let hashes = Set(rows.compactMap { Data(hexString: $0.peerHex.lowercased()) }.filter { $0.count == 16 })
    await send(.node(.client(.rehydrateIgnoredDestinations(hashes))))
}
