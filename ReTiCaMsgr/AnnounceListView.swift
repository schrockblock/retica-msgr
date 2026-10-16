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

struct AnnounceListView: View {
    let store: StoreOf<AppFeature>

    private var detectedAnnounces: [DetectedAnnounce] {
        store.state.node.client.learnedPeers
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
            Group {
                if detectedAnnounces.isEmpty {
                    ContentUnavailableView(
                        "No Announces Detected",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("LXMF delivery announces from other clients will appear here once the node is connected.")
                    )
                } else {
                    List(detectedAnnounces) { announce in
                        Button {
                            store.send(.announceRowTapped(destinationHashHex: announce.hex))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
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
                                        .foregroundStyle(.secondary)
                                }
                                publicKeyRequestStatus(for: announce.hex)
                            }
                            // Make the whole row tappable, not just the text glyphs (same pattern
                            // as ConversationListView).
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Announces")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { store.send(.announceTapped) } label: {
                        Label("Announce", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }
        }
    }

    /// The tapped row's public key (from the peer's announce), if any.
    @ViewBuilder
    private func publicKeyRequestStatus(for hex: String) -> some View {
        switch store.state.publicKeyRequests[hex] {
        case let .received(keyHex):
            Label(shortHex(keyHex), systemImage: "checkmark.seal")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green)
        case let .failed(reason):
            Label(reason, systemImage: "xmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
}
