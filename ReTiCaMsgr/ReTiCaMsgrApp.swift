//
//  ReTiCaMsgrApp.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import ComposableArchitecture
import SQLiteData
import ReTiCaMsgrCore

@main
struct ReTiCaMsgrApp: App {
    static let store: StoreOf<AppFeature> = {
        let identity = IdentityStore.liveValue.load()
        let dbPath = URL.documentsDirectory.appending(path: "reticamsgr.sqlite").path()
        prepareDependencies { $0.defaultDatabase = try! AppDatabase.makeOnDisk(path: dbPath) }
        return Store(initialState: AppFeature.State(identity: identity)) { AppFeature() }
    }()

    var body: some Scene {
        WindowGroup {
            RootView(store: Self.store)
                .task { Self.store.send(.onLaunch) }
        }
    }
}
