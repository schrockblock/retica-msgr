//
//  SettingsNetworkViews.swift
//  ReTiCAMsgr
//

import SwiftUI
import ComposableArchitecture
import ReTiCAMsgrCore

/// Settings › Transports: the ways this app reaches the network without a radio, one row each.
struct TransportsSettingsView: View {
    let store: StoreOf<AppFeature>

    /// Nodes, Direct Connections and Bluetooth, each on or off, for the rows' "2 on".
    static func enabledFlags(_ state: AppFeature.State) -> [Bool] {
        [!state.enabledNodes.isEmpty, directConnectionsOn(state), state.bleEnabled]
    }

    /// Either of the Direct Connections screen's switches is on.
    static func directConnectionsOn(_ state: AppFeature.State) -> Bool {
        state.listenEnabled || (state.autoInterfaceAvailable && state.autoInterfaceEnabled)
    }

    var body: some View {
        Form {
            Section {
                NavigationLink { NodesSettingsView(store: store) } label: {
                    SettingsRowLabel("Nodes", systemImage: "network",
                                     value: SettingsSummary.nodes(enabled: store.enabledNodes.count,
                                                                  total: store.nodes.count))
                }
                NavigationLink { DirectConnectionsSettingsView(store: store) } label: {
                    SettingsRowLabel("Direct Connections", systemImage: "wifi",
                                     value: SettingsSummary.onOff(Self.directConnectionsOn(store.state)))
                }
                NavigationLink { BluetoothSettingsView(store: store) } label: {
                    SettingsRowLabel("Bluetooth", systemImage: "dot.radiowaves.left.and.right",
                                     value: SettingsSummary.onOff(store.bleEnabled))
                }
            }
        }
        .settingsScreen("Transports")
    }
}

/// Settings › Transports › Nodes. The add and edit sheets are on this screen's Form: a Form row
/// only presents while it is drawn.
struct NodesSettingsView: View {
    let store: StoreOf<AppFeature>
    @State private var showingAddNode = false
    @State private var editingNode: NodeEntry? = nil

    var body: some View {
        Form {
            Section {
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
            } footer: {
                if store.enabledNodes.isEmpty {
                    Text("No node is enabled. The app reaches peers only over Bluetooth or direct "
                         + "connections.")
                } else {
                    Text("Connect and Disconnect act on every enabled node. Tap a node to edit it, "
                         + "swipe to delete. The node marked Push delivers notifications; changing it "
                         + "re-registers with the new hub as soon as it is reachable.")
                }
            }
        }
        .settingsScreen("Nodes")
        .sheet(isPresented: $showingAddNode) {
            NodeFormView(store: store, existing: nil)
        }
        .sheet(item: $editingNode) { node in
            NodeFormView(store: store, existing: node)
        }
    }
}

/// Settings › Transports › Direct Connections.
struct DirectConnectionsSettingsView: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.openURL) private var openURL
    @FocusState private var listenPortFocused: Bool

    var body: some View {
        Form {
            Section {
                // Standard Toggle in a Form row: the whole row is already hittable, so no
                // explicit contentShape is needed here.
                Toggle("Listen for direct connections", isOn: $store.listenEnabled)
                TextField("Listen port", value: $store.listenPort, format: .number)
                    .platformKeyboard(.numberPad)
                    .focused($listenPortFocused)
                    .disabled(!store.listenEnabled)
                Text("Lets other Reticulum nodes on your local Wi-Fi connect directly to this "
                     + "device — anyone on the same network can reach it. On by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // AutoInterface (spec 2026-11-10 §5.8). Hidden where it can't run: an iOS build
                // without the multicast entitlement (`AutoInterfaceAvailability.isEntitledOniOS`).
                if store.autoInterfaceAvailable {
                    autoInterfaceRows
                }
            }
        }
        .settingsScreen("Direct Connections")
        // The listen-port number pad has no return key.
        .keyboardDoneButton { listenPortFocused = false }
    }

    /// The AutoInterface toggle and what the interface last reported. The status lines replace the
    /// caption the way Bluetooth's alerts do, worst first.
    @ViewBuilder
    private var autoInterfaceRows: some View {
        Toggle(AutoInterfaceText.toggleTitle, isOn: $store.autoInterfaceEnabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        if store.autoInterfaceEnabled, store.state.autoInterfaceLocalNetworkDenied {
            Text(AutoInterfaceText.localNetworkDenied)
                .font(.caption)
                .foregroundStyle(.red)
            Button("Open Settings") {
                if let url = SystemSettings.localNetworkURL { openURL(url) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        } else if store.autoInterfaceEnabled, !store.autoInterfaceDataPortInUse.isEmpty {
            Text(AutoInterfaceText.dataPortInUse)
                .font(.caption)
                .foregroundStyle(.red)
        } else if store.autoInterfaceEnabled, store.autoInterfaceNoUsableInterfaces {
            Text(AutoInterfaceText.noUsableInterfaces)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if store.autoInterfaceEnabled, store.state.autoInterfaceNoPeersHint(at: Date()) {
            Text(AutoInterfaceText.noPeersYet)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(store.autoInterfaceEnabled && store.autoInterfacePeerCount > 0
                 ? AutoInterfaceText.caption + " Connected to \(store.autoInterfacePeerCount) "
                    + (store.autoInterfacePeerCount == 1 ? "device." : "devices.")
                 : AutoInterfaceText.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings › Transports › Bluetooth.
struct BluetoothSettingsView: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                // Standard Toggle in a Form row: the whole row is already hittable.
                Toggle("Connect over Bluetooth", isOn: $store.bleEnabled)
                if store.bluetoothAlert == .permissionDenied {
                    Text("Bluetooth permission is denied. Allow it in Settings to connect to "
                         + "nearby devices.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Open Settings") {
                        if let url = SystemSettings.url {
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
                         + "or shared server needed. Off by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsScreen("Bluetooth")
    }
}

/// Settings › Relay.
struct RelaySettingsView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        Form {
            Section {
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
        }
        .settingsScreen("Relay")
    }
}

/// Settings › Propagation Node.
struct PropagationNodeSettingsView: View {
    let store: StoreOf<AppFeature>
    /// Starts blank each visit: pasting a fresh hex address is the field's normal use.
    @State private var pnInput: String = ""
    @FocusState private var fieldFocused: Bool

    /// The default's propagation node is in effect: a default exists and the toggle is on.
    private var usesDefaultPropagation: Bool {
        DefaultNode.propagationHex != nil && store.usePropagationDefault
    }

    var body: some View {
        Form {
            Section {
                if DefaultNode.propagationHex != nil {
                    Toggle("Use the default node's propagation node", isOn: Binding(
                        get: { store.usePropagationDefault },
                        set: { store.send(.setUsePropagationDefault($0)) }
                    ))
                }
                TextField("Node LXMF address (hex)", text: $pnInput)
                    .autocorrectionDisabled()
                    .platformAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    .submitLabel(.done)
                    .focused($fieldFocused)
                    .disabled(usesDefaultPropagation)
                Button("Save node") { store.send(.setPropagationNode(pnInput)) }
                    .disabled(usesDefaultPropagation || !isValidPeerAddress(pnInput))
                if !store.propagationNodeHex.isEmpty {
                    Text("Current: \(store.propagationNodeHex)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Holds messages sent to you while you're offline, so you can collect them later.")
                    if let sync = PropagationSyncText.describe(store.propagationSyncState,
                                                               lastResult: store.propagationSyncLastResult) {
                        Text(sync)
                    }
                }
            }
        }
        .settingsScreen("Propagation Node")
        .keyboardDoneButton { fieldFocused = false }
    }
}

/// Settings › Run as Propagation Node.
struct RunAsPropagationNodeSettingsView: View {
    let store: StoreOf<AppFeature>
    @State private var staticPeerInput: String = ""
    @FocusState private var fieldFocused: Bool

    /// The static-peer field's text as the reducer will read it (trimmed, lowercased).
    private var staticPeerCandidate: String {
        staticPeerInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    /// A valid address that is not already listed: the only input that clears the field.
    private var staticPeerInputIsAddable: Bool {
        isValidPeerAddress(staticPeerCandidate) && !store.staticPeerHexes.contains(staticPeerCandidate)
    }
    private func addStaticPeer() {
        guard staticPeerInputIsAddable else { return }
        store.send(.addStaticPeer(staticPeerInput))
        staticPeerInput = ""
    }

    var body: some View {
        Form {
            Section {
                Toggle("Act as a propagation node", isOn: Binding(
                    get: { store.nodeModeEnabled },
                    set: { store.send(.setNodeMode($0)) }
                ))
                Text("Stores and forwards messages for other users while this app is open, and exchanges them with nearby propagation nodes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.nodeModeEnabled {
                    Toggle("Peer with other propagation nodes", isOn: Binding(
                        get: { store.autopeerEnabled },
                        set: { store.send(.setAutopeer($0)) }
                    ))
                    ForEach(store.staticPeerHexes, id: \.self) { hex in
                        Text(hex)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    store.send(.removeStaticPeer(hex))
                                }
                            }
                    }
                    TextField("Static peer address (hex)", text: $staticPeerInput)
                        .autocorrectionDisabled()
                        .platformAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit(addStaticPeer)
                    Button("Add static peer", action: addStaticPeer)
                        .disabled(!staticPeerInputIsAddable)
                    Text("Peered with \(store.pnPeerCount) \(store.pnPeerCount == 1 ? "node" : "nodes")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsScreen("Run as Propagation Node")
        .keyboardDoneButton { fieldFocused = false }
    }
}
