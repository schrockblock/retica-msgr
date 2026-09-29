import Foundation
import Observation
import ComposableArchitecture
import SQLiteData
import GRDB
import ReTiCA
import ReTiCAKeychain
import ReTiCANode
import ReTiCaMsgrCore

/// Owns the database, resolves the identity, and builds the store ONLY in `.ready` (spec §5.4).
/// The identity enters the app by building the store and never changes afterwards.
@MainActor @Observable
final class AppRuntime {
    struct Environment {
        var database: any DatabaseWriter
        var identityStore: IdentityStore
        var anchor: IdentityAnchor
        var now: () -> Date = Date.init

        static func live() -> Environment {
            let dbPath = URL.documentsDirectory.appending(path: "reticamsgr.sqlite").path()
            return Environment(
                database: try! AppDatabase.makeOnDisk(path: dbPath),
                identityStore: .liveValue,
                anchor: IdentityAnchor(defaults: .standard))
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
                anchor: IdentityAnchor(defaults: defaults))
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
        let store = Store(initialState: AppFeature.State(identity: identity)) {
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
}
