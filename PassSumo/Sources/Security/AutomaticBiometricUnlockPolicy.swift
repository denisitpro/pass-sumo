import Foundation

/// Whether the unlock screen may raise the system Touch ID sheet **by itself**, with no click
/// (issue #69).
///
/// A separate type rather than a pile of conditions inside `UnlockView`'s `.task`, for the same
/// reason `BiometricUnlockRecovery` is one: the decision is the whole feature, this Mac has no
/// Touch ID sensor to exercise it on, and a rule buried in a view body is only testable by driving
/// real SwiftUI. Everything here is plain values and a single `Bool` of state, so the whole policy
/// is covered by `SecurityAutomaticBiometricUnlockTests` without a keychain, a window, or a finger.
///
/// **A class, not a `struct` with a `mutating` decision function, because the one piece of state —
/// "has this locked session already had its automatic attempt" — must outlive `UnlockView`.**
/// The obvious home for it is a `@State` flag on that view, and it is the wrong one: a wrong
/// master password moves `VaultStore.state` `.locked → .unlocking → .locked`, which is a different
/// branch of `RootView`'s switch and therefore destroys and rebuilds `UnlockView` along with all
/// of its `@State`. A flag living there would re-arm on every mistyped password, so cancelling the
/// sheet and then fat-fingering the password would put the sheet straight back up — precisely the
/// loop this policy exists to prevent. `AppEnvironment` owns one instance for the app's lifetime
/// instead, and `PassSumoApp` re-arms it when the vault actually unlocks.
@MainActor
final class AutomaticBiometricUnlockPolicy {
    /// Everything the decision reads. A value type, so a test states a situation outright instead
    /// of arranging a keychain, an `NSWindow` and an `AutoLockController` that between them
    /// produce it.
    struct Conditions {
        /// `BiometricUnlock.isEnabled(for:)` — a secret is stored for **this** database. Nothing
        /// to prompt for otherwise; the sheet would appear only to fail.
        var isEnrolledForThisVault: Bool

        /// `BiometricUnlock.availabilityError()`. Non-`nil` covers no sensor, no enrolled finger,
        /// and the post-too-many-attempts lockout — none of which a prompt can get past.
        var availabilityError: BiometricUnlockError?

        /// The app is active **and** this vault's window is the active one. Never prompt from the
        /// background: a system biometric sheet landing on top of whatever the user is actually
        /// doing is worse than a button. `UnlockView` derives this from SwiftUI's `appearsActive`
        /// environment value — see its call site for exactly what that does and does not promise.
        var isWindowActive: Bool

        /// `AutoLockController.lastLockReason`. `.userRequested` is the one reason that suppresses
        /// the prompt: being asked to unlock half a second after deliberately locking is absurd,
        /// and it is the case where the user most likely walked away on purpose. `nil` — a
        /// database that was picked but never yet unlocked in this launch — is *not* suppressed:
        /// that is the cold-launch case the feature is mostly for.
        var lastLockReason: LockReason?
    }

    /// Whether this locked session's single automatic attempt has been spent. Readable so a test
    /// can assert the claim happened (or did not) without inferring it from a second call.
    private(set) var hasAttemptedThisLockedSession = false

    /// Asks for — and, when granted, **consumes** — this locked session's one automatic attempt.
    ///
    /// Query and consume are one call on purpose. Two (`shouldAttempt` then `recordAttempt`) would
    /// leave a caller able to prompt without claiming, which is the only way this policy can fail
    /// open into the repeating-sheet loop it exists to prevent.
    ///
    /// A refusal never spends the attempt. That matters for `isWindowActive`: the app can perfectly
    /// well be launched into the background, and burning the attempt on a condition that is about
    /// *when* rather than *whether* would mean the user comes back to a window that has silently
    /// decided never to offer them the sheet. `UnlockView` therefore asks again when the window
    /// becomes active, and it is this method returning `false` without a claim that makes asking
    /// again correct rather than a second prompt.
    func claimAutomaticAttempt(_ conditions: Conditions) -> Bool {
        guard !hasAttemptedThisLockedSession else { return false }
        guard conditions.isEnrolledForThisVault else { return false }
        guard conditions.availabilityError == nil else { return false }
        guard conditions.isWindowActive else { return false }
        guard conditions.lastLockReason != .userRequested else { return false }

        hasAttemptedThisLockedSession = true
        return true
    }

    /// Gives the next locked session its attempt back. Called from `PassSumoApp` when the vault
    /// reaches `.unlocked`, i.e. exactly once per genuine unlock — never on the `.unlocking`
    /// round-trip a wrong password causes, which is what keeps a mistyped password from
    /// re-arming the sheet.
    func rearm() {
        hasAttemptedThisLockedSession = false
    }
}
