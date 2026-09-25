import Foundation

/// The full emoji set offered by the reaction picker, from a trimmed Unicode 16.0
/// `emoji-test.txt` (fully-qualified only, no skin tones) bundled as `Resources/emoji.tsv`.
/// Regenerate with `scripts/trim-emoji-test.swift`.
public struct EmojiCatalog: Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public let emoji: String
        public let name: String
        public var id: String { emoji }
        public init(emoji: String, name: String) {
            self.emoji = emoji
            self.name = name
        }
    }

    public struct Group: Hashable, Sendable, Identifiable {
        public let name: String
        public let emojis: [Entry]
        public var id: String { name }
    }

    public let groups: [Group]

    /// Parses `group<TAB>emoji<TAB>name` lines, preserving first-seen group order.
    public init(tsv: String) {
        var order: [String] = []
        var byGroup: [String: [Entry]] = [:]
        for line in tsv.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard cols.count == 3 else { continue }
            if byGroup[cols[0]] == nil { order.append(cols[0]) }
            byGroup[cols[0], default: []].append(Entry(emoji: cols[1], name: cols[2]))
        }
        groups = order.map { Group(name: $0, emojis: byGroup[$0] ?? []) }
    }

    public static let shared: EmojiCatalog = {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "tsv"),
              let tsv = try? String(contentsOf: url, encoding: .utf8)
        else { return EmojiCatalog(tsv: "") }
        return EmojiCatalog(tsv: tsv)
    }()

    /// Case-insensitive substring match on the emoji's name. Empty query → no results.
    public func search(_ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return groups.flatMap(\.emojis).filter { $0.name.lowercased().contains(q) }
    }
}
