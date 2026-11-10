import Foundation
import UserNotifications

/// What the Notification Service Extension hands back to the system. It lives here rather than in
/// the extension target so it can be tested.
public enum PushBanner {
    /// For `.deliverOriginal`: the original content with the default sound (the hub's payload
    /// carries none, so without this pushes arrive silently), badged with the app-group counter plus
    /// this push (spec 2026-10-25, amendment A1) when `badgeDefaults` is available.
    /// For `.suppress`: empty content (no title, body, sound or badge, which is what the filtering
    /// entitlement treats as "do not show"), which counts nothing.
    public static func content(for verdict: PushVerdict,
                               original: UNNotificationContent,
                               badgeDefaults: UserDefaults? = BadgeCounter.appGroupDefaults()) -> UNNotificationContent {
        switch verdict {
        case .deliverOriginal:
            guard let delivered = original.mutableCopy() as? UNMutableNotificationContent else { return original }
            delivered.sound = .default
            if let badgeDefaults {
                delivered.badge = NSNumber(value: BadgeCounter.increment(badgeDefaults))
            }
            return delivered
        case .suppress:
            return UNNotificationContent()
        }
    }
}
