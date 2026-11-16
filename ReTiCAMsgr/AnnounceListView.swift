//
//  AnnounceListView.swift
//  ReTiCAMsgr
//
//  Created by Elliot Schrock on 8/19/26.
//

import SwiftUI
import ComposableArchitecture
import ReTiCAMsgrCore

/// Presented as a sheet from the Chats nav bar. Tapping a row hands its address to `onPick`; the
/// presenter dismisses the sheet and opens the chat once the sheet is gone.
struct AnnounceListView: View {
    let store: StoreOf<AppFeature>
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Row order captured when the sheet opens. Announces re-arrive every few seconds, and sorting
    /// purely by recency moved rows under the user's finger, so a tap opened the wrong chat. Peers
    /// already listed keep their place; newcomers go at the bottom, so nothing above them shifts.
    @State private var order = AnnounceList.Order()
    @State private var searchText = ""

    var body: some View {
        // Once per body, and with a row limit. The peer table is network-sized and this body runs
        // on every announce the node accepts, so what it does per run has to stay small
        // (`AnnounceList`).
        let list = AnnounceList(from: store.state, order: order, search: searchText,
                                rowLimit: AnnounceList.screenRowLimit)
        NavigationStack {
            List {
                Section {
                    if list.known == 0 {
                        ContentUnavailableView(
                            "No One Yet",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text("People will show up here as their apps announce "
                                              + "themselves. Make sure you're connected in Settings.")
                        )
                    } else if list.rows.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ForEach(list.rows) { announce in
                            row(announce)
                        }
                        if list.more > 0 {
                            Text(moreText(list))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
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
            .searchable(text: $searchText, prompt: "Name or address")
            .autocorrectionDisabled()
            .onAppear { order = AnnounceList.Order(of: store.state) }
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

    /// The last row when the limit cut the list: how many people are not shown, and how to reach them.
    private func moreText(_ list: AnnounceList) -> String {
        let more = list.more.formatted()
        return list.matching == list.known
            ? "\(more) more not shown. Search by name or address to find someone."
            : "\(more) more match. Keep typing to narrow the search."
    }

    private func row(_ announce: AnnounceList.Row) -> some View {
        Button {
            onPick(announce.hex)
        } label: {
            HStack(spacing: 12) {
                AvatarView(store: store, peerHex: announce.hex, size: 40,
                           name: announce.contactName ?? announce.announcedName ?? "")
                VStack(alignment: .leading, spacing: 2) {
                    Text(announce.contactName ?? announce.announcedName ?? "Unnamed")
                        .font(.headline)
                    if announce.contactName != nil, let name = announce.announcedName {
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
