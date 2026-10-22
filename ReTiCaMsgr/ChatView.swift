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
    @State private var showingGroupInfo = false
    @State private var showingPeerInfo = false
    /// Set once the thread has been scrolled to its latest message, so a later message never
    /// pulls the reader away from what they scrolled back to.
    @State private var openedAtLatest = false
    /// Whether the reader is within `ChatScroll.nearBottomThreshold` of the bottom of the thread.
    @State private var nearBottom = true
    /// Messages that arrived below the reader while they were scrolled up; drives the jump button.
    @State private var unseenCount = 0

    private var isGroup: Bool { store.openConversationKind == .group }

    /// The Send gate: the peer routes now, or for a group at least one member does (spec §3).
    private var peerReachable: Bool {
        if isGroup { return store.anyGroupMemberReachable }
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
        // Group threads: the bubbles that end a sender's run carry their avatar.
        let thread = store.threadMessages
        let avatarMessageIDs: Set<Message.ID> = isGroup
            ? Set(thread.indices.filter { thread.showsSenderAvatar(at: $0) }.map { thread[$0].id })
            : []
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(store.threadMessages) { message in
                    if message.isTimerChange || message.isGroupEvent {
                        TimerChangeLine(text: message.body,
                                        status: message.isOutgoing ? statusText(for: message) : nil)
                            .id(message.id)
                            .listRowSeparator(.hidden)
                    } else {
                        let reactions = store.threadReactions[message.messageHash] ?? []
                        // A reply to a caption-less photo or file in the thread quotes its placeholder.
                        let replyPreview = ReplyPreview.resolve(for: message, in: store.threadMessages, peerName: peerName,
                                                                attachments: store.attachmentsByMessageId,
                                                                names: store.threadSenderNames)
                        let attachment = store.attachmentsByMessageId[message.id]
                        // A sending message shows the bar from the start: 0 until the first report,
                        // which the bar draws as indeterminate ("waiting for link").
                        let progress = message.isOutgoing && message.status == MessageStatus.sending
                            ? store.outgoingProgress[message.messageHash] ?? 0 : nil
                        MessageBubble(
                            message: message,
                            senderName: isGroup && !message.isOutgoing
                                ? store.state.groupMemberName(message.peerHex) : nil,
                            statusText: statusText(for: message),
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
                            onFileTap: { a, url in quickLookURL = shareableURL(for: a, stored: url) },
                            hasAvatarSlot: isGroup,
                            senderAvatar: isGroup && avatarMessageIDs.contains(message.id)
                                ? AnyView(AvatarView(store: store, peerHex: message.peerHex, size: 28))
                                : nil
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
                            if !isGroup, message.isOutgoing, message.status == MessageStatus.sending, !message.messageHash.isEmpty {
                                Button("Cancel Send", systemImage: "xmark.circle", role: .destructive) {
                                    store.send(.cancelSendTapped(message.id))
                                }
                            }
                            // Offline too: a retry falls back to the propagation node like any send.
                            if canRetry(message) {
                                Button("Retry", systemImage: "arrow.clockwise") {
                                    store.send(.retryTapped(message.id))
                                }
                            }
                            Button("Info", systemImage: "info.circle") {
                                infoTarget = InfoTarget(id: message.id)
                            }
                            // A caption-less photo or file has no text to copy.
                            if !message.body.isEmpty {
                                Button("Copy", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = message.body
                                }
                            }
                        } preview: {
                            BubbleText(message: message, replyPreview: replyPreview,
                                       attachment: attachment, attachmentURL: attachment.flatMap(attachmentStore.url(for:)))
                                .padding(8)
                        }
                    }
                }
                .listStyle(.plain)
                // An LXMF address in a bubble opens that chat in place; other links go to iOS.
                .environment(\.openURL, OpenURLAction { url in
                    guard MessageLinks.isLxmf(url) else { return .systemAction }
                    if let hex = MessageLinks.conversationTarget(for: url, ownAddress: store.myAddressHex),
                       isGroup || hex != store.openPeerHex {
                        openedAtLatest = false
                        unseenCount = 0
                        highlightedMessageID = nil
                        store.send(.startConversation(hex))
                    }
                    return .handled
                })
                // A conversation opens on its latest message. The thread loads after the screen
                // appears, so the anchor alone can land on an empty list: scroll once the last
                // message is known, on the next run loop so the row exists to scroll to.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // Where the reader is. Content growing under a still viewport (a message landing)
                // isn't the reader scrolling, so it leaves `nearBottom` as it was: the follow
                // decision below must see where they were before the new row arrived.
                .onScrollGeometryChange(for: ScrollSpot.self) { geometry in
                    ScrollSpot(contentHeight: geometry.contentSize.height, visibleMaxY: geometry.visibleRect.maxY)
                } action: { old, new in
                    if new.visibleMaxY == old.visibleMaxY, new.contentHeight > old.contentHeight { return }
                    nearBottom = ChatScroll.isNearBottom(contentHeight: new.contentHeight, visibleMaxY: new.visibleMaxY)
                    if nearBottom { unseenCount = 0 }
                }
                .onChange(of: store.threadMessages.last?.id, initial: true) { old, last in
                    guard let last else { return }
                    guard openedAtLatest else {
                        openedAtLatest = true
                        Task { @MainActor in proxy.scrollTo(last, anchor: .bottom) }
                        return
                    }
                    // Only rows appended after the previous last one are new; if that one is gone
                    // (a disappearing message purged), nothing arrived.
                    let thread = store.threadMessages
                    guard let old, let oldIndex = thread.firstIndex(where: { $0.id == old }) else { return }
                    let newOutgoing = thread.last?.isOutgoing ?? false
                    if ChatScroll.shouldFollow(newLastIsOutgoing: newOutgoing, wasNearBottom: nearBottom) {
                        unseenCount = 0
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    } else {
                        unseenCount += thread.count - 1 - oldIndex
                    }
                }
                .onChange(of: store.openPeerHex) {
                    // Another conversation (`startConversation` or an LXMF link) starts fresh and
                    // opens on its latest message. The thread itself loads later, in an effect.
                    openedAtLatest = false
                    unseenCount = 0
                    nearBottom = true
                }
                .overlay(alignment: .bottomTrailing) {
                    if unseenCount > 0, let last = store.threadMessages.last?.id {
                        Button {
                            unseenCount = 0
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        } label: {
                            Text(unseenCount == 1 ? "↓ New message" : "↓ \(unseenCount) new messages")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                                // UI rule: the whole capsule is the tap target, not just the glyphs.
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                        .accessibilityHint("Scrolls to the latest message")
                    }
                }
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

            if showAttachmentBar, isGroup || !store.state.isBlocked(store.openPeerHex ?? "") {
                AttachmentComposerBar(
                    pending: store.pendingAttachment,
                    preparing: store.attachmentPreparing,
                    error: store.attachmentError,
                    onRemove: { store.send(.attachmentRemoved) },
                    onOriginalToggled: { store.send(.attachmentOriginalToggled($0)) }
                )
            }

            if !isGroup, let peer = store.openPeerHex, store.state.isBlocked(peer) {
                BlockedBar(onUnblock: { store.send(.unblockPeer(peer)) })
            } else if isGroup, store.openGroup?.state == GroupState.invited {
                InviteBar(groupName: store.openGroup?.name ?? "the group",
                          onAccept: { store.send(.acceptInvite) },
                          onDecline: { store.send(.declineInvite) })
            } else if isGroup, let state = store.openGroup?.state, state != GroupState.active {
                ClosedGroupLine(state: state)
            } else {
                // Bottom-aligned so the buttons stay beside the last line as the field grows.
                HStack(alignment: .bottom, spacing: 4) {
                    if !isGroup {
                        AttachmentPickerButton(
                            peerHex: store.openPeerHex ?? "",
                            onLoadStarted: { store.send(.attachmentLoadStarted(peerHex: $0)) },
                            onPicked: { store.send(.attachmentPicked($0)) },
                            onFailed: { store.send(.attachmentFailed($0)) }
                        )
                    }
                    TextField("Message", text: $store.draft, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .focused($draftFocused)
                        // One line plus this is 44 pt, the buttons' height, so they line up.
                        .padding(.vertical, 5)
                    Button("Send") { store.send(.sendTapped) }
                        .frame(minHeight: 44)
                        .disabled(!canSend)
                        .padding(.leading, 4)
                }
                .padding(.vertical)
                .padding(.trailing)
                .padding(.leading, 8)
            }
        }
        // Amendment A11: a message is "viewed" only while this screen is actually showing.
        .onAppear { store.send(.chatAppeared) }
        .onDisappear { store.send(.chatDisappeared) }
        .incomingDownloadBanner(store.incomingDownloadFraction)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if isGroup {
                    Button { showingGroupInfo = true } label: {
                        ChatTitle(title: store.openGroup?.name ?? "Group", expiry: nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the group's members and settings")
                } else {
                    Button { showingPeerInfo = true } label: {
                        // The contact's or announced name on top with the address beneath it; with
                        // no name, the address alone is the title.
                        let name = store.openPeerHex.flatMap { store.state.peerDisplayName($0) }
                        ChatTitle(title: name ?? store.openPeerHex.map(shortHex) ?? "Chat",
                                  subtitle: name == nil ? nil : store.openPeerHex.map(shortHex),
                                  expiry: store.openConversationExpiry,
                                  avatar: store.openPeerHex.map {
                                      AnyView(AvatarView(store: store, peerHex: $0, size: 28))
                                  })
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the address and contact for this chat")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isGroup {
                    Button { showingGroupInfo = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Group info")
                } else {
                    // Not gated on reachability (amendment A17): the pick applies here at once, the
                    // change line shows if its message failed, and every later message carries the
                    // timer, so the peer converges even when the change itself never arrived.
                    HStack(spacing: 16) {
                        Button { showingPeerInfo = true } label: { Image(systemName: "info.circle") }
                            .accessibilityLabel("Chat info")
                        if !store.state.isBlocked(store.openPeerHex ?? "") {
                            ExpiryMenu(current: store.openConversationExpiry) { store.send(.expirySelected(seconds: $0)) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingGroupInfo) {
            GroupInfoView(store: store)
        }
        .sheet(isPresented: $showingPeerInfo) {
            if let peer = store.openPeerHex { PeerInfoView(store: store, peerHex: peer) }
        }
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

    /// A group row's status comes from its delivery rows (spec §4); a peer row's from its column,
    /// in words (`MessageStatusLabel`).
    private func statusText(for message: Message) -> String {
        guard isGroup, message.isOutgoing, let rows = store.deliveriesByMessageId[message.id] else {
            return MessageStatusLabel.text(for: message.status)
        }
        return GroupRoster.statusLabel(rows)
    }

    /// Retry is offered on our own failed message: a peer row whose status is failed, or a group
    /// post with at least one failed member copy. Cancelled is never retried.
    private func canRetry(_ message: Message) -> Bool {
        guard message.isOutgoing, !message.isTimerChange, !message.isGroupEvent else { return false }
        if isGroup {
            return store.deliveriesByMessageId[message.id]?.contains { $0.status == MessageStatus.failed } ?? false
        }
        return message.status == MessageStatus.failed
    }
}

private struct PickerTarget: Identifiable {
    let messageHash: String
    var id: String { messageHash }
}

/// The scroll geometry `ChatScroll.isNearBottom` needs, in the scroll content's coordinates.
private struct ScrollSpot: Equatable {
    let contentHeight: CGFloat
    let visibleMaxY: CGFloat
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
    /// In a group thread, the incoming sender's name above the bubble (spec §4).
    var senderName: String? = nil
    /// What the status area shows; a group post passes its "Delivered to d of n" label.
    var statusText: String? = nil
    var reactions: [ReactionSummary.Item] = []
    var replyPreview: ReplyPreview.Resolved? = nil
    var attachment: Attachment? = nil
    var attachmentURL: URL? = nil
    var progress: Double? = nil
    var isHighlighted = false
    var onQuoteTap: ((Message.ID) -> Void)? = nil
    var onImageTap: ((Attachment, URL) -> Void)? = nil
    var onFileTap: ((Attachment, URL) -> Void)? = nil
    /// Group threads only: incoming bubbles get a 28 pt leading slot, holding the sender's avatar
    /// on the last bubble of their run and empty otherwise, so the bubbles stay aligned.
    var hasAvatarSlot = false
    var senderAvatar: AnyView? = nil

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isOutgoing { Spacer() }
            if hasAvatarSlot, !message.isOutgoing {
                Group {
                    if let senderAvatar { senderAvatar } else { Color.clear }
                }
                .frame(width: 28, height: 28)
            }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if let senderName {
                    Text(senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
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
                if message.isOutgoing || message.expirySeconds != nil {
                    HStack(spacing: 4) {
                        if message.expirySeconds != nil {
                            // Spec §4: a static glyph, no live countdown.
                            Image(systemName: "timer")
                                .accessibilityLabel("Disappearing message")
                        }
                        if message.isOutgoing {
                            Text(statusText ?? MessageStatusLabel.text(for: message.status))
                        }
                    }
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
                // Links are underlined; on my bubbles they're white so they read on the gradient.
                Text(MessageLinks.attributed(message.body))
                    .tint(message.isOutgoing ? .white : .accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if message.isOutgoing { Brand.gradient } else { Color(.systemGray5) }
        }
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
