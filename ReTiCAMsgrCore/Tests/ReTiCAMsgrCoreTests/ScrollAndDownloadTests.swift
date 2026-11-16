import Testing
import Foundation
import ReTiCA
@testable import ReTiCANode
@testable import ReTiCAMsgrCore

// Auto-scroll and the incoming-download banner (brief 2026-10-21). Each test names the mutation
// of the code under test that it must catch.

// MARK: - ChatScroll

/// Mutation: ignore isOutgoing (`shouldFollow` returns `wasNearBottom`).
@Test func followsOwnMessageWhenScrolledUp() {
    #expect(ChatScroll.shouldFollow(newLastIsOutgoing: true, wasNearBottom: false))
}

/// Mutation: ignore wasNearBottom (`shouldFollow` returns `newLastIsOutgoing`).
@Test func followsIncomingWhenNearBottom() {
    #expect(ChatScroll.shouldFollow(newLastIsOutgoing: false, wasNearBottom: true))
}

/// Mutation: always follow (`shouldFollow` returns true).
@Test func staysPutForIncomingWhenScrolledUp() {
    #expect(!ChatScroll.shouldFollow(newLastIsOutgoing: false, wasNearBottom: false))
}

/// Mutation: `<` instead of `<=` in `isNearBottom`.
@Test func nearBottomUsesThreshold() {
    #expect(ChatScroll.nearBottomThreshold == 80)
    #expect(ChatScroll.isNearBottom(contentHeight: 1000, visibleMaxY: 920))   // exactly 80 pt
    #expect(!ChatScroll.isNearBottom(contentHeight: 1000, visibleMaxY: 919))  // 81 pt
}

/// Mutation: pin whenever the inset changes (drop `wasNearBottom`).
@Test func growingInsetPinsOnlyAReaderAtTheBottom() {
    #expect(ChatScroll.shouldPin(oldBottomInset: 60, newBottomInset: 396, wasNearBottom: true))
    #expect(!ChatScroll.shouldPin(oldBottomInset: 60, newBottomInset: 396, wasNearBottom: false))
}

/// Mutation: `!=` instead of `>` (pin on a shrinking inset too).
@Test func shrinkingOrSteadyInsetNeverPins() {
    #expect(!ChatScroll.shouldPin(oldBottomInset: 396, newBottomInset: 60, wasNearBottom: true))
    #expect(!ChatScroll.shouldPin(oldBottomInset: 60, newBottomInset: 60, wasNearBottom: true))
}

/// Mutation: show only for unseen messages (`showsJumpButton` returns `unseenCount > 0`).
@Test func jumpButtonShowsWheneverScrolledUp() {
    #expect(ChatScroll.showsJumpButton(nearBottom: false, unseenCount: 0))
}

/// Mutation: always show (`showsJumpButton` returns true).
@Test func jumpButtonHidesAtTheBottom() {
    #expect(!ChatScroll.showsJumpButton(nearBottom: true, unseenCount: 0))
}

/// Mutation: ignore unseenCount (`showsJumpButton` returns `!nearBottom`).
@Test func jumpButtonShowsForUnseenMessages() {
    #expect(ChatScroll.showsJumpButton(nearBottom: true, unseenCount: 2))
}

/// Mutation: badge a zero count (drop the guard).
@Test func jumpBadgeIsEmptyWithNothingUnseen() {
    #expect(ChatScroll.jumpBadgeText(unseenCount: 0) == nil)
}

/// Mutation: `>=` instead of `>` at the cap, or no cap.
@Test func jumpBadgeCountsUpToNinetyNine() {
    #expect(ChatScroll.jumpBadgeText(unseenCount: 1) == "1")
    #expect(ChatScroll.jumpBadgeText(unseenCount: 99) == "99")
    #expect(ChatScroll.jumpBadgeText(unseenCount: 100) == "99+")
}

/// Mutation: always the plural (or always "Latest message").
@Test func jumpButtonLabelNamesWhatIsWaiting() {
    #expect(ChatScroll.jumpButtonLabel(unseenCount: 0) == "Latest message")
    #expect(ChatScroll.jumpButtonLabel(unseenCount: 1) == "1 new message")
    #expect(ChatScroll.jumpButtonLabel(unseenCount: 3) == "3 new messages")
}

// MARK: - incomingDownloadFraction

/// Mutation: return 0 instead of nil when nothing is arriving.
@Test func noDownloadMeansNoFraction() {
    let state = AppFeature.State(identity: Identity())
    #expect(state.node.client.inboundProgress.isEmpty)
    #expect(state.incomingDownloadFraction == nil)
}

/// Mutation: return the max instead of the mean.
@Test func downloadFractionIsMeanOfTransfers() {
    var state = AppFeature.State(identity: Identity())
    state.node.client.inboundProgress[Data([0x01])] = 0.25
    state.node.client.inboundProgress[Data([0x02])] = 0.75
    #expect(state.incomingDownloadFraction == 0.5)
}
