import UserNotifications
import ReTiCaMsgrPushService

/// Runs for every push with `mutable-content: 1` (spec 2026-10-01 §1, §3). Stashes the packets
/// and proves them to the hub, then hands back the ORIGINAL content: the banner always reads what
/// the server sent ("New message"). Nothing is decrypted here.
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
            finish()
            return
        }
        work = Task {
            await handler.handle(userInfo: userInfo)
            await MainActor.run { self.finish() }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        finish()
    }

    private func finish() {
        finishLock.lock()
        defer { finishLock.unlock() }
        guard let contentHandler, let originalContent else { return }
        self.contentHandler = nil
        contentHandler(originalContent)
    }
}
