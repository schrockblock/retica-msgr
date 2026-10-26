import Foundation

/// The badge number while the app isn't running (spec 2026-10-25, amendment A1): the Notification
/// Service Extension adds 1 per delivered push, and the app writes the true count back every time
/// it recomputes, which corrects any overcount. Kept in the app group's defaults so both processes
/// see it. No TCA here: the extension links this target.
public enum BadgeCounter {
    static let key = "badgeCount"

    /// The app group's defaults. In practice this is never nil (it is nil only for a reserved suite
    /// name such as the app's own bundle ID). Without the app-group entitlement you still get a
    /// store, but it is private to the process, so the app and the extension each count on their
    /// own and the app's write-back doesn't reach the extension.
    public static func appGroupDefaults() -> UserDefaults? {
        UserDefaults(suiteName: ReTiCaMsgrPush.appGroupID)
    }

    /// Adds one and returns the new count.
    @discardableResult
    public static func increment(_ defaults: UserDefaults) -> Int {
        let n = defaults.integer(forKey: key) + 1
        defaults.set(n, forKey: key)
        return n
    }

    public static func set(_ n: Int, _ defaults: UserDefaults) {
        defaults.set(n, forKey: key)
    }
}
