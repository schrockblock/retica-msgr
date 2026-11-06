import XCTest

/// The only place a UI test launches the app: the flag makes the app use an in-memory Keychain,
/// database and defaults, so no test run can mint or read a real identity.
enum TestApp {
    @MainActor static func make() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RETICAMSGR_TEST_HOST"] = "1"
        return app
    }
}
