//
//  GroupViews.swift
//  ReTiCaMsgr
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore
import ReTiCANode

/// Local hex helper — ReTiCaMsgrCore's `Data.hexString` is internal to the package.
private func groupHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// One announced peer the pickers can offer.
private struct AnnouncedPeer: Identifiable {
    let hex: String
    let name: String?
    var id: String { hex }
}

private func announcedPeers(_ store: StoreOf<AppFeature>, excluding: Set<String>) -> [AnnouncedPeer] {
    store.state.node.client.learnedPeers
        .map { hash, peer in AnnouncedPeer(hex: groupHex(hash), name: peer.displayName) }
        .filter { !excluding.contains($0.hex) }
        .sorted { ($0.name ?? "~") < ($1.name ?? "~") }
}

/// Picks members from the announce list, a typed address or a scanned QR (spec 2026-10-09 §4).
/// `exclude` holds me and anyone already in the group.
struct GroupMemberPicker: View {
    let store: StoreOf<AppFeature>
    let exclude: Set<String>
    @Binding var selected: Set<String>
    @State private var address = ""
    @State private var showingScanner = false

    private var announced: [AnnouncedPeer] { announcedPeers(store, excluding: exclude) }
    private var typedOnly: [String] { selected.subtracting(announced.map(\.hex)).sorted() }
    private var canAddTyped: Bool {
        isValidPeerAddress(address) && !exclude.contains(address.lowercased()) && !selected.contains(address.lowercased())
    }

    var body: some View {
        Section("From announces") {
            if announced.isEmpty {
                Text("No announces heard yet").foregroundStyle(.secondary)
            }
            ForEach(announced) { peer in
                Button {
                    if selected.contains(peer.hex) { selected.remove(peer.hex) } else { selected.insert(peer.hex) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name ?? "Unnamed")
                            Text(shortHex(peer.hex))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected.contains(peer.hex) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    // The whole row is the tap target (UI rule), not just the glyphs.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        Section("By address") {
            TextField("32 hex characters", text: $address)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))
            Button("Add address") {
                selected.insert(address.lowercased())
                address = ""
            }
            .disabled(!canAddTyped)
            Button { showingScanner = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
            ForEach(typedOnly, id: \.self) { hex in
                HStack {
                    Text(shortHex(hex)).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button { selected.remove(hex) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove")
                }
            }
        }
        .sheet(isPresented: $showingScanner) {
            QRScannerView(ownAddress: store.myAddressHex) { hex in
                if !exclude.contains(hex.lowercased()) { selected.insert(hex.lowercased()) }
                showingScanner = false
            }
        }
    }
}

/// "New group" (spec §4): a name and members, Create disabled above the ceiling.
struct NewGroupView: View {
    let store: StoreOf<AppFeature>
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var selected: Set<String> = []

    private var memberCount: Int { selected.count + 1 }
    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selected.isEmpty
            && memberCount <= GroupWire.maxMembers
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group name") {
                    TextField("Name", text: $name)
                }
                Section {
                    Text("\(memberCount) of \(GroupWire.maxMembers) members, you included")
                        .foregroundStyle(memberCount > GroupWire.maxMembers ? .red : .secondary)
                }
                GroupMemberPicker(store: store, exclude: [store.myAddressHex], selected: $selected)
                Button("Create group") {
                    store.send(.createGroup(name: name, members: Array(selected)))
                    isPresented = false
                }
                .disabled(!canCreate)
            }
            .navigationTitle("New group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}

/// Add members to the open group (creator only).
struct AddGroupMembersView: View {
    let store: StoreOf<AppFeature>
    @Binding var isPresented: Bool
    @State private var selected: Set<String> = []

    private var current: Set<String> { Set(store.openGroupMembers.map(\.memberHex)) }
    private var canAdd: Bool { !selected.isEmpty && current.count + selected.count <= GroupWire.maxMembers }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(current.count + selected.count) of \(GroupWire.maxMembers) members")
                        .foregroundStyle(current.count + selected.count > GroupWire.maxMembers ? .red : .secondary)
                }
                GroupMemberPicker(store: store, exclude: current, selected: $selected)
                Button("Add members") {
                    store.send(.addGroupMembers(Array(selected)))
                    isPresented = false
                }
                .disabled(!canAdd)
            }
            .navigationTitle("Add members")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}

/// The group info screen (spec §4): name, members with reachability, the role's actions, caveat.
struct GroupInfoView: View {
    let store: StoreOf<AppFeature>
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var confirmingLeave = false
    @State private var pendingBlock: PendingBlock? = nil

    private var group: ChatGroup? { store.openGroup }
    private var isCreator: Bool { store.isOpenGroupCreator }
    private var isActive: Bool { group?.state == GroupState.active }

    var body: some View {
        NavigationStack {
            List {
                Section("Group") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(group?.name ?? "").foregroundStyle(.secondary)
                    }
                    if let state = group?.state, state != GroupState.active {
                        HStack {
                            Text("State")
                            Spacer()
                            Text(state).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(store.openGroupMembers, id: \.memberHex) { member in
                        VStack(alignment: .leading) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(store.reachablePeers.contains(member.memberHex) || member.memberHex == store.myAddressHex
                                          ? Color.green : Color.secondary.opacity(0.4))
                                    .frame(width: 8, height: 8)
                                if member.memberHex == store.myAddressHex {
                                    MyAvatarView(store: store, size: 32)
                                } else {
                                    AvatarView(store: store, peerHex: member.memberHex, size: 32)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.state.groupMemberName(member.memberHex))
                                    Text(shortHex(member.memberHex))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if member.memberHex == group?.creatorHex {
                                    Text("Creator").font(.caption).foregroundStyle(.secondary)
                                }
                                if store.state.isBlocked(member.memberHex) {
                                    Text("Blocked").font(.caption).foregroundStyle(.red)
                                }
                            }
                            if member.memberHex != store.myAddressHex {
                                // Shows no avatar of its own: the member row above has it.
                                ContactLinkRow(store: store, peerHex: member.memberHex)
                                    .padding(.leading, 16)
                            }
                        }
                        .swipeActions {
                            if isCreator, isActive, member.memberHex != store.myAddressHex {
                                Button("Remove", role: .destructive) { store.send(.removeGroupMember(member.memberHex)) }
                            }
                            if member.memberHex != store.myAddressHex {
                                if store.state.isBlocked(member.memberHex) {
                                    Button("Unblock") { store.send(.unblockPeer(member.memberHex)) }.tint(.accentColor)
                                } else {
                                    Button("Block", role: .destructive) {
                                        pendingBlock = PendingBlock(peerHex: member.memberHex, report: false)
                                    }
                                    if BlockUI.canReport {
                                        Button("Report", role: .destructive) {
                                            pendingBlock = PendingBlock(peerHex: member.memberHex, report: true)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Members (\(store.openGroupMembers.count) of \(GroupWire.maxMembers))")
                } footer: {
                    Text(GroupEventText.caveat)
                }
                if isCreator, isActive {
                    Section {
                        Button("Add members") { showingAdd = true }
                            .disabled(store.openGroupMembers.count >= GroupWire.maxMembers)
                        Button("Rename group") {
                            newName = group?.name ?? ""
                            renaming = true
                        }
                        Button("Delete group", role: .destructive) { confirmingDelete = true }
                    }
                } else if !isCreator, group?.state == GroupState.active {
                    Section {
                        Button("Leave group", role: .destructive) { confirmingLeave = true }
                    }
                }
            }
            // Refreshes `contactsAuthorization` and re-scans for import candidates (spec
            // 2026-10-11 Review Focus F3), as `PeerInfoView` already does — a group member's
            // Contact row needs the same up-to-date access state.
            .onAppear { store.send(.contactLinkSheetAppeared) }
            .navigationTitle("Group info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showingAdd) { AddGroupMembersView(store: store, isPresented: $showingAdd) }
            .alert("Rename group", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Rename") { store.send(.renameGroup(newName)) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this group for everyone?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete group", role: .destructive) {
                    store.send(.deleteGroup)
                    dismiss()
                }
            }
            .confirmationDialog("Leave this group?", isPresented: $confirmingLeave, titleVisibility: .visible) {
                Button("Leave group", role: .destructive) {
                    store.send(.leaveGroup)
                    dismiss()
                }
            }
            .blockConfirmation(store: store, pending: $pendingBlock)
            // A7: group members are blocked from here, so this sheet hosts the report composer too.
            .modifier(ReportPromptsModifier(store: store))
        }
    }
}

/// Accept and Decline in place of the composer while the group is `invited` (spec §4).
struct InviteBar: View {
    let groupName: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("You were invited to \(groupName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Decline", role: .destructive, action: onDecline)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Accept", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
    }
}

/// The line that replaces the composer once the group is left or dissolved.
struct ClosedGroupLine: View {
    let state: String

    var body: some View {
        Text(state == GroupState.dissolved ? "This group was deleted" : "You are no longer in this group")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding()
    }
}
