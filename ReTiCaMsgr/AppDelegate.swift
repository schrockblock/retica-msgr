#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if os(macOS)
import ServiceManagement
#endif
import UserNotifications
import ReTiCAPushCore
import ReTiCaMsgrCore

/// Owns the runtime so a background push can build the store without a scene, forwards the APNs
/// token, and handles notification presentation and taps (spec 2026-10-01 §3.2).
final class AppDelegate: NSObject, UNUserNotificationCenterDelegate {
    let runtime = AppRuntime(environment: .forProcess())
    #if os(macOS)
    /// Set when the system opened the app at login; the main window closes itself once and clears it.
    var launchedAsLoginItem = false
    #endif

    // MARK: Presentation and taps

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // A send that failed outside the open chat: the user is on another screen, so show it
        // even while the app is active.
        if SendFailedNotification.peerHex(from: notification.request.content.userInfo) != nil {
            return [.banner, .list, .sound]
        }
        // Foreground: the message is about to appear in the UI, so no banner. Drain instead.
        if isAppActive {
            let packets = (try? PushPayload.decode(notification.request.content.userInfo)) ?? []
            stash(packets)
            runtime.drainPushInbox()
            // The hub carries no packets for mail waiting at a propagation node: go and fetch it.
            if PushPayload.isPropagated(notification.request.content.userInfo) {
                runtime.propagatedPush()
            }
            return []
        }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        // A local "Message not sent": open that chat. Not a push, so no wake.
        if let peerHex = SendFailedNotification.peerHex(from: response.notification.request.content.userInfo) {
            runtime.openFailedSend(peerHex)
            return
        }
        let packets = (try? PushPayload.decode(response.notification.request.content.userInfo)) ?? []
        stash(packets)
        // M2: a tap means the user is already looking at the app — nothing to hold for.
        _ = await runtime.pushWake(hold: .zero)
    }

    private var isAppActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        NSApplication.shared.isActive
        #endif
    }

    /// Append the decoded packets to the inbox. A no-op for packets the extension already wrote.
    private func stash(_ packets: [Data]) {
        let inbox = runtime.pushStorage.inbox
        for raw in packets {
            _ = try? inbox.append(raw)
        }
    }
}

#if os(iOS)
extension AppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: Token

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        runtime.pushDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        runtime.pushDeviceTokenFailed(error.localizedDescription)
    }

    // MARK: Background wake (content-available)

    // M3: `nonisolated` so the msgpack decode (possibly several packets) runs off the main actor;
    // only the inbox write and the wake itself touch actor-isolated state, so just those hop over.
    nonisolated func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // The extension already stashed the packets. Stash again anyway (idempotent) in case it
        // was killed before writing, then wake the store.
        let packets = (try? PushPayload.decode(userInfo)) ?? []
        await MainActor.run { self.stash(packets) }
        return await runtime.pushWake() ? .newData : .noData
    }
}
#endif

#if os(macOS)
extension AppDelegate: NSApplicationDelegate {
    /// Before launch finishes, so a notification click that launched the app reaches the delegate.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        launchedAsLoginItem = LaunchAtLogin.launchEventIsLoginItem()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Connect now, window or not: a login launch starts in the menu bar only.
        runtime.build()
        // Hosted tests run inside this app; they must never add it to the login items.
        if !AppRuntime.Environment.isTestHost {
            LaunchAtLogin.registerOnFirstRun(defaults: .standard, service: SMAppService.mainApp)
        }
    }

    /// Closing the window leaves the app in the menu bar, not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Token

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        runtime.pushDeviceToken(deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        runtime.pushDeviceTokenFailed(error.localizedDescription)
    }

    // MARK: Remote notification

    // No completion handler on the Mac: stash what the payload carries, then wake the store.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        let packets = (try? PushPayload.decode(userInfo)) ?? []
        stash(packets)
        Task { _ = await runtime.pushWake() }
    }
}
#endif
