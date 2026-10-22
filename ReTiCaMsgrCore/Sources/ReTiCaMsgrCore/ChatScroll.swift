import CoreGraphics

/// Whether an open chat follows a new last message (brief 2026-10-21, auto-scroll). The view
/// tracks the scroll geometry and asks here; nothing in the view decides on its own.
public enum ChatScroll {
    /// How far above the bottom of the content the visible area may end and still count as
    /// "at the bottom", in points.
    public static let nearBottomThreshold: CGFloat = 80

    /// Whether the bottom of the visible area is within `nearBottomThreshold` of the bottom of
    /// the content (both in the scroll content's coordinates).
    public static func isNearBottom(contentHeight: CGFloat, visibleMaxY: CGFloat) -> Bool {
        contentHeight - visibleMaxY <= nearBottomThreshold
    }

    /// My own message is always followed; someone else's only when the reader was already at the
    /// bottom, so it never pulls them away from what they scrolled back to.
    public static func shouldFollow(newLastIsOutgoing: Bool, wasNearBottom: Bool) -> Bool {
        newLastIsOutgoing || wasNearBottom
    }
}
