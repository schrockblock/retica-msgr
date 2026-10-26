import ComposableArchitecture
@testable import ReTiCaMsgrCore

extension BadgeClient {
    /// For TestStore tests that don't assert on the badge: the testValue is `unimplemented`.
    static let ignored = BadgeClient(set: { _ in })

    /// Appends every value set to `calls`.
    static func recording(into calls: LockIsolated<[Int]>) -> BadgeClient {
        BadgeClient(set: { n in calls.withValue { $0.append(n) } })
    }
}
