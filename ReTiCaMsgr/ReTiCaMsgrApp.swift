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
        #if os(iOS)
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
        #elseif os(macOS)
        // One window: every window would share the one `StoreOf<AppFeature>`, and `Window` is single
        // by nature; ⌘N opens none. The store is built at launch by the app delegate as well as
        // here: a login launch closes this window straight away and must stay connected regardless.
        // The window's own scene phase drives foreground and activity (`MainWindowLifecycle`): the
        // app-wide one would also turn active when only the menu bar menu opens.
        Window("ReTiCaMsgr", id: mainWindowID) {
            RootView(runtime: delegate.runtime)
                .task { delegate.runtime.build() }
                .modifier(MainWindowLifecycle(delegate: delegate))
        }
        .commands { CommandGroup(replacing: .newItem) {} }

        // The app lives here while its window is closed (brief 2026-10-31).
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            MenuBarLabel()
        }
        #endif
    }
}
