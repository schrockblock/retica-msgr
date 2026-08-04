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

    var body: some View {
        NavigationStack {
            Form {
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
        }
    }
}
