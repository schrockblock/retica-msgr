//
//  ChatView.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

struct ChatView: View {
    @Bindable var store: StoreOf<AppFeature>

    var connectionColor: Color {
        switch store.connection {
        case .disconnected: return .red
        case .connecting: return .yellow
        case .connected: return .green
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List(store.messages) { message in
                    MessageBubble(message: message)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)

                Divider()

                HStack(spacing: 8) {
                    TextField("Message", text: $store.draft)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        store.send(.sendTapped)
                    }
                    .disabled(!store.peerReachable || store.draft.isEmpty)
                }
                .padding()
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 10, height: 10)
                }
            }
        }
    }
}

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer() }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(message.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isOutgoing ? Color.blue : Color(.systemGray5))
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
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
