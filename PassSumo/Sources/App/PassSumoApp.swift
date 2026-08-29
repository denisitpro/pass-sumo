import SwiftUI

@main
struct PassSumoApp: App {
    // Launch argument contract with Sources/UITests: `-ui-testing 1` sets the `ui-testing` default,
    // which is how the XCUITest runner tells the app under test to boot against fakes and skip
    // Touch ID instead of a real vault (see `AppEnvironment.uiTesting()`). `UserDefaults.standard`
    // reads a launch argument of the form `-key value` as the value for `key`, no parsing needed.
    // Read exactly once, here, to pick a factory — every other file reads `environment.isUITesting`
    // instead of going back to `UserDefaults` a second time.
    @State private var environment = UserDefaults.standard.bool(forKey: "ui-testing")
        ? AppEnvironment.uiTesting()
        : AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                // Sized for a three-pane browser (sidebar / list / detail) — the shell's steady
                // state once a vault is open, not the Welcome/Unlock screens, which are small and
                // simply centre themselves in whatever size this establishes.
                .frame(minWidth: 900, minHeight: 560)
                // Finishes what `AppEnvironment.uiTesting()` can only start synchronously — see that
                // method's doc comment for why the actual `store.open` has to happen from an `async`
                // context. A no-op under a real launch and a no-op on every render after the first
                // (`loadUITestingFixture()` guards on `store.state` still being `.empty`).
                .task { await environment.loadUITestingFixture() }
                // Keeps `AutoLockController` honest about the vault's real state regardless of which
                // path changed it — `UnlockView` unlocking, `-ui-testing`'s fixture load, "Lock
                // Database", the idle timer itself. The controller's own `lock(reason:)` already
                // stops its timer when *it* is the one that triggered the lock; the `.locked`/
                // `.empty` branch here is what covers a lock that happened some other way (e.g. the
                // "Lock Database" command calling `store.lock()` directly), which the controller has
                // no way to notice on its own.
                .onChange(of: environment.store.state) { _, newState in
                    switch newState {
                    case .unlocked:
                        environment.autoLock.vaultDidUnlock()
                        if let url = environment.store.currentURL {
                            environment.rememberRecentDatabase(url)
                        }
                    case .locked, .empty:
                        environment.autoLock.stop()
                    case .unlocking:
                        break
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(environment: environment)
        }

        Settings {
            SettingsView(environment: environment)
        }
    }
}
