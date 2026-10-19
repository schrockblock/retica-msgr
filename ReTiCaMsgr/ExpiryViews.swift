//
//  ExpiryViews.swift
//  ReTiCaMsgr
//

import SwiftUI
import ReTiCaMsgrCore

/// The disappearing-messages picker in the chat toolbar (spec 2026-10-05 §4): Signal's presets
/// with a checkmark on the current one, and the caveat that only ReTiCaMsgr peers honour it.
struct ExpiryMenu: View {
    let current: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        Menu {
            Section {
                ForEach(ExpiryPreset.allCases, id: \.rawValue) { preset in
                    Button {
                        onSelect(preset.seconds)
                    } label: {
                        if (current ?? 0) == preset.seconds {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
            } header: {
                Text(ExpiryPreset.caveat)
            }
        } label: {
            Image(systemName: current == nil ? "timer" : "timer.circle.fill")
        }
        .accessibilityLabel("Disappearing messages")
    }
}

/// The chat title, with the peer's short address and the active timer beneath the name.
struct ChatTitle: View {
    let title: String
    var subtitle: String? = nil
    let expiry: Int?

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let expiry {
                Label(ExpiryPreset.label(forSeconds: expiry), systemImage: "timer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A timer-change announcement: a centred, secondary single line instead of a bubble. No context
/// menu, no reactions, no reply. An outgoing change shows its send status until it is delivered
/// or propagated (amendment A14): a change that never reached the peer has not taken effect there.
struct TimerChangeLine: View {
    let text: String
    var status: String? = nil

    private var visibleStatus: String? {
        guard let status, status != MessageStatus.delivered, status != MessageStatus.propagated else { return nil }
        return status
    }

    var body: some View {
        HStack {
            Spacer()
            Group {
                if let visibleStatus {
                    Text("\(text)\(Text(" · \(visibleStatus)").font(.caption2))")
                } else {
                    Text(text)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
