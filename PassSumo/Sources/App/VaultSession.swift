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
    let clipboard: ClipboardService
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
        self.clipboard = clipboard
        let bridge = AutomaticLockBridge()
        self.autoLock = AutoLockController(idleTimeout: autoLockTimeout, onLock: { [bridge] reason in
            bridge.fire(reason)
        })
        bridge.session = self
    }

    /// Idle / sleep / screen-lock: auto-save a dirty vault, then drop it. A failed idle save
    /// keeps the vault unlocked (issue #172). Sleep and screen-lock still drop after a failed
    /// save — another user could sit down. User-requested locks with a dirty vault never
    /// arrive here; they go through the Save / Discard / Cancel prompt.
    func handleAutomaticLock(reason: LockReason) async {
        if reason == .userRequested {
            clipboard.clearNow()
            store.lock()
            return
        }
        if store.isDirty {
            await store.save()
            if store.isDirty {
                if reason == .idleTimeout {
                    autoLock.recoverFromFailedSave()
                    return
                }
            }
        }
        clipboard.clearNow()
        store.lock()
    }

    func lockNow() {
        clipboard.clearNow()
        store.lock()
        autoLock.lockRequestedByUser()
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

    /// The tab a user-requested lock is waiting on a Save / Discard / Cancel answer for (issue #172).
    private(set) var unsavedChangesLockID: UUID?

    /// ⌘Q is waiting on a Save / Discard / Cancel answer because at least one tab is dirty.
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

    var dirtySessions: [VaultSession] {
        sessions.filter(\.store.isDirty)
    }

    private let codec: any VaultCodec
    private let fileAccess: any VaultFileAccess
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
            // Leave the dialog up so the failure is in-place, not only in the status bar (L10).
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
        session.clipboard.clearNow()
        session.store.lock()
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

    /// User-requested lock (⌘L / toolbar). Dirty tabs prompt; clean ones drop immediately.
    @discardableResult
    func requestLockSelected() -> LockDecision {
        guard let session = selected, session.isUnlocked else { return .ignored }
        if session.store.isDirty {
            unsavedChangesLockID = session.id
            return .confirmUnsavedChanges
        }
        session.lockNow()
        return .locked
    }

    func cancelLock() {
        unsavedChangesLockID = nil
    }

    func discardThenLockPending() {
        guard let id = unsavedChangesLockID,
              let session = sessions.first(where: { $0.id == id })
        else { return }
        unsavedChangesLockID = nil
        session.lockNow()
    }

    func saveThenLockPending() async {
        guard let id = unsavedChangesLockID,
              let session = sessions.first(where: { $0.id == id })
        else { return }
        await session.store.save()
        guard session.store.lastError == nil else { return }
        guard !session.store.isDirty else { return }
        unsavedChangesLockID = nil
        session.lockNow()
    }

    // MARK: - Quit (issue #172)

    /// Returns whether the process may exit now. Dirty tabs park a quit prompt instead.
    func requestQuit() -> Bool {
        if dirtySessions.isEmpty {
            clipboard.clearNow()
            return true
        }
        isQuitPending = true
        return false
    }

    func cancelQuit() {
        isQuitPending = false
    }

    func discardThenQuit() {
        isQuitPending = false
        clipboard.clearNow()
        for session in sessions {
            session.autoLock.stop()
            session.store.lock()
        }
    }

    /// Saves every dirty tab. Returns whether all of them are now clean (so the app may exit).
    func saveThenQuit() async -> Bool {
        for session in dirtySessions {
            await session.store.save()
            if session.store.lastError != nil || session.store.isDirty {
                return false
            }
        }
        isQuitPending = false
        clipboard.clearNow()
        return true
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

/// Breaks the `VaultSession` ↔ `AutoLockController.onLock` init cycle so the controller can
/// call back into the session (which owns the dirty-save policy) without capturing `self`
/// before it exists.
private final class AutomaticLockBridge {
    weak var session: VaultSession?

    func fire(_ reason: LockReason) {
        Task { @MainActor in
            await session?.handleAutomaticLock(reason: reason)
        }
    }
}
