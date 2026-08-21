//
//  ReTiCaMsgrApp.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCANode
import ReTiCaMsgrCore

@main
struct ReTiCaMsgrApp: App {
    static let store: StoreOf<AppFeature> = {
        let identity = IdentityStore.liveValue.load()
        let dbPath = URL.documentsDirectory.appending(path: "reticamsgr.sqlite").path()
        prepareDependencies {
            $0.defaultDatabase = try! AppDatabase.makeOnDisk(path: dbPath)
            // Answer peers' /publicKey requests with our own 64-byte public key. The link the
            // request arrives on is already authenticated, and the key is public (every announce
            // carries it), so answering unconditionally is safe.
            $0.requestResponder = RequestResponder { path, _, _ in
                guard path == AppFeature.publicKeyRequestPath else { return nil }
                return identity.publicKey
            }
        }
        return Store(initialState: AppFeature.State(identity: identity)) { AppFeature() }
    }()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(store: Self.store)
                .task { Self.store.send(.onLaunch) }
        }
        // iOS suspends the app in the background and the TCP socket does not survive it. Nothing
        // else re-dials: `.task` runs once per view lifetime, and the interface's reconnect backoff
        // cannot run while the process is suspended. Without this the only way back was to kill the
        // app, which is exactly what "stuck on Disconnected" looked like on device.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Self.store.send(.foregrounded)
        }
    }
}
