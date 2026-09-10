import Foundation
import Observation

/// Decides what an "open this `.kdbx`" request should do to an app that holds exactly one vault,
/// and then carries that decision out.
///
/// **Why this is a type and not a few lines in a view (issue #84).** The same request arrives from
/// three places that share no view: Launch Services (a Finder double-click, `open(1)`, a drop on
/// the Dock icon — see `DocumentOpenReceiver`), the "Open Database…" menu item, and `WelcomeView`'s
/// own button. Two of those can fire while `WelcomeView` is unmounted, so there is no single view
/// that could own the logic; putting it in each of them would be three copies of a rule whose
/// wrong answer is silent data loss. `AppEnvironment` constructs one of these and every entry point
/// routes through it.
///
/// Injected with the `VaultStore` it acts on (Dependency Inversion, same rule as `VaultStore`'s own
/// collaborators) and holds no reference to AppKit or SwiftUI: `decision(for:)` is answerable from
/// a unit test that never builds a window, which is the whole point — see
/// `VaultOpenRoutingTests`. The two things that genuinely need UI — running `NSOpenPanel`, and
/// presenting the Save/Discard/Cancel dialog — stay with their callers.
///
/// **This is NOT issue #47** (several databases open at the same time). The app stays single-vault
/// and single-window; "open a different database" means the open one is closed first.
@MainActor
@Observable
final class VaultOpenRouter {
    /// What an open request means for the vault that is currently open.
    ///
    /// A value, not a set of side effects, so the rule can be asserted directly in a test and so
    /// the one branch that needs AppKit (`alreadyOpen`, which brings the window forward) can be
    /// handled by the caller that has a window to bring forward.
    enum Decision: Equatable {
        /// Nothing is open. Point the store at the file; `UnlockView` takes it from there.
        case open(URL)
        /// The request names the file that is already open (or already picked and waiting for a
        /// password). Bring the window forward and change **nothing** — no lock, no reload, no
        /// re-selection. Re-opening the front database must not cost the user their place in it.
        case alreadyOpen(URL)
        /// A different file, and nothing unsaved would be lost. Close the open one and take it.
        case replace(URL)
        /// A different file, and the open vault has unsaved edits. Nothing happens until the user
        /// answers Save / Discard / Cancel — `unsavedChangesPrompt` carries the file that is
        /// waiting.
        case confirmUnsavedChanges(URL)
        /// An unlock is already running. Argon2 takes about a second and `VaultStore.open` writes
        /// `state`/`currentURL` when it finishes, so acting on a request now would be overwritten
        /// by that completion — with the *new* file on screen and the *old* vault's contents
        /// behind it. Dropping the request is the only answer here that cannot lie about which
        /// database is open; the user can double-click the file again a second later.
        case ignore(URL)
    }

    private let store: VaultStore

    /// The file an open request is waiting on a Save / Discard / Cancel answer for, or `nil` when
    /// nothing is pending. Read by `RootView` to drive its confirmation dialog; only this type
    /// writes it.
    private(set) var unsavedChangesPrompt: URL?

    init(store: VaultStore) {
        self.store = store
    }

    /// What `requestOpen(_:)` would do, without doing it.
    func decision(for requested: URL) -> Decision {
        if case .unlocking = store.state { return .ignore(requested) }
        if case .empty = store.state { return .open(requested) }
        guard let current = store.currentURL else { return .open(requested) }
        if Self.isSameFile(current, requested) { return .alreadyOpen(requested) }
        return store.isDirty ? .confirmUnsavedChanges(requested) : .replace(requested)
    }

    /// Acts on `decision(for:)` and returns what it acted on, so a caller with a window can handle
    /// the one branch that needs one (`alreadyOpen`).
    ///
    /// A second request arriving while one is already waiting for an answer replaces it: the user
    /// double-clicked a different file, and the newest ask is the one they are looking at.
    @discardableResult
    func requestOpen(_ requested: URL) -> Decision {
        let decision = decision(for: requested)
        switch decision {
        case .open(let url), .replace(let url):
            store.select(url: url)
        case .confirmUnsavedChanges(let url):
            unsavedChangesPrompt = url
        case .alreadyOpen, .ignore:
            // Both are deliberate no-ops on the store — see `Decision`.
            break
        }
        return decision
    }

    // MARK: - Answers to the unsaved-changes prompt

    /// "Save": write the open vault, then open the pending file.
    ///
    /// A save that fails drops the request and leaves the vault open and dirty. Proceeding anyway
    /// is exactly the data loss this prompt exists to prevent, and the failure is already on
    /// `VaultStore.lastError` rather than being invented here.
    func saveThenOpenPending() async {
        guard let pending = unsavedChangesPrompt else { return }
        await store.save()
        guard store.lastError == nil else {
            unsavedChangesPrompt = nil
            return
        }
        // Still dirty after a *successful* save means an edit landed while Argon2 was running, and
        // `VaultStore` deliberately does not credit that save with it (issue #27's `editRevision`
        // rule). The answer the user gave covered the vault as it was, not as it now is — so leave
        // the prompt standing and ask again rather than discarding an edit they never saw the
        // question about.
        guard !store.isDirty else { return }
        unsavedChangesPrompt = nil
        store.select(url: pending)
    }

    /// "Discard": throw the unsaved edits away and open the pending file. The only caller allowed
    /// to pass `discardingUnsavedChanges:` — see `VaultStore.select(url:discardingUnsavedChanges:)`.
    func discardThenOpenPending() {
        guard let pending = unsavedChangesPrompt else { return }
        unsavedChangesPrompt = nil
        store.select(url: pending, discardingUnsavedChanges: true)
    }

    /// "Cancel": a true no-op. The request is dropped and nothing about the open vault — its state,
    /// its dirty flag, its selection — is touched.
    func cancelPending() {
        unsavedChangesPrompt = nil
    }

    // MARK: - Identity

    /// Whether two URLs name the same file on disk.
    ///
    /// Never a raw string comparison: Launch Services hands over a URL it resolved itself, while
    /// `VaultStore.currentURL` is whatever `NSOpenPanel` or a resolved bookmark produced, and the
    /// two routinely differ in spelling for the same file — `/tmp/x.kdbx` against
    /// `/private/tmp/x.kdbx`, a `/./` component, a percent-encoding difference. Getting this wrong
    /// turns "the file is already open" into "close it and reopen it", which is precisely the
    /// lock-and-lose-your-place outcome issue #84 rules out.
    ///
    /// Standardised *and* symlink-resolved: standardisation alone does not collapse the
    /// `/tmp` → `/private/tmp` symlink that both the system and this app's own tests hit.
    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath()
            == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }
}
