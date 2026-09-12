import Foundation
import Observation

/// Decides what an "open this `.kdbx`" request should do to an app that holds a list of database
/// tabs, and then carries that decision out.
///
/// **Why this is a type and not a few lines in a view (issue #84).** The same request arrives from
/// three places that share no view: Launch Services (a Finder double-click, `open(1)`, a drop on
/// the Dock icon — see `DocumentOpenReceiver`), the "Open Database…" menu item, and `WelcomeView`'s
/// own button. Two of those can fire while `WelcomeView` is unmounted, so there is no single view
/// that could own the logic; putting it in each of them would be three copies of a rule whose
/// wrong answer is silent data loss. `AppEnvironment` constructs one of these and every entry point
/// routes through it.
///
/// **Issue #47: a second database is a new tab, not a replacement.** The previous `.replace` /
/// `.confirmUnsavedChanges` answers existed because the app held exactly one vault; opening another
/// file meant closing the one that was open. Tabs keep that vault, so the only question left is
/// "is this file already a tab?" Unsaved-changes prompting moved onto *closing* a tab
/// (`VaultSessionList.requestClose`).
///
/// Injected with the `VaultSessionList` it acts on (Dependency Inversion) and holds no reference to
/// AppKit or SwiftUI: `decision(for:)` is answerable from a unit test that never builds a window —
/// see `VaultOpenRoutingTests`. Running `NSOpenPanel` stays with the callers.
@MainActor
@Observable
final class VaultOpenRouter {
    /// What an open request means for the tabs that are currently open.
    ///
    /// A value, not a set of side effects, so the rule can be asserted directly in a test and so
    /// the one branch that needs AppKit (`alreadyOpen`, which brings the window forward) can be
    /// handled by the caller that has a window to bring forward.
    enum Decision: Equatable {
        /// Nothing is open. Add the first tab; `UnlockView` takes it from there.
        case open(URL)
        /// The request names a file that is already a tab. Focus that tab and change **nothing**
        /// else — no lock, no reload, no second copy of the same vault.
        case alreadyOpen(URL)
        /// A different file, added as another tab. The previously front tab is left as it was.
        case addTab(URL)
    }

    private let sessionList: VaultSessionList

    init(sessionList: VaultSessionList) {
        self.sessionList = sessionList
    }

    /// What `requestOpen(_:)` would do, without doing it.
    func decision(for requested: URL) -> Decision {
        if sessionList.session(matching: requested) != nil {
            return .alreadyOpen(requested)
        }
        return sessionList.sessions.isEmpty ? .open(requested) : .addTab(requested)
    }

    /// Acts on `decision(for:)` and returns what it acted on, so a caller with a window can handle
    /// the one branch that needs one (`alreadyOpen`).
    @discardableResult
    func requestOpen(_ requested: URL) -> Decision {
        let decision = decision(for: requested)
        switch decision {
        case .open, .addTab, .alreadyOpen:
            sessionList.open(requested)
        }
        return decision
    }

    // MARK: - Identity

    /// Whether two URLs name the same file on disk.
    ///
    /// Never a raw string comparison: Launch Services hands over a URL it resolved itself, while
    /// `VaultSession.url` is whatever `NSOpenPanel` or a resolved bookmark produced, and the
    /// two routinely differ in spelling for the same file — `/tmp/x.kdbx` against
    /// `/private/tmp/x.kdbx`, a `/./` component, a percent-encoding difference. Getting this wrong
    /// turns "the file is already a tab" into "open it again", which is the duplicate-tab outcome
    /// issue #47 rules out.
    ///
    /// Standardised *and* symlink-resolved: standardisation alone does not collapse the
    /// `/tmp` → `/private/tmp` symlink that both the system and this app's own tests hit.
    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath()
            == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }
}
