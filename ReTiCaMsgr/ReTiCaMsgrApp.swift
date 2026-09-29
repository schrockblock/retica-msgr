import SwiftUI
import ReTiCaMsgrCore

@main
struct ReTiCaMsgrApp: App {
    @State private var runtime = AppRuntime(environment: .forProcess())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(runtime: runtime)
                .task { runtime.build() }
        }
        // iOS suspends the app in the background and the TCP socket does not survive it. Nothing
        // else re-dials: `.task` runs once per view lifetime, and the interface's reconnect backoff
        // cannot run while the process is suspended. Without this the only way back was to kill the
        // app, which is exactly what "stuck on Disconnected" looked like on device.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            runtime.foregrounded()
        }
    }
}
