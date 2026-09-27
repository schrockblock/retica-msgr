//
//  MessageInfoSheet.swift
//  ReTiCaMsgr
//

import SwiftUI
import UIKit
import ComposableArchitecture
import ReTiCaMsgrCore

/// Debugging metadata for one message. It reads the message from `store.threadMessages` by id, so
/// a milestone that lands while the sheet is open (the thread reloads) shows up live.
struct MessageInfoSheet: View {
    let store: StoreOf<AppFeature>
    let messageID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var showCopied = false
    @State private var copyGeneration = 0

    private var message: Message? {
        store.threadMessages.first { $0.id == messageID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let message {
                    List {
                        ForEach(Array(MessageInfo.sections(for: message).enumerated()), id: \.offset) { _, section in
                            Section {
                                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                    InfoRow(row: row) { copy(row.copy) }
                                }
                            } header: {
                                Text(section.title)
                            } footer: {
                                if let footer = section.footer { Text(footer) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    ContentUnavailableView("Message unavailable", systemImage: "questionmark.bubble")
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if showCopied {
                    Text("Copied")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else { return }   // "—" rows have nothing to copy
        UIPasteboard.general.string = value
        copyGeneration += 1
        let generation = copyGeneration
        withAnimation { showCopied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            // A newer copy restarts the timer: only the latest tap hides the overlay.
            if generation == copyGeneration {
                withAnimation { showCopied = false }
            }
        }
    }
}

/// Label left, monospaced value right. The whole row is the tap target (see the UI rule: a plain
/// Button otherwise only hit-tests its glyphs).
private struct InfoRow: View {
    let row: MessageInfo.Row
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.label)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(row.display)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Controller ruling P8 (overrides the brief): allowsHitTesting instead of disabled, so
        // "—" rows can't be tapped but aren't greyed out.
        .allowsHitTesting(!row.copy.isEmpty)
        .accessibilityHint(row.copy.isEmpty ? "" : "Copies the value")
    }
}
