//
//  ComposerTextField.swift
//  ReTiCAMsgr
//

import SwiftUI

/// The chat composer's message field: grows with its text up to `maxLines`, then scrolls.
///
/// On iOS this is a `UITextView` that this file keeps in step with `text` itself, because SwiftUI's
/// multi-line `TextField` does not always show a change made to its binding from code. After the
/// keyboard reports a change that leaves the text as it was (confirming a composition does), or
/// when a key and the change land in one main-thread turn, that field ignores the next value it is
/// given. Clearing the draft on Send is such a change: the sent text stayed in the field with Send
/// disabled, and one more key wrote "sent text + key" back as a new draft, which went out as a
/// second copy. See `ComposerTextFieldTests`.
struct ComposerTextField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var maxLines = 5

    var body: some View {
        #if os(iOS)
        ComposerTextView(text: $text, isFocused: $isFocused, maxLines: maxLines, label: placeholder)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.placeholder)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        #else
        SystemComposerTextField(placeholder: placeholder, text: $text, isFocused: $isFocused, maxLines: maxLines)
        #endif
    }
}

#if os(iOS)
import UIKit

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let maxLines: Int
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// The look shared by the field and the view that measures its height limit.
    fileprivate static func style(_ view: UITextView) {
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .clear
        // The surrounding SwiftUI padding is the field's only inset, as for a plain `TextField`.
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        Self.style(view)
        view.delegate = context.coordinator
        view.isScrollEnabled = false
        view.accessibilityLabel = label
        view.text = text
        // The row decides the width; the text wraps inside it and never pushes it wider.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        // The point of this type: whatever the model holds is what the field shows.
        if view.text != text { view.text = text }

        // Focus is acted on only when the model's wish changes, so it never fights the field's
        // own report of gaining or losing the keyboard (the delegate methods below).
        if context.coordinator.requestedFocus != isFocused {
            context.coordinator.requestedFocus = isFocused
            let wanted = isFocused
            // On the next turn: becoming first responder calls the delegate, which writes the
            // binding, and that must not happen inside a view update.
            DispatchQueue.main.async {
                if wanted, !view.isFirstResponder {
                    view.becomeFirstResponder()
                } else if !wanted, view.isFirstResponder {
                    view.resignFirstResponder()
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let natural = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let limit = context.coordinator.heightLimit(lines: maxLines, like: uiView)
        // Past the limit the field stops growing and scrolls instead.
        let scrolls = natural > limit
        if uiView.isScrollEnabled != scrolls { uiView.isScrollEnabled = scrolls }
        return CGSize(width: width, height: min(natural, limit))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        /// The focus the model last asked for, or the field last reported.
        var requestedFocus = false
        private var limit: (lines: Int, pointSize: CGFloat, height: CGFloat)?

        init(_ parent: ComposerTextView) { self.parent = parent }

        /// The height of `lines` lines in the field's font, measured rather than computed: a text
        /// view's line is taller than the font's own line height.
        func heightLimit(lines: Int, like view: UITextView) -> CGFloat {
            let pointSize = view.font?.pointSize ?? 0
            if let limit, limit.lines == lines, limit.pointSize == pointSize { return limit.height }
            let sizer = UITextView()
            ComposerTextView.style(sizer)
            sizer.font = view.font
            sizer.isScrollEnabled = false
            sizer.text = Array(repeating: "M", count: max(lines, 1)).joined(separator: "\n")
            let height = sizer.sizeThatFits(CGSize(width: 1000, height: CGFloat.greatestFiniteMagnitude)).height
            limit = (lines, pointSize, height)
            return height
        }

        func textViewDidChange(_ textView: UITextView) {
            let text = textView.text ?? ""
            if parent.text != text { parent.text = text }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            requestedFocus = true
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            requestedFocus = false
            if parent.isFocused { parent.isFocused = false }
        }
    }
}
#else
/// macOS keeps SwiftUI's own field, with `isFocused` mirrored onto its focus state.
private struct SystemComposerTextField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    let maxLines: Int
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...maxLines)
            .textFieldStyle(.plain)
            .focused($focused)
            .onChange(of: isFocused) { _, new in if focused != new { focused = new } }
            .onChange(of: focused) { _, new in if isFocused != new { isFocused = new } }
    }
}
#endif
