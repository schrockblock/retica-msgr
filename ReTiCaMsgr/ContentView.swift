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
            ChatView(store: store)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            AddressView(store: store)
                .tabItem { Label("Address", systemImage: "person.crop.circle") }
            SettingsView(store: store)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
