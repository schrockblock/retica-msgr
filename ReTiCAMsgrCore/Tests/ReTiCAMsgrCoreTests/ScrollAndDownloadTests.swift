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
