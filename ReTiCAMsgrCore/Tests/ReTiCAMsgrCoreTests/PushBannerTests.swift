import Testing
import Foundation
import UserNotifications
@testable import ReTiCAMsgrPushService

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

@Test func pushBannerPeeksTheBadgeWithoutStoringIt() async {
    let defaults = freshDefaults()
    BadgeCounter.set(2, defaults)
    let c = await PushBanner.content(for: outcome("Alice"), original: original(),
                                     badgeDefaults: defaults, applyIntent: { c, _ in c })
    #expect(c.badge == 3)
    #expect(BadgeCounter.next(defaults) == 3) // still 2 stored
}

@Test func pushBannerWithoutBadgeDefaultsLeavesTheBadgeUnset() async {
    let c = await PushBanner.content(for: outcome("Alice"), original: original(),
                                     badgeDefaults: nil, applyIntent: { c, _ in c })
    #expect(c.badge == nil)
    #expect(c.sound == .default)
}

@Test func pushBannerCommitStoresTheContentsBadgeExactlyOnce() async {
    let defaults = freshDefaults()
    BadgeCounter.set(2, defaults)
    let c = await PushBanner.content(for: outcome("Alice"), original: original(),
                                     badgeDefaults: defaults, applyIntent: { c, _ in c })
    PushBanner.commitBadge(of: c, badgeDefaults: defaults)
    #expect(c.badge == 3)
    #expect(BadgeCounter.next(defaults) == 4) // stored is 3, not 4 or 2
}

@Test func pushBannerCommitIgnoresContentWithoutABadge() async {
    let defaults = freshDefaults()
    BadgeCounter.set(2, defaults)
    let suppressed = await PushBanner.content(for: outcome("Alice", verdict: .suppress), original: original(),
                                              badgeDefaults: defaults, applyIntent: { c, _ in c })
    PushBanner.commitBadge(of: suppressed, badgeDefaults: defaults)
    PushBanner.commitBadge(of: original(), badgeDefaults: defaults)
    #expect(BadgeCounter.next(defaults) == 3) // still 2
}

@Test func pushBannerSetsEverythingBeforeTheIntentStepAndReturnsItsResultAsIs() async {
    let defaults = freshDefaults()
    BadgeCounter.set(2, defaults)
    nonisolated(unsafe) var seen: UNMutableNotificationContent?
    let c = await PushBanner.content(for: outcome("Alice"), original: original(),
                                     badgeDefaults: defaults, applyIntent: { c, _ in seen = c; return c })
    #expect(seen?.title == "Alice")
    #expect(seen?.threadIdentifier == hex)
    #expect(seen?.sound == .default)
    #expect(seen?.badge == 3)
    #expect(c === seen)
}

// Dispatch semaphores, not async/await, so the timing does not depend on the cooperative pool
// (a loaded full-suite run can starve it for a minute).
@Test func pushBannerDonationHangingStillFinishesAtTheDeadline() {
    let done = DispatchSemaphore(value: 0)
    PushBanner.raceDeadline(seconds: 0.1, start: { _ in }, finished: { done.signal() })
    #expect(done.wait(timeout: .now() + 5) == .success)
}

@Test func pushBannerDonationAcknowledgedFinishesBeforeTheDeadline() {
    let done = DispatchSemaphore(value: 0)
    PushBanner.raceDeadline(seconds: 60, start: { ack in ack() }, finished: { done.signal() })
    #expect(done.wait(timeout: .now() + 5) == .success)
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
