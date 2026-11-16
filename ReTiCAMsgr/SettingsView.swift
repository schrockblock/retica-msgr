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
///
/// Only the profile and the connection row are on this screen. Every other section is a row that
/// pushes its own screen (`SettingsGeneralViews`, `SettingsNetworkViews`, `SettingsRadioViews`),
/// and each of those screens owns its fields' state and the sheets its rows present.
struct SettingsView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// The MeshCore paste and share sheets talk to the key store directly, so the key never
    /// passes through `AppFeature`.
    let meshCoreKeyStore: MeshCoreKeyStore
    @State private var nameInput: String = ""
    @State private var showingAddress = false
    @State private var showingPhotoOptions = false
    @State private var showingPhotoLibrary = false
    @State private var showingCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var cropTarget: CropTarget?
    @FocusState private var focusedField: Field?

    private enum Field { case name }

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
                messagingSection
                networkSection
            }
            .scrollingFormStyle()
            .navigationTitle("Settings")
            // Every field gets a Done above the keyboard, and scrolling the form drops it too.
            .scrollDismissesKeyboard(.interactively)
            // Leaving the name field by any route (Done, a scroll) saves it, as return does.
            .onChange(of: focusedField) { old, _ in
                if old == .name { saveName() }
            }
            .toolbar {
                // Connection, paths, peers, links and delivery state, and a snapshot for bug reports.
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { DiagnosticsView(store: store) } label: {
                        Image(systemName: "stethoscope")
                    }
                    .accessibilityLabel("Diagnostics")
                }
            }
            .keyboardDoneButton { focusedField = nil }
            .sheet(isPresented: $showingAddress) {
                AddressView(store: store)
            }
            // Seed the field from persisted state, so opening Settings with a name set does not
            // show a blank box whose Save button would clear it. (The propagation-node field
            // deliberately starts blank — pasting a fresh hex address is its normal use — but a
            // name is edited, not replaced.)
            .onAppear {
                nameInput = store.displayName
            }
        }
        // On the stack, not on a screen in it: the three radio screens share this one picker, and
        // a screen that is covered by a pushed one presents nothing.
        // Driven by state: a swipe sends `.radioPicker(.dismiss)`, like Cancel and a pick.
        .sheet(item: $store.scope(state: \.radioPicker, action: \.radioPicker)) { pickerStore in
            RadioPickerView(store: pickerStore)
                .macSheetFrame()
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

    /// Privacy, Notifications, the Mac's own section and Contacts, one row each. Privacy only ever
    /// held the Blocked link, so that link is its row.
    private var messagingSection: some View {
        Section {
            NavigationLink { BlockedAddressesView(store: store) } label: {
                HStack {
                    Label("Blocked", systemImage: "hand.raised")
                    Spacer()
                    if !store.blockedPeerRows.isEmpty {
                        Text("\(store.blockedPeerRows.count)").foregroundStyle(.secondary)
                    }
                }
            }
            NavigationLink { NotificationsSettingsView(store: store) } label: {
                SettingsRowLabel("Notifications", systemImage: "bell",
                                 value: SettingsSummary.onOff(store.push.enabled))
            }
            #if os(macOS)
            NavigationLink { MacSettingsView() } label: {
                SettingsRowLabel("Mac", systemImage: "desktopcomputer")
            }
            #endif
            NavigationLink { ContactsSettingsView(store: store) } label: {
                SettingsRowLabel("Contacts", systemImage: "person.crop.circle",
                                 value: SettingsSummary.onOff(store.contactMirrorEnabled))
            }
        }
    }

    // MARK: - Network

    /// The connection row, then one row per network section. The radios stay last, as the footer
    /// says.
    private var networkSection: some View {
        Section {
            HStack(spacing: 8) {
                Circle().fill(connectionColor).frame(width: 10, height: 10)
                Text(connectionLabel)
                Spacer()
                // Stacked, each as wide as the wider label (`fixedSize` sizes the stack to it and
                // `maxWidth: .infinity` stretches both to fill), so neither label wraps mid-word.
                VStack(spacing: 8) {
                    Button { store.send(.connectTapped) } label: {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { store.send(.disconnectTapped) } label: {
                        Text("Disconnect").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            NavigationLink { TransportsSettingsView(store: store) } label: {
                SettingsRowLabel("Transports", systemImage: "point.3.connected.trianglepath.dotted",
                                 value: SettingsSummary.countOn(TransportsSettingsView.enabledFlags(store.state)))
            }
            NavigationLink { RelaySettingsView(store: store) } label: {
                SettingsRowLabel("Relay", systemImage: "arrow.triangle.branch",
                                 value: SettingsSummary.onOff(store.relayEnabled))
            }
            NavigationLink { PropagationNodeSettingsView(store: store) } label: {
                SettingsRowLabel("Propagation Node", systemImage: "tray.and.arrow.down",
                                 value: SettingsSummary.propagationNode(usesDefault: usesDefaultPropagation,
                                                                        hex: store.propagationNodeHex))
            }
            NavigationLink { RunAsPropagationNodeSettingsView(store: store) } label: {
                SettingsRowLabel("Run as Propagation Node", systemImage: "server.rack",
                                 value: SettingsSummary.onOff(store.nodeModeEnabled))
            }
            NavigationLink { RadiosSettingsView(store: store, meshCoreKeyStore: meshCoreKeyStore) } label: {
                SettingsRowLabel("Radios", systemImage: "antenna.radiowaves.left.and.right",
                                 value: SettingsSummary.countOn(RadiosSettingsView.enabledFlags(store.state)))
            }
        } header: {
            Text("Network")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
                .padding(.top, 16)
        } footer: {
            Text("How this app reaches the Reticulum network. The defaults work for most people. "
                 + "Bluetooth and direct-connection changes take effect on the next Connect. Radios "
                 + "are at the bottom, each with its own Connect button.")
        }
    }
}

/// A drill-down row's label: an icon and a title, then what the screen behind it is set to.
struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    let value: String?

    init(_ title: String, systemImage: String, value: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
    }

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The trailing text on a drill-down row.
enum SettingsSummary {
    static func onOff(_ on: Bool) -> String { on ? "On" : "Off" }

    /// How many of a screen's switches are on: "2 on", or "Off" when none is.
    static func countOn(_ flags: [Bool]) -> String {
        let count = flags.filter { $0 }.count
        return count == 0 ? "Off" : "\(count) on"
    }

    static func nodes(enabled: Int, total: Int) -> String { "\(enabled) of \(total) on" }

    static func propagationNode(usesDefault: Bool, hex: String) -> String {
        if usesDefault { return "Default" }
        return hex.isEmpty ? "None" : shortHex(hex)
    }

    /// A radio type's row: "Off", or while it is switched on the chosen radio's name ("On" until
    /// one is chosen, where the radio's own label would read "None").
    static func radio(enabled: Bool, chosen: Bool, label: String) -> String {
        guard enabled else { return "Off" }
        return chosen ? label : "On"
    }
}

extension View {
    /// What every Settings drill-down shares: the grouped form the main screen uses, the section's
    /// name as an inline title, and a scroll that drops the keyboard.
    func settingsScreen(_ title: String) -> some View {
        scrollingFormStyle()
            .navigationTitle(title)
            .inlineNavigationTitle()
            .scrollDismissesKeyboard(.interactively)
    }

    /// A Done above the keyboard: the number pads have no return key. Nothing on the Mac.
    func keyboardDoneButton(_ action: @escaping () -> Void) -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done", action: action)
            }
        }
        #else
        self
        #endif
    }
}

/// A picked library photo waiting in the crop screen.
private struct CropTarget: Identifiable {
    let id = UUID()
    let image: PlatformImage
}
