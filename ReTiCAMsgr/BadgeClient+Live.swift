import Foundation
import UserNotifications
import ReTiCAMsgrCore
import ReTiCAMsgrPushService

extension BadgeClient {
    /// The real thing on both platforms: `setBadgeCount` badges the Home Screen icon on iOS and the
    /// Dock tile on macOS. The true count also goes to the extension's counter, so the next push
    /// counts up from it instead of from a stale overcount. Not allowed to badge is a silent no-op.
    static let userNotifications = BadgeClient(set: { n in
        if let defaults = BadgeCounter.appGroupDefaults() {
            BadgeCounter.set(n, defaults)
        }
        try? await UNUserNotificationCenter.current().setBadgeCount(n)
    })
}
