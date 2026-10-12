//
//  SettingsView.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import UIKit
import ComposableArchitecture
import ReTiCaMsgrCore
import ReTiCAPush

struct SettingsView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var pnInput: String = ""
    @State private var nameInput: String = ""
    @State private var showingAddress = false
    @State private var showingAddNode = false
    @State private var editingNode: NodeEntry? = nil
    @Environment(\.openURL) private var openURL

    private var pushStatusIsFailure: Bool {
        if case .failed = store.push.status { return true }
        return false
    }

    /// The default's propagation node is in effect: a default exists and the toggle is on.
    private var usesDefaultPropagation: Bool {
        DefaultNode.propagationHex != nil && store.usePropagationDefault
    }

    private var connectionColor: Color {
        switch store.connection {
        case .disconnected: return .red
        case .connecting: return .yellow
        case .connected: return .green
        }
    }

    private var connectionLabel: String {
        switch store.connection {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        }
    }

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

                Section {
                    HStack(spacing: 8) {
                        Circle().fill(connectionColor).frame(width: 10, height: 10)
                        Text(connectionLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.nodes) { node in
                        NodeRow(
                            node: node,
                            isConnected: store.connectedInterfaces.contains(node.interfaceID),
                            isPushNode: store.pushNode?.id == node.id,
                            onTap: node.isBuiltIn ? nil : { editingNode = node },
                            onToggle: { store.send(.setNodeEnabled(id: node.id, enabled: $0)) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !node.isBuiltIn {
                                Button("Delete", role: .destructive) { store.send(.removeNode(id: node.id)) }
                            }
                        }
                    }
                    Button("Add node") { showingAddNode = true }
                    HStack {
                        Button("Connect") { store.send(.connectTapped) }
                            .buttonStyle(.bordered)
                        Button("Disconnect") { store.send(.disconnectTapped) }
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }
                } header: {
                    Text("Nodes")
                } footer: {
                    if store.enabledNodes.isEmpty {
                        Text("No node is enabled. The app reaches peers only over Bluetooth or direct "
                             + "connections.")
                    } else {
                        Text("Connect and Disconnect act on every enabled node. Tap a node to edit it, "
                             + "swipe to delete.")
                    }
                }

                Section("Direct Connections") {
                    // Standard Toggle in a Form row: the whole row is already hittable, so no
                    // explicit contentShape is needed here.
                    Toggle("Listen for direct connections", isOn: $store.listenEnabled)
                    TextField("Listen port", value: $store.listenPort, format: .number)
                        .keyboardType(.numberPad)
                        .disabled(!store.listenEnabled)
                    Text("Lets other Reticulum nodes on your local Wi-Fi connect directly to this "
                         + "device — anyone on the same network can reach it. Off by default. "
                         + "Takes effect on the next Connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Bluetooth") {
                    // Standard Toggle in a Form row: the whole row is already hittable.
                    Toggle("Connect over Bluetooth", isOn: $store.bleEnabled)
                    if store.bluetoothAlert == .permissionDenied {
                        Text("Bluetooth permission is denied. Allow it in Settings to connect to "
                             + "nearby devices.")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                    } else if store.bluetoothAlert == .unsupported {
                        Text("This device doesn’t support Bluetooth LE, so Bluetooth connections "
                             + "aren’t available.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Connects directly to nearby Reticulum devices (other iPhones, "
                             + "Raspberry Pis) over Bluetooth to send and relay messages — no Wi-Fi "
                             + "or shared server needed. Off by default. Takes effect on the next "
                             + "Connect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Relay") {
                    Toggle("Relay traffic for other nodes", isOn: Binding(
                        get: { store.relayEnabled },
                        set: { store.send(.setRelayMode($0)) }
                    ))
                    Text("Carries other users' messages through this device so the mesh reaches "
                         + "further — it forwards transit traffic and answers path requests for "
                         + "peers it hasn't met. Off by default. Uses more battery and data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Push Notifications") {
                    Toggle("Wake me with push", isOn: Binding(
                        get: { store.push.enabled },
                        set: { store.send(.push(.setEnabled($0))) }
                    ))
                    .disabled(store.pushNode == nil && !store.push.enabled)
                    if let pushNode = store.pushNode {
                        Text("Push node: \(pushNode.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(store.pushStatusText)
                            .font(.caption)
                            .foregroundStyle(pushStatusIsFailure ? .red : .secondary)
                    } else {
                        Text("No push node. Add a push hub destination to a node to enable wake-ups.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Notifications only ever say \"New message\"; nothing about the sender or the "
                         + "content leaves the device unencrypted. Changing the push node re-registers with "
                         + "the new hub as soon as it is reachable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    if DefaultNode.propagationHex != nil {
                        Toggle("Use the default node's propagation node", isOn: Binding(
                            get: { store.usePropagationDefault },
                            set: { store.send(.setUsePropagationDefault($0)) }
                        ))
                    }
                    TextField("Node LXMF address (hex)", text: $pnInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .disabled(usesDefaultPropagation)
                    Button("Save node") { store.send(.setPropagationNode(pnInput)) }
                        .disabled(usesDefaultPropagation || !isValidPeerAddress(pnInput))
                    if !store.propagationNodeHex.isEmpty {
                        Text("Current: \(store.propagationNodeHex)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    NavigationLink { DiagnosticsView(store: store) } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("Connection, paths, peers, links and delivery state — and a shareable "
                         + "snapshot for bug reports.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddress = true } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("My Address")
                }
            }
            .sheet(isPresented: $showingAddress) {
                AddressView(store: store)
            }
            .sheet(isPresented: $showingAddNode) {
                NodeFormView(store: store, existing: nil)
            }
            .sheet(item: $editingNode) { node in
                NodeFormView(store: store, existing: node)
            }
            // Seed the field from persisted state, so opening Settings with a name set does not
            // show a blank box whose Save button would clear it. (The propagation-node field above
            // deliberately starts blank — pasting a fresh hex address is its normal use — but a
            // name is edited, not replaced.)
            .onAppear { nameInput = store.displayName }
        }
    }
}
