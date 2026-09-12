import SwiftUI

/// The app's single top-level switch: what's on screen is a pure function of `VaultStore.state`
/// (plus the one documented bridge below), never a separately-tracked navigation flag that could
/// drift out of sync with it.
struct RootView: View {
    let environment: AppEnvironment

    /// Welcome and Unlock sit on white like Strongbox (issue #137). The browser paints its
    /// own pane grounds, so the window fill behind it can stay the mint canvas.
    private var authWindowBackground: Color {
        switch environment.store.state {
        case .unlocked: return Palette.canvas
        default: return Palette.surface
        }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Every screen sits on one of two grounds: `canvas` behind a centred card (Welcome,
            // Unlock) and `surface` inside the browser's panes, which paint their own. Painting
            // the canvas once here is what stops the system window background showing through.
            .background(authWindowBackground)
            // Welcome / Unlock / Unlocking have no status bar. Pin the same compact stamp the
            // browser puts in `StatusBar`'s trailing end (issue #153) so a leftover build is
            // obvious before a vault is open too. Hidden once unlocked — that screen already
            // has the bar. `.allowsHitTesting(false)` so it cannot steal the card's buttons.
            .overlay(alignment: .bottomTrailing) {
                if case .unlocked = environment.store.state {
                    EmptyView()
                } else {
                    Text(AppVersionInfo.current().shortLabel)
                        .font(Typography.monoCaption2)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(Spacing.s5)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("window.build")
                }
            }
            // The app-wide accent, so the controls this design pass does not hand-draw — a
            // `Slider`'s fill, a `Toggle`'s knob, a `ProgressView`'s bar, `List`'s focus ring —
            // follow palette C instead of the system blue.
            .tint(Palette.accent600)
            // Makes `AppEnvironment` reachable via `@Environment(AppEnvironment.self)` for anything
            // mounted under here — in particular `VaultBrowserView`, which reads `selectedEntryID`
            // and `menuRequest` off it (see `AppEnvironment`'s "Cross-cutting UI state" comment for
            // why the menu talks to views this way). Its own dependencies are still passed
            // explicitly below rather than fished out of the environment, so the view stays
            // constructible in a preview with no environment at all.
            .environment(environment)
            // "Open Database…" is handled HERE, not in `WelcomeView`, because since issue #84 the
            // item is enabled while a vault is open — and `WelcomeView` is unmounted in every state
            // but `.empty`. `RootView` is the only view that exists in all of them.
            .onChange(of: environment.menuRequest) { _, request in
                guard request == .openDatabase else { return }
                environment.menuRequest = nil
                guard let url = DatabaseFilePicker.chooseExistingDatabase() else { return }
                environment.openRouter.requestOpen(url)
            }
            .confirmationDialog(
                "Save changes before opening another database?",
                isPresented: Binding(
                    get: { environment.openRouter.unsavedChangesPrompt != nil },
                    // Anything that dismisses the dialog without picking a button (Esc, a click
                    // outside) means Cancel, and Cancel is a true no-op: the request is dropped and
                    // the open vault keeps its state, its edits and its selection.
                    set: { if !$0 { environment.openRouter.cancelPending() } }
                ),
                presenting: environment.openRouter.unsavedChangesPrompt
            ) { _ in
                // The presented URL is named in the message below, not on a button: a button label
                // carrying a filename would make the destructive choice the widest one on screen.
                Button("Save") { Task { await environment.openRouter.saveThenOpenPending() } }
                    .accessibilityIdentifier("root.openRequest.save")
                Button("Discard", role: .destructive) {
                    environment.openRouter.discardThenOpenPending()
                }
                .accessibilityIdentifier("root.openRequest.discard")
                Button("Cancel", role: .cancel) { environment.openRouter.cancelPending() }
            } message: { requested in
                // Both filenames, because "unsaved changes" alone does not say which database is
                // about to be closed — and with two databases in play that is the whole question.
                Text(
                    "“\(environment.store.currentURL?.lastPathComponent ?? "The open database")” "
                        + "has unsaved changes. Opening “\(requested.lastPathComponent)” closes it."
                )
            }
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
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("root.unlocking")

        case .unlocked:
            VaultBrowserView(
                store: environment.store,
                clipboard: environment.clipboard,
                generator: environment.generator,
                autoLock: environment.autoLock,
                settings: environment.settings
            )
            .accessibilityIdentifier("root.browser")
        }
    }
}

#Preview("Welcome") {
    RootView(environment: .uiTesting())
}
