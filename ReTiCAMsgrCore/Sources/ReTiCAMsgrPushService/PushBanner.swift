import Foundation
import Intents
import UserNotifications

/// What the Notification Service Extension hands back to the system. It lives here rather than in
/// the extension target so it can be tested.
public enum PushBanner {
    /// How a verified sender is shown: titled with their name (or a short hash) and grouped into
    /// one thread per sender.
    public struct Plan: Equatable {
        public var title: String
        public var body: String
        public var threadIdentifier: String
        public var senderHex: String
        public var imageURL: URL?

        public init(title: String, body: String, threadIdentifier: String, senderHex: String, imageURL: URL?) {
            self.title = title
            self.body = body
            self.threadIdentifier = threadIdentifier
            self.senderHex = senderHex
            self.imageURL = imageURL
        }
    }

    /// nil unless the push is delivered and its sender is verified. The title is the directory
    /// name (trimmed, non-empty) or else the first 8 hex characters of the sender hash.
    public static func plan(for outcome: PushOutcome) -> Plan? {
        guard case .deliverOriginal = outcome.verdict, let sender = outcome.sender else { return nil }
        let trimmed = sender.entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Plan(title: trimmed.isEmpty ? String(sender.hex.prefix(8)) : trimmed,
                    body: "New message",
                    threadIdentifier: sender.hex,
                    senderHex: sender.hex,
                    imageURL: sender.imageURL)
    }

    /// A mutable copy of `original` with the default sound (the hub's payload carries none, so
    /// without this pushes arrive silently) and `badge`. Shared by both `content` overloads.
    private static func delivered(_ original: UNNotificationContent, badge: Int?) -> UNMutableNotificationContent? {
        guard let copy = original.mutableCopy() as? UNMutableNotificationContent else { return nil }
        copy.sound = .default
        if let badge { copy.badge = NSNumber(value: badge) }
        return copy
    }

    /// For `.deliverOriginal`: the original content with the default sound, badged with the
    /// app-group counter plus this push (spec 2026-10-25, amendment A1) when `badgeDefaults` is
    /// available. This version READS AND STORES the count in one step, so it is for a path that is
    /// already the one delivering (the extension's timeout / no-handler path, inside `finishLock`).
    /// For `.suppress`: empty content (no title, body, sound or badge, which is what the filtering
    /// entitlement treats as "do not show"), which counts nothing.
    public static func content(for verdict: PushVerdict,
                               original: UNNotificationContent,
                               badgeDefaults: UserDefaults? = BadgeCounter.appGroupDefaults()) -> UNNotificationContent {
        switch verdict {
        case .deliverOriginal:
            return delivered(original, badge: badgeDefaults.map(BadgeCounter.increment)) ?? original
        case .suppress:
            return UNNotificationContent()
        }
    }

    /// The finished banner for an outcome: sound, badge and (with a verified sender) name, thread
    /// and picture, all set on ONE mutable content BEFORE `applyIntent`, whose result is returned
    /// unchanged (Apple treats what `updating(from:)` returns as the final Communication
    /// Notification, so it is never copied or mutated afterwards). If `applyIntent` throws, the
    /// titled content is returned.
    ///
    /// The badge on the content is `BadgeCounter.next` (stored count + 1) and is NOT stored here:
    /// this runs before the extension knows whether it or the timeout path delivers. Both paths read
    /// the same base value N and put N+1 on their content, and only the path that wins
    /// `finishLock` stores it, through `commitBadge(of:)`. So a push is counted once, and the
    /// number shown equals the number stored.
    public static func content(for outcome: PushOutcome,
                               original: UNNotificationContent,
                               badgeDefaults: UserDefaults? = BadgeCounter.appGroupDefaults(),
                               applyIntent: (UNMutableNotificationContent, Plan) async throws -> UNNotificationContent = PushBanner.liveIntent) async -> UNNotificationContent {
        switch outcome.verdict {
        case .suppress:
            return UNNotificationContent()
        case .deliverOriginal:
            guard let content = delivered(original, badge: badgeDefaults.map(BadgeCounter.next)) else { return original }
            guard let plan = plan(for: outcome) else { return content }
            content.title = plan.title
            content.body = plan.body
            content.threadIdentifier = plan.threadIdentifier
            do {
                return try await applyIntent(content, plan)
            } catch {
                return content
            }
        }
    }

    /// Stores the badge that `content(for: outcome, …)` put on `content`. Call it only from the path
    /// that is delivering (under the extension's `finishLock`). A no-op for content with no badge
    /// (suppressed, or no defaults).
    public static func commitBadge(of content: UNNotificationContent,
                                   badgeDefaults: UserDefaults? = BadgeCounter.appGroupDefaults()) {
        guard let badgeDefaults, let badge = content.badge else { return }
        BadgeCounter.commit(badge.intValue, badgeDefaults)
    }

    /// How long the extension waits for the Intents daemon to acknowledge the donation. The
    /// donation is an XPC call that cancelling the work Task does not interrupt, so without a
    /// deadline a stalled daemon would eat the whole ~30 s and the push would end up nameless.
    static let donationDeadline: TimeInterval = 1

    /// Runs `start` and returns when the callback it is given is called, or after `seconds`,
    /// whichever comes first. Unlike a task group, it does not wait for `start`'s work to finish
    /// (a group would wait for a child that ignores cancellation).
    static func awaitOrTimeout(seconds: TimeInterval,
                               start: (@escaping @Sendable () -> Void) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            raceDeadline(seconds: seconds, start: start, finished: { continuation.resume() })
        }
    }

    /// Calls `finished` once: when the callback given to `start` is called, or after `seconds`.
    /// The timer is a Dispatch timer, not a Task, so it does not depend on the cooperative pool.
    static func raceDeadline(seconds: TimeInterval,
                             start: (@escaping @Sendable () -> Void) -> Void,
                             finished: @escaping @Sendable () -> Void) {
        let once = Once(finished)
        let timer = DispatchWorkItem { once.fire() }
        once.timer = timer
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
        start { once.fire() }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?
        var timer: DispatchWorkItem?
        init(_ action: @escaping @Sendable () -> Void) { self.action = action }
        func fire() {
            lock.lock()
            let a = action
            action = nil
            lock.unlock()
            timer?.cancel()
            a?()
        }
    }

    /// Turns `content` into a Communication Notification: an incoming `INSendMessageIntent` whose
    /// sender carries the picture. `content` already carries the title, body, thread, sound and
    /// badge, and the result of `updating(from:)` is returned as is.
    public static func liveIntent(_ content: UNMutableNotificationContent, _ plan: Plan) async throws -> UNNotificationContent {
        let image = plan.imageURL.flatMap { try? Data(contentsOf: $0) }.map(INImage.init(imageData:))
        let person = INPerson(personHandle: INPersonHandle(value: plan.senderHex, type: .unknown),
                              nameComponents: nil,
                              displayName: plan.title,
                              image: image,
                              contactIdentifier: nil,
                              customIdentifier: plan.senderHex)
        let intent = INSendMessageIntent(recipients: nil,
                                         outgoingMessageType: .outgoingMessageText,
                                         content: nil,
                                         speakableGroupName: nil,
                                         conversationIdentifier: plan.senderHex,
                                         serviceName: nil,
                                         sender: person,
                                         attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        // The completion-handler `donate`, raced against a deadline (see `donationDeadline`).
        // A failed or late donation still gets the picture and the name.
        await awaitOrTimeout(seconds: donationDeadline) { done in
            interaction.donate { _ in done() }
        }
        return try content.updating(from: intent)
    }
}
