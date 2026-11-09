import Foundation
import ReTiCAKeychain
// Re-exported so callers that only `import ReTiCAMsgrPushService` (e.g. the Notification Service
// Extension) still see `PushServiceHandler`'s members under the MemberImportVisibility upcoming
// feature, without importing ReTiCAPushExtension directly.
@_exported import ReTiCAPushExtension

/// Constants and factories shared by the app and its Notification Service Extension. This target
/// deliberately depends only on `ReTiCAPushExtension`, so the extension links no TCA or SQLite.
public enum ReTiCAMsgrPush {
    /// Must match `com.apple.security.application-groups` in both entitlements files.
    public static let appGroupID = "group.co.lithobyte.ReTiCaMsgr"

    /// The inbox and shared settings for this process, or nil without the app-group entitlement.
    public static func storage() -> PushStorage? {
        PushStorage.appGroup(appGroupID)
    }

    /// The extension's handler: inbox and settings from the app group, identity from the shared
    /// Keychain location the app wrote into the settings, proofs over one TCP connection. The own
    /// ratchet ring is read (never written) from the same access group, so a blocked sender who
    /// encrypts to one of our ratchets is still attributed.
    public static func makeServiceHandler() -> PushServiceHandler? {
        storage().map { makeServiceHandler(storage: $0) }
    }

    static func makeServiceHandler(storage: PushStorage, ops: KeychainOps = .live) -> PushServiceHandler {
        let accessGroup = storage.settings.load().keychainAccessGroup
        return PushServiceHandler.live(storage: storage,
                                       loadRatchets: OwnRatchetRing.reader(accessGroup: accessGroup, ops: ops))
    }
}
