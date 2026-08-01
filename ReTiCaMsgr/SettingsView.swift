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
    @State private var peerInput: String = ""

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
                        Button("Connect") {
                            store.send(.connectTapped)
                        }
                        .buttonStyle(.bordered)
                        Button("Disconnect") {
                            store.send(.disconnectTapped)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }

                Section("Peer Address") {
                    TextField("Peer LXMF address (hex)", text: $peerInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                    Button("Save peer") {
                        store.send(.setPeer(peerInput))
                    }
                    .disabled(peerInput.isEmpty)
                    if !store.peerAddressHex.isEmpty {
                        Text("Current: \(store.peerAddressHex)")
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
