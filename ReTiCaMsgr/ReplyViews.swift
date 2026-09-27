//
//  ReplyViews.swift
//  ReTiCaMsgr
//

import SwiftUI
import ReTiCaMsgrCore

/// The quoted original inside a reply's bubble. It can be tapped (to scroll to the original) only
/// when the original is in this thread and a tap handler is given. The context-menu preview passes none.
struct QuoteBlock: View {
    let preview: ReplyPreview.Resolved
    /// Outgoing bubbles are blue with white text, so the bar and panel are drawn in white there.
    let onOutgoingBubble: Bool
    var onTap: ((Message.ID) -> Void)? = nil

    var body: some View {
        if let originalID = preview.originalID, let onTap {
            Button { onTap(originalID) } label: { panel }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the original message")
        } else {
            panel
        }
    }

    private var panel: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(onOutgoingBubble ? Color.white : Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.senderLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(preview.text)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        // The bar takes the text's height, not the height the row proposes.
        .fixedSize(horizontal: false, vertical: true)
        .padding(6)
        // UI rule: the whole panel is the tap target, at least 44 pt tall. Not maxWidth .infinity,
        // which would stretch every reply bubble to the full row width.
        .frame(minHeight: 44, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(onOutgoingBubble ? Color.white.opacity(0.2) : Color.primary.opacity(0.08))
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reply to \(preview.senderLabel): \(preview.text)")
    }
}

/// "Replying to …" above the text field, with a ✕ that cancels the reply.
struct ReplyComposerBar: View {
    let senderLabel: String
    let text: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(senderLabel)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    // UI rule: a 44 pt hit area, all of it tappable.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.top, 4)
    }
}
