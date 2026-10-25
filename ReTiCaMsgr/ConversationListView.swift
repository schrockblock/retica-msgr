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

/// What a scanned-then-dismissed compose sheet decided (spec 2026-10-11 Review Focus F1): acted
/// on from `ConversationListView`'s `onDismiss`, once the compose sheet itself has finished
/// tearing down, so the root picker it may trigger never collides with that dismissal.
enum ScanOutcome: Equatable {
    case start(String)
    case startAndLink(String)
}

struct ConversationListView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var showingCompose = false
    @State private var showingNewGroup = false
    @State private var scanOutcome: ScanOutcome?
    @State private var showingAnnounces = false
    /// Picked in the announces sheet; started from its `onDismiss`, once the sheet is gone, so
    /// the chat push never races the sheet's dismissal (same reason as `scanOutcome`).
    @State private var announcePick: String?

    var connectionColor: Color {
        switch store.connection {
        case .disconnected: return .red
        case .connecting: return .yellow
        case .connected: return .green
        }
    }

    var body: some View {
        NavigationStack {
            List(store.conversationRows) { convo in
                Button {
                    store.send(convo.kind == .group ? .openGroupConversation(convo.peerHex) : .openConversation(convo.peerHex))
                } label: {
                    HStack(spacing: 12) {
                        rowAvatar(convo)
                        rowDetails(convo)
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
            .overlay {
                if store.conversationRows.isEmpty {
                    ChatsWelcomeView { showingCompose = true }
                }
            }
            // A larger message on its way in, from anyone (the sender isn't known yet).
            .incomingDownloadBanner(store.incomingDownloadFraction)
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .barLeading) {
                    Circle().fill(connectionColor).frame(width: 10, height: 10)
                }
                ToolbarItem(placement: .barTrailing) {
                    Button { showingAnnounces = true } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .accessibilityLabel("Announces")
                }
                ToolbarItem(placement: .barTrailing) {
                    Button { store.send(.syncTapped) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Check for messages")
                }
                ToolbarItem(placement: .barTrailing) {
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
            .sheet(isPresented: $showingCompose, onDismiss: {
                switch scanOutcome {
                case let .start(hex)?:
                    store.send(.startConversation(hex))
                case let .startAndLink(hex)?:
                    store.send(.startConversation(hex))
                    store.send(.linkContactTapped(peerHex: hex, source: ContactLinkSource.scanned))
                case nil:
                    break
                }
                scanOutcome = nil
            }) {
                ComposeSheet(store: store, isPresented: $showingCompose, scanOutcome: $scanOutcome)
            }
            .sheet(isPresented: $showingNewGroup) {
                NewGroupView(store: store, isPresented: $showingNewGroup)
            }
            .sheet(isPresented: $showingAnnounces, onDismiss: {
                if let hex = announcePick { store.send(.startConversation(hex)) }
                announcePick = nil
            }) {
                AnnounceListView(store: store) { hex in
                    announcePick = hex
                    showingAnnounces = false
                }
                .macSheetFrame()
            }
        }
    }

    /// A peer's avatar; a group keeps its `person.3` glyph, in a circle of the same size.
    @ViewBuilder
    private func rowAvatar(_ convo: Conversation) -> some View {
        if convo.kind == .group {
            Image(systemName: "person.3.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Brand.gradient))
                .accessibilityHidden(true)
        } else {
            AvatarView(store: store, peerHex: convo.peerHex, size: 40)
        }
    }

    private func rowDetails(_ convo: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let title = convo.title {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                } else {
                    // Contact name, else the name from their announce, else the address.
                    Text(store.state.peerDisplayName(convo.peerHex) ?? shortHex(convo.peerHex))
                        .font(store.state.peerDisplayName(convo.peerHex) == nil
                              ? .system(.headline, design: .monospaced) : .headline)
                }
                if convo.groupState == GroupState.invited {
                    Text("Invited")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                if convo.kind == .peer, store.state.isBlocked(convo.peerHex) {
                    Text("Blocked")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                }
                if store.state.contactLinks[convo.peerHex]?.isConflicted == true {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                }
                Spacer()
                Text(convo.lastTimestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(convo.preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct ComposeSheet: View {
    @Bindable var store: StoreOf<AppFeature>
    @Binding var isPresented: Bool
    @Binding var scanOutcome: ScanOutcome?
    @State private var address: String = ""
    @State private var showingScanner = false
    @State private var pendingScan: String?
    @State private var askingWhoIsThis = false

    // Uses the public `isValidPeerAddress` helper added in Step 2 (add that
    // helper first — `Data(hexString:)` is internal to the package and NOT
    // visible to the app target).
    private var isValid: Bool { isValidPeerAddress(address) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Their address (32 characters)", text: $address)
                        .autocorrectionDisabled()
                        .platformAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                    // Camera QR scanning is hidden on macOS (macOS port Global Constraints).
                    #if os(iOS)
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                    #endif
                } header: {
                    Text("Address")
                } footer: {
                    Text("Ask them for their code: it's under Settings › My QR Code & Address.")
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
            // The scanner sheet must fully dismiss before "Who is this?" goes up — presenting
            // both at once let the picker collide with the in-flight dismissal (Review Focus
            // F1). `onDismiss` fires only after that teardown finishes.
            .sheet(isPresented: $showingScanner, onDismiss: {
                if pendingScan != nil { askingWhoIsThis = true }
            }) {
                QRScannerView(ownAddress: store.myAddressHex) { hex in
                    address = hex
                    pendingScan = hex
                    showingScanner = false
                }
            }
            // `presenting:` hands the scanned hex to the buttons themselves, so clearing
            // `pendingScan` when the dialog goes away cannot race a tap.
            .confirmationDialog("Who is this?", isPresented: $askingWhoIsThis, titleVisibility: .visible,
                                presenting: pendingScan) { hex in
                // Neither button sends anything itself: the pick's `linkContactTapped` would
                // race the compose sheet's own dismissal. They just record the outcome; the
                // list's `onDismiss` acts on it once this sheet is fully gone.
                Button("Choose contact") {
                    scanOutcome = .startAndLink(hex)
                    isPresented = false
                }
                Button("Not now") {
                    scanOutcome = .start(hex)
                    isPresented = false
                }
            }
            .onChange(of: askingWhoIsThis) { _, asking in
                // Dismissed by tapping outside: forget the scan, or reopening and cancelling the
                // scanner in this same sheet would re-ask about the old address (backlog item 1).
                if !asking { pendingScan = nil }
            }
        }
    }
}
