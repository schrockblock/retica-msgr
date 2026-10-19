import SwiftUI
import ReTiCaMsgrCore

@main
struct ReTiCaMsgrApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The LXMF icon glyphs in `AvatarView` draw in the bundled Material Design Icons font.
        MDIIcons.registerFont()
    }

    var body: some Scene {
        WindowGroup {
            RootView(runtime: delegate.runtime)
                .task { delegate.runtime.build() }
        }
        // iOS suspends the app in the background and the TCP socket does not survive it. Nothing
        // else re-dials: `.task` runs once per view lifetime, and the interface's reconnect backoff
        // cannot run while the process is suspended. Without this the only way back was to kill the
        // app, which is exactly what "stuck on Disconnected" looked like on device.
        //
        // Going to the background closes the socket deliberately (see `.backgrounded`): a socket
        // left open from a suspended app looks alive to the push hub, which then writes into it
        // instead of pushing. `.inactive` (app switcher, Control Center, an incoming call) is not
        // the background and does nothing.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: delegate.runtime.foregrounded()
            case .background: delegate.runtime.backgrounded()
            default: break
            }
        }
    }
}
