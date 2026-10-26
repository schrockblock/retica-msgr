import Foundation
import ComposableArchitecture

/// Sets the app-icon badge (spec 2026-10-25 Part 2). The core package has no UserNotifications
/// wiring, so the live value does nothing and `AppRuntime` installs one over
/// `UNUserNotificationCenter.setBadgeCount` that also writes the extension's counter.
public struct BadgeClient: Sendable {
    public var set: @Sendable (Int) async -> Void

    public init(set: @escaping @Sendable (Int) async -> Void) {
        self.set = set
    }
}

extension BadgeClient: DependencyKey {
    public static let liveValue = BadgeClient(set: { _ in })
    public static let testValue = BadgeClient(set: unimplemented("BadgeClient.set"))
}

extension DependencyValues {
    public var badge: BadgeClient {
        get { self[BadgeClient.self] }
        set { self[BadgeClient.self] = newValue }
    }
}
