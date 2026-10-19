import Foundation
import ComposableArchitecture
import GRDB

/// My profile photo and the mirror of peers' profiles (spec 2026-10-19), composed into
/// `AppFeature.body` after `BlockingReducer`; the main reducer treats every action handled here as
/// a no-op. The encode runs in the effect, off the main actor; the version is set only after the
/// file is on disk, so a version never points at a missing file.
struct ProfilePhotoReducer: Reducer {
    @Dependency(\.avatarStore) var avatarStore

    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            switch action {
            case let .profilePhotoPicked(source):
                state.profilePhotoError = nil
                return .run { [avatarStore] send in
                    do {
                        let encoded = try ImageEncoder.encodeAvatar(source)
                        try avatarStore.storeMine(encoded.data)
                        await send(.profilePhotoSaved(version: ProfileWire.version(of: encoded.data).hexString))
                    } catch {
                        await send(.profilePhotoFailed)
                    }
                }

            case let .profilePhotoSaved(version):
                state.$myPhotoVersion.withLock { $0 = version }
                return .none

            case .profilePhotoFailed:
                state.profilePhotoError = "That photo couldn't be used. Try another."
                return .none

            case .removeProfilePhotoTapped:
                state.$myPhotoVersion.withLock { $0 = "" }
                return .run { [avatarStore] _ in
                    try? avatarStore.deleteMine()
                }

            case let .peerProfilesLoaded(rows):
                state.peerProfiles = Dictionary(rows.map { ($0.peerHex, $0) }, uniquingKeysWith: { _, last in last })
                return .none

            case let .peerProfileUpdated(peerHex, profile):
                state.peerProfiles[peerHex] = profile
                return .none

            default:
                return .none
            }
        }
    }
}

/// Reads every stored peer profile and hands it to the reducer (launch).
func reloadPeerProfiles(_ database: any DatabaseWriter, _ send: Send<AppFeature.Action>) async throws {
    let rows = try await database.read { try PeerProfile.all($0) }
    await send(.peerProfilesLoaded(rows))
}
