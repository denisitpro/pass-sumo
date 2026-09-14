import Foundation
import Observation

/// One open database: its own `VaultStore`, idle clock, and automatic Touch ID policy.
///
/// **Auto-lock is per-session, not one clock for the front tab.** A background tab that stayed
/// decrypted forever is the threat this exists to close — each session starts its own idle timer
/// on unlock, and a stale tab locks even while the user is working in another one. System events
/// (sleep, screen lock, fast user switching) are observed independently by each controller and
/// lock every unlocked session.
@MainActor
@Observable
final class VaultSession: Identifiable {
    let id = UUID()
    /// Identity for this tab. Compared with `VaultOpenRouter.isSameFile`, never by string equality.
    let url: URL
    let store: VaultStore
    let autoLock: AutoLockController
    /// What a lock actually does to this session — see `SessionLockPolicy`.
    let lockPolicy: SessionLockPolicy
    let automaticBiometricUnlock = AutomaticBiometricUnlockPolicy()

    var title: String { url.lastPathComponent }

    var isUnlocked: Bool {
        if case .unlocked = store.state { return true }
        return false
    }

    init(
        url: URL,
        codec: any VaultCodec,
        fileAccess: any VaultFileAccess,
        autoLockTimeout: TimeInterval,
        clipboard: ClipboardService
    ) {
        self.url = url
        let store = VaultStore(codec: codec, fileAccess: fileAccess)
        self.store = store
        // Built in this order because each link needs the one before it: the policy needs the
        // store and the pasteboard, the controller needs the policy's handler at init, and the
        // policy needs the controller back to report a lock it declined — which is the one
        // reference that has to be assigned afterwards, and is weak.
        let lockPolicy = SessionLockPolicy(store: store, clipboard: clipboard)
        self.lockPolicy = lockPolicy
        self.autoLock = AutoLockController(idleTimeout: autoLockTimeout, onLock: { reason in
            lockPolicy.handleLock(reason: reason)
        })
        lockPolicy.controller = autoLock
    }

    /// Mirrors `VaultStore.state` into this session's auto-lock and Touch ID policy. Called from
    /// `SessionLifecycleMonitor` for every session, including background tabs — a lock that
    /// happens because *this* store changed (idle timer, ⌘L, an unlock) must not be inferred from
    /// whichever session happens to be selected.
    func handleStoreStateChange(from oldState: VaultStore.State, to newState: VaultStore.State) {
        switch newState {
        case .unlocked:
            // `.unlocked` carries the vault, so an in-place edit looks like a state change.
            // Unlock side effects run only when arriving from a non-unlocked state.
            if case .unlocked = oldState { break }
            autoLock.vaultDidUnlock()
            automaticBiometricUnlock.rearm()
        case .locked(let url):
            autoLock.stop()
            if case .locked(let previousURL) = oldState, previousURL != url {
                autoLock.forgetLockReason()
            }
        case .empty:
            autoLock.stop()
        case .unlocking:
            break
        }
    }
}

/// What a lock does to one session: the pasteboard first, then the vault — and, for a lock the
/// user could not be asked about, an auto-save before the vault is dropped.
///
/// **`VaultStore.lock()` stays the security primitive that drops plaintext; the policy lives
/// here** (issue #172). That split is the same one `select(url:)` already draws for issue #84: the
/// store refuses to discard unsaved work, and what to do about it — prompt, save, refuse — is
/// decided a layer up, where there is a pasteboard, a tab list and a user to ask.
///
/// A type of its own rather than a method on `VaultSession`, for two reasons. Construction order
/// is one: `AutoLockController` takes its `onLock` handler at init, and a closure calling back
/// into the session cannot be written before the session's own stored properties — that
/// controller among them — are initialised, whereas a policy built *before* the controller needs
/// no weak-self dance and no forwarding object to break the cycle. The other is that this is
/// where the issue's decision lives, and it is worth exercising against a store and a pasteboard
/// with no tab list, no window and no timer anywhere in the picture.
@MainActor
final class SessionLockPolicy {
    private let store: VaultStore
    private let clipboard: ClipboardService

    /// Weak because the controller owns the closure that owns this policy, so a strong reference
    /// back would close the cycle. Assigned once, by `VaultSession.init`, as soon as the
    /// controller it points at exists.
    weak var controller: AutoLockController?

    init(store: VaultStore, clipboard: ClipboardService) {
        self.store = store
        self.clipboard = clipboard
    }

    /// Every lock this session's controller decides on arrives here — see `AutoLockController`'s
    /// `onLock`.
    func handleLock(reason: LockReason) {
        // The pasteboard goes first, for every reason, including the ones that end up leaving the
        // vault open below (audit finding M1). A password we put there is the one secret that
        // outlives this process, the user is provably away for every automatic reason and has just
        // asked to lock for the other one, and `clearNow()` already declines to touch a pasteboard
        // somebody else has taken over since.
        clipboard.clearNow()

        // Everything except an automatic lock of a vault with unsaved edits is settled right here,
        // synchronously. That is not an optimisation: `WorkspaceLockEventSource` goes out of its
        // way to deliver `.systemSleep` with no hop through a `Task` (see its `observe`), and
        // making this path async unconditionally would hand that whole window back.
        guard reason != .userRequested, store.isDirty else {
            store.lock()
            return
        }
        Task { [weak self] in await self?.saveThenLock() }
    }

    /// Drops the decrypted vault and anything of ours on the pasteboard, with no policy attached —
    /// for callers that have already settled what happens to unsaved edits, i.e. closing a tab.
    func lockNow() {
        clipboard.clearNow()
        store.lock()
    }

    /// The automatic path with unsaved edits: idle timeout, sleep, screen lock, fast user
    /// switching. There is nobody at the keyboard to prompt, so the edits are written rather than
    /// discarded — discarding them silently on a timer is the defect (audit finding H1).
    ///
    /// **A failed save leaves the vault unlocked, for every reason, sleep included.** The two
    /// harms are not symmetrical. A lock that did not happen is recoverable: the user comes back
    /// to a vault that is still open, with the failure already on screen (`VaultStore.lastError`,
    /// read by `VaultBrowserView` into `StatusBar.saveError` exactly as for a failed ⌘S — issue
    /// #203; before that fix this claim was false, and `StatusBar` showed nothing), and can fix
    /// the cause and lock. Edits
    /// dropped along with the decrypted vault exist nowhere at all — not in the file, because the
    /// save is what failed, and not in the pre-save backup, which is a copy of the file as it was
    /// *before* them. So this refuses to trade a possible exposure for a certain, irreversible
    /// loss. It also is not the whole exposure it looks like: for `.systemSleep` and
    /// `.screenLocked` the Mac's own login screen is already in front of this window.
    ///
    /// `lockDeclined()` re-arms the idle clock rather than abandoning the attempt, so a save that
    /// starts working — the volume came back, the disk was freed — locks the vault on the next
    /// round instead of leaving it open until somebody notices.
    ///
    /// Internal rather than private **because it is the test seam**: the suite drives it directly
    /// against a file access that refuses to write, with no timer and no notification involved.
    func saveThenLock() async {
        await store.save()
        // `isDirty`, not `lastError`: a save can succeed and still leave edits unwritten, because
        // an edit that landed while Argon2 was running is deliberately not claimed as saved
        // (issue #27's `editRevision` rule). Those edits are as unwritten as a failed save's.
        guard !store.isDirty else {
            controller?.lockDeclined()
            return
        }
        store.lock()
    }
}

/// Ordered tabs plus the selected one. The only type that adds or drops a `VaultSession`.
///
/// Opening a file that is already a tab focuses it rather than duplicating it (issue #47). Closing
/// the last tab leaves this list empty — `RootView` then shows Welcome. Unsaved-changes prompting
/// belongs to *closing* a tab, not to opening a second database: the second database is another
/// tab, so the first vault is not being discarded.
@MainActor
@Observable
final class VaultSessionList {
    private(set) var sessions: [VaultSession] = []
    private(set) var selectedID: UUID?

    /// The tab a close request is waiting on a Save / Discard / Cancel answer for.
    private(set) var unsavedChangesCloseID: UUID?

    /// The tab a user-requested lock is waiting on that same answer for (issue #172).
    private(set) var unsavedChangesLockID: UUID?

    /// Whether ⌘Q is parked on that answer. One flag for the whole app rather than per tab: the
    /// question is "may the process exit", and it is asked once however many tabs are dirty.
    private(set) var isQuitPending = false

    var selected: VaultSession? {
        sessions.first { $0.id == selectedID }
    }

    var unsavedChangesCloseSession: VaultSession? {
        guard let unsavedChangesCloseID else { return nil }
        return sessions.first { $0.id == unsavedChangesCloseID }
    }

    var unsavedChangesLockSession: VaultSession? {
        guard let unsavedChangesLockID else { return nil }
        return sessions.first { $0.id == unsavedChangesLockID }
    }

    /// Every tab with edits that are not on disk, in tab order — what the quit prompt names.
    var dirtySessions: [VaultSession] {
        sessions.filter(\.store.isDirty)
    }

    /// The first tab whose last save refused because the file had changed underneath it (issue
    /// #173), or `nil` when none has. What `RootView`'s external-change prompt is about.
    ///
    /// **Derived, not parked on a flag like the close/lock/quit requests above.** Those three are
    /// questions the user asked and this list has to remember until they answer. This one is a
    /// condition a store is already in, reached from paths this list does not drive — ⌘S in the
    /// browser, a background tab's auto-lock save, the Touch ID enrolment save — so a flag would
    /// have to be set by every one of them, and whichever one forgot would leave a save refused
    /// with nothing on screen. Reading the stores cannot fall out of step with them.
    ///
    /// **Per-tab, and that is the point.** The prompt has to be about the store that actually
    /// refused. Binding it to `AppEnvironment.store`, which resolves to whichever tab is selected,
    /// would let a background tab's conflict be answered by an Overwrite aimed at the front one.
    ///
    /// `first` rather than all of them: two tabs in conflict are asked about one at a time, the
    /// next appearing once the first is settled.
    var externalChangeSession: VaultSession? {
        sessions.first { $0.store.lastError == .externallyModified }
    }

    /// Dismisses the external-change prompt for the tab it is about, leaving that tab's edits
    /// exactly as dirty as they were.
    func acknowledgeExternalChange() {
        externalChangeSession?.store.acknowledgeExternalChange()
    }

    private let codec: any VaultCodec
    private let fileAccess: any VaultFileAccess
    /// The app's single `ClipboardService`, handed to every session's lock policy and used
    /// directly on the quit path. One instance, not one per tab: there is one system pasteboard,
    /// and its `changeCount` ownership check only works if a single object remembers what it put
    /// there.
    private let clipboard: ClipboardService
    private var autoLockTimeout: TimeInterval

    init(
        codec: any VaultCodec,
        fileAccess: any VaultFileAccess,
        autoLockTimeout: TimeInterval,
        clipboard: ClipboardService
    ) {
        self.codec = codec
        self.fileAccess = fileAccess
        self.autoLockTimeout = autoLockTimeout
        self.clipboard = clipboard
    }

    func session(matching url: URL) -> VaultSession? {
        sessions.first { VaultOpenRouter.isSameFile($0.url, url) }
    }

    /// Selects `id` if it names a live session. Noting activity on an unlocked tab is what
    /// keeps switching to it from looking like idleness on that session's own clock.
    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
        if let session = selected, session.isUnlocked {
            session.autoLock.noteActivity()
        }
    }

    /// Adds a tab for `url`, or focuses the existing one. The new store is left `.locked` —
    /// `UnlockView` takes it from there. `createDatabase` is the path that unlocks immediately.
    @discardableResult
    func open(_ url: URL) -> VaultSession {
        if let existing = session(matching: url) {
            selectedID = existing.id
            return existing
        }
        let session = makeSession(url: url)
        session.store.select(url: url)
        sessions.append(session)
        selectedID = session.id
        return session
    }

    /// Builds an empty database in a fresh session and, on success, adds it as the front tab.
    /// Failure does not leave a zombie tab: the session is discarded and the caller reads
    /// `lastError` off the returned store.
    func createDatabase(at url: URL, credentials: VaultCredentials) async -> VaultStore {
        let session = makeSession(url: url)
        await session.store.createNew(at: url, credentials: credentials)
        if case .unlocked = session.store.state {
            sessions.append(session)
            selectedID = session.id
        }
        return session.store
    }

    func applyAutoLockTimeout(_ timeout: TimeInterval) {
        autoLockTimeout = timeout
        for session in sessions {
            session.autoLock.idleTimeout = timeout
        }
    }

    // MARK: - Close

    enum CloseDecision: Equatable {
        case closed
        case confirmUnsavedChanges
        case ignored
    }

    /// Closes `id` immediately when it is clean (or when the user already answered Discard). A
    /// dirty tab parks the request on `unsavedChangesCloseID` instead. Unlocking is ignored —
    /// dropping the store while Argon2 is still running would let the completion hop back onto a
    /// deallocated object.
    @discardableResult
    func requestClose(_ id: UUID) -> CloseDecision {
        guard let session = sessions.first(where: { $0.id == id }) else { return .ignored }
        if case .unlocking = session.store.state { return .ignored }
        if session.store.isDirty {
            unsavedChangesCloseID = id
            return .confirmUnsavedChanges
        }
        drop(id)
        return .closed
    }

    func requestCloseSelected() -> CloseDecision {
        guard let selectedID else { return .ignored }
        return requestClose(selectedID)
    }

    func cancelClose() {
        unsavedChangesCloseID = nil
    }

    func discardThenClosePending() {
        guard let id = unsavedChangesCloseID else { return }
        unsavedChangesCloseID = nil
        drop(id)
    }

    /// "Save": write the tab, then drop it. A failed save, or an edit that landed during Argon2
    /// (issue #27's `editRevision` rule), leaves the tab standing — same as the old replace-prompt.
    func saveThenClosePending() async {
        guard let id = unsavedChangesCloseID,
              let session = sessions.first(where: { $0.id == id })
        else { return }
        await session.store.save()
        guard session.store.lastError == nil else {
            unsavedChangesCloseID = nil
            return
        }
        guard !session.store.isDirty else { return }
        unsavedChangesCloseID = nil
        drop(id)
    }

    private func drop(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        session.autoLock.stop()
        // Through the policy, not `store.lock()`: closing a tab drops that vault, so it clears the
        // pasteboard for the same reason every other lock does (audit finding M1). Whether the
        // unsaved edits may go was already answered — a dirty tab cannot reach `drop` without
        // passing the Save / Discard prompt above.
        session.lockPolicy.lockNow()
        sessions.remove(at: index)
        if unsavedChangesCloseID == id {
            unsavedChangesCloseID = nil
        }
        guard selectedID == id else { return }
        if sessions.indices.contains(index) {
            selectedID = sessions[index].id
        } else if sessions.indices.contains(index - 1) {
            selectedID = sessions[index - 1].id
        } else {
            selectedID = nil
        }
    }

    // MARK: - Lock (issue #172)

    enum LockDecision: Equatable {
        case locked
        case confirmUnsavedChanges
        case ignored
    }

    /// "Lock Database" (⌘L) and the browser toolbar's Lock button. A clean tab locks immediately;
    /// a dirty one parks the request on `unsavedChangesLockID` and `RootView` asks Save / Discard
    /// / Cancel — the same prompt, and the same three answers, closing a dirty tab already gets.
    ///
    /// **The dirty question is settled here, above the controller, and that is what keeps the lock
    /// path single-pass.** By the time `AutoLockController.lockRequestedByUser()` is called — from
    /// this method, or from Discard/Save below — the answer is already known, which is why
    /// `SessionLockPolicy` can treat `.userRequested` as "drop it" with no second guard and no way
    /// back into this decision.
    @discardableResult
    func requestLock(_ id: UUID) -> LockDecision {
        guard let session = sessions.first(where: { $0.id == id }), session.isUnlocked else {
            return .ignored
        }
        if session.store.isDirty {
            unsavedChangesLockID = id
            return .confirmUnsavedChanges
        }
        session.autoLock.lockRequestedByUser()
        return .locked
    }

    @discardableResult
    func requestLockSelected() -> LockDecision {
        guard let selectedID else { return .ignored }
        return requestLock(selectedID)
    }

    func cancelLock() {
        unsavedChangesLockID = nil
    }

    /// "Discard": the user has said the unsaved edits may go, so the lock proceeds on a vault that
    /// is still dirty. This is the one path where dropping them is not silent.
    func discardThenLockPending() {
        guard let id = unsavedChangesLockID,
              let session = sessions.first(where: { $0.id == id })
        else { return }
        unsavedChangesLockID = nil
        session.autoLock.lockRequestedByUser()
    }

    /// "Save": write the tab, then lock it. A failed save, or an edit that landed during Argon2
    /// (issue #27's `editRevision` rule), leaves the vault unlocked with the edits intact — same
    /// shape, and the same reasoning, as `saveThenClosePending()`.
    func saveThenLockPending() async {
        guard let id = unsavedChangesLockID,
              let session = sessions.first(where: { $0.id == id })
        else { return }
        await session.store.save()
        guard session.store.lastError == nil else {
            unsavedChangesLockID = nil
            return
        }
        guard !session.store.isDirty else { return }
        unsavedChangesLockID = nil
        session.autoLock.lockRequestedByUser()
    }

    // MARK: - Quit (issue #172)

    enum QuitDecision: Equatable {
        case quitNow
        case confirmUnsavedChanges
        /// A quit request arrived while an earlier one is still parked on its prompt.
        case alreadyAsking
    }

    /// Whether ⌘Q may proceed. Called from `applicationShouldTerminate`, which turns the answer
    /// into a `TerminateReply` — this method deliberately knows nothing about `NSApplication`, so
    /// the decision is assertable without an app to quit.
    ///
    /// `.alreadyAsking` is not a defensive nicety. A second ⌘Q while the prompt is up makes AppKit
    /// ask again, and answering both requests with the one `reply(toApplicationShouldTerminate:)`
    /// the prompt will send leaves the other one parked forever — an app that can no longer be
    /// quit. The caller cancels the duplicate instead, leaving the first request and its prompt
    /// exactly as they were.
    func requestQuit() -> QuitDecision {
        if isQuitPending { return .alreadyAsking }
        guard dirtySessions.isEmpty else {
            isQuitPending = true
            return .confirmUnsavedChanges
        }
        prepareToQuit()
        return .quitNow
    }

    /// Takes the quit request off the prompt. Whoever calls this owns replying to AppKit, and the
    /// flag going false is what makes that reply exactly-once (see `RootView`).
    func endQuitRequest() {
        isQuitPending = false
    }

    /// Saves every dirty tab and reports whether they are all clean afterwards, i.e. whether the
    /// process may exit. Saves them all rather than stopping at the first failure: one database on
    /// an unreachable volume must not cost the others their edits.
    func saveDirtySessionsForQuit() async -> Bool {
        for session in dirtySessions {
            await session.store.save()
        }
        return dirtySessions.isEmpty
    }

    /// The last thing that runs before the process exits. Only the pasteboard needs it: the
    /// decrypted vaults die with the address space, while a password we copied outlives us
    /// (audit finding M1), and `clearNow()` still leaves alone a pasteboard somebody else owns.
    func prepareToQuit() {
        clipboard.clearNow()
    }

    private func makeSession(url: URL) -> VaultSession {
        VaultSession(
            url: url,
            codec: codec,
            fileAccess: fileAccess,
            autoLockTimeout: autoLockTimeout,
            clipboard: clipboard
        )
    }
}
