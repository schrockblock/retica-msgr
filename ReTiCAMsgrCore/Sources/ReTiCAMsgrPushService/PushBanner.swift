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

    /// For `.deliverOriginal`: the original content with the default sound (the hub's payload
    /// carries none, so without this pushes arrive silently), badged with the app-group counter plus
    /// this push (spec 2026-10-25, amendment A1) when `badgeDefaults` is available.
    /// For `.suppress`: empty content (no title, body, sound or badge, which is what the filtering
    /// entitlement treats as "do not show"), which counts nothing.
    public static func content(for verdict: PushVerdict,
                               original: UNNotificationContent,
                               badgeDefaults: UserDefaults? = BadgeCounter.appGroupDefaults()) -> UNNotificationContent {
        switch verdict {
        case .deliverOriginal:
            guard let delivered = original.mutableCopy() as? UNMutableNotificationContent else { return original }
            delivered.sound = .default
            if let badgeDefaults {
                delivered.badge = NSNumber(value: BadgeCounter.increment(badgeDefaults))
            }
            return delivered
        case .suppress:
            return UNNotificationContent()
        }
    }

    /// `content(for: verdict, …)`, then, when the outcome carries a verified sender, the sender's
    /// name, thread and (through `applyIntent`) picture on top. If `applyIntent` throws, the titled
    /// copy is delivered. The sound and badge from the verdict version survive both paths.
    public static func content(for outcome: PushOutcome,
                               original: UNNotificationContent,
                               badgeDefaults: UserDefaults? = BadgeCounter.appGroupDefaults(),
                               applyIntent: (UNMutableNotificationContent, Plan) async throws -> UNNotificationContent = PushBanner.liveIntent) async -> UNNotificationContent {
        let base = content(for: outcome.verdict, original: original, badgeDefaults: badgeDefaults)
        guard let plan = plan(for: outcome),
              let titled = base.mutableCopy() as? UNMutableNotificationContent else { return base }
        titled.title = plan.title
        titled.body = plan.body
        titled.threadIdentifier = plan.threadIdentifier
        do {
            return try await applyIntent(titled, plan)
        } catch {
            return titled
        }
    }

    /// Adds this push to the app-group counter and puts the total on a copy of `content`. Split
    /// out so the extension can count only the push whose content is actually delivered.
    public static func badged(_ content: UNNotificationContent,
                              badgeDefaults: UserDefaults? = BadgeCounter.appGroupDefaults()) -> UNNotificationContent {
        guard let badgeDefaults, let copy = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        copy.badge = NSNumber(value: BadgeCounter.increment(badgeDefaults))
        return copy
    }

    /// Turns `content` into a Communication Notification: an incoming `INSendMessageIntent` whose
    /// sender carries the picture. The result keeps `content`'s sound and badge.
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
        try? await interaction.donate()
        let updated = try content.updating(from: intent)
        // `updating(from:)` should keep these; setting them again makes it not our assumption.
        guard let result = updated.mutableCopy() as? UNMutableNotificationContent else { return updated }
        result.sound = content.sound
        result.badge = content.badge
        return result
    }
}
