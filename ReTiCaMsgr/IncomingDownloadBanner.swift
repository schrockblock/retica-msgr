//
//  IncomingDownloadBanner.swift
//  ReTiCaMsgr
//

import SwiftUI

/// "Receiving a message…" with a progress bar, while a larger message is on its way in. It never
/// names a sender: who sent it is unknown until the message is decrypted.
struct IncomingDownloadBanner: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Receiving a message…")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Receiving a message, \(Int(fraction * 100)) percent")
    }
}

/// Pins `IncomingDownloadBanner` under the navigation bar once a download has run for
/// `appearDelay`, so a quick one never flickers it; it goes as soon as the download ends.
private struct IncomingDownloadInset: ViewModifier {
    static let appearDelay: Duration = .milliseconds(500)

    let fraction: Double?
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                if shown, let fraction {
                    IncomingDownloadBanner(fraction: fraction)
                }
            }
            .task(id: fraction != nil) {
                guard fraction != nil else {
                    shown = false
                    return
                }
                // Cancelled when the download ends first (the id flips), so it never shows.
                do { try await ContinuousClock().sleep(for: Self.appearDelay) } catch { return }
                shown = true
            }
    }
}

extension View {
    /// The incoming-download banner for `fraction` (`AppFeature.State.incomingDownloadFraction`).
    func incomingDownloadBanner(_ fraction: Double?) -> some View {
        modifier(IncomingDownloadInset(fraction: fraction))
    }
}
