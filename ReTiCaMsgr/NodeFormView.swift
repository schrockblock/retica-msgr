//
//  NodeFormView.swift
//  ReTiCaMsgr
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

/// Add or edit a user node (spec 2026-10-10 §4 "Node form"). Save stays disabled until
/// `NodeRules` accepts the fields; saving a push hex makes this node the push node.
struct NodeFormView: View {
    let store: StoreOf<AppFeature>
    /// nil for "Add node"; the entry being edited otherwise.
    let existing: NodeEntry?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var portText = ""
    @State private var pushHex = ""

    private var port: Int { Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0 }

    private var isValid: Bool {
        NodeRules.validationError(host: host, port: port, pushHubHex: pushHex) == nil
    }

    /// True when saving would move the push role off another node.
    private var replacesPushNode: NodeEntry? {
        guard NodeRules.normalized(host: host, pushHubHex: pushHex).pushHubHex != nil,
              let current = store.pushNode, current.id != existing?.id else { return nil }
        return current
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Node") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                    TextField("Host", text: $host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                }
                Section("Push") {
                    TextField("Push hub destination (32 hex)", text: $pushHex)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Text("Your hub must support ReTiCA push and must have announced its registration "
                         + "destination to this device. Notifications only ever say \"New message\"; nothing "
                         + "about the sender or the content leaves the device unencrypted. A changed hub "
                         + "takes effect on the next launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let current = replacesPushNode {
                        Text("Saving makes this node the push node and removes the push hub destination "
                             + "from \(current.name).")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Node" : "Edit Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .onAppear {
                guard let existing else { return }
                name = existing.name
                host = existing.host
                portText = String(existing.port)
                pushHex = existing.pushHubHex ?? ""
            }
        }
    }

    private func save() {
        let hex: String? = pushHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pushHex
        if var entry = existing {
            entry.name = name
            entry.host = host
            entry.port = port
            entry.pushHubHex = hex
            store.send(.updateNode(entry))
        } else {
            store.send(.addNode(name: name, host: host, port: port, pushHubHex: hex))
        }
        dismiss()
    }
}

/// One row of the Nodes list: a connection dot, the name (with "(default)" for the built-in
/// entry), host:port beneath, a Push tag on the push node, and the enabled toggle. A user row's
/// content is tappable to edit; the whole content area is the hit target (project UI rule).
struct NodeRow: View {
    let node: NodeEntry
    let isConnected: Bool
    let isPushNode: Bool
    let onTap: (() -> Void)?
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onTap?()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(node.isBuiltIn ? "\(node.name) (default)" : node.name)
                            if isPushNode {
                                Text("Push")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                        }
                        Text(node.hostPort)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
            Toggle("", isOn: Binding(get: { node.enabled }, set: onToggle))
                .labelsHidden()
                .accessibilityLabel("\(node.name) enabled")
        }
    }
}
