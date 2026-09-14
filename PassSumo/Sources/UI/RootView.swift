import AppKit
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
            // The lock prompt is the close prompt's twin (issue #172): ⌘L and the toolbar's Lock
            // button used to drop a dirty vault without a word. Only the selected tab can raise
            // it — a background tab has no Lock button, and an automatic lock never prompts at all
            // because there is nobody there to answer.
            .confirmationDialog(
                "Save changes before locking this database?",
                isPresented: Binding(
                    get: { environment.sessionList.unsavedChangesLockID != nil },
                    // Esc or a click outside means Cancel, and Cancel leaves the vault open and
                    // unlocked — the same true no-op as the close prompt's.
                    set: { if !$0 { environment.sessionList.cancelLock() } }
                ),
                presenting: environment.sessionList.unsavedChangesLockSession
            ) { session in
                Button("Save") { Task { await environment.sessionList.saveThenLockPending() } }
                    .accessibilityIdentifier("root.lockTab.save")
                Button("Discard", role: .destructive) {
                    environment.sessionList.discardThenLockPending()
                }
                .accessibilityIdentifier("root.lockTab.discard")
                Button("Cancel", role: .cancel) { environment.sessionList.cancelLock() }
            } message: { session in
                Text(
                    "“\(session.title)” has unsaved changes. Locking discards them unless you save first."
                )
            }
            // ⌘Q (issue #172). Unlike the two above this one is answering AppKit, which is holding
            // the whole termination on a `.terminateLater` until somebody replies — see
            // `answerQuit` for why every branch, including the dialog being dismissed some other
            // way, funnels through one place.
            .confirmationDialog(
                "Save changes before quitting?",
                isPresented: Binding(
                    get: { environment.sessionList.isQuitPending },
                    set: { if !$0 { answerQuit(false) } }
                )
            ) {
                Button("Save") {
                    Task {
                        // A failed save answers "no, do not quit" and leaves the app running with
                        // the error where a failed ⌘S puts it — quitting anyway would discard
                        // exactly the edits the user asked to keep.
                        answerQuit(await environment.sessionList.saveDirtySessionsForQuit())
                    }
                }
                .accessibilityIdentifier("root.quit.save")
                Button("Discard", role: .destructive) { answerQuit(true) }
                    .accessibilityIdentifier("root.quit.discard")
                Button("Cancel", role: .cancel) { answerQuit(false) }
            } message: {
                Text(
                    "Unsaved changes in \(environment.sessionList.dirtySessions.map(\.title).joined(separator: ", ")). "
                        + "Quitting discards them unless you save first."
                )
            }
            // A save that refused rather than clobber a file another app or Mac had already
            // changed (issue #173). The fourth dialog on this view, and the only one not raised
            // by a request the user made: it reports a condition a store has ended up in, so it
            // is driven by `externalChangeSession` — see that property for why it is derived and
            // per-tab rather than parked on a flag and read off the selected store.
            .confirmationDialog(
                "This database changed on disk",
                isPresented: Binding(
                    get: { environment.sessionList.externalChangeSession != nil },
                    // Esc or a click outside means Cancel: the refusal is acknowledged, nothing is
                    // written, and the edits stay dirty.
                    set: { if !$0 { environment.sessionList.acknowledgeExternalChange() } }
                ),
                presenting: environment.sessionList.externalChangeSession
            ) { session in
                // Overwrite is NOT marked destructive and Reload is, which reads backwards until
                // you ask what each one destroys and whether it can be got back. Overwrite
                // replaces the other copy — and the pre-save backup taken immediately before that
                // write is a copy of exactly what it replaces (`VaultFileAccess.write`), so it is
                // recoverable through "Show Backups in Finder". Reload throws away edits that
                // exist in this process's memory and nowhere else: not in the file, and not in any
                // backup, because no backup was ever of them.
                Button("Overwrite") {
                    Task { await session.store.save(overwritingExternalChanges: true) }
                }
                .accessibilityIdentifier("root.externalChange.overwrite")
                Button("Reload", role: .destructive) {
                    Task { await session.store.reloadFromDisk() }
                }
                .accessibilityIdentifier("root.externalChange.reload")
                Button("Cancel", role: .cancel) {
                    environment.sessionList.acknowledgeExternalChange()
                }
            } message: { session in
                Text(
                    "“\(session.title)” was changed by another app or Mac since it was opened here, "
                        + "so it was not saved. Overwrite replaces that copy with yours, keeping "
                        + "the version it replaces as a backup. Reload discards your unsaved "
                        + "changes and opens the file again."
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
            // Argon2 key derivation is ~0.9 s of real work for a database we created, and can be
            // far longer for one another client tuned (see `VaultStore.open`'s doc comment) —
            // long enough that a blank window here would read as frozen, so this state is its own
            // visible case rather than folded into `.locked`.
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
                settings: environment.settings,
                // The toolbar's Lock button asks the tab list, not the controller, so it gets the
                // unsaved-changes prompt ⌘L gets (issue #172). Injected rather than read out of
                // the environment inside the browser for the reason that view's own `autoLock`
                // doc comment gives: an environment lookup that resolves to nothing would let the
                // button go quietly inert.
                onLockRequested: { environment.sessionList.requestLock(session.id) }
            )
            .accessibilityIdentifier("root.browser")
        }
    }

    /// Replies to AppKit's parked `.terminateLater` **exactly once**, and dismisses the prompt.
    ///
    /// Both halves are load-bearing. Never replying hangs ⌘Q forever — the app simply stops
    /// quitting, with no error and nothing on screen to explain it. Replying twice answers a
    /// request that no longer exists. `isQuitPending` is the parked-request flag, so clearing it
    /// before the reply makes the count exactly one however this is reached: a button's action and
    /// the `isPresented` binding's own set-to-false both land here, and the second call finds the
    /// flag already down.
    private func answerQuit(_ shouldTerminate: Bool) {
        guard environment.sessionList.isQuitPending else { return }
        environment.sessionList.endQuitRequest()
        if shouldTerminate { environment.sessionList.prepareToQuit() }
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
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
