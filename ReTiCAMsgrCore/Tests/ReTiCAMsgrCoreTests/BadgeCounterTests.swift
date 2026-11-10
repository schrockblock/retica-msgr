import Testing
import Foundation
import ReTiCAMsgrPushService

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "test.\(UUID())")!
}

@Test func incrementStartsAtOne() {
    #expect(BadgeCounter.increment(freshDefaults()) == 1)
}

@Test func incrementAccumulates() {
    let defaults = freshDefaults()
    BadgeCounter.increment(defaults)
    BadgeCounter.increment(defaults)
    #expect(BadgeCounter.increment(defaults) == 3)
}

@Test func nextPeeksWithoutStoring() {
    let defaults = freshDefaults()
    BadgeCounter.set(4, defaults)
    #expect(BadgeCounter.next(defaults) == 5)
    #expect(BadgeCounter.next(defaults) == 5)
    #expect(BadgeCounter.increment(defaults) == 5)
}

@Test func commitStoresTheGivenCount() {
    let defaults = freshDefaults()
    BadgeCounter.commit(6, defaults)
    #expect(BadgeCounter.next(defaults) == 7)
}

@Test func setOverwrites() {
    let defaults = freshDefaults()
    BadgeCounter.increment(defaults)
    BadgeCounter.set(7, defaults)
    #expect(BadgeCounter.increment(defaults) == 8)
}
