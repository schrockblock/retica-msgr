//
//  ChatView.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import UIKit
import QuickLook
import os
import ComposableArchitecture
import ReTiCaMsgrCore

struct ChatView: View {
    private static let log = Logger(subsystem: "com.reticamsgr", category: "attachments")

    @Bindable var store: StoreOf<AppFeature>
    @Dependency(\.attachmentStore) private var attachmentStore
    @State private var pickerTarget: PickerTarget?
    @State private var infoTarget: InfoTarget?
    @State private var viewerTarget: ViewerTarget?
    /// A file to open in QuickLook (the system preview with share / save to Files).
    @State private var quickLookURL: URL?
    /// The bubble briefly outlined after a quote tap scrolled to it.
    @State private var highlightedMessageID: Message.ID?
    /// Bumped per quote tap, so only the latest tap's timer clears the highlight.
    @State private var highlightGeneration = 0
    @FocusState private var draftFocused: Bool

    private var peerReachable: Bool {
        guard let peer = store.openPeerHex else { return false }
        return store.reachablePeers.contains(peer)
    }

    /// Text or an attachment, once the attachment is ready.
    private var canSend: Bool {
        peerReachable && !store.attachmentPreparing && (!store.draft.isEmpty || store.pendingAttachment != nil)
    }

    private var showAttachmentBar: Bool {
        store.pendingAttachment != nil || store.attachmentPreparing || store.attachmentError != nil
    }

    var body: some View {
        let peerName = store.openPeerDisplayName
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(store.threadMessages) { message in
                    let reactions = store.threadReactions[message.messageHash] ?? []
                    // A reply to a caption-less photo or file in the thread quotes its placeholder.
                    let replyPreview = ReplyPreview.resolve(for: message, in: store.threadMessages, peerName: peerName,
                                                            attachments: store.attachmentsByMessageId)
                    let attachment = store.attachmentsByMessageId[message.id]
                    let progress = message.isOutgoing && message.status == MessageStatus.sending
                        ? store.outgoingProgress[message.messageHash] : nil
                    MessageBubble(
                        message: message,
                        reactions: reactions,
                        replyPreview: replyPreview,
                        attachment: attachment,
                        attachmentURL: attachment.flatMap(attachmentStore.url(for:)),
                        progress: attachment != nil ? progress : nil,
                        isHighlighted: highlightedMessageID == message.id,
                        onQuoteTap: { showOriginal($0, proxy: proxy) },
                        onImageTap: { a, url in
                            viewerTarget = ViewerTarget(attachment: a, url: url, shareURL: shareableURL(for: a, stored: url))
                        },
                        onFileTap: { a, url in quickLookURL = shareableURL(for: a, stored: url) }
                    )
                    .id(message.id)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        if !message.messageHash.isEmpty {
                            ReactionPaletteMenu(
                                current: reactions.first(where: \.includesMe)?.emoji,
                                onSelect: { store.send(.reactionSelected(messageHash: message.messageHash, emoji: $0)) },
                                onMore: { pickerTarget = PickerTarget(messageHash: message.messageHash) }
                            )
                            .disabled(!peerReachable)
                            // Not gated on reachability: composing works offline, and Send is gated itself.
                            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                                store.send(.replyTapped(message.id))
                                draftFocused = true
                            }
                        }
                        if message.isOutgoing, message.status == MessageStatus.sending, !message.messageHash.isEmpty {
                            Button("Cancel Send", systemImage: "xmark.circle", role: .destructive) {
                                store.send(.cancelSendTapped(message.id))
                            }
                        }
                        Button("Info", systemImage: "info.circle") {
                            infoTarget = InfoTarget(id: message.id)
                        }
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.body
                        }
                    } preview: {
                        BubbleText(message: message, replyPreview: replyPreview,
                                   attachment: attachment, attachmentURL: attachment.flatMap(attachmentStore.url(for:)))
                            .padding(8)
                    }
                }
                .listStyle(.plain)
                .sheet(item: $infoTarget) { target in
                    MessageInfoSheet(store: store, messageID: target.id)
                }
            }

            Divider()

            if let target = store.replyTarget {
                let trimmedQuote = ReplyWire.trimQuote(target.body)
                ReplyComposerBar(
                    senderLabel: ReplyPreview.senderLabel(originalIsOutgoing: target.isOutgoing, peerName: peerName),
                    // A whitespace-only original trims to "", so it shows the same "not available"
                    // text as the resolver rather than an empty line (P1).
                    text: trimmedQuote.isEmpty ? ReplyPreview.unavailable : trimmedQuote,
                    onCancel: { store.send(.replyCancelled) }
                )
            }

            if showAttachmentBar {
                AttachmentComposerBar(
                    pending: store.pendingAttachment,
                    preparing: store.attachmentPreparing,
                    error: store.attachmentError,
                    onRemove: { store.send(.attachmentRemoved) },
                    onOriginalToggled: { store.send(.attachmentOriginalToggled($0)) }
                )
            }

            HStack(spacing: 4) {
                AttachmentPickerButton(
                    onPicked: { store.send(.attachmentPicked($0)) },
                    onFailed: { store.send(.attachmentFailed($0)) }
                )
                TextField("Message", text: $store.draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($draftFocused)
                Button("Send") { store.send(.sendTapped) }
                    .disabled(!canSend)
                    .padding(.leading, 4)
            }
            .padding(.vertical)
            .padding(.trailing)
            .padding(.leading, 8)
        }
        .safeAreaInset(edge: .top) {
            let transfers = store.inboundTransfersForOpenThread
            if !transfers.isEmpty {
                ReceivingCapsule(transfers: transfers).padding(.top, 4)
            }
        }
        .navigationTitle(store.openPeerHex.map(shortHex) ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pickerTarget) { target in
            EmojiPickerSheet { emoji in
                store.send(.reactionSelected(messageHash: target.messageHash, emoji: emoji))
            }
        }
        .fullScreenCover(item: $viewerTarget) { target in
            ImageViewerSheet(attachment: target.attachment, url: target.url, shareURL: target.shareURL)
        }
        .quickLookPreview($quickLookURL)
    }

    /// The bytes under the attachment's real name for QuickLook and the share sheet, so "save to
    /// Files" writes `Trail map.pdf`, not `<hash>-in.pdf`. Falls back to the stored file (and logs)
    /// if the copy fails.
    private func shareableURL(for attachment: Attachment, stored: URL) -> URL {
        do {
            return try attachmentStore.exportURL(for: attachment)
        } catch {
            Self.log.error("attachment export failed: \(String(describing: error), privacy: .public)")
            return stored
        }
    }

    /// Scroll the original to the middle of the list, outline it, then fade the outline over ~1 s.
    private func showOriginal(_ id: Message.ID, proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(id, anchor: .center) }
        highlightGeneration += 1
        let generation = highlightGeneration
        highlightedMessageID = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))   // let the scroll land first
            guard generation == highlightGeneration else { return }
            withAnimation(.easeOut(duration: 1)) { highlightedMessageID = nil }
        }
    }
}

private struct PickerTarget: Identifiable {
    let messageHash: String
    var id: String { messageHash }
}

private struct InfoTarget: Identifiable {
    let id: UUID
}

private struct ViewerTarget: Identifiable {
    let attachment: Attachment
    let url: URL
    /// What the share button hands over: the real-name copy, or `url` if the copy failed.
    let shareURL: URL
    var id: UUID { attachment.id }
}

struct MessageBubble: View {
    let message: Message
    var reactions: [ReactionSummary.Item] = []
    var replyPreview: ReplyPreview.Resolved? = nil
    var attachment: Attachment? = nil
    var attachmentURL: URL? = nil
    var progress: Double? = nil
    var isHighlighted = false
    var onQuoteTap: ((Message.ID) -> Void)? = nil
    var onImageTap: ((Attachment, URL) -> Void)? = nil
    var onFileTap: ((Attachment, URL) -> Void)? = nil

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer() }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                BubbleText(message: message, replyPreview: replyPreview,
                           attachment: attachment, attachmentURL: attachmentURL, progress: progress,
                           onQuoteTap: onQuoteTap, onImageTap: onImageTap, onFileTap: onFileTap)
                    .overlay(
                        // Drawn 4 pt outside the bubble, so the accent ring shows on the blue
                        // outgoing bubble too.
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.accentColor, lineWidth: 3)
                            .padding(-4)
                            .opacity(isHighlighted ? 1 : 0)
                    )
                if !reactions.isEmpty {
                    ReactionBadge(items: reactions)
                        .padding(.top, -10)
                        .padding(.horizontal, 8)
                }
                if message.isOutgoing {
                    Text(message.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !message.isOutgoing { Spacer() }
        }
    }
}

/// The rounded bubble alone — also the context-menu preview, so the lifted view is just the bubble.
/// A reply shows its quote block above the text; an attachment sits above the caption.
struct BubbleText: View {
    let message: Message
    var replyPreview: ReplyPreview.Resolved? = nil
    var attachment: Attachment? = nil
    var attachmentURL: URL? = nil
    var progress: Double? = nil
    var onQuoteTap: ((Message.ID) -> Void)? = nil
    var onImageTap: ((Attachment, URL) -> Void)? = nil
    var onFileTap: ((Attachment, URL) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyPreview {
                QuoteBlock(preview: replyPreview, onOutgoingBubble: message.isOutgoing, onTap: onQuoteTap)
            }
            if let attachment {
                AttachmentBubbleSlot(
                    attachment: attachment,
                    url: attachmentURL,
                    progress: progress,
                    onOutgoingBubble: message.isOutgoing,
                    onTapImage: (onImageTap != nil && attachmentURL != nil) ? { onImageTap?(attachment, attachmentURL!) } : nil,
                    onTapFile: (onFileTap != nil && attachmentURL != nil) ? { onFileTap?(attachment, attachmentURL!) } : nil
                )
            }
            if !message.body.isEmpty || attachment == nil {
                Text(message.body)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(message.isOutgoing ? Color.blue : Color(.systemGray5))
        .foregroundStyle(message.isOutgoing ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// Small capsule of reactions overlapping the bubble's bottom edge. Tinted border when one is mine.
struct ReactionBadge: View {
    let items: [ReactionSummary.Item]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.emoji) { item in
                HStack(spacing: 1) {
                    Text(item.emoji)
                    if item.count > 1 {
                        Text("\(item.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color(.systemBackground)))
        .overlay(
            Capsule().stroke(items.contains(where: \.includesMe) ? Color.accentColor : Color(.separator),
                             lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(items.map { "\($0.emoji) \($0.count)" }.joined(separator: ", "))
    }
}
