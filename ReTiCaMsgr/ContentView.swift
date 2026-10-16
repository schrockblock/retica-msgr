import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

struct RootView: View {
    let runtime: AppRuntime

    var body: some View {
        if let store = runtime.store, case .ready = runtime.state {
            TabView {
                ConversationListView(store: store)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                AnnounceListView(store: store)
                    .tabItem { Label("Announces", systemImage: "antenna.radiowaves.left.and.right") }
                SettingsView(store: store)
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
            .modifier(LinkPromptsModifier(store: store))        } else if case .loading = runtime.state {
            ProgressView()
        } else {
            IdentityRecoveryView(runtime: runtime)
        }
    }
}
