#if os(macOS)
import SwiftUI
import AppKit
import ComposableArchitecture
import ServiceManagement

/// The one main window's scene id, for opening it from the menu bar.
let mainWindowID = "main"

/// The menu bar icon's menu (brief 2026-10-31).
struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open ReTiCaMsgr") {
            openWindow(id: mainWindowID)
            NSApp.activate()
        }
        Divider()
        Button("Quit ReTiCaMsgr") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The icon itself, dotted red while the chat list has anything unread: the same counts that feed
/// the Dock badge, so the two always agree.
struct MenuBarLabel: View {
    @Shared(.inMemory("unreadCounts")) private var unreadCounts: [String: Int] = [:]

    var body: some View {
        Image(nsImage: MenuBarIcon.image(hasUnread: MenuBarIcon.hasUnread(unreadCounts)))
    }
}

/// The Mac's Settings switch for start at login. It reads the system's own state each time it
/// shows, so a change made in System Settings shows here too.
struct LaunchAtLoginSection: View {
    @State private var isOn = false
    @State private var failed = false

    var body: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { isOn },
                set: { on in
                    let service = SMAppService.mainApp
                    failed = (try? on ? service.register() : service.unregister()) == nil
                    isOn = service.isEnabled
                }
            ))
            if failed {
                Text("macOS didn't accept the change. Try it in System Settings › General › Login Items.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Mac")
        } footer: {
            Text("ReTiCaMsgr stays in the menu bar when its window is closed.")
        }
        .onAppear { isOn = SMAppService.mainApp.isEnabled }
    }
}

/// The app is in the Dock only while its window is open; closed, it lives in the menu bar. A login
/// launch closes the window it opened, so the app starts in the menu bar only.
///
/// A Mac app is never suspended, so its sockets stay open: no `backgrounded()` here. It still has
/// to say nobody is looking when the window is hidden, behind another app, or closed (arrivals into
/// the open chat are not viewed, "Message not sent" posts). `.foregrounded` on `.active` already
/// sets the flag back and views the open chat, so `activityChanged(true)` is not sent as well.
struct MainWindowLifecycle: ViewModifier {
    let delegate: AppDelegate
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                if delegate.launchedAsLoginItem {
                    delegate.launchedAsLoginItem = false
                    dismissWindow(id: mainWindowID)
                    return
                }
                NSApp.setActivationPolicy(.regular)
            }
            .onDisappear {
                NSApp.setActivationPolicy(.accessory)
                delegate.runtime.activityChanged(isActive: false)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: delegate.runtime.foregrounded()
                case .inactive, .background: delegate.runtime.activityChanged(isActive: false)
                @unknown default: break
                }
            }
    }
}
#endif
