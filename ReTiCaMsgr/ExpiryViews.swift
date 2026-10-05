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

/// The chat title with the active timer beneath the peer's name.
struct ChatTitle: View {
    let title: String
    let expiry: Int?

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
            if let expiry {
                Label(ExpiryPreset.label(forSeconds: expiry), systemImage: "timer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A timer-change announcement: a centred, secondary single line instead of a bubble. No context
/// menu, no reactions, no reply.
struct TimerChangeLine: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
