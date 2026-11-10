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
