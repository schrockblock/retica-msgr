import SwiftUI
import ComposableArchitecture
import ReTiCAMsgrCore

struct RootView: View {
    let runtime: AppRuntime

    var body: some View {
        if let store = runtime.store, case .ready = runtime.state {
            // The one root screen: chats and Settings are both pushed on its stack.
            ConversationListView(store: store, meshCoreKeyStore: runtime.meshCoreKeyStore)
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
            get: { store.state.presentedLocalNetworkAlert != nil },
            set: { if !$0 { store.send(.localNetworkAlertDismissed) } }
        )) {
            Button("Open Settings") {
                if let url = SystemSettings.localNetworkURL { openURL(url) }
                store.send(.localNetworkAlertDismissed)
            }
            Button("Not Now", role: .cancel) { store.send(.localNetworkAlertDismissed) }
        } message: {
            Text(store.state.presentedLocalNetworkAlert.map(AutoInterfaceText.alertMessage) ?? "")
        }
    }
}
