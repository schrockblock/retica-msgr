import Testing
import Foundation
import ReTiCaMsgrPushService

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

@Test func setOverwrites() {
    let defaults = freshDefaults()
    BadgeCounter.increment(defaults)
    BadgeCounter.set(7, defaults)
    #expect(BadgeCounter.increment(defaults) == 8)
}
