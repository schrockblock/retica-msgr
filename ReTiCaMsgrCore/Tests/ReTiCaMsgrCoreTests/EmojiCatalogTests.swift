import Testing
import Foundation
@testable import ReTiCaMsgrCore

@Test func bundledCatalogLoadsWithGroups() {
    let c = EmojiCatalog.shared
    #expect(c.groups.count >= 8)
    #expect(c.groups.first?.name == "Smileys & Emotion")
    #expect(c.groups.flatMap(\.emojis).count > 1500)
    #expect(!c.groups.contains { $0.name == "Component" })
}

@Test func catalogContainsAllQuickReactions() {
    let all = Set(EmojiCatalog.shared.groups.flatMap(\.emojis).map(\.emoji))
    for q in QuickReactions.default { #expect(all.contains(q), "missing \(q)") }
}

@Test func catalogHasNoSkinToneVariants() {
    let tones: Set<UInt32> = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]
    let offenders = EmojiCatalog.shared.groups.flatMap(\.emojis).filter {
        $0.emoji.unicodeScalars.contains { tones.contains($0.value) }
    }
    #expect(offenders.isEmpty)
}

@Test func searchMatchesNameCaseInsensitively() {
    let hits = EmojiCatalog.shared.search("  Red HEART ").map(\.emoji)
    #expect(hits.contains("❤️"))
    #expect(EmojiCatalog.shared.search("").isEmpty)
    #expect(EmojiCatalog.shared.search("zzzznotanemoji").isEmpty)
}

@Test func parsesTSVIntoOrderedGroups() {
    let c = EmojiCatalog(tsv: "A\t😀\tgrinning face\nA\t😃\tbig eyes\nB\t🐶\tdog face\n")
    #expect(c.groups.map(\.name) == ["A", "B"])
    #expect(c.groups[0].emojis.map(\.emoji) == ["😀", "😃"])
    #expect(c.groups[1].emojis == [.init(emoji: "🐶", name: "dog face")])
}

/// Review Focus 5: anything the picker offers must survive the wire limit.
@Test func everyCatalogEmojiFitsWireLimit() {
    let target = Data(repeating: 7, count: 32)
    for e in EmojiCatalog.shared.groups.flatMap(\.emojis) {
        #expect(ReactionWire.decode(ReactionWire.encode(target: target, emoji: e.emoji))
                == .reaction(target: target, emoji: e.emoji), "\(e.name)")
    }
}
