import SwiftUI
import ComposableArchitecture
import ReTiCAMsgrCore

struct RootView: View {
    let runtime: AppRuntime

    private enum Tab: Hashable { case chat, settings }
    @State private var tab = Tab.chat

    var body: some View {
        if let store = runtime.store, case .ready = runtime.state {
            TabView(selection: $tab) {
                ConversationListView(store: store)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(Tab.chat)
                SettingsView(store: store, meshCoreKeyStore: runtime.meshCoreKeyStore)
                    .tabItem { Label("Settings", systemImage: "gear") }
                    .tag(Tab.settings)
            }
            // A "Message not sent" tap opens its chat, which lives on the Chat tab.
            .onChange(of: runtime.chatRequests) { tab = .chat }
            .modifier(LinkPromptsModifier(store: store))
            .modifier(LocalNetworkAlertModifier(store: store))
        } else if case .loading = runtime.state {
            ProgressView()
        } else {
            IdentityRecoveryView(runtime: runtime)
        }
    }
}

/// AutoInterface was denied the local network (spec 2026-11-10 §8.4): say where the setting is.
/// Shown at most once per launch (`localNetworkAlertShown`); Settings keeps the status line.
private struct LocalNetworkAlertModifier: ViewModifier {
    let store: StoreOf<AppFeature>
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert(AutoInterfaceText.alertTitle, isPresented: Binding(
            get: { store.localNetworkAlert != nil },
            set: { if !$0 { store.send(.localNetworkAlertDismissed) } }
        )) {
            Button("Open Settings") {
                if let url = SystemSettings.localNetworkURL { openURL(url) }
                store.send(.localNetworkAlertDismissed)
            }
            Button("Not Now", role: .cancel) { store.send(.localNetworkAlertDismissed) }
        } message: {
            Text(store.localNetworkAlert.map(AutoInterfaceText.alertMessage) ?? "")
        }
    }
}
