#if os(macOS)
import AppKit
import UserNotifications
import ReTiCAPush

extension PushPlatform {
    /// The real thing: alert permission through UserNotifications, the token through AppKit. The
    /// token itself arrives in `AppDelegate`.
    static let appKit = PushPlatform(
        requestAuthorization: {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        },
        registerForRemoteNotifications: {
            await MainActor.run { NSApplication.shared.registerForRemoteNotifications() }
        },
        unregisterForRemoteNotifications: {
            await MainActor.run { NSApplication.shared.unregisterForRemoteNotifications() }
        })
}
#endif
