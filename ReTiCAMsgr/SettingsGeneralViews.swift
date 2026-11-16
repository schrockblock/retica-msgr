//
//  SettingsGeneralViews.swift
//  ReTiCAMsgr
//

import SwiftUI
import ComposableArchitecture
import ReTiCAMsgrCore
import ReTiCAPush

/// Settings › Notifications.
struct NotificationsSettingsView: View {
    let store: StoreOf<AppFeature>

    private var pushStatusIsFailure: Bool {
        if case .failed = store.push.status { return true }
        return false
    }

    var body: some View {
        Form {
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
            } footer: {
                if store.pushNode == nil {
                    Text("Unavailable: none of your nodes offers notifications. See Transports in Settings.")
                } else {
                    Text("Notifications only ever say \"New message\"; nothing about the sender or the "
                         + "content leaves the device unencrypted.")
                }
            }
        }
        .settingsScreen("Notifications")
    }
}

#if os(macOS)
/// Settings › Mac.
struct MacSettingsView: View {
    var body: some View {
        Form {
            LaunchAtLoginSection()
        }
        .settingsScreen("Mac")
    }
}
#endif

/// Settings › Contacts.
struct ContactsSettingsView: View {
    let store: StoreOf<AppFeature>
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
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
        .settingsScreen("Contacts")
        // This screen shows access state and import candidates: refresh both.
        .onAppear { store.send(.contactLinkSheetAppeared) }
    }
}
