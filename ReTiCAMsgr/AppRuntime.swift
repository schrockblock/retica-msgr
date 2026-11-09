import Foundation
import Observation
import OSLog
import ComposableArchitecture
import SQLiteData
import GRDB
import ReTiCA
import ReTiCAKeychain
import ReTiCANode
import ReTiCAMsgrCore
import ReTiCAPush
import ReTiCAPushCore
import ReTiCAMsgrPushService

/// Owns the database, resolves the identity, and builds the store ONLY in `.ready` (spec §5.4).
/// The identity enters the app by building the store and never changes afterwards.
@MainActor @Observable
final class AppRuntime {
    struct Environment {
        var database: any DatabaseWriter
        var identityStore: IdentityStore
        var anchor: IdentityAnchor
        var now: () -> Date = Date.init
        /// Inbox and shared settings for push (spec 2026-10-01 §3). The app group when entitled,
        /// a throwaway location otherwise (and always under test).
        var pushStorage: PushStorage = .temporary()
        /// How long `pushWake` holds the process after sending `.pushWake`, so the re-dial and
        /// drain get a chance before the fetch handler completes. Zero under test.
        var wakeHold: Duration = .seconds(20)
        /// The MeshCore channel-key store. Inert by default, so a runtime built without one (the
        /// app's own runtime tests) never touches the real Keychain; `live()` passes the real one.
        var meshCoreKeyStore: MeshCoreKeyStore = .inert
        /// The delivery destination's own ratchet ring (private keys). Inert by default for the same
        /// reason as `meshCoreKeyStore`; inert means ratchets stay off.
        var ownRatchetStore: OwnRatchetStore = .inert

        static func live() -> Environment {
            let dbPath = URL.documentsDirectory.appending(path: "reticamsgr.sqlite").path()
            // M6: nil here means the app-group entitlement is missing or misconfigured — pushed
            // packets would silently never reach the inbox the extension writes into. Surface it
            // loudly in debug builds (assertionFailure is a no-op in release) and always log it,
            // since a release build has no other way to notice before a user reports missing pushes.
            let pushStorage = ReTiCAMsgrPush.storage()
            if pushStorage == nil {
                assertionFailure("app group container missing: check the entitlement")
                Logger(subsystem: "com.reticamsgr", category: "push")
                    .error("app group container missing: check the entitlement")
            }
            return Environment(
                database: try! AppDatabase.makeOnDisk(path: dbPath),
                identityStore: .liveValue,
                anchor: IdentityAnchor(defaults: .standard),
                pushStorage: pushStorage ?? .temporary(),
                meshCoreKeyStore: .live(ops: .live),
                ownRatchetStore: .live(ops: .live))
        }

        /// Hosted XCTest runs and UI-test launches never touch the real Keychain, database or
        /// defaults: an in-memory Keychain pre-planted with a fixed identity, an in-memory
        /// database, and a throwaway defaults suite.
        static func testHost() -> Environment {
            let keychain = InMemoryKeychain()
            let identity = Identity()
            keychain.set(identity.privateKey!, at: SharedIdentityLocation.shared)
            let suite = "reticamsgr.testhost"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return Environment(
                database: try! AppDatabase.makeInMemory(),
                identityStore: .live(ops: keychain.ops),
                anchor: IdentityAnchor(defaults: defaults),
                wakeHold: .zero,
                meshCoreKeyStore: .live(ops: keychain.ops),
                ownRatchetStore: .live(ops: keychain.ops))
        }

        static var isTestHost: Bool {
            let env = ProcessInfo.processInfo.environment
            return env["XCTestConfigurationFilePath"] != nil || env["RETICAMSGR_TEST_HOST"] == "1"
        }

        static func forProcess() -> Environment {
            isTestHost ? testHost() : live()
        }
    }

    static let retryInterval: TimeInterval = 1

    private(set) var state: IdentityState = .loading
    private(set) var store: StoreOf<AppFeature>?
    private(set) var isBuilding = false
    private let environment: Environment
    private var lastRetry: Date?

    init(environment: Environment) {
        self.environment = environment
    }

    /// Launch, Retry, Restore and Accept all come through here. A no-op once a store exists.
    func build() {
        guard store == nil else { return }
        isBuilding = true
        defer { isBuilding = false }
        let policy = LoadPolicy.forLaunch(database: environment.database, anchor: environment.anchor)
        let resolved = LaunchIdentity.resolve(policy: policy, anchor: environment.anchor, store: environment.identityStore)
        state = resolved.state
        guard let identity = resolved.identity else { return }
        let database = environment.database
        let pushStorage = environment.pushStorage
        let meshCoreKeyStore = environment.meshCoreKeyStore
        let ownRatchetStore = environment.ownRatchetStore
        let store = Store(initialState: AppFeature.State(identity: identity, pushStorage: pushStorage)) {
            AppFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            // Explicit, not the ambient default: a hosted XCTest process makes swift-dependencies
            // require every dependency to be overridden (it treats the process as "testing" and
            // `\.date`'s default test value fails on use). This is still the real wall clock in
            // every configuration — live app, hosted tests and UI-test launches alike.
            $0.date = DateGenerator { Date() }
            // Answer peers' /publicKey requests with our own 64-byte public key. The link the
            // request arrives on is already authenticated, and the key is public (every announce
            // carries it), so answering unconditionally is safe.
            $0.requestResponder = RequestResponder { path, _, _ in
                guard path == AppFeature.publicKeyRequestPath else { return nil }
                return identity.publicKey
            }
            // The package's liveValue only reports an issue: the app owns UIKit (AppKit on macOS).
            #if os(iOS)
            $0.pushPlatform = .uiKit
            // Likewise: background time for sends still in flight (spec 2026-10-21, A4).
            $0.backgroundTask = .uiKit
            #elseif os(macOS)
            $0.pushPlatform = .appKit
            // A Mac app isn't suspended, so there is no background time to borrow; explicit for the
            // same hosted-XCTest reason as `\.date` (its testValue is unimplemented).
            $0.backgroundTask = .liveValue
            #endif
            // Likewise: the "Message not sent" notification (brief 2026-10-21).
            $0.localNotifications = .userNotifications
            // Likewise: the app-icon badge and the extension's counter (spec 2026-10-25 Part 2).
            $0.badge = .userNotifications
            // Explicit for the same hosted-XCTest reason as `\.date` (its testValue is unimplemented):
            // the live radio scan over MeshtasticKit (spec 2026-10-16 §7 lane E).
            MeshtasticLiveWiring.installScanner(into: &$0)
            // The live Meshtastic driver over the app's ONE MeshtasticSession (spec 2026-10-16 §7
            // lane E). Lazy: no CoreBluetooth work until a radio slot starts.
            MeshtasticLiveWiring.installDriver(into: &$0)
            // The live MeshCore driver over the app's ONE MeshCoreSession (spec 2026-11-07 lane D),
            // filling the channel key from the key store only at `driver.start`; its radio details
            // for Diagnostics; and the MeshCore half of the picker scan. Outside `#if DEBUG`: they
            // build nothing until a slot starts, and a Release build can't start one.
            MeshCoreLiveWiring.installDriver(into: &$0, keyStore: meshCoreKeyStore)
            MeshCoreLiveWiring.installDetails(into: &$0)
            MeshCoreLiveWiring.installScanner(into: &$0)
            // The live RNode driver over the app's ONE RNodeSession (spec 2026-11-08 lane D) and
            // the RNode half of the picker scan. Outside `#if DEBUG`: they build nothing until a
            // slot starts, and a Release build can't start one.
            RNodeLiveWiring.installScanner(into: &$0)
            RNodeLiveWiring.installDriver(into: &$0)
            // A purged attachment's decoded images leave the app's cache with its file (A17).
            $0.attachmentCacheEvictor = AttachmentCacheEvictor { ids in
                await ThumbnailCache.shared.evict(attachmentIds: ids)
            }
            // Explicit for the same hosted-XCTest reason as `\.date`, and so a hosted run uses the
            // test host's in-memory Keychain, never the real one.
            $0.meshCoreKeyStore = meshCoreKeyStore
            // Likewise for the own ratchet ring, read at `.onLaunch` and written on each rotation.
            $0.ownRatchetStore = ownRatchetStore
            // Settings' Copy button. Local-only with an expiry on iOS (ruling R8); revealed only here.
            // The copy effect runs off the main actor; the pasteboard is used from the main actor.
            $0.meshCoreKeyPasteboard = MeshCoreKeyPasteboard { text in
                Task { @MainActor in Pasteboard.copySecret(text.reveal()) }
            }
        }
        self.store = store
        store.send(.onLaunch)
    }

    /// Rate-limited to once per `retryInterval`. Returns whether a build ran.
    @discardableResult
    func retry() -> Bool {
        guard store == nil else { return false }
        let now = environment.now()
        if let last = lastRetry, now.timeIntervalSince(last) < Self.retryInterval { return false }
        lastRetry = now
        build()
        return true
    }

    /// Only in `.missing`. Validates strictly against the anchor, imports add-only, then builds.
    func restore(privateKey: Data) -> RestoreResult {
        guard case let .missing(expected) = state else { return .refused(.notMissing) }
        if case let .failure(rejection) = IdentityRestore.validate(privateKey: privateKey, expected: expected) {
            return .rejected(rejection)
        }
        switch environment.identityStore.restore(privateKey) {
        case let .restored(identity):
            build()
            return .restored(identity.hash)
        case let .identityPresent(service):
            return .refused(.identityPresent(service: service))
        case .invalidKey:
            return .rejected(.invalidKey)
        case let .failed(reason):
            return .failed(reason)
        }
    }

    /// Only from the no-anchor `.missing` state (spec amendment 1 to §5.5): this device has never
    /// used an identity, so minting is safe. Mints via `loadOrCreate`, then re-resolves through
    /// `build()` so the normal path (messages exist → `.loadOnly` → the just-minted item loads →
    /// anchor nil → recorded) is what actually produces `.ready`.
    func createNewIdentity() {
        guard case .missing(expected: nil) = state else { return }
        if case let .failed(reason) = environment.identityStore.load(.loadOrCreate) {
            state = .unavailable(reason)
            return
        }
        build()
    }

    /// The explicit "Use the new identity": rewrites the anchor and builds.
    func acceptNewIdentity() {
        guard case let .identityChanged(_, got) = state else { return }
        environment.anchor.replace(with: got)
        build()
    }

    func foregrounded() {
        store?.send(.foregrounded)
    }

    /// The scene entered the background: flush learned paths and close the hub socket so the push
    /// hub sees a FIN and goes dormant instead of writing into a frozen socket.
    func backgrounded() {
        store?.send(.backgrounded)
    }

    /// The Mac app went inactive or came back without being suspended: only "is anyone looking"
    /// changes, the sockets stay open (see `AppFeature.Action.activityChanged`).
    func activityChanged(isActive: Bool) {
        store?.send(.activityChanged(isActive: isActive))
    }

    /// A background push or a notification tap. Builds the store if the scene never rendered
    /// (`build()` is view-independent), sends `.pushWake`, holds for `hold` (or `wakeHold` when
    /// nil) so the re-dial and drain can run, and reports whether a store exists. False means the
    /// identity is unavailable (locked before first unlock, or missing); the inbox then waits for
    /// the next launch.
    ///
    /// M1: when `build()` is what just created the store, `.pushWake` is NOT also sent — `onLaunch`
    /// (which `build()` triggers) already starts the endpoint and sends `.push(.appLaunched)`,
    /// which itself drains. Sending `.pushWake` too would just be a redundant, harmless re-dial —
    /// but on a cold launch there is no connection to re-dial yet, so the hold would be wasted
    /// waiting on nothing.
    ///
    /// M2: `hold` defaults to `environment.wakeHold`; a notification TAP passes `.zero` — the user
    /// is already looking at the app by the time the tap handler runs, so nothing needs holding.
    func pushWake(hold: Duration? = nil) async -> Bool {
        let hadStore = store != nil
        build()
        guard let store else { return false }
        if hadStore {
            store.send(.pushWake)
        }
        let wait = hold ?? environment.wakeHold
        if wait > .zero {
            try? await Task.sleep(for: wait)
        }
        return true
    }

    func pushDeviceToken(_ token: Data) {
        store?.send(.pushDeviceToken(token))
    }

    func pushDeviceTokenFailed(_ reason: String) {
        store?.send(.pushDeviceTokenFailed(reason))
    }

    func drainPushInbox() {
        store?.send(.push(.drainInbox))
    }

    func propagatedPush() {
        store?.send(.propagatedPush)
    }

    /// Bumped when something outside the chat list asks to show a chat, so `RootView` switches to
    /// the Chat tab.
    private(set) var chatRequests = 0

    /// A tap on a "Message not sent" notification: open that conversation on the Chat tab. Builds
    /// the store first if the tap launched the app.
    func openFailedSend(_ peerHex: String) {
        build()
        guard let store else { return }
        chatRequests += 1
        store.send(.sendFailedNotificationTapped(peerHex))
    }

    var pushStorage: PushStorage { environment.pushStorage }

    /// The key sheets call the store directly; a view's own `@Dependency` wouldn't see the store's
    /// override, so they take this one.
    var meshCoreKeyStore: MeshCoreKeyStore { environment.meshCoreKeyStore }
}
