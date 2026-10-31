//
//  AnnounceListView.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/19/26.
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore
import ReTiCANode

/// Local hex helper — ReTiCaMsgrCore's `Data.hexString` is internal to the package.
private func toHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// A row in the detected-announces list, derived from `LXMFNode.LearnedPeer`.
private struct DetectedAnnounce: Identifiable {
    let id: Data          // destination hash (stable identity)
    let hex: String       // hex of the destination hash, for display
    let displayName: String?
    let learnedAt: Date
}

/// Presented as a sheet from the Chats nav bar. Tapping a row hands its address to `onPick`; the
/// presenter dismisses the sheet and opens the chat once the sheet is gone.
struct AnnounceListView: View {
    let store: StoreOf<AppFeature>
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Row order captured when the sheet opens. Announces re-arrive every few seconds, and sorting
    /// purely by recency moved rows under the user's finger, so a tap opened the wrong chat. Peers
    /// already listed keep their place; newcomers go at the bottom, so nothing above them shifts.
    @State private var frozenOrder: [Data] = []

    private var orderedAnnounces: [DetectedAnnounce] {
        let rank = Dictionary(uniqueKeysWithValues: frozenOrder.enumerated().map { ($1, $0) })
        let all = detectedAnnounces
        let newcomers = all.filter { rank[$0.id] == nil }
        let known = all.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return known + newcomers
    }

    private var detectedAnnounces: [DetectedAnnounce] {
        learnedPeers(store)
            .filter { hash, _ in !store.state.isBlocked(toHex(hash)) }
            .map { hash, peer in
                DetectedAnnounce(
                    id: hash,
                    hex: toHex(hash),
                    displayName: peer.displayName,
                    learnedAt: peer.learnedAt
                )
            }
            .sorted { $0.learnedAt > $1.learnedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if detectedAnnounces.isEmpty {
                        ContentUnavailableView(
                            "No One Yet",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text("People will show up here as their apps announce "
                                              + "themselves. Make sure you're connected in Settings.")
                        )
                    } else {
                        ForEach(orderedAnnounces) { announce in
                            row(announce)
                        }
                    }
                } header: {
                    Text("Messaging apps on the network periodically announce themselves so others "
                         + "can find them. Everyone this phone has heard from recently is listed "
                         + "here. Tap someone to start a chat.")
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
            }
            .insetGroupedListStyle()
            .onAppear { frozenOrder = detectedAnnounces.map(\.id) }
            .navigationTitle("Announces")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { store.send(.announceTapped) } label: {
                        Label("Announce Me", systemImage: "megaphone")
                    }
                    .accessibilityHint("Lets others on the network find you now")
                }
            }
        }
    }

    private func row(_ announce: DetectedAnnounce) -> some View {
        Button {
            onPick(announce.hex)
        } label: {
            HStack(spacing: 12) {
                AvatarView(store: store, peerHex: announce.hex, size: 40,
                           name: store.state.contactName(announce.hex) ?? announce.displayName ?? "")
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.state.contactName(announce.hex) ?? announce.displayName ?? "Unnamed")
                        .font(.headline)
                    if store.state.contactName(announce.hex) != nil, let name = announce.displayName {
                        Text("announces as \(name)").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(shortHex(announce.hex))
                            .font(.system(.caption, design: .monospaced))
                        Text(announce.learnedAt, style: .relative)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "bubble.left")
                    .foregroundStyle(Color.accentColor)
            }
            // Make the whole row tappable, not just the text glyphs (same pattern
            // as ConversationListView).
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
