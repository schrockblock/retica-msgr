import UIKit
import UserNotifications
import ReTiCAPushCore
import ReTiCaMsgrCore

/// Owns the runtime so a background push can build the store without a scene, forwards the APNs
/// token, and handles notification presentation and taps (spec 2026-10-01 §3.2).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let runtime = AppRuntime(environment: .forProcess())

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

    // MARK: Presentation and taps

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // A send that failed outside the open chat: the user is on another screen, so show it
        // even while the app is active.
        if SendFailedNotification.peerHex(from: notification.request.content.userInfo) != nil {
            return [.banner, .list, .sound]
        }
        // Foreground: the message is about to appear in the UI, so no banner. Drain instead.
        if UIApplication.shared.applicationState == .active {
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

    /// Append the decoded packets to the inbox. A no-op for packets the extension already wrote.
    private func stash(_ packets: [Data]) {
        let inbox = runtime.pushStorage.inbox
        for raw in packets {
            _ = try? inbox.append(raw)
        }
    }
}
