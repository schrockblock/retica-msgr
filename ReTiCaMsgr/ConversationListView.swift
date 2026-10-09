//
//  ConversationListView.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

/// Truncate a hex address for display: first 4 + … + last 2.
func shortHex(_ hex: String) -> String {
    guard hex.count > 8 else { return hex }
    return "\(hex.prefix(4))…\(hex.suffix(2))"
}

struct ConversationListView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var showingCompose = false
    @State private var showingNewGroup = false

    var connectionColor: Color {
        switch store.connection {
        case .disconnected: return .red
        case .connecting: return .yellow
        case .connected: return .green
        }
    }

    var body: some View {
        NavigationStack {
            List(store.conversations) { convo in
                Button {
                    store.send(convo.kind == .group ? .openGroupConversation(convo.peerHex) : .openConversation(convo.peerHex))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if let title = convo.title {
                                Label(title, systemImage: "person.3")
                                    .font(.headline)
                                    .lineLimit(1)
                            } else {
                                Text(shortHex(convo.peerHex))
                                    .font(.system(.headline, design: .monospaced))
                            }
                            if convo.groupState == GroupState.invited {
                                Text("Invited")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            }
                            Spacer()
                            Text(convo.lastTimestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(convo.lastBody)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // Make the whole row tappable, not just the text glyphs: a
                    // plain-style Button only hit-tests its content, so the empty
                    // row area (gaps + trailing space) otherwise swallows taps.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Circle().fill(connectionColor).frame(width: 10, height: 10)
                }
                // No transfers, no toolbar item (an empty one still takes a slot).
                if !store.unattributedInboundTransfers.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        ReceivingCapsule(transfers: store.unattributedInboundTransfers)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { store.send(.syncTapped) } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showingCompose = true } label: { Label("New conversation", systemImage: "bubble.left") }
                        Button { showingNewGroup = true } label: { Label("New group", systemImage: "person.3") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(
                isPresented: Binding(
                    get: { store.openPeerHex != nil },
                    set: { presented in if !presented { store.send(.closeConversation) } }
                )
            ) {
                ChatView(store: store)
            }
            .sheet(isPresented: $showingCompose) {
                ComposeSheet(store: store, isPresented: $showingCompose)
            }
            .sheet(isPresented: $showingNewGroup) {
                NewGroupView(store: store, isPresented: $showingNewGroup)
            }
        }
    }
}

struct ComposeSheet: View {
    @Bindable var store: StoreOf<AppFeature>
    @Binding var isPresented: Bool
    @State private var address: String = ""
    @State private var showingScanner = false

    // Uses the public `isValidPeerAddress` helper added in Step 2 (add that
    // helper first — `Data(hexString:)` is internal to the package and NOT
    // visible to the app target).
    private var isValid: Bool { isValidPeerAddress(address) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Peer LXMF address (hex)") {
                    TextField("32 hex characters", text: $address)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                }
                Button("Start conversation") {
                    store.send(.startConversation(address))
                    isPresented = false
                }
                .disabled(!isValid)
            }
            .navigationTitle("New conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerView(ownAddress: store.myAddressHex) { hex in
                    address = hex
                    showingScanner = false
                    store.send(.startConversation(address))
                    isPresented = false
                }
            }
        }
    }
}
