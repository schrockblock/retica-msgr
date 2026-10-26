import Foundation
import ComposableArchitecture
import GRDB

private enum ProfilePhotoCancelID: Hashable { case pick }

/// My profile photo and the mirror of peers' profiles (spec 2026-10-19), composed into
/// `AppFeature.body` after `BlockingReducer`; the main reducer treats every action handled here as
/// a no-op. The encode runs in the effect, off the main actor; the version is set only after the
/// file is on disk, so a version never points at a missing file.
struct ProfilePhotoReducer: Reducer {
    @Dependency(\.avatarStore) var avatarStore
    @Dependency(\.continuousClock) var clock

    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            switch action {
            case let .profilePhotoPicked(source):
                state.profilePhotoError = nil
                return .run { [avatarStore, clock] send in
                    do {
                        // A yield point so a remove can cancel the pick before the file is written.
                        try await clock.sleep(for: .milliseconds(1))
                        let encoded = try ImageEncoder.encodeAvatar(source)
                        try Task.checkCancellation()
                        try avatarStore.storeMine(encoded.data)
                        try Task.checkCancellation()
                        await send(.profilePhotoSaved(version: ProfileWire.version(of: encoded.data).hexString))
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.profilePhotoFailed)
                    }
                }
                .cancellable(id: ProfilePhotoCancelID.pick, cancelInFlight: true)

            case let .profilePhotoSaved(version):
                state.$myPhotoVersion.withLock { $0 = version }
                return .none

            case .profilePhotoFailed:
                state.profilePhotoError = "That photo couldn't be used. Try another."
                return .none

            case .removeProfilePhotoTapped:
                state.$myPhotoVersion.withLock { $0 = "" }
                return .merge(
                    .cancel(id: ProfilePhotoCancelID.pick),
                    .run { [avatarStore] _ in
                        try? avatarStore.deleteMine()
                    }
                )

            case let .myPhotoFileMissing(version):
                // Only the version launch checked: a photo picked since then stays.
                if state.myPhotoVersion == version {
                    state.$myPhotoVersion.withLock { $0 = "" }
                }
                return .none

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

/// Launch reconciliation (final review 1 and 5), run before `reloadPeerProfiles`:
/// - my version survives a backup restore in UserDefaults while `me.jpg` (excluded from backup)
///   does not, so a version with no file hashing to it is reset (peers then get a removal);
/// - the router's pending deliveries are in memory only, so no outcome will ever settle a stored
///   pending pair: every one is cleared and the next message carries the photo (and the display
///   name, spec 2026-10-25) again;
/// - a peer row whose photo file is gone loses its photo, so the avatar falls through.
func reconcileProfilePhotosAtLaunch(_ database: any DatabaseWriter, _ avatarStore: AvatarStore,
                                    myVersion: String, now: Date,
                                    _ send: Send<AppFeature.Action>) async throws {
    if !myVersion.isEmpty,
       avatarStore.mine().map({ ProfileWire.version(of: $0).hexString }) != myVersion {
        await send(.myPhotoFileMissing(version: myVersion))
    }
    try await database.write { db in
        try ProfilePhotoDelivery.clearAllPending(db)
        try ProfileNameDelivery.clearAllPending(db)
        try PeerProfile.clearMissingPhotos(fileExists: { avatarStore.hasFile($0) }, at: now, db)
    }
}

/// Reads every stored peer profile and hands it to the reducer (launch).
func reloadPeerProfiles(_ database: any DatabaseWriter, _ send: Send<AppFeature.Action>) async throws {
    let rows = try await database.read { try PeerProfile.all($0) }
    await send(.peerProfilesLoaded(rows))
}
