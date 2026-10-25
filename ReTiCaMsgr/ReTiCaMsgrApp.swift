import SwiftUI
import ReTiCaMsgrCore

@main
struct ReTiCaMsgrApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif
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
        #if os(macOS)
        // One window: every window would share the one `StoreOf<AppFeature>`, so ⌘N opens none.
        .commands { CommandGroup(replacing: .newItem) {} }
        #endif
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
            // A Mac app is never suspended, so its sockets stay open: no `backgrounded()` there.
            // It still has to say nobody is looking when hidden or behind another app (arrivals into
            // the open chat are not viewed, "Message not sent" posts). `.foregrounded` on `.active`
            // already sets the flag back and views the open chat, so `activityChanged(true)` is
            // not sent as well.
            #if os(iOS)
            case .background: delegate.runtime.backgrounded()
            #elseif os(macOS)
            case .inactive, .background: delegate.runtime.activityChanged(isActive: false)
            #endif
            default: break
            }
        }
    }
}
