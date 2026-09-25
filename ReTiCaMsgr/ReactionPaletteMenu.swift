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

    var body: some View {
        Group {
            // Empty title: inside a context menu the Picker's title becomes an inline section
            // header, which `.labelsHidden()` alone does not suppress (observed on iOS 26.4).
            Picker("", selection: Binding(
                get: { current ?? "" },
                set: { onSelect($0) }
            )) {
                ForEach(QuickReactions.default, id: \.self) { emoji in
                    Text(emoji)
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
}
