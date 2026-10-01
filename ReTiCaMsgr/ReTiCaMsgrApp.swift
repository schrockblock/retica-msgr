import SwiftUI
import ReTiCaMsgrCore

@main
struct ReTiCaMsgrApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(runtime: delegate.runtime)
                .task { delegate.runtime.build() }
        }
        // iOS suspends the app in the background and the TCP socket does not survive it. Nothing
        // else re-dials: `.task` runs once per view lifetime, and the interface's reconnect backoff
        // cannot run while the process is suspended. Without this the only way back was to kill the
        // app, which is exactly what "stuck on Disconnected" looked like on device.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            delegate.runtime.foregrounded()
        }
    }
}
