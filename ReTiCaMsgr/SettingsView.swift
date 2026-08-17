//
//  SettingsView.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

struct SettingsView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var pnInput: String = ""
    @State private var nameInput: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Display Name") {
                    TextField("Your name", text: $nameInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                    // Saved on commit rather than per keystroke: each save re-announces on every
                    // interface, and `Transport` paces only RELAYED announces — locally originated
                    // ones go out immediately and ungated.
                    Button("Save name") { store.send(.setDisplayName(nameInput)) }
                        .disabled(nameInput == store.displayName)
                    if store.displayName.isEmpty {
                        Text("Other Reticulum clients show you as unnamed. Saving a name announces "
                             + "it to the network; clearing it announces that too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Shown to other clients as “\(store.displayName)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Node Connection") {
                    TextField("Host", text: $store.host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", value: $store.port, format: .number)
                        .keyboardType(.numberPad)
                    HStack {
                        Button("Connect") { store.send(.connectTapped) }
                            .buttonStyle(.bordered)
                        Button("Disconnect") { store.send(.disconnectTapped) }
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }
                }

                Section("Run as Propagation Node") {
                    Toggle("Act as a propagation node", isOn: Binding(
                        get: { store.nodeModeEnabled },
                        set: { store.send(.setNodeMode($0)) }
                    ))
                    Text("Stores and forwards messages for other users while this app is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Propagation Node") {
                    TextField("Node LXMF address (hex)", text: $pnInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                    Button("Save node") { store.send(.setPropagationNode(pnInput)) }
                        .disabled(!isValidPeerAddress(pnInput))
                    if !store.propagationNodeHex.isEmpty {
                        Text("Current: \(store.propagationNodeHex)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Settings")
            // Seed the field from persisted state, so opening Settings with a name set does not
            // show a blank box whose Save button would clear it. (The propagation-node field above
            // deliberately starts blank — pasting a fresh hex address is its normal use — but a
            // name is edited, not replaced.)
            .onAppear { nameInput = store.displayName }
        }
    }
}
