import UserNotifications
import ReTiCaMsgrPushService

/// Runs for every push with `mutable-content: 1` (spec 2026-10-01 §1, §3; spec 2026-10-15 §4).
/// Stashes the packets and proves them to the hub, then hands back the ORIGINAL content, unless
/// every packet in the push could be attributed and every one came from a blocked sender (spec A6): then it hands back EMPTY content, which
/// hides the banner once `com.apple.developer.usernotifications.filtering` is in the profile and
/// before that iOS shows the original content anyway. Nothing but the sender hash is decrypted here.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var originalContent: UNNotificationContent?
    private var work: Task<Void, Never>?
    // M5: `finish()` can be called from the normal path (the Task, hopped to the main actor) and
    // from `serviceExtensionTimeWillExpire()` (a system callback with no isolation guarantee
    // relative to that Task) at the same time. Without a lock both can observe `contentHandler` as
    // non-nil and both call it — UNNotificationServiceExtension asserts/terminates the extension
    // if its content handler is invoked twice.
    private let finishLock = NSLock()

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.originalContent = request.content
        let userInfo = request.content.userInfo
        guard let handler = ReTiCaMsgrPush.makeServiceHandler() else {
            finish(.deliverOriginal)
            return
        }
        work = Task {
            let verdict = await handler.handle(userInfo: userInfo)
            await MainActor.run { self.finish(verdict) }
        }
    }

    /// Out of time: the original, never a suppression we did not decide.
    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        finish(.deliverOriginal)
    }

    /// What goes back to the system for `verdict`: the original content, or empty content for
    /// `.suppress` (no title, body, sound or badge, which is what the filtering entitlement
    /// treats as "do not show").
    static func content(for verdict: PushVerdict, original: UNNotificationContent) -> UNNotificationContent {
        switch verdict {
        case .deliverOriginal: return original
        case .suppress: return UNNotificationContent()
        }
    }

    private func finish(_ verdict: PushVerdict) {
        finishLock.lock()
        defer { finishLock.unlock() }
        guard let contentHandler, let originalContent else { return }
        self.contentHandler = nil
        contentHandler(Self.content(for: verdict, original: originalContent))
    }
}
