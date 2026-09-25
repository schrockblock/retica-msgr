import SwiftUI
import ReTiCaMsgrCore

/// The reaction items at the top of a message's context menu: a palette row of the six quick
/// emoji (the current one gets the palette's built-in selected highlight), followed by a
/// separate "More Reactions" menu item that opens the full picker.
/// `onSelect` must fire on every tap, including the currently selected emoji — the reducer
/// turns a repeat into a removal. (Verified on iOS 26.4: re-tapping the selected item still
/// calls the binding's setter.)
struct ReactionPaletteMenu: View {
    let current: String?
    let onSelect: (String) -> Void
    let onMore: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            // Empty title: inside a context menu the Picker's title becomes an inline section
            // header, which `.labelsHidden()` alone does not suppress (observed on iOS 26.4).
            Picker("", selection: Binding(
                get: { current ?? "" },
                set: { onSelect($0) }
            )) {
                ForEach(QuickReactions.default, id: \.self) { emoji in
                    emojiLabel(emoji)
                        .tag(emoji)
                        .accessibilityLabel(current == emoji ? "Remove \(emoji)" : "React \(emoji)")
                }
            }
            .pickerStyle(.palette)
            .labelsHidden()
            // Close the context menu on an emoji tap, like iMessage. Without this a palette
            // selection leaves the menu open (observed on iOS 26.4).
            .menuActionDismissBehavior(.enabled)

            Button { onMore() } label: {
                Label("More Reactions", systemImage: "face.smiling")
            }
        }
    }

    /// Enabled: the plain emoji `Text`. Disabled (peer unreachable): a pre-dimmed bitmap, because
    /// the palette flattens its items into menu elements and ignores `.opacity` / `.foregroundStyle`
    /// on the label (observed on iOS 26.4), so the only way to show it disabled is to bake the
    /// alpha into the image. `.alwaysOriginal` keeps the menu from template-tinting it.
    @ViewBuilder
    private func emojiLabel(_ emoji: String) -> some View {
        if isEnabled {
            Text(emoji)
        } else {
            Image(uiImage: dimmedEmoji(emoji))
        }
    }

    private func dimmedEmoji(_ emoji: String) -> UIImage {
        let renderer = ImageRenderer(content: Text(emoji).font(.footnote).opacity(0.35))
        renderer.scale = displayScale
        return (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysOriginal)
    }
}
