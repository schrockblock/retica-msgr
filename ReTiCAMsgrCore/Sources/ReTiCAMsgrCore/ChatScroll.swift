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

    /// Whether the thread stays on its latest message when the area under it grows (the keyboard
    /// comes up, the composer gains a line or a reply bar). That isn't the reader scrolling, so a
    /// reader at the bottom is kept there; one who scrolled up stays where they are. A shrinking
    /// inset needs nothing: the scroll view settles back onto its last row by itself.
    public static func shouldPin(oldBottomInset: CGFloat, newBottomInset: CGFloat, wasNearBottom: Bool) -> Bool {
        newBottomInset > oldBottomInset && wasNearBottom
    }

    /// The jump-to-latest button shows while the reader is scrolled up, and whenever messages
    /// arrived below them.
    public static func showsJumpButton(nearBottom: Bool, unseenCount: Int) -> Bool {
        !nearBottom || unseenCount > 0
    }

    /// The count on the jump button: nil when nothing arrived below the reader, "99+" past 99.
    public static func jumpBadgeText(unseenCount: Int) -> String? {
        guard unseenCount > 0 else { return nil }
        return unseenCount > 99 ? "99+" : "\(unseenCount)"
    }

    /// What VoiceOver reads for the jump button: where it goes, or what is waiting there.
    public static func jumpButtonLabel(unseenCount: Int) -> String {
        if unseenCount <= 0 { return "Latest message" }
        return unseenCount == 1 ? "1 new message" : "\(unseenCount) new messages"
    }
}
