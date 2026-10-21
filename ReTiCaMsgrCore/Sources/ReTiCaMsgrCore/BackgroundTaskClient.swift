import Foundation
import ComposableArchitecture

/// Background time for sends still in flight when the app leaves the foreground (spec 2026-10-21,
/// amendment A4). The core package has no UIKit, so the live value grants nothing (the sockets
/// close at once, as before) and `AppRuntime` installs one over
/// `UIApplication.beginBackgroundTask`.
public struct BackgroundTaskClient: Sendable {
    /// Asks iOS for background time. Returns nil when none is granted. `onExpire` runs when it runs out.
    public var begin: @Sendable (_ onExpire: @escaping @Sendable () -> Void) async -> Int?
    public var end: @Sendable (Int) async -> Void

    public init(begin: @escaping @Sendable (_ onExpire: @escaping @Sendable () -> Void) async -> Int?,
                end: @escaping @Sendable (Int) async -> Void) {
        self.begin = begin
        self.end = end
    }
}

extension BackgroundTaskClient: DependencyKey {
    public static let liveValue = BackgroundTaskClient(begin: { _ in nil }, end: { _ in })
    public static let testValue = BackgroundTaskClient(
        begin: unimplemented("BackgroundTaskClient.begin", placeholder: nil),
        end: unimplemented("BackgroundTaskClient.end"))
}

extension DependencyValues {
    public var backgroundTask: BackgroundTaskClient {
        get { self[BackgroundTaskClient.self] }
        set { self[BackgroundTaskClient.self] = newValue }
    }
}
