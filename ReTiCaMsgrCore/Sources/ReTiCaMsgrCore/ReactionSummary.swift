import Foundation

/// Turns raw reaction rows into badge data.
public enum ReactionSummary {
    public struct Item: Equatable, Sendable {
        public var emoji: String
        public var count: Int
        public var includesMe: Bool
        public init(emoji: String, count: Int, includesMe: Bool) {
            self.emoji = emoji
            self.count = count
            self.includesMe = includesMe
        }
    }

    /// Badge items for one message's rows: tombstones dropped, grouped by emoji, ordered by the
    /// earliest `sentAt` among each emoji's reactors.
    public static func summarize(_ rows: [Reaction], me: String) -> [Item] {
        let live = rows.filter { !$0.emoji.isEmpty }
        let grouped = Dictionary(grouping: live, by: \.emoji)
        return grouped
            .map { emoji, rs in
                (first: rs.map(\.sentAt).min() ?? 0,
                 item: Item(emoji: emoji, count: rs.count, includesMe: rs.contains { $0.reactorHex == me }))
            }
            .sorted { $0.first < $1.first }
            .map(\.item)
    }

    /// `summarize` per message hash; hashes with no live reactions are omitted.
    public static func byMessage(_ rows: [Reaction], me: String) -> [String: [Item]] {
        Dictionary(grouping: rows, by: \.messageHash)
            .mapValues { summarize($0, me: me) }
            .filter { !$0.value.isEmpty }
    }
}
