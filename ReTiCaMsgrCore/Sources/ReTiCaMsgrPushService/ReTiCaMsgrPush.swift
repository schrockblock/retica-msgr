import Foundation
import ReTiCAPushExtension

/// Constants and factories shared by the app and its Notification Service Extension. This target
/// deliberately depends only on `ReTiCAPushExtension`, so the extension links no TCA or SQLite.
public enum ReTiCaMsgrPush {
    /// Must match `com.apple.security.application-groups` in both entitlements files.
    public static let appGroupID = "group.co.lithobyte.ReTiCaMsgr"

    /// The inbox and shared settings for this process, or nil without the app-group entitlement.
    public static func storage() -> PushStorage? {
        PushStorage.appGroup(appGroupID)
    }
}
