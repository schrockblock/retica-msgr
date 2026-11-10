import Testing
import Foundation
import UserNotifications
import ReTiCAMsgrPushService

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "test.\(UUID())")!
}

private func original() -> UNNotificationContent {
    let c = UNMutableNotificationContent()
    c.title = "New message"
    return c
}

@Test func pushBannerDeliversTheOriginalWithTheDefaultSound() {
    let c = PushBanner.content(for: .deliverOriginal, original: original(), badgeDefaults: freshDefaults())
    #expect(c.title == "New message")
    #expect(c.sound == .default)
}

@Test func pushBannerAddsTheSoundEvenWithoutBadgeDefaults() {
    let c = PushBanner.content(for: .deliverOriginal, original: original(), badgeDefaults: nil)
    #expect(c.sound == .default)
}

@Test func pushBannerBadgesFromTheAppGroupCounter() {
    let defaults = freshDefaults()
    BadgeCounter.set(4, defaults)
    let c = PushBanner.content(for: .deliverOriginal, original: original(), badgeDefaults: defaults)
    #expect(c.badge == 5)
}

@Test func pushBannerSuppressesToSilentEmptyContent() {
    let c = PushBanner.content(for: .suppress, original: original(), badgeDefaults: freshDefaults())
    #expect(c.title.isEmpty)
    #expect(c.body.isEmpty)
    #expect(c.sound == nil)
    #expect(c.badge == nil)
}

// MARK: - Sender on the banner

private let hex = String(repeating: "a", count: 32)

private func outcome(_ name: String?, verdict: PushVerdict = .deliverOriginal) -> PushOutcome {
    PushOutcome(verdict: verdict, sender: PushSenderMatch(hex: hex,
        entry: .init(name: name, publicKey: Data(repeating: 1, count: 64), imageFile: nil), imageURL: nil))
}

@Test func pushBannerTitlesANamedSender() {
    #expect(PushBanner.plan(for: outcome("Alice")) ==
            .init(title: "Alice", body: "New message", threadIdentifier: hex, senderHex: hex, imageURL: nil))
}

@Test func pushBannerTitlesAPictureOnlySenderWithShortHex() {
    #expect(PushBanner.plan(for: outcome(nil))?.title == "aaaaaaaa")
    #expect(PushBanner.plan(for: outcome("  "))?.title == "aaaaaaaa")
}

@Test func pushBannerHasNoPlanWithoutASender() {
    #expect(PushBanner.plan(for: PushOutcome(verdict: .deliverOriginal, sender: nil)) == nil)
}

@Test func pushBannerNamesTheSenderOnTheContentAndKeepsSoundAndBadge() async {
    let defaults = freshDefaults()
    BadgeCounter.set(2, defaults)
    let c = await PushBanner.content(for: outcome("Alice"), original: original(),
                                     badgeDefaults: defaults, applyIntent: { c, _ in c })
    #expect(c.title == "Alice")
    #expect(c.body == "New message")
    #expect(c.threadIdentifier == hex)
    #expect(c.sound == .default)
    #expect(c.badge == 3)
}

@Test func pushBannerSuppressesToEmptyContentForAnOutcome() async {
    let c = await PushBanner.content(for: outcome("Alice", verdict: .suppress), original: original(),
                                     badgeDefaults: freshDefaults(), applyIntent: { c, _ in c })
    #expect(c.title.isEmpty && c.body.isEmpty && c.sound == nil)
}

@Test func pushBannerLeavesTheOriginalWithoutASender() async {
    let c = await PushBanner.content(for: PushOutcome(verdict: .deliverOriginal, sender: nil),
                                     original: original(), badgeDefaults: freshDefaults(),
                                     applyIntent: { _, _ in Issue.record("called"); return original() })
    #expect(c.title == "New message")
    #expect(c.threadIdentifier.isEmpty)
}

@Test func pushBannerFallsBackWhenTheIntentStepThrows() async {
    struct Boom: Error {}
    let c = await PushBanner.content(for: outcome("Alice"), original: original(),
                                     badgeDefaults: freshDefaults(), applyIntent: { _, _ in throw Boom() })
    #expect(c.title == "Alice")
    #expect(c.body == "New message")
    #expect(c.threadIdentifier == hex)
    #expect(c.sound == .default)
}
