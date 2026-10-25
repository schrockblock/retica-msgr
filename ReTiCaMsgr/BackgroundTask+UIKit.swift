#if os(iOS)
#if canImport(UIKit)
import UIKit
#endif
import ReTiCaMsgrCore

extension BackgroundTaskClient {
    /// The real thing: UIKit background time, named for the debugger's task list.
    static let uiKit = BackgroundTaskClient(
        begin: { onExpire in await MainActor.run { LiveBackgroundTasks.begin(onExpire) } },
        end: { id in await MainActor.run { LiveBackgroundTasks.end(UIBackgroundTaskIdentifier(rawValue: id)) } },
        remaining: { await MainActor.run { UIApplication.shared.backgroundTimeRemaining } })
}

/// The background tasks begun and not yet ended. iOS requires `endBackgroundTask` before the
/// expiration handler returns, so the handler ends its own task; the reducer's later `end` for it
/// then finds the id gone and does nothing (each id is ended once).
@MainActor
private enum LiveBackgroundTasks {
    static var ids: Set<UIBackgroundTaskIdentifier> = []

    /// The id, set once `beginBackgroundTask` returns, for the handler that cannot capture it sooner.
    private final class Slot {
        var id = UIBackgroundTaskIdentifier.invalid
    }

    static func begin(_ onExpire: @escaping @Sendable () -> Void) -> Int? {
        let slot = Slot()
        let id = UIApplication.shared.beginBackgroundTask(withName: "Finish sending") {
            onExpire()
            end(slot.id)
        }
        guard id != .invalid else { return nil }
        slot.id = id
        ids.insert(id)
        return id.rawValue
    }

    static func end(_ id: UIBackgroundTaskIdentifier) {
        guard ids.remove(id) != nil else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
#endif
