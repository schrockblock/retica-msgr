//
//  ContentView.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

struct RootView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        TabView {
            ConversationListView(store: store)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            AnnounceListView(store: store)
                .tabItem { Label("Announces", systemImage: "antenna.radiowaves.left.and.right") }
            SettingsView(store: store)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
