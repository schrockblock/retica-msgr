import SwiftUI
import ReTiCaMsgrCore

/// The quick-reaction row at the top of a message's context menu: six emoji and a ＋.
/// A palette-style `Picker` gives the current reaction a built-in selected highlight.
/// `onSelect` must fire on every tap, including the currently selected emoji — the reducer
/// turns a repeat into a removal. (Verified on iOS 26.4: re-tapping the selected item still
/// calls the binding's setter.)
struct ReactionPaletteMenu: View {
    let current: String?
    let onSelect: (String) -> Void
    let onMore: () -> Void

    private static let moreTag = "__more__"

    var body: some View {
        Picker("React", selection: Binding(
            get: { current ?? "" },
            set: { value in value == Self.moreTag ? onMore() : onSelect(value) }
        )) {
            ForEach(QuickReactions.default, id: \.self) { emoji in
                Text(emoji).tag(emoji)
            }
            Image(systemName: "plus").tag(Self.moreTag)
        }
        .pickerStyle(.palette)
    }
}
