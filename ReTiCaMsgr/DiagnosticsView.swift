//
//  DiagnosticsView.swift
//  ReTiCaMsgr
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

/// Read-only triage. All derivation lives in `DiagnosticsSnapshot`; this file renders and
/// nothing else. Rebuilding the snapshot inside `body` is what makes the screen live — TCA
/// re-runs `body` when the observed state changes, so no timer or stored copy is needed.
struct DiagnosticsView: View {
    let store: StoreOf<AppFeature>

    private var snapshot: DiagnosticsSnapshot {
        DiagnosticsSnapshot(from: store.state, at: Date())
    }

    var body: some View {
        let snapshot = self.snapshot
        List {
            Section {
                ShareLink(item: snapshot.text) {
                    Label("Share diagnostics", systemImage: "square.and.arrow.up")
                }
                Button {
                    Pasteboard.copy(snapshot.text)
                } label: {
                    Label("Copy to clipboard", systemImage: "doc.on.doc")
                }
            } footer: {
                Text("The shared text carries full identifiers; the rows below are shortened "
                     + "for readability.")
            }

            ForEach(snapshot.layers, id: \.title) { layer in
                Section {
                    ForEach(Array(layer.rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top) {
                            // `shorten` is applied to BOTH label and value: the Paths layer uses
                            // the full destination hash as its label, and non-hex labels (a peer's
                            // display name, "app connection") pass through untouched.
                            Text(shorten(row.label))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(shorten(row.value))
                                .font(.system(.caption, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Circle().fill(color(layer.health)).frame(width: 8, height: 8)
                        Text(layer.title)
                        if let reason = layer.reason {
                            Text("— \(reason)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // The font's licence text is bundled as MDI-Apache-2.0.txt (ReTiCaMsgrCore Resources).
            Section {
            } footer: {
                Text("Icons: Material Design Icons by Pictogrammers, Apache License 2.0.")
            }
        }
        .navigationTitle("Diagnostics")
        .inlineNavigationTitle()
    }

    private func color(_ health: DiagnosticsSnapshot.Health) -> Color {
        switch health {
        case .ok:      return .green
        case .warn:    return .yellow
        case .problem: return .red
        }
    }

    /// Truncation is the VIEW's job — `DiagnosticsSnapshot.text` deliberately keeps identifiers
    /// full so a pasted dump can be correlated against other logs.
    private func shorten(_ value: String) -> String {
        value.split(separator: " ").map { token -> String in
            let parts = token.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[1].count > 16, isHex(String(parts[1])) {
                return "\(parts[0])=\(parts[1].prefix(8))…"
            }
            if token.count > 16, isHex(String(token)) { return "\(token.prefix(8))…" }
            return String(token)
        }.joined(separator: " ")
    }

    private func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isHexDigit }
    }
}
