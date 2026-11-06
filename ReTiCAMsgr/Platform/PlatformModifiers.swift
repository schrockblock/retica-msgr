import SwiftUI

enum PlatformAutocapitalization {
    case never, words
}

enum PlatformKeyboard {
    case url, numberPad, asciiCapable
}

/// Wrappers for iOS-only modifiers. Each is the original modifier on iOS and
/// the closest Mac behaviour (usually none) on macOS.
extension View {
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    func platformAutocapitalization(_ mode: PlatformAutocapitalization) -> some View {
        #if os(iOS)
        textInputAutocapitalization(mode == .never ? .never : .words)
        #else
        self
        #endif
    }

    func platformKeyboard(_ kind: PlatformKeyboard) -> some View {
        #if os(iOS)
        keyboardType({
            switch kind {
            case .url: .URL
            case .numberPad: .numberPad
            case .asciiCapable: .asciiCapable
            }
        }())
        #else
        self
        #endif
    }

    /// Full-screen on iPhone; a sheet with a usable size on the Mac.
    func fullScreenCoverOrSheet<Item: Identifiable, C: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> C
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item) { value in
            content(value).frame(minWidth: 480, minHeight: 480)
        }
        #endif
    }

    func fullScreenCoverOrSheet<C: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented) {
            content().frame(minWidth: 480, minHeight: 480)
        }
        #endif
    }

    /// A Mac sheet sizes to its content's ideal size, and a `List` root has none, so the sheet
    /// collapses to a sliver. Nothing on iOS, where sheets take the screen's width.
    func macSheetFrame() -> some View {
        #if os(iOS)
        self
        #else
        frame(minWidth: 480, minHeight: 400)
        #endif
    }

    /// A Mac `Form` in its automatic (columns) style does not scroll, so its window grows to the
    /// whole form's height and the top rows end up under the toolbar. The grouped style scrolls,
    /// and matches what iOS draws already. Nothing on iOS.
    func scrollingFormStyle() -> some View {
        #if os(iOS)
        self
        #else
        formStyle(.grouped)
        #endif
    }

    func insetGroupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }
}

extension ToolbarItemPlacement {
    static var barLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    static var barTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}
