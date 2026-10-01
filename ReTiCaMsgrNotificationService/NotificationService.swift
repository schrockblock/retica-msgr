import UserNotifications
import ReTiCaMsgrPushService

/// Runs for every push with `mutable-content: 1` (spec 2026-10-01 §1, §3). Stashes the packets
/// and proves them to the hub, then hands back the ORIGINAL content: the banner always reads what
/// the server sent ("New message"). Nothing is decrypted here.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var originalContent: UNNotificationContent?
    private var work: Task<Void, Never>?

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
        guard let contentHandler, let originalContent else { return }
        self.contentHandler = nil
        contentHandler(originalContent)
    }
}
