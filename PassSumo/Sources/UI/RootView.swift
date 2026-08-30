import SwiftUI

/// The app's single top-level switch: what's on screen is a pure function of `VaultStore.state`
/// (plus the one documented bridge below), never a separately-tracked navigation flag that could
/// drift out of sync with it.
struct RootView: View {
    let environment: AppEnvironment

    var body: some View {
        content
            // Makes `AppEnvironment` reachable via `@Environment(AppEnvironment.self)` for anything
            // mounted under here — in particular `VaultBrowserView`, which reads `selectedEntryID`
            // and `menuRequest` off it (see `AppEnvironment`'s "Cross-cutting UI state" comment for
            // why the menu talks to views this way). Its own dependencies are still passed
            // explicitly below rather than fished out of the environment, so the view stays
            // constructible in a preview with no environment at all.
            .environment(environment)
    }

    @ViewBuilder
    private var content: some View {
        // What is on screen is now a *pure* function of `VaultStore.state`, with no extra branch:
        // a file the user just picked reaches `.locked` through `VaultStore.select(url:)` rather
        // than through an app-level URL held beside the store, so there is nothing left that could
        // disagree with `state` about which screen is correct.
        switch environment.store.state {
        case .empty:
            WelcomeView(environment: environment)
                .accessibilityIdentifier("root.welcome")

        case .locked(let url):
            UnlockView(environment: environment, url: url)
                .accessibilityIdentifier("root.unlock")

        case .unlocking:
            // Argon2 key derivation is deliberately ~1s of real work (see `VaultStore.open`'s
            // doc comment) — long enough that a blank window here would read as frozen, so this
            // state is its own visible case rather than folded into `.locked`.
            ProgressView("Unlocking…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("root.unlocking")

        case .unlocked:
            VaultBrowserView(
                store: environment.store,
                clipboard: environment.clipboard,
                generator: environment.generator,
                autoLock: environment.autoLock
            )
            .accessibilityIdentifier("root.browser")
        }
    }
}

#Preview("Welcome") {
    RootView(environment: .uiTesting())
}
