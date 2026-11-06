import SwiftUI
import ReTiCAMsgrCore

/// A plain-language explanation of one part of how Reticulum works (spec 2026-10-22): what is
/// happening and why, the Reticulum term, and a page of the docs for more.
struct ExplainerSheet: View {
    let topic: ExplainerTopic
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        let explainer = ReticulumExplainer.explainer(for: topic)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(explainer.title)
                    .font(.title3.weight(.semibold))
                Text(explainer.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: explainer.learnMoreURL) {
                    Label("Learn more in the Reticulum manual", systemImage: "arrow.up.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .font(.callout.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        #if os(macOS)
        // A Mac sheet has no swipe-down: without a cancel button it cannot be closed.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 420, minHeight: 320)
        #endif
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Text first, then the icon, so the link reads "Learn more … ↗".
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

/// The empty Chats screen: the app's principle, then its four points, each opening an
/// explanation (spec 2026-10-22, layout A).
struct ChatsWelcomeView: View {
    let onNewConversation: () -> Void
    @State private var explaining: ExplainerTopic?
    /// Grows with Dynamic Type so the row symbols line up without overflowing at large sizes.
    @ScaledMetric(relativeTo: .subheadline) private var symbolWidth: CGFloat = 24

    private static let points: [(topic: ExplainerTopic, title: String, subtitle: String, symbol: String)] = [
        (.direct, "Direct", "No company server holds your chats", "arrow.left.arrow.right"),
        (.encrypted, "Encrypted by default", "Only you and they can read it", "lock.fill"),
        (.resilient, "Resilient", "Retries, and leaves messages at a pickup point", "arrow.clockwise"),
        (.anyConnection, "Any connection", "Internet, Wi‑Fi, Bluetooth, radio", "antenna.radiowaves.left.and.right"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Messaging without a middleman")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Your messages travel directly between devices, encrypted from the start, over whatever "
                         + "connection exists. There's no company server in the middle, so it keeps working when "
                         + "networks are slow or down.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 0) {
                    ForEach(Self.points, id: \.topic) { point in
                        Divider()
                        Button { explaining = point.topic } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: point.symbol)
                                    .foregroundStyle(.tint)
                                    .frame(width: symbolWidth)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.title).font(.subheadline.weight(.semibold))
                                    Text(point.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.tint)
                            }
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Shows an explanation")
                    }
                    Divider()
                }
                Button("New Conversation", action: onNewConversation)
                    .buttonStyle(.borderedProminent)
                Text("Start by scanning a friend's QR code, or tap the antenna to see who has announced "
                     + "themselves recently.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $explaining) { ExplainerSheet(topic: $0) }
    }
}
