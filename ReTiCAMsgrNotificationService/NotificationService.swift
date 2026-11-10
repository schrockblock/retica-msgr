import UserNotifications
import ReTiCAMsgrPushService

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
        guard let handler = ReTiCAMsgrPush.makeServiceHandler() else {
            deliverOriginal(original: request.content)
            return
        }
        let original = request.content
        work = Task {
            let outcome = await handler.outcome(userInfo: userInfo)
            if Task.isCancelled { return } // timed out: that path delivers
            // The (async) intent step can outlast the timeout, so the content is built before the
            // lock is taken. It carries the NEXT badge value (stored count + 1) but stores nothing,
            // and is never copied afterwards (a Communication Notification must stay as
            // `updating(from:)` returned it). Only the path that wins the lock counts the push, and
            // it adds one to the stored count rather than storing the peeked value: another push in
            // this process (its own instance, its own lock) may have peeked the same base. The
            // number drawn may lag by one; the stored count is exact.
            let defaults = BadgeCounter.appGroupDefaults()
            let content = await PushBanner.content(for: outcome, original: original, badgeDefaults: defaults)
            finish {
                PushBanner.commitBadge(of: content, badgeDefaults: defaults)
                return content
            }
        }
    }

    /// Out of time: the original (titled by nobody), never a suppression we did not decide.
    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        if let originalContent { deliverOriginal(original: originalContent) }
    }

    /// The sync, name-less banner: sound and badge, no sender. Built inside `finish`'s lock, so
    /// the badge is only counted when this path is the one that delivers.
    private func deliverOriginal(original: UNNotificationContent) {
        finish { PushBanner.content(for: .deliverOriginal, original: original) }
    }

    /// Hands `makeContent()` to the system, once. `makeContent` runs under `finishLock` and only if
    /// no earlier call delivered, so any side effect in it (the badge count) happens for the winner
    /// alone.
    private func finish(_ makeContent: () -> UNNotificationContent) {
        finishLock.lock()
        defer { finishLock.unlock() }
        guard let contentHandler else { return }
        self.contentHandler = nil
        contentHandler(makeContent())
    }
}
