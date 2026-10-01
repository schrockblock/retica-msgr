import UIKit
import UserNotifications
import ReTiCAPush

extension PushPlatform {
    /// The real thing: alert permission through UserNotifications, the token through UIKit. The
    /// token itself arrives in `AppDelegate`.
    static let uiKit = PushPlatform(
        requestAuthorization: {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        },
        registerForRemoteNotifications: {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        },
        unregisterForRemoteNotifications: {
            await MainActor.run { UIApplication.shared.unregisterForRemoteNotifications() }
        })
}
