import Foundation
import XCTest

@testable import PassSumo

/// The automatic Touch ID prompt (issue #69), as pure logic.
///
/// **This suite carries the whole feature.** The Mac this repo is developed on is a Mac mini with
/// no Touch ID sensor, and `make test` builds unsigned, so no test here — or anywhere — can raise
/// a real biometric sheet and watch what happens (hardware validation is issue #21). What CAN be
/// verified without hardware is every rule about *when* the sheet is raised, which is exactly why
/// those rules live in `AutomaticBiometricUnlockPolicy` and not inside `UnlockView`'s `.task`.
@MainActor
final class SecurityAutomaticBiometricUnlockTests: XCTestCase {
    /// The situation the feature is FOR: an enrolled database, working hardware, our window in
    /// front, and a lock the user did not ask for. Every test below states only its difference
    /// from this, so a test's subject is the line it changes.
    private func conditions(
        isEnrolledForThisVault: Bool = true,
        availabilityError: BiometricUnlockError? = nil,
        isWindowActive: Bool = true,
        lastLockReason: LockReason? = .idleTimeout
    ) -> AutomaticBiometricUnlockPolicy.Conditions {
        AutomaticBiometricUnlockPolicy.Conditions(
            isEnrolledForThisVault: isEnrolledForThisVault,
            availabilityError: availabilityError,
            isWindowActive: isWindowActive,
            lastLockReason: lastLockReason
        )
    }

    // MARK: - The happy path

    func testPromptsOnceWhenEverythingHolds() {
        let policy = AutomaticBiometricUnlockPolicy()
        XCTAssertFalse(policy.hasAttemptedThisLockedSession)

        XCTAssertTrue(policy.claimAutomaticAttempt(conditions()))
        XCTAssertTrue(policy.hasAttemptedThisLockedSession)
    }

    /// A database picked but never yet unlocked in this launch has no lock reason at all. That is
    /// the cold-launch case the whole feature is for, so `nil` must not be mistaken for "unknown,
    /// therefore don't".
    func testNoLockReasonYetStillPrompts() {
        let policy = AutomaticBiometricUnlockPolicy()
        XCTAssertTrue(policy.claimAutomaticAttempt(conditions(lastLockReason: nil)))
    }

    func testEveryAutomaticLockReasonStillPrompts() {
        for reason in [LockReason.idleTimeout, .systemSleep, .screenLocked, .sessionResignedActive] {
            let policy = AutomaticBiometricUnlockPolicy()
            XCTAssertTrue(
                policy.claimAutomaticAttempt(conditions(lastLockReason: reason)),
                "\(reason) suppressed the automatic prompt; only .userRequested may"
            )
        }
    }

    // MARK: - At most one attempt per locked session

    /// The core of the policy. A second prompt after the first was answered — or cancelled — is
    /// the loop the issue exists to prevent; the manual button is the retry.
    func testASecondAskInTheSameLockedSessionIsRefused() {
        let policy = AutomaticBiometricUnlockPolicy()
        XCTAssertTrue(policy.claimAutomaticAttempt(conditions()))

        XCTAssertFalse(policy.claimAutomaticAttempt(conditions()))
        XCTAssertFalse(policy.claimAutomaticAttempt(conditions()))
    }

    /// A user who cancelled the sheet is back at the master-password field, and the window is
    /// still active — nothing about the conditions has changed, so only the spent attempt stands
    /// between them and a second sheet. `UnlockView` re-asks whenever the window becomes active
    /// again (⌘-tab away and back), which is precisely this call.
    func testAfterACancelTheWindowComingBackDoesNotRePrompt() {
        let policy = AutomaticBiometricUnlockPolicy()
        XCTAssertTrue(policy.claimAutomaticAttempt(conditions()))

        // The cancel itself is not modelled here: it changes nothing the policy reads. What
        // follows a cancel is the user leaving and returning.
        XCTAssertFalse(policy.claimAutomaticAttempt(conditions(isWindowActive: false)))
        XCTAssertFalse(policy.claimAutomaticAttempt(conditions(isWindowActive: true)))
    }

    func testUnlockingRearmsTheNextLockedSession() {
        let policy = AutomaticBiometricUnlockPolicy()
        XCTAssertTrue(policy.claimAutomaticAttempt(conditions()))
        XCTAssertFalse(policy.claimAutomaticAttempt(conditions()))

        policy.rearm()

        XCTAssertFalse(policy.hasAttemptedThisLockedSession)
        XCTAssertTrue(policy.claimAutomaticAttempt(conditions()), "a fresh lock got no prompt")
    }

    // MARK: - Gates

    /// Locking on purpose and being asked to unlock a second later is absurd. This is the reason
    /// `.userRequested` had to start being produced at all (see `AutoLockController`).
    func testALockTheUserAskedForSuppressesThePrompt() {
        let policy = AutomaticBiometricUnlockPolicy()
        XCTAssertFalse(policy.claimAutomaticAttempt(conditions(lastLockReason: .userRequested)))
    }

    func testNothingEnrolledForThisDatabaseSuppressesThePrompt() {
        let policy = AutomaticBiometricUnlockPolicy()
        XCTAssertFalse(policy.claimAutomaticAttempt(conditions(isEnrolledForThisVault: false)))
    }

    /// No sensor, no enrolled finger, or a lockout: a sheet would appear only to fail.
    func testAnyAvailabilityErrorSuppressesThePrompt() {
        for error in [BiometricUnlockError.biometricsUnavailable, .biometricsNotEnrolled, .biometricsLockedOut] {
            let policy = AutomaticBiometricUnlockPolicy()
            XCTAssertFalse(
                policy.claimAutomaticAttempt(conditions(availabilityError: error)),
                "prompted despite \(error)"
            )
        }
    }

    /// Never prompt a background app: a system biometric sheet over whatever the user is actually
    /// doing is worse than a button.
    func testAnInactiveWindowSuppressesThePrompt() {
        let policy = AutomaticBiometricUnlockPolicy()
        XCTAssertFalse(policy.claimAutomaticAttempt(conditions(isWindowActive: false)))
    }

    // MARK: - A refusal must not spend the attempt

    /// The difference between "not yet" and "never". An app launched into the background would
    /// otherwise come to the front having silently decided this locked session gets no prompt.
    func testAnInactiveWindowDoesNotSpendTheAttempt() {
        let policy = AutomaticBiometricUnlockPolicy()
        XCTAssertFalse(policy.claimAutomaticAttempt(conditions(isWindowActive: false)))
        XCTAssertFalse(policy.hasAttemptedThisLockedSession)

        XCTAssertTrue(policy.claimAutomaticAttempt(conditions(isWindowActive: true)))
    }

    /// Same reasoning for every other gate: `UnlockView` asks again on each window activation, so
    /// a refusal that spent the attempt would be a permanent one. Enrollment in particular can
    /// change mid-session — `.invalidatedByBiometryChange` clears it, and Settings can re-enable
    /// it — without the vault ever unlocking in between.
    func testARefusedAskLeavesTheAttemptAvailable() {
        let policy = AutomaticBiometricUnlockPolicy()
        XCTAssertFalse(policy.claimAutomaticAttempt(conditions(isEnrolledForThisVault: false)))
        XCTAssertFalse(policy.claimAutomaticAttempt(conditions(availabilityError: .biometricsLockedOut)))
        XCTAssertFalse(policy.claimAutomaticAttempt(conditions(lastLockReason: .userRequested)))
        XCTAssertFalse(policy.hasAttemptedThisLockedSession)

        XCTAssertTrue(policy.claimAutomaticAttempt(conditions()))
    }
}
