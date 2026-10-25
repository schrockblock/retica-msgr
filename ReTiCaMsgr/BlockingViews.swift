import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(MessageUI)
import MessageUI
#endif
import ComposableArchitecture
import ReTiCaMsgrCore

/// The "Safety" section of the peer info sheet (spec 2026-10-15 §3): Block / Report and block, or
/// Unblock / Report once blocked. Report is hidden while `SupportContact.reportAddress` is empty.
struct SafetySection: View {
    let store: StoreOf<AppFeature>
    let peerHex: String
    @State private var pending: PendingBlock? = nil

    var body: some View {
        Section("Safety") {
            if store.state.isBlocked(peerHex) {
                Button("Unblock") { store.send(.unblockPeer(peerHex)) }
                if BlockUI.canReport {
                    Button("Report") { store.send(.reportPeer(peerHex)) }
                }
            } else {
                Button("Block", role: .destructive) { pending = PendingBlock(peerHex: peerHex, report: false) }
                if BlockUI.canReport {
                    Button("Report and block", role: .destructive) { pending = PendingBlock(peerHex: peerHex, report: true) }
                }
            }
        }
        .blockConfirmation(store: store, pending: $pending)
    }
}

/// A block the user is about to confirm: which address, and whether a report follows.
struct PendingBlock: Identifiable, Equatable {
    let peerHex: String
    let report: Bool
    var id: String { "\(peerHex)-\(report)" }
}

enum BlockUI {
    /// Report actions exist only once the support address is filled in.
    static var canReport: Bool { !SupportContact.reportAddress.isEmpty }
}

extension View {
    /// The block confirmation dialog (spec §3), shared by the peer info Safety section and the
    /// group member rows (A7). `pending` drives presentation; confirming blocks and, if asked, reports.
    func blockConfirmation(store: StoreOf<AppFeature>, pending: Binding<PendingBlock?>) -> some View {
        confirmationDialog("Block this address?", isPresented: Binding(
            get: { pending.wrappedValue != nil },
            set: { if !$0 { pending.wrappedValue = nil } }
        ), titleVisibility: .visible, presenting: pending.wrappedValue) { choice in
            Button(choice.report ? "Report and block" : "Block", role: .destructive) {
                pending.wrappedValue = nil
                store.send(.blockPeer(choice.peerHex))
                if choice.report { store.send(.reportPeer(choice.peerHex)) }
            }
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
        } message: { _ in
            Text("Messages from this address will no longer arrive. The conversation stays, and you can unblock it here later.")
        }
    }
}

/// Replaces the composer in a direct chat with a blocked peer (spec §3 "Chat").
struct BlockedBar: View {
    let onUnblock: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("You blocked this address")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Unblock", action: onUnblock)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
        .padding()
    }
}

/// Settings → Blocked Addresses (spec §3 "Settings"): every block, newest first, with Unblock.
struct BlockedAddressesView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        Group {
            if store.blockedPeerRows.isEmpty {
                ContentUnavailableView("No Blocked Addresses", systemImage: "hand.raised",
                                       description: Text("Addresses you block appear here."))
            } else {
                List(store.blockedPeerRows, id: \.peerHex) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.state.contactName(row.peerHex) ?? shortHex(row.peerHex))
                            .font(store.state.contactName(row.peerHex) == nil
                                  ? .system(.headline, design: .monospaced) : .headline)
                        Text("Blocked \(row.blockedAt, style: .date)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .swipeActions {
                        Button("Unblock") { store.send(.unblockPeer(row.peerHex)) }.tint(.accentColor)
                    }
                }
            }
        }
        .navigationTitle("Blocked Addresses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Presents the report draft (spec §3 "Report flow"): the mail composer when the device can send
/// mail, otherwise a `mailto:` URL. Either way the user sees the full text before sending, and
/// dismissal clears the draft. Hosted by each sheet that can start a report (`PeerInfoView`, `GroupInfoView`), never at the root: those sheets are already presenting, so a root host could not present over them.
struct ReportPromptsModifier: ViewModifier {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { MFMailComposeViewController.canSendMail() ? store.reportDraft : nil },
                set: { if $0 == nil { store.send(.reportDismissed) } }
            )) { draft in
                ReportMailSheet(draft: draft) { store.send(.reportDismissed) }
                    .ignoresSafeArea()
            }
            .onChange(of: store.reportDraft) { _, draft in
                guard let draft, !MFMailComposeViewController.canSendMail() else { return }
                if let url = Self.mailtoURL(draft) { openURL(url) }
                store.send(.reportDismissed)
            }
    }

    static func mailtoURL(_ draft: ReportDraft) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.recipient
        components.queryItems = [URLQueryItem(name: "subject", value: draft.subject),
                                 URLQueryItem(name: "body", value: draft.body)]
        return components.url
    }
}

/// `MFMailComposeViewController` with the draft filled in; `onFinish` on any result, cancel included.
struct ReportMailSheet: UIViewControllerRepresentable {
    let draft: ReportDraft
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([draft.recipient])
        controller.setSubject(draft.subject)
        controller.setMessageBody(draft.body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: (any Error)?) {
            // SwiftUI owns the sheet: clearing the draft dismisses it.
            onFinish()
        }
    }
}
