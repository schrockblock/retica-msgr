import UserNotifications
import ReTiCaMsgrCore

extension LocalNotificationClient {
    /// The real thing: an immediate local notification. Posts nothing unless notifications are
    /// already allowed, and never asks; push owns the permission prompt.
    static let userNotifications = LocalNotificationClient { id, title, body, threadID, userInfo in
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = threadID
        content.userInfo = userInfo
        content.sound = .default
        // A request with an id already delivered replaces that notification.
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
