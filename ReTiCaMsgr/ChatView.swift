//
//  ChatView.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import UIKit
import ComposableArchitecture
import ReTiCaMsgrCore

struct ChatView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var pickerTarget: PickerTarget?
    @State private var infoTarget: InfoTarget?

    private var peerReachable: Bool {
        guard let peer = store.openPeerHex else { return false }
        return store.reachablePeers.contains(peer)
    }

    private var canSend: Bool {
        peerReachable && !store.draft.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            List(store.threadMessages) { message in
                let reactions = store.threadReactions[message.messageHash] ?? []
                MessageBubble(message: message, reactions: reactions)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        if !message.messageHash.isEmpty {
                            ReactionPaletteMenu(
                                current: reactions.first(where: \.includesMe)?.emoji,
                                onSelect: { store.send(.reactionSelected(messageHash: message.messageHash, emoji: $0)) },
                                onMore: { pickerTarget = PickerTarget(messageHash: message.messageHash) }
                            )
                            .disabled(!peerReachable)
                        }
                        Button("Info", systemImage: "info.circle") {
                            infoTarget = InfoTarget(id: message.id)
                        }
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.body
                        }
                    } preview: {
                        BubbleText(message: message)
                            .padding(8)
                    }
            }
            .listStyle(.plain)
            .sheet(item: $infoTarget) { target in
                MessageInfoSheet(store: store, messageID: target.id)
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Message", text: $store.draft)
                    .textFieldStyle(.roundedBorder)
                Button("Send") { store.send(.sendTapped) }
                    .disabled(!canSend)
            }
            .padding()
        }
        .navigationTitle(store.openPeerHex.map(shortHex) ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pickerTarget) { target in
            EmojiPickerSheet { emoji in
                store.send(.reactionSelected(messageHash: target.messageHash, emoji: emoji))
            }
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

struct MessageBubble: View {
    let message: Message
    var reactions: [ReactionSummary.Item] = []

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer() }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                BubbleText(message: message)
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
struct BubbleText: View {
    let message: Message

    var body: some View {
        Text(message.body)
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
