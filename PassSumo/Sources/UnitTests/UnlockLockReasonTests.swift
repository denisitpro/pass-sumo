import XCTest

@testable import PassSumo

/// `UnlockView.lockReasonNote`: the mapping from `AutoLockController.lastLockReason` to the short,
/// calm sentence issue #62 asks for.
///
/// Drives the real computed property on a real `UnlockView` value — no rendering, the same pattern
/// `EntryEditSaveTests` uses for `EntryEditView.save()` — rather than re-implementing the switch
/// here, which would only agree with itself about what each case should say.
@MainActor
final class UnlockLockReasonTests: XCTestCase {
    private func makeView() -> UnlockView {
        UnlockView(environment: .uiTesting(), url: URL(fileURLWithPath: "/unlock-lock-reason-tests/vault.kdbx"))
    }

    // MARK: - No reason to show

    /// A database just selected but never unlocked this session: `AutoLockController` starts with
    /// `lastLockReason == nil`, and this must stay the neutral no-reason case, never a guess.
    func testNoLockYetShowsNoReason() {
        let view = makeView()
        XCTAssertNil(view.environment.autoLock.lastLockReason)
        XCTAssertNil(view.lockReasonNote)
    }

    /// The user just clicked Lock / hit ⌘L — explaining that back to them is telling them
    /// something they already know, so `.userRequested` is deliberately not surfaced (per the
    /// issue's own "probably not" note).
    func testUserRequestedLockShowsNoReason() {
        let view = makeView()
        view.environment.autoLock.vaultDidUnlock()
        view.environment.autoLock.lockRequestedByUser()
        XCTAssertEqual(view.environment.autoLock.lastLockReason, .userRequested)
        XCTAssertNil(view.lockReasonNote)
    }

    // MARK: - Reasons that are shown

    func testIdleTimeoutReason() {
        let view = makeView()
        view.environment.autoLock.vaultDidUnlock()
        view.environment.autoLock.lock(reason: .idleTimeout)
        XCTAssertEqual(view.lockReasonNote, "Locked after a period of inactivity.")
    }

    func testSystemSleepReason() {
        let view = makeView()
        view.environment.autoLock.vaultDidUnlock()
        view.environment.autoLock.lock(reason: .systemSleep)
        XCTAssertEqual(view.lockReasonNote, "Locked because the Mac went to sleep.")
    }

    func testScreenLockedReason() {
        let view = makeView()
        view.environment.autoLock.vaultDidUnlock()
        view.environment.autoLock.lock(reason: .screenLocked)
        XCTAssertEqual(view.lockReasonNote, "Locked because the screen locked.")
    }

    func testSessionResignedActiveReason() {
        let view = makeView()
        view.environment.autoLock.vaultDidUnlock()
        view.environment.autoLock.lock(reason: .sessionResignedActive)
        XCTAssertEqual(view.lockReasonNote, "Locked because you switched to another user.")
    }

    // MARK: - Staleness across a database switch (issue #62's `forgetLockReason()`)

    /// The mapping itself has no notion of "which vault" — that guarantee lives in
    /// `AutoLockController.forgetLockReason()` and `PassSumoApp`'s state mirror, not here. This
    /// pins the seam `lockReasonNote` depends on: once the reason is cleared, the note goes back to
    /// the neutral no-reason case, the same as a database that was never locked at all.
    func testClearedReasonShowsNoReason() {
        let view = makeView()
        view.environment.autoLock.vaultDidUnlock()
        view.environment.autoLock.lock(reason: .screenLocked)
        XCTAssertNotNil(view.lockReasonNote)

        view.environment.autoLock.forgetLockReason()
        XCTAssertNil(view.lockReasonNote)
    }
}
