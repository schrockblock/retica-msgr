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
            }
            .navigationTitle("Settings")
        }
    }
}
