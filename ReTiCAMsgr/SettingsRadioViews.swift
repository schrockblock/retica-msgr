//
//  SettingsRadioViews.swift
//  ReTiCAMsgr
//

import SwiftUI
import ComposableArchitecture
import ReTiCAMsgrCore

/// Settings › Radios: the supported radio types, one row each. MeshCore stays last, under
/// "Experimental" (`MeshCoreCopy.header`). The "Choose radio" sheet all three share is on
/// `SettingsView`'s stack.
struct RadiosSettingsView: View {
    let store: StoreOf<AppFeature>
    /// Passed on to the MeshCore screen, whose paste and share sheets talk to it directly.
    let meshCoreKeyStore: MeshCoreKeyStore

    /// Each radio type's own switch, for the Radios row's "1 on".
    static func enabledFlags(_ state: AppFeature.State) -> [Bool] {
        [state.meshtasticEnabled, state.rnodeEnabled, state.meshCoreEnabled]
    }

    var body: some View {
        Form {
            Section {
                NavigationLink { MeshtasticSettingsView(store: store) } label: {
                    RadioTypeRowLabel(title: "Meshtastic", light: store.state.radioLight(.meshtastic),
                                      value: SettingsSummary.radio(enabled: store.meshtasticEnabled,
                                                                   chosen: store.meshtasticRadioUUID != nil,
                                                                   label: store.meshtasticRadioLabel))
                }
                NavigationLink { RNodeSettingsView(store: store) } label: {
                    RadioTypeRowLabel(title: RNodeCopy.header, light: store.state.radioLight(.rnode),
                                      value: SettingsSummary.radio(enabled: store.rnodeEnabled,
                                                                   chosen: store.rnodeRadioUUID != nil,
                                                                   label: store.rnodeRadioLabel))
                }
            }
            Section(MeshCoreCopy.header) {
                NavigationLink { MeshCoreSettingsView(store: store, keyStore: meshCoreKeyStore) } label: {
                    RadioTypeRowLabel(title: "MeshCore", light: store.state.radioLight(.meshCore),
                                      value: SettingsSummary.radio(enabled: store.meshCoreEnabled,
                                                                   chosen: store.meshCoreRadioUUID != nil,
                                                                   label: store.meshCoreRadioLabel))
                }
            }
        }
        .settingsScreen("Radios")
    }
}

/// A radio type's row on the Radios screen: its status light, its name, and the radio it is set to.
private struct RadioTypeRowLabel: View {
    let title: String
    let light: RadioLight
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            RadioLightDot(light: light)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct RadioLightDot: View {
    let light: RadioLight

    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .accessibilityLabel(light.accessibilityText)
    }

    private var color: Color {
        switch light {
        case .off: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .problem: return .red
        }
    }
}

/// A radio screen's Radio row, with the radio's status light before its title (as the Network
/// row has one before its status).
private struct RadioStatusRow: View {
    let title: String
    let value: String
    let light: RadioLight

    var body: some View {
        LabeledContent {
            Text(value)
        } label: {
            HStack(spacing: 8) {
                RadioLightDot(light: light)
                Text(title)
            }
        }
    }
}

/// A radio screen's own Connect button: shown while the radio is set up and not online,
/// disabled with `connecting` while it dials, and `apply` while the running radio differs from
/// Settings. The label spans the row and is its hit shape, so a tap anywhere on the row connects.
private struct RadioConnectRow: View {
    let store: StoreOf<AppFeature>
    let kind: RadioKind
    let connect: String
    let connecting: String
    let apply: String

    var body: some View {
        let button = store.state.radioConnectButton(kind)
        if button != .hidden {
            Button { store.send(.radioConnectTapped(kind)) } label: {
                Text(label(button))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(button == .connecting)
        }
    }

    private func label(_ button: RadioConnectButton) -> String {
        switch button {
        case .hidden, .connect: return connect
        case .connecting: return connecting
        case .applyChanges: return apply
        }
    }
}

/// A radio screen's caption rows.
private struct RadioNote: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
    }
}

// MARK: - Meshtastic

/// Settings › Radios › Meshtastic.
struct MeshtasticSettingsView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        Form {
            Section {
                // Standard Toggle in a Form row: the whole row is already hittable.
                Toggle("Connect through a Meshtastic radio", isOn: $store.meshtasticEnabled)
                RadioStatusRow(title: "Radio", value: store.meshtasticRadioLabel,
                               light: store.state.radioLight(.meshtastic))
                // A standard Form button row is hittable across its width already.
                Button("Choose radio…") { store.send(.chooseRadioTapped) }
                RadioConnectRow(store: store, kind: .meshtastic, connect: MeshtasticCopy.connectButton,
                                connecting: MeshtasticCopy.connecting, apply: MeshtasticCopy.applyChanges)
                // Shows the clamped value; a change reaches a running radio through Apply changes.
                Stepper(value: Binding(get: { store.meshtasticHopLimitValue },
                                       set: { store.send(.binding(.set(\.meshtasticHopLimit, $0))) }),
                        in: MeshtasticHopLimit.range) {
                    Text(MeshtasticCopy.hopLimitRow(store.meshtasticHopLimitValue))
                }
                Text(MeshtasticCopy.hopLimitNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
        .settingsScreen("Meshtastic")
    }
}

// MARK: - RNode

/// Settings › Radios › RNode.
struct RNodeSettingsView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// The RNode frequency and bandwidth fields' text, seeded from the stored values when the
    /// screen appears. Typing sends the text to the reducer, which stores what it can read.
    @State private var rnodeFrequencyText = ""
    @State private var rnodeBandwidthText = ""
    @FocusState private var focusedField: Field?

    private enum Field { case rnodeFrequency, rnodeBandwidth }

    var body: some View {
        Form {
            Section {
                // Standard Toggle in a Form row: the whole row is already hittable. It stays enabled
                // while on (`rnodeToggleDisabled`), so stale defaults can still be turned off.
                Toggle(RNodeCopy.toggle, isOn: $store.rnodeEnabled)
                    .disabled(store.rnodeToggleDisabled)
                if store.rnodeIncompleteNoticeVisible {
                    RadioNote(RNodeCopy.incompleteNotice)
                }
                if let message = store.rnodeStatus.userMessage {
                    RadioNote(message, color: .red)
                }
                RadioStatusRow(title: RNodeCopy.radioRow, value: store.rnodeRadioLabel,
                               light: store.state.radioLight(.rnode))
                // A standard Form button row is hittable across its width already.
                Button(RNodeCopy.chooseRadio) { store.send(.chooseRNodeRadioTapped) }
                RadioConnectRow(store: store, kind: .rnode, connect: RNodeCopy.connectButton,
                                connecting: RNodeCopy.connecting, apply: RNodeCopy.applyChanges)
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
                    RadioNote(RNodeCopy.problemMessage(problem), color: .red)
                }
                RadioNote(RNodeCopy.boardsNotice)
                RadioNote(RNodeCopy.pairingNotice)
            } footer: {
                Text(RNodeCopy.footer)
            }
        }
        .settingsScreen(RNodeCopy.header)
        .keyboardDoneButton { focusedField = nil }
        .onAppear { rnodeReseedFields() }
    }

    /// Called once from this screen's own `onAppear` (not from a row, which would fire again
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
}

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

// MARK: - MeshCore

/// Settings › Radios › MeshCore.
struct MeshCoreSettingsView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// The paste and share sheets talk to the key store directly, so the key never passes through
    /// `AppFeature`.
    let keyStore: MeshCoreKeyStore
    /// The key the share sheet shows, nil when it is closed: dismissing drops it.
    @State private var meshCoreShareText: MeshCoreKeyText?
    @State private var showingMeshCorePaste = false
    /// A Generate or Paste over an existing key, waiting for "Replace".
    @State private var meshCorePendingReplace: MeshCoreKeyReplacement?

    private var meshCoreKeyIsPresent: Bool { store.meshCoreKeyPresence == .present }

    var body: some View {
        Form {
            Section {
                // Standard Toggle in a Form row: the whole row is already hittable. It stays enabled
                // while on, so restored defaults without a key can still be turned off.
                Toggle(MeshCoreCopy.toggle, isOn: $store.meshCoreEnabled)
                    .disabled(!store.meshCoreEnabled && !meshCoreKeyIsPresent)
                if !meshCoreKeyIsPresent {
                    RadioNote(MeshCoreCopy.noKeyNotice)
                }
                if let message = store.meshCoreStatus.userMessage {
                    RadioNote(message, color: .red)
                }
                RadioStatusRow(title: MeshCoreCopy.radioRow, value: store.meshCoreRadioLabel,
                               light: store.state.radioLight(.meshCore))
                // A standard Form button row is hittable across its width already.
                Button(MeshCoreCopy.chooseRadio) { store.send(.chooseMeshCoreRadioTapped) }
                RadioConnectRow(store: store, kind: .meshCore, connect: MeshCoreCopy.connectButton,
                                connecting: MeshCoreCopy.connecting, apply: MeshCoreCopy.applyChanges)
                if store.meshCoreRadioUUID != nil {
                    RadioNote(MeshCoreCopy.radioChangeNotice)
                }
                // Its confirmation and sheets are on the Form (`MeshCoreKeyPresentations`).
                LabeledContent(MeshCoreCopy.keyRow, value: MeshCoreCopy.keyValue(store.meshCoreKeyPresence))
                if let message = store.meshCoreKeyMessage {
                    RadioNote(message, color: .red)
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
                        meshCoreShareText = keyStore.exportText()
                    }
                }
                if store.meshCoreStatus.channelLeftOnRadio {
                    RadioNote(MeshCoreCopy.channelLeftNotice)
                }
                if store.meshCoreTurnOffNoticeVisible {
                    RadioNote(MeshCoreCopy.turnOffNotice)
                }
            } header: {
                Text(MeshCoreCopy.header)
            } footer: {
                Text(MeshCoreCopy.footer)
            }
        }
        .settingsScreen("MeshCore")
        // At Form level: a Form row only presents while it is drawn.
        .modifier(MeshCoreKeyPresentations(
            store: store,
            keyStore: keyStore,
            pendingReplace: $meshCorePendingReplace,
            showingPaste: $showingMeshCorePaste,
            shareText: $meshCoreShareText,
            onReplace: meshCoreKeyReplacementConfirmed))
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
