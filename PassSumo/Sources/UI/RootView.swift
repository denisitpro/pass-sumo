import SwiftUI

/// The app's single top-level switch: what's on screen is a function of the tab list (issue #47)
/// and the selected session's `VaultStore.state`, never a separately-tracked navigation flag.
struct RootView: View {
    let environment: AppEnvironment

    /// Create's sheet lives here, not on `WelcomeView`, so File → New, the tab-bar + menu, and
    /// Welcome's own Create button can all present it — Welcome is unmounted whenever a tab exists
    /// (issue #165).
    @State private var isPresentingCreateSheet = false

    /// Welcome and Unlock sit on white like Strongbox (issue #137). The browser paints its
    /// own pane grounds, so the window fill behind it can stay the mint canvas.
    private var authWindowBackground: Color {
        if let session = environment.sessionList.selected, case .unlocked = session.store.state {
            return Palette.canvas
        }
        return Palette.surface
    }

    var body: some View {
        VStack(spacing: 0) {
            if !environment.sessionList.sessions.isEmpty {
                DatabaseTabBar(environment: environment)
            }
            content
        }
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
            // Open and Create are handled HERE, not in `WelcomeView`: both stay enabled while
            // tabs exist (issue #84 / #165), and Welcome is unmounted then. One owner so ⌘O,
            // File → New, the tab-bar + menu, and Welcome's Create button cannot each present
            // their own panel/sheet for the same request.
            .onChange(of: environment.menuRequest) { _, request in
                switch request {
                case .openDatabase:
                    environment.menuRequest = nil
                    guard let url = DatabaseFilePicker.chooseExistingDatabase() else { return }
                    environment.openRouter.requestOpen(url)
                case .newDatabase:
                    environment.menuRequest = nil
                    isPresentingCreateSheet = true
                default:
                    break
                }
            }
            .sheet(isPresented: $isPresentingCreateSheet) {
                CreateDatabaseSheet(environment: environment)
            }
            .confirmationDialog(
                "Save changes before closing this database?",
                isPresented: Binding(
                    get: { environment.sessionList.unsavedChangesCloseID != nil },
                    // Anything that dismisses the dialog without picking a button (Esc, a click
                    // outside) means Cancel, and Cancel is a true no-op: the tab stays.
                    set: { if !$0 { environment.sessionList.cancelClose() } }
                ),
                presenting: environment.sessionList.unsavedChangesCloseSession
            ) { session in
                Button("Save") { Task { await environment.sessionList.saveThenClosePending() } }
                    .accessibilityIdentifier("root.closeTab.save")
                Button("Discard", role: .destructive) {
                    environment.sessionList.discardThenClosePending()
                }
                .accessibilityIdentifier("root.closeTab.discard")
                Button("Cancel", role: .cancel) { environment.sessionList.cancelClose() }
            } message: { session in
                Text(
                    "“\(session.title)” has unsaved changes. Closing it discards them unless you save first."
                )
            }
            // One monitor per tab, including background ones: auto-lock and Touch ID re-arm have
            // to follow that session's store, not whichever tab is selected.
            .background {
                ForEach(environment.sessionList.sessions) { session in
                    SessionLifecycleMonitor(session: session) { url in
                        environment.rememberRecentDatabase(url)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let session = environment.sessionList.selected {
            sessionContent(session)
                .id(session.id)
        } else {
            WelcomeView(environment: environment)
                .accessibilityIdentifier("root.welcome")
        }
    }

    @ViewBuilder
    private func sessionContent(_ session: VaultSession) -> some View {
        switch session.store.state {
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
                store: session.store,
                clipboard: environment.clipboard,
                generator: environment.generator,
                autoLock: session.autoLock,
                settings: environment.settings
            )
            .accessibilityIdentifier("root.browser")
        }
    }
}

/// Keeps a session's auto-lock and Touch ID policy honest about *that* vault's state, including
/// when the tab is in the background. `onAppear` covers the case where the store reached
/// `.unlocked` before this view was mounted (the `-ui-testing` fixture load does exactly that).
private struct SessionLifecycleMonitor: View {
    let session: VaultSession
    let onUnlocked: (URL) -> Void

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onAppear { apply(from: .empty, to: session.store.state) }
            .onChange(of: session.store.state) { oldState, newState in
                apply(from: oldState, to: newState)
            }
    }

    private func apply(from oldState: VaultStore.State, to newState: VaultStore.State) {
        session.handleStoreStateChange(from: oldState, to: newState)
        if case .unlocked = oldState { return }
        if case .unlocked = newState, let url = session.store.currentURL {
            onUnlocked(url)
        }
    }
}

#Preview("Welcome") {
    RootView(environment: .uiTesting())
}
