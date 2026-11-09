//
//  SettingsView.swift
//  ReTiCAMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import PhotosUI
import ComposableArchitecture
import ReTiCAMsgrCore
import ReTiCAPush

/// Ordered like a mainstream messenger: profile, privacy, notifications and contacts first, so
/// nobody needs to know how Reticulum works to set the app up. The network controls follow, under
/// their own "Network" heading.
struct SettingsView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// The MeshCore paste and share sheets talk to the key store directly, so the key never
    /// passes through `AppFeature`.
    let meshCoreKeyStore: MeshCoreKeyStore
    @State private var pnInput: String = ""
    @State private var nameInput: String = ""
    @State private var showingAddress = false
    @State private var showingAddNode = false
    @State private var editingNode: NodeEntry? = nil
    @State private var showingPhotoOptions = false
    @State private var showingPhotoLibrary = false
    @State private var showingCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var cropTarget: CropTarget?
    #if DEBUG
    /// The key the share sheet shows, nil when it is closed: dismissing drops it.
    @State private var meshCoreShareText: MeshCoreKeyText?
    @State private var showingMeshCorePaste = false
    /// A Generate or Paste over an existing key, waiting for "Replace".
    @State private var meshCorePendingReplace: MeshCoreKeyReplacement?
    /// The RNode frequency and bandwidth fields' text, seeded from the stored values when the
    /// section appears. Typing sends the text to the reducer, which stores what it can read.
    @State private var rnodeFrequencyText = ""
    @State private var rnodeBandwidthText = ""
    #endif
    @Environment(\.openURL) private var openURL
    @FocusState private var focusedField: Field?

    private enum Field { case name, listenPort, propagationNode, rnodeFrequency, rnodeBandwidth }

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
                profileSection
                privacySection
                notificationsSection
                #if os(macOS)
                LaunchAtLoginSection()
                #endif
                contactsSection
                networkSections
            }
            .scrollingFormStyle()
            .navigationTitle("Settings")
            // The listen-port number pad has no return key, so every field gets a Done above the
            // keyboard, and scrolling the form drops it too.
            .scrollDismissesKeyboard(.interactively)
            // Leaving the name field by any route (Done, a scroll) saves it, as return does.
            .onChange(of: focusedField) { old, _ in
                if old == .name { saveName() }
            }
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            #endif
            .sheet(isPresented: $showingAddress) {
                AddressView(store: store)
            }
            .sheet(isPresented: $showingAddNode) {
                NodeFormView(store: store, existing: nil)
            }
            .sheet(item: $editingNode) { node in
                NodeFormView(store: store, existing: node)
            }
            // Driven by state: a swipe sends `.radioPicker(.dismiss)`, like Cancel and a pick.
            .sheet(item: $store.scope(state: \.radioPicker, action: \.radioPicker)) { pickerStore in
                RadioPickerView(store: pickerStore)
                    .macSheetFrame()
            }
            #if DEBUG
            // At Form level, like the sheets above: a Form row only presents while it is drawn.
            .modifier(MeshCoreKeyPresentations(
                store: store,
                keyStore: meshCoreKeyStore,
                pendingReplace: $meshCorePendingReplace,
                showingPaste: $showingMeshCorePaste,
                shareText: $meshCoreShareText,
                onReplace: meshCoreKeyReplacementConfirmed))
            #endif
            // Seed the field from persisted state, so opening Settings with a name set does not
            // show a blank box whose Save button would clear it. (The propagation-node field below
            // deliberately starts blank — pasting a fresh hex address is its normal use — but a
            // name is edited, not replaced.)
            .onAppear {
                nameInput = store.displayName
                // The Contacts section shows access state and import candidates: refresh both.
                store.send(.contactLinkSheetAppeared)
                #if DEBUG
                rnodeReseedFields()
                #endif
            }
        }
    }

    /// The grouped-row background, so the camera badge's ring blends into the row.
    private var badgeRingColor: Color {
        #if os(iOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    // MARK: - Messaging

    private var profileSection: some View {
        Section {
            HStack(spacing: 14) {
                Button { showingPhotoOptions = true } label: {
                    MyAvatarView(store: store, name: nameInput)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.accentColor))
                                .overlay(Circle().stroke(badgeRingColor, lineWidth: 2))
                                .offset(x: 2, y: 2)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(store.myPhotoVersion.isEmpty ? "Add profile photo" : "Change profile photo")
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Your name", text: $nameInput)
                        .font(.title3.weight(.semibold))
                        .autocorrectionDisabled()
                        .platformAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($focusedField, equals: .name)
                        // Saved on commit rather than per keystroke: each save re-announces on every
                        // interface, and `Transport` paces only RELAYED announces — locally originated
                        // ones go out immediately and ungated.
                        .onSubmit { saveName() }
                    Text(store.displayName.isEmpty
                         ? "Add a name so people know it's you."
                         : "Shown to others as “\(store.displayName)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .confirmationDialog("Profile Photo", isPresented: $showingPhotoOptions, titleVisibility: .hidden) {
                Button("Choose Photo") { showingPhotoLibrary = true }
                #if os(iOS)
                if CameraPicker.isAvailable {
                    Button("Take Photo") { showingCamera = true }
                }
                #endif
                if !store.myPhotoVersion.isEmpty {
                    Button("Remove Photo", role: .destructive) { store.send(.removeProfilePhotoTapped) }
                }
            }
            .photosPicker(isPresented: $showingPhotoLibrary, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = PlatformImage(data: data) {
                        cropTarget = CropTarget(image: image)
                    } else {
                        store.send(.profilePhotoPicked(Data()))
                    }
                }
            }
            .fullScreenCoverOrSheet(item: $cropTarget) { target in
                AvatarCropView(image: target.image,
                               onChoose: { jpeg in
                                   cropTarget = nil
                                   store.send(.profilePhotoPicked(jpeg))
                               },
                               onCancel: { cropTarget = nil })
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker(onPicked: { jpeg in
                                 showingCamera = false
                                 store.send(.profilePhotoPicked(jpeg))
                             },
                             onCancel: { showingCamera = false })
                    .ignoresSafeArea()
            }
            #endif
            if let error = store.profilePhotoError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if nameInput != store.displayName {
                Button("Save name") { saveName() }
            }
            Button { showingAddress = true } label: {
                Label("My QR Code & Address", systemImage: "qrcode")
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("Your name and photo are visible to people you message.")
        }
    }

    private func saveName() {
        guard nameInput != store.displayName else { return }
        store.send(.setDisplayName(nameInput))
    }

    private var privacySection: some View {
        Section("Privacy") {
            NavigationLink { BlockedAddressesView(store: store) } label: {
                HStack {
                    Label("Blocked", systemImage: "hand.raised")
                    Spacer()
                    if !store.blockedPeerRows.isEmpty {
                        Text("\(store.blockedPeerRows.count)").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("Notify me when the app is closed", isOn: Binding(
                get: { store.push.enabled },
                set: { store.send(.push(.setEnabled($0))) }
            ))
            .disabled(store.pushNode == nil && !store.push.enabled)
            // While off, the status would only repeat the toggle.
            if store.pushNode != nil, store.push.enabled {
                Text(store.pushStatusText)
                    .font(.caption)
                    .foregroundStyle(pushStatusIsFailure ? .red : .secondary)
            }
        } header: {
            Text("Notifications")
        } footer: {
            if store.pushNode == nil {
                Text("Unavailable: none of your nodes offers notifications. See Network below.")
            } else {
                Text("Notifications only ever say \"New message\"; nothing about the sender or the "
                     + "content leaves the device unencrypted.")
            }
        }
    }

    private var contactsSection: some View {
        Section("Contacts") {
            Toggle("Save addresses to Contacts", isOn: Binding(
                get: { store.contactMirrorEnabled },
                set: { store.send(.setContactMirror($0)) }
            ))
            Text("Adds your chats' addresses to their contact cards, so your other devices and apps "
                 + "can find them. Needs full Contacts access.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.contactMirrorEnabled, store.contactsAuthorization == .denied {
                Text("Contacts access is off, so nothing is written to cards. Allow it in Settings.")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Open Settings") {
                    if let url = SystemSettings.url { openURL(url) }
                }
            } else if store.contactMirrorEnabled, store.contactsAuthorization == .limited {
                Text("Only the contacts you selected are available, and their cards cannot be "
                     + "updated with limited access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !store.contactMirrorEnabled, !store.contactLinks.isEmpty {
                Text("Addresses already saved to Contacts stay there, and are offered for import "
                     + "again when you turn this back on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !store.importCandidates.isEmpty {
                Button("Import \(store.importCandidates.count) addresses found in Contacts") {
                    store.send(.importContactLinks)
                }
            }
        }
    }

    // MARK: - Network

    @ViewBuilder
    private var networkSections: some View {
        Section {
            HStack(spacing: 8) {
                Circle().fill(connectionColor).frame(width: 10, height: 10)
                Text(connectionLabel)
                Spacer()
                Button("Connect") { store.send(.connectTapped) }
                    .buttonStyle(.bordered)
                Button("Disconnect") { store.send(.disconnectTapped) }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        } header: {
            Text("Network")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
                .padding(.top, 16)
        } footer: {
            Text("How this app reaches the Reticulum network. The defaults work for most people. "
                 + "Bluetooth, Meshtastic and direct-connection changes take effect on the next "
                 + "Connect.")
        }

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
        } header: {
            Text("Nodes")
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

        Section("Bluetooth") {
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

        Section {
            // Standard Toggle in a Form row: the whole row is already hittable.
            Toggle("Connect through a Meshtastic radio", isOn: $store.meshtasticEnabled)
            LabeledContent("Radio", value: store.meshtasticRadioLabel)
            // A standard Form button row is hittable across its width already.
            Button("Choose radio…") { store.send(.chooseRadioTapped) }
        } header: {
            Text("Meshtastic")
        } footer: {
            Text("Sends and receives messages over LoRa through a Meshtastic radio paired with "
                 + "this device over Bluetooth. Set the radio to a Short preset (ShortTurbo or "
                 + "ShortFast): longer presets are too slow for most messages. The radio must not "
                 + "be connected to another app, such as the Meshtastic app, at the same time. "
                 + "Text messages waiting on the radio may be removed when this app connects, and "
                 + "may not reach the Meshtastic app. "
                 + "Choosing a radio pauses Bluetooth connections to nearby devices until the list "
                 + "closes. Off by default.")
        }

        #if DEBUG
        meshCoreSection
        rnodeSection
        #endif

        Section("Direct Connections") {
            // Standard Toggle in a Form row: the whole row is already hittable, so no
            // explicit contentShape is needed here.
            Toggle("Listen for direct connections", isOn: $store.listenEnabled)
            TextField("Listen port", value: $store.listenPort, format: .number)
                .platformKeyboard(.numberPad)
                .focused($focusedField, equals: .listenPort)
                .disabled(!store.listenEnabled)
            Text("Lets other Reticulum nodes on your local Wi-Fi connect directly to this "
                 + "device — anyone on the same network can reach it. On by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .focused($focusedField, equals: .propagationNode)
                .disabled(usesDefaultPropagation)
            Button("Save node") { store.send(.setPropagationNode(pnInput)) }
                .disabled(usesDefaultPropagation || !isValidPeerAddress(pnInput))
            if !store.propagationNodeHex.isEmpty {
                Text("Current: \(store.propagationNodeHex)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Propagation Node")
        } footer: {
            Text("Holds messages sent to you while you're offline, so you can collect them later.")
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

        Section {
            NavigationLink { DiagnosticsView(store: store) } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
        } footer: {
            Text("Connection, paths, peers, links and delivery state — and a shareable "
                 + "snapshot for bug reports.")
        }
    }

    // MARK: - MeshCore (Debug-only until lane E)

    #if DEBUG
    private var meshCoreKeyIsPresent: Bool { store.meshCoreKeyPresence == .present }

    private var meshCoreSection: some View {
        Section {
            // Standard Toggle in a Form row: the whole row is already hittable. It stays enabled
            // while on, so restored defaults without a key can still be turned off.
            Toggle(MeshCoreCopy.toggle, isOn: $store.meshCoreEnabled)
                .disabled(!store.meshCoreEnabled && !meshCoreKeyIsPresent)
            if !meshCoreKeyIsPresent {
                meshCoreNote(MeshCoreCopy.noKeyNotice)
            }
            if let message = store.meshCoreStatus.userMessage {
                meshCoreNote(message, color: .red)
            }
            LabeledContent(MeshCoreCopy.radioRow, value: store.meshCoreRadioLabel)
            // A standard Form button row is hittable across its width already.
            Button(MeshCoreCopy.chooseRadio) { store.send(.chooseMeshCoreRadioTapped) }
            if store.meshCoreRadioUUID != nil {
                meshCoreNote(MeshCoreCopy.radioChangeNotice)
            }
            // Its confirmation and sheets are on the Form (`MeshCoreKeyPresentations`).
            LabeledContent(MeshCoreCopy.keyRow, value: MeshCoreCopy.keyValue(store.meshCoreKeyPresence))
            if let message = store.meshCoreKeyMessage {
                meshCoreNote(message, color: .red)
            }
            // Disabled while a Generate runs: each one is a real key change and a reconnect.
            Button(MeshCoreCopy.generateKey) { meshCoreKeyChangeTapped(.generate) }
                .disabled(store.meshCoreKeyGenerating)
            Button(MeshCoreCopy.pasteKey) { meshCoreKeyChangeTapped(.paste) }
                .disabled(store.meshCoreKeyGenerating)
            if meshCoreKeyIsPresent {
                Button(MeshCoreCopy.copyKey) { store.send(.meshCoreCopyKeyTapped) }
                Button(MeshCoreCopy.shareKey) {
                    // nil (the key went away or can't be read) presents nothing.
                    meshCoreShareText = meshCoreKeyStore.exportText()
                }
            }
            if store.meshCoreStatus.channelLeftOnRadio {
                meshCoreNote(MeshCoreCopy.channelLeftNotice)
            }
            if store.meshCoreTurnOffNoticeVisible {
                meshCoreNote(MeshCoreCopy.turnOffNotice)
            }
        } header: {
            Text(MeshCoreCopy.header)
        } footer: {
            Text(MeshCoreCopy.footer)
        }
    }

    private func meshCoreNote(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
    }

    // MARK: - RNode (Debug-only until lane E)

    private var rnodeSection: some View {
        Section {
            // Standard Toggle in a Form row: the whole row is already hittable. It stays enabled
            // while on (`rnodeToggleDisabled`), so stale defaults can still be turned off.
            Toggle(RNodeCopy.toggle, isOn: $store.rnodeEnabled)
                .disabled(store.rnodeToggleDisabled)
            if store.rnodeIncompleteNoticeVisible {
                rnodeNote(RNodeCopy.incompleteNotice)
            }
            if let message = store.rnodeStatus.userMessage {
                rnodeNote(message, color: .red)
            }
            LabeledContent(RNodeCopy.radioRow, value: store.rnodeRadioLabel)
            // A standard Form button row is hittable across its width already.
            Button(RNodeCopy.chooseRadio) { store.send(.chooseRNodeRadioTapped) }
            rnodeNumberRow(RNodeCopy.frequencyRow, prompt: RNodeCopy.frequencyPrompt,
                           text: $rnodeFrequencyText, field: .rnodeFrequency)
                .onChange(of: rnodeFrequencyText) { _, text in
                    store.send(.rnodeFrequencyTextChanged(text))
                }
            rnodeNumberRow(RNodeCopy.bandwidthRow, prompt: "", text: $rnodeBandwidthText,
                           field: .rnodeBandwidth)
                .onChange(of: rnodeBandwidthText) { _, text in
                    store.send(.rnodeBandwidthTextChanged(text))
                }
            Stepper(value: Binding(get: { store.rnodeSpreadingFactor },
                                   set: { store.send(.rnodeSpreadingFactorChanged($0)) }),
                    in: RNodeRadioSettings.spreadingFactorRange) {
                Text("\(RNodeCopy.spreadingFactorRow): \(store.rnodeSpreadingFactor)")
            }
            Stepper(value: Binding(get: { store.rnodeCodingRate },
                                   set: { store.send(.rnodeCodingRateChanged($0)) }),
                    in: RNodeRadioSettings.codingRateRange) {
                Text("\(RNodeCopy.codingRateRow): \(store.rnodeCodingRate)")
            }
            Stepper(value: Binding(get: { store.rnodeTXPowerDBm },
                                   set: { store.send(.rnodeTXPowerChanged($0)) }),
                    in: RNodeRadioSettings.txPowerRange) {
                Text("\(RNodeCopy.txPowerRow): \(store.rnodeTXPowerDBm)")
            }
            ForEach(store.rnodeShownProblems, id: \.self) { problem in
                rnodeNote(RNodeCopy.problemMessage(problem), color: .red)
            }
            rnodeNote(RNodeCopy.boardsNotice)
            rnodeNote(RNodeCopy.pairingNotice)
        } header: {
            Text(RNodeCopy.header)
        } footer: {
            Text(RNodeCopy.footer)
        }
    }

    /// Called once from the Settings screen's own `onAppear` (not from a row, which would fire again
    /// whenever the row scrolls back into view and overwrite what is being typed). Re-seeds the fields
    /// from the stored values and sends both texts, which clears a text problem left over from an
    /// earlier visit (the field no longer shows that text).
    private func rnodeReseedFields() {
        rnodeFrequencyText = store.rnodeFrequencyHz.map(RNodeRadioSettings.megahertzText) ?? ""
        rnodeBandwidthText = RNodeRadioSettings.kilohertzText(store.rnodeBandwidthHz)
        store.send(.rnodeFrequencyTextChanged(rnodeFrequencyText))
        store.send(.rnodeBandwidthTextChanged(rnodeBandwidthText))
    }

    /// A labelled number field. A bare `TextField` in a Form hides its title once it has text (and
    /// next to a prompt), so the label is its own `Text`; the row is a custom tappable row and
    /// focuses the field from anywhere across its width.
    private func rnodeNumberRow(_ label: String, prompt: String, text: Binding<String>,
                                field: Field) -> some View {
        HStack {
            Text(label)
            TextField(label, text: text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .rnodeNumberField()
                .focused($focusedField, equals: field)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = field }
    }

    private func rnodeNote(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
    }

    /// Over an existing key, Generate and Paste ask first; otherwise they go straight ahead.
    private func meshCoreKeyChangeTapped(_ replacement: MeshCoreKeyReplacement) {
        if meshCoreKeyIsPresent {
            meshCorePendingReplace = replacement
        } else {
            meshCoreKeyReplacementConfirmed(replacement)
        }
    }

    private func meshCoreKeyReplacementConfirmed(_ replacement: MeshCoreKeyReplacement) {
        switch replacement {
        case .generate: store.send(.meshCoreGenerateKeyTapped)
        case .paste:
            store.send(.meshCorePasteKeyOpened)
            showingMeshCorePaste = true
        }
    }
    #endif
}

#if DEBUG
private extension View {
    /// The RNode frequency and bandwidth fields: a keyboard with a "." (`.numbersAndPunctuation`, not
    /// `.decimalPad`, which types "," in comma-decimal locales and would strand "868,1" users), and no
    /// autocorrection or capitalization.
    func rnodeNumberField() -> some View {
        #if os(iOS)
        self.keyboardType(.numbersAndPunctuation)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

/// Which key change the "Replace the channel key?" confirmation is for.
private enum MeshCoreKeyReplacement {
    case generate, paste
}

/// The MeshCore key section's "Replace the channel key?" confirmation and its paste and share
/// sheets. Applied to the Form, never to a row: a lazily drawn row that is off screen presents
/// nothing, and would present late (holding the key in `shareText`) once scrolled back.
private struct MeshCoreKeyPresentations: ViewModifier {
    let store: StoreOf<AppFeature>
    let keyStore: MeshCoreKeyStore
    @Binding var pendingReplace: MeshCoreKeyReplacement?
    @Binding var showingPaste: Bool
    @Binding var shareText: MeshCoreKeyText?
    let onReplace: (MeshCoreKeyReplacement) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(MeshCoreCopy.replaceTitle,
                                isPresented: Binding(get: { pendingReplace != nil },
                                                     set: { if !$0 { pendingReplace = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingReplace) { replacement in
                Button(MeshCoreCopy.replaceButton, role: .destructive) {
                    pendingReplace = nil
                    onReplace(replacement)
                }
                Button(MeshCoreCopy.cancelButton, role: .cancel) { pendingReplace = nil }
            } message: { _ in
                Text(MeshCoreCopy.replaceMessage)
            }
            // The paste sheet clears its own field on Save, Cancel and disappear (R7).
            .sheet(isPresented: $showingPaste) {
                MeshCorePasteKeySheet(store: store, keyStore: keyStore)
            }
            // `item:` already sets it to nil on dismissal; onDismiss makes the drop explicit.
            .sheet(item: $shareText, onDismiss: { shareText = nil }) { key in
                MeshCoreShareKeySheet(key: key)
            }
    }
}
#endif

/// A picked library photo waiting in the crop screen.
private struct CropTarget: Identifiable {
    let id = UUID()
    let image: PlatformImage
}
