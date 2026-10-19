//
//  PeerInfoView.swift
//  ReTiCaMsgr
//

import SwiftUI
import UIKit
import ContactsUI
import ComposableArchitecture
import ReTiCaMsgrCore

/// Info for a one-to-one chat (spec 2026-10-11 §3): the address, the announce name, and the
/// Contact row. Group chats keep `GroupInfoView`, which reuses `ContactLinkRow` per member.
struct PeerInfoView: View {
    let store: StoreOf<AppFeature>
    let peerHex: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Address") {
                    Text(peerHex)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    if let announce = store.state.peerAnnounceName(peerHex),
                       announce != store.state.contactName(peerHex) {
                        Text("announces as \(announce)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Contact") {
                    ContactLinkRow(store: store, peerHex: peerHex)
                    // Its own row, not per group member (Review Focus F3 item 4): the button
                    // imports every candidate at once, so it belongs here once, not repeated.
                    if !store.state.importCandidates.isEmpty {
                        Button("Import \(store.state.importCandidates.count) addresses found in Contacts") {
                            store.send(.importContactLinks)
                        }
                    }
                }
                if peerHex != store.myAddressHex { SafetySection(store: store, peerHex: peerHex) }
            }
            .navigationTitle("Chat info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { store.send(.contactLinkSheetAppeared) }
            // Hosted here, not at the root: this view is itself a sheet, and the report is only started from it.
            .modifier(ReportPromptsModifier(store: store))
        }
    }
}

/// The Contact row (spec §3): link, or the linked contact with its source, verified state,
/// thumbnail and actions. Used by `PeerInfoView` and per member in `GroupInfoView`.
struct ContactLinkRow: View {
    let store: StoreOf<AppFeature>
    let peerHex: String
    @State private var managingAccess = false

    private var link: ContactLink? { store.state.contactLinks[peerHex] }
    /// What Contacts reported for the linked card, keyed by the contact so a changed link never
    /// shows the previous contact's photo (backlog item 6); loaded by `contactRowAppeared`.
    private var card: ContactCard? { link.flatMap { store.state.contactCards[$0.contactIdentifier] } }

    var body: some View {
        if let link {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    // Same precedence as everywhere else: their photo, the contact's, their icon, initials.
                    AvatarView(store: store, peerHex: peerHex, size: 36, name: link.cachedName,
                               loadsContactCard: false)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(link.cachedName)
                            if !link.verified {
                                Text("unverified").font(.caption2).foregroundStyle(.orange)
                            }
                            if link.isConflicted {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            }
                        }
                        Text(sourceText(link)).font(.caption).foregroundStyle(.secondary)
                        // Not when access is merely denied: the contact itself is not gone, only
                        // unreadable, and that case already gets its own explanation below.
                        if card == .missing, store.state.contactsAuthorization != .denied {
                            Text("Contact not available").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if store.state.pendingVerifyPrompts.contains(peerHex), let last = link.confirmations.last {
                    let who = store.state.peerDisplayName(last.peerHex) ?? shortHex(last.peerHex)
                    Text("\(who) also has this address for \(link.cachedName). Mark it verified?")
                        .font(.caption)
                    HStack {
                        Button("Verify") { store.send(.markContactVerified(peerHex: peerHex)) }
                        Button("Not now") { store.send(.dismissVerifyPrompt(peerHex: peerHex)) }
                    }
                    .buttonStyle(.bordered)
                }
                if link.isConflicted, let other = link.conflictPeerHex {
                    Text("\(store.state.peerDisplayName(other) ?? shortHex(other)) has a different address for \(link.cachedName).")
                        .font(.caption).foregroundStyle(.red)
                    Button("Dismiss conflict") { store.send(.resolveConflict(peerHex: peerHex)) }
                }
                HStack {
                    Button("Change contact") { store.send(.linkContactTapped(peerHex: peerHex, source: ContactLinkSource.manual)) }
                    if !link.verified {
                        Button("Mark as verified") { store.send(.markContactVerified(peerHex: peerHex)) }
                    }
                    Button("Unlink", role: .destructive) { store.send(.unlinkContact(peerHex: peerHex)) }
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
            // Live name and photo through the reducer (backlog item 10): a rename updates the
            // cache, a missing contact says so. Re-sent whenever the linked contact changes. This is
            // the live refresh; the row's `AvatarView` is told not to load the card itself.
            .task(id: link.contactIdentifier) { store.send(.contactRowAppeared(peerHex: peerHex)) }
            // The denied/limited affordance shows whether or not a link already exists
            // (Review Focus F3 item 3): access, not the contact, is what's missing.
            accessRows(linked: true)
        } else {
            Button {
                store.send(.linkContactTapped(peerHex: peerHex, source: ContactLinkSource.manual))
            } label: {
                Label("Link to contact", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            accessRows(linked: false)
        }
    }

    @ViewBuilder
    private func accessRows(linked: Bool) -> some View {
        if store.state.contactsAuthorization == .denied {
            Text(linked
                 ? "Contacts access is off for ReTiCaMsgr. The name shown is the one saved when you linked "
                   + "it; allow access in Settings to update or change the contact."
                 : "Contacts access is off for ReTiCaMsgr. Allow it in Settings to link a contact.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
        if store.state.contactsAuthorization == .limited {
            Text("Only the contacts you selected are available.")
                .font(.caption).foregroundStyle(.secondary)
            if store.state.contactMirrorEnabled {
                Text("The contact card cannot be updated with limited access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Manage selected contacts") { managingAccess = true }
                .modifier(ManageAccessPickerModifier(isPresented: $managingAccess))
        }
    }

    private func sourceText(_ link: ContactLink) -> String {
        switch link.source {
        case ContactLinkSource.scanned: return "Scanned from a QR code"
        case ContactLinkSource.imported: return "Imported from Contacts"
        case ContactLinkSource.discovered:
            let via = link.discoveredViaHex.map { store.state.peerDisplayName($0) ?? shortHex($0) } ?? "a contact exchange"
            let when = link.discoveredAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
            return "Found via \(via) on \(when)"
        default: return "You linked this"
        }
    }
}

/// The system "manage selected contacts" picker, applied to the button that opens it (iOS 18+;
/// `contactAccessPicker` does not exist before that). Below iOS 18 the button it's applied to
/// disappears instead of sitting there doing nothing — the one place this feature checks
/// `#available`.
private struct ManageAccessPickerModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.contactAccessPicker(isPresented: $isPresented) { _ in }
        } else {
            EmptyView()
        }
    }
}

/// Presents the contact picker and the Replace alert for the whole app, driven by state
/// (`linkPickerTarget`, `pendingLinkCollision`), so a pick started from the compose sheet
/// survives that sheet's dismissal. Attached once, at the root.
struct LinkPromptsModifier: ViewModifier {
    @Bindable var store: StoreOf<AppFeature>

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { store.linkPickerTarget != nil },
                set: { if !$0 { store.send(.linkPickerDismissed) } }
            )) {
                if let target = store.linkPickerTarget {
                    ContactPicker(
                        onPick: { identifier, name in
                            store.send(.contactPicked(peerHex: target.peerHex, identifier: identifier,
                                                      name: name, source: target.source))
                        },
                        onCancel: { store.send(.linkPickerDismissed) })
                    .ignoresSafeArea()
                }
            }
            .alert(collisionTitle, isPresented: Binding(
                get: { store.pendingLinkCollision != nil },
                set: { if !$0 { store.send(.cancelLinkCollision) } }
            )) {
                Button("Replace") { store.send(.replaceLinkConfirmed) }
                Button("Cancel", role: .cancel) { store.send(.cancelLinkCollision) }
            }
            // A link asked for with access denied, from any entry point (the scan dialog has no
            // info sheet to explain itself in): say why nothing happened (backlog item 2).
            .alert("Contacts access is off", isPresented: Binding(
                get: { store.showingContactsDenied },
                set: { if !$0 { store.send(.dismissContactsDenied) } }
            )) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    store.send(.dismissContactsDenied)
                }
                Button("Cancel", role: .cancel) { store.send(.dismissContactsDenied) }
            } message: {
                Text("Allow ReTiCaMsgr to use Contacts in Settings to link a contact.")
            }
    }

    private var collisionTitle: String {
        guard let c = store.pendingLinkCollision else { return "" }
        return zip(c.existing, c.kinds).map { row, kind -> String in
            switch kind {
            case .peerAlreadyLinked: return "This address is linked to \(row.cachedName)"
            case .contactAlreadyLinked: return "\(row.cachedName) is linked to \(shortHex(row.peerHex))"
            }
        }.joined(separator: ", and ")
    }
}
