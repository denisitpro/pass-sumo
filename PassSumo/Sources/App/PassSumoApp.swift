import AppKit
import SwiftUI

@main
struct PassSumoApp: App {
    /// Installs `DocumentOpenReceiver` as the app delegate, which is what finally gives the app
    /// somewhere to receive the Launch Services open requests it advertises
    /// (`LSHandlerRank: Alternate` on imported `app.passsumo.kdbx` — issue #131; Owner is
    /// deferred to #132) and used to drop on the floor — issue #84.
    @NSApplicationDelegateAdaptor(DocumentOpenReceiver.self) private var openReceiver

    // Launch argument contract with Sources/UITests: `-ui-testing 1` sets the `ui-testing` default,
    // which is how the XCUITest runner tells the app under test to boot against fakes and skip
    // Touch ID instead of a real vault (see `AppEnvironment.uiTesting()`). `UserDefaults.standard`
    // reads a launch argument of the form `-key value` as the value for `key`, no parsing needed.
    // Read exactly once, here, to pick a factory — every other file reads `environment.isUITesting`
    // instead of going back to `UserDefaults` a second time.
    @State private var environment = UserDefaults.standard.bool(forKey: "ui-testing")
        ? AppEnvironment.uiTesting()
        : AppEnvironment.live()

    /// The window's color scheme.
    ///
    /// **Pinned to `.light` (issue #57).** Every design token has exactly one, light value (see
    /// `Sources/UI/DesignTokens.swift`), so under a dark system appearance the app would paint its
    /// own light surfaces inside dark window chrome — light content in a dark frame, with the
    /// titlebar and the sheet backdrop disagreeing with everything below them. The pin goes away
    /// with issue #57, which decides the dark ramp as a set.
    ///
    /// `PASSSUMO_PREFERRED_COLOR_SCHEME=dark`/`light` still overrides it, so a visual-verification
    /// pass can check the other appearance without flipping the Mac's system setting (which would
    /// repaint every other app's window on the same screen). Unset on every normal launch,
    /// including under `-ui-testing 1`.
    private var contentColorScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment["PASSSUMO_PREFERRED_COLOR_SCHEME"] {
        case "dark": return .dark
        case "light": return .light
        default: return .light
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                // Sized for a three-pane browser (sidebar / list / detail) — the shell's steady
                // state once a vault is open, not the Welcome/Unlock screens, which are small and
                // simply centre themselves in whatever size this establishes.
                //
                // **Reconsidered, not just kept, now that the sidebar has a real minimum (issue
                // #101).** The three panes' own genuine floors are: the sidebar's 165
                // (`VaultBrowserView.browserContent`'s `.navigationSplitViewColumnWidth`), the
                // inspector's 400 (`.inspectorColumnWidth`, issue #86) — and the entry list in
                // between, which carries no width range of its own and has nothing in its row that
                // truncation actually breaks (title and username both just truncate, same as a
                // sidebar group name past its own floor), so its "genuine need" is editorial rather
                // than technical: `Metrics.rowIconSlot` (20) + the icon/text `Spacing.s4` gap (8) +
                // the row's own `Spacing.s5` padding on both sides (24) + enough room for a short,
                // real title to read whole rather than as an ellipsis (measured: "Gmail Personal",
                // this app's own sample data, is 90pt at `Typography.body`) — about 142pt. Summed,
                // the three panes' bare floors come to roughly 707, a good 190pt under 900.
                //
                // 900 is still the right number, but for a different reason than a bare floor: it
                // is what keeps the STEADY STATE comfortable, giving the list column (the one pane
                // with no minimum of its own) enough slack to show full titles and usernames rather
                // than sitting at its bare-content floor on every ordinary launch. Shrinking this to
                // 707 would trade "the shell's steady state" for "the shell's most cramped legal
                // state" — a real regression this issue did not ask for. Left at 900.
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(contentColorScheme)
                // Finishes what `AppEnvironment.uiTesting()` can only start synchronously — see that
                // method's doc comment for why the actual `store.open` has to happen from an `async`
                // context. A no-op under a real launch and a no-op on every render after the first
                // (`loadUITestingFixture()` guards on `store.state` still being `.empty`).
                .task { await environment.loadUITestingFixture() }
                // Wired here rather than at `DocumentOpenReceiver`'s construction because the
                // adaptor builds it before this scene's `environment` exists. The receiver buffers
                // a URL that arrives before this runs (a cold launch by double-click does exactly
                // that), so nothing is lost in the gap — see its doc comment.
                .task { openReceiver.onOpen { requestOpen($0) } }
                // Keeps `AutoLockController` honest about the vault's real state regardless of which
                // path changed it — `UnlockView` unlocking, `-ui-testing`'s fixture load, "Lock
                // Database", the idle timer itself. The controller's own `lock(reason:)` already
                // stops its timer when *it* is the one that triggered the lock; the `.locked`/
                // `.empty` branch here is what covers a lock that happened some other way (e.g. the
                // "Lock Database" command calling `store.lock()` directly), which the controller has
                // no way to notice on its own.
                .onChange(of: environment.store.state) { oldState, newState in
                    switch newState {
                    case .unlocked:
                        environment.autoLock.vaultDidUnlock()
                        // The next lock gets a fresh automatic Touch ID attempt. Re-armed HERE,
                        // on a genuine unlock, and deliberately not when `UnlockView` appears:
                        // that view is rebuilt every time a wrong password bounces the state
                        // through `.unlocking`, and re-arming there would put the sheet back up
                        // on every typo (see `AutomaticBiometricUnlockPolicy`).
                        environment.automaticBiometricUnlock.rearm()
                        if let url = environment.store.currentURL {
                            environment.rememberRecentDatabase(url)
                        }
                    case .locked(let url):
                        environment.autoLock.stop()
                        // `VaultOpenRouter`'s `.replace` (issue #84) moves the store straight from
                        // one locked database to another — `.locked(A)` → `.locked(B)` — with no
                        // `.unlocked` in between, so nothing else notices that B was never touched
                        // this session. Left alone, `UnlockView` would show B the reason A locked
                        // for. This is the one place that sees both URLs, so it is the one place
                        // that can tell a genuine re-lock of the SAME database (reason still valid)
                        // apart from a switch to a different one (reason stale) — see issue #62.
                        if case .locked(let previousURL) = oldState, previousURL != url {
                            environment.autoLock.forgetLockReason()
                        }
                    case .empty:
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
                // Same pin as the main window (issue #57) — a Settings window left on the system
                // appearance would be the one dark surface in an otherwise light app.
                .preferredColorScheme(contentColorScheme)
        }
    }

    /// Hands a Launch Services open request to the one type that decides what it means, and does
    /// the single part of the answer that needs a window.
    ///
    /// `.alreadyOpen` is why this is not a bare call into the router: the acceptance criterion is
    /// that re-opening the front database brings the window forward and changes *nothing else* —
    /// no lock, no reload, no lost selection. Launch Services activates the app on its own, but not
    /// a window the user had minimised, so that half is done here. Every other branch is already
    /// complete by the time `requestOpen` returns.
    @MainActor
    private func requestOpen(_ url: URL) {
        guard case .alreadyOpen = environment.openRouter.requestOpen(url) else { return }
        NSApp.activate()
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}
