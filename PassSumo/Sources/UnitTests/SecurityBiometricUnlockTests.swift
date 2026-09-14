import Foundation
import LocalAuthentication
import Security
import XCTest

@testable import PassSumo

/// Everything here runs against `FakeSecretStore`. Nothing in this file reaches
/// `Security.framework` or `LocalAuthentication` in a way that can prompt — see
/// `testRealKeychainIsNotExercisedByThisSuite` at the bottom for why that is a deliberate line and
/// not an oversight.
final class SecurityBiometricUnlockTests: XCTestCase {
    private let vaultA = VaultKeyIdentifier("vault-a")
    private let vaultB = VaultKeyIdentifier("vault-b")

    // MARK: - Identifiers

    /// The identifier must never be a file path. Paths change when the user renames or moves the
    /// database, and iCloud Drive relocates files on its own — each of which would orphan the
    /// keychain item, while a *different* database later landing on the old path would inherit the
    /// previous one's stored master password.
    func testIdentifierIsWhateverTheCallerSuppliesAndIsValueEqual() {
        XCTAssertEqual(VaultKeyIdentifier("abc"), VaultKeyIdentifier("abc"))
        XCTAssertNotEqual(VaultKeyIdentifier("abc"), VaultKeyIdentifier("abd"))
        XCTAssertEqual(VaultKeyIdentifier("abc").rawValue, "abc")
    }

    /// `derived(from:)` hashes so the caller's identifying bytes never reach the keychain's account
    /// attribute, which is readable without authentication.
    func testDerivedIdentifierIsAStableSHA256Hex() {
        let identifier = VaultKeyIdentifier.derived(from: Data("stable-vault-id".utf8))
        XCTAssertEqual(identifier.rawValue.count, 64)
        XCTAssertEqual(identifier, VaultKeyIdentifier.derived(from: Data("stable-vault-id".utf8)))
        XCTAssertNotEqual(identifier, VaultKeyIdentifier.derived(from: Data("other-vault-id".utf8)))
        XCTAssertTrue(identifier.rawValue.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // Known-answer: SHA-256 of the empty input, so a change of hash function is caught rather
        // than merely a change of output length.
        XCTAssertEqual(
            VaultKeyIdentifier.derived(from: Data()).rawValue,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    // MARK: - Enrolment lifecycle

    func testEnableStoresAndUnlockReturnsTheMasterPassword() throws {
        let store = FakeSecretStore()
        let unlock = BiometricUnlock(store: store)

        XCTAssertFalse(unlock.isEnabled(for: vaultA))
        try unlock.enable(masterPassword: SecureBytes(string: "master"), for: vaultA)
        XCTAssertTrue(unlock.isEnabled(for: vaultA))
        XCTAssertEqual(try unlock.unlock(vaultA, reason: "Unlock Personal.kdbx"), SecureBytes(string: "master"))
    }

    func testEnrolmentIsPerDatabase() throws {
        let store = FakeSecretStore()
        let unlock = BiometricUnlock(store: store)
        try unlock.enable(masterPassword: SecureBytes(string: "a"), for: vaultA)

        XCTAssertTrue(unlock.isEnabled(for: vaultA))
        XCTAssertFalse(unlock.isEnabled(for: vaultB))
        XCTAssertThrowsError(try unlock.unlock(vaultB, reason: "")) {
            XCTAssertEqual($0 as? BiometricUnlockError, .notEnrolledForThisVault)
        }
    }

    func testDisableRemovesTheStoredSecret() throws {
        let store = FakeSecretStore()
        let unlock = BiometricUnlock(store: store)
        try unlock.enable(masterPassword: SecureBytes(string: "master"), for: vaultA)

        try unlock.disable(for: vaultA)
        XCTAssertFalse(unlock.isEnabled(for: vaultA))
    }

    func testReEnablingReplacesTheStoredSecret() throws {
        let store = FakeSecretStore()
        let unlock = BiometricUnlock(store: store)
        try unlock.enable(masterPassword: SecureBytes(string: "old"), for: vaultA)
        try unlock.enable(masterPassword: SecureBytes(string: "new"), for: vaultA)
        XCTAssertEqual(try unlock.unlock(vaultA, reason: ""), SecureBytes(string: "new"))
    }

    /// The reason string is what the system sheet shows. It travels through the store rather than
    /// being invented there, so the caller can name the actual database.
    func testUnlockPassesTheCallerSuppliedPromptThrough() throws {
        let store = FakeSecretStore()
        let unlock = BiometricUnlock(store: store)
        try unlock.enable(masterPassword: SecureBytes(string: "master"), for: vaultA)

        _ = try unlock.unlock(vaultA, reason: "Unlock “Work.kdbx”")
        XCTAssertEqual(store.lastReason, "Unlock “Work.kdbx”")
    }

    /// `isEnabled` decides whether the unlock screen even draws a Touch ID button. A throwing
    /// keychain there is not something the user can act on, so it degrades to "no button" rather
    /// than to an error dialog over a screen the user has not interacted with yet.
    func testIsEnabledSwallowsStoreErrors() {
        let store = FakeSecretStore()
        store.nextError = .keychain(errSecNotAvailable)
        XCTAssertFalse(BiometricUnlock(store: store).isEnabled(for: vaultA))
    }

    /// `.invalidatedByBiometryChange` must produce a recovery, never a crash: `BiometricUnlockRecovery`
    /// (`UnlockView.swift`) is the pure decision of whether the stale item should be cleared out,
    /// and this is the one case it says yes to (see that type's own doc comment for why the item is
    /// invalidated-but-still-present rather than gone, and why every other error leaves it alone).
    func testInvalidatedByBiometryChangeProducesTheRecoveryPathNotACrash() throws {
        let store = FakeSecretStore()
        let unlock = BiometricUnlock(store: store)
        try unlock.enable(masterPassword: SecureBytes(string: "master"), for: vaultA)

        store.nextError = .invalidatedByBiometryChange
        XCTAssertThrowsError(try unlock.unlock(vaultA, reason: "")) {
            let error = $0 as? BiometricUnlockError
            XCTAssertEqual(error, .invalidatedByBiometryChange)
            XCTAssertTrue(BiometricUnlockRecovery.shouldClearEnrollment(after: error!))
        }

        // The recovery path itself: disabling the stale item must not throw a second time, and
        // must actually remove it so `isEnabled` — and therefore the "Remember with Touch ID"
        // offer — comes back next time.
        XCTAssertNoThrow(try unlock.disable(for: vaultA))
        XCTAssertFalse(unlock.isEnabled(for: vaultA))
    }

    /// Every OTHER error must leave the stored item alone — it says something about this one
    /// attempt (cancelled, wrong finger, locked out), not about whether the item is still good.
    func testOnlyBiometryChangeTriggersRecovery() {
        let others: [BiometricUnlockError] = [
            .biometricsUnavailable, .biometricsNotEnrolled, .biometricsLockedOut, .userCancelled,
            .authenticationFailed, .notEnrolledForThisVault, .keychain(errSecItemNotFound)
        ]
        for error in others {
            XCTAssertFalse(
                BiometricUnlockRecovery.shouldClearEnrollment(after: error),
                "\(error) must not clear an otherwise-valid enrollment"
            )
        }
        XCTAssertTrue(BiometricUnlockRecovery.shouldClearEnrollment(after: .invalidatedByBiometryChange))
    }

    // MARK: - Stale stored secret (issue #175, audit M5)

    /// Touch ID succeeded, the keychain handed the password over, the database rejected it: the
    /// master password was changed somewhere else and the stored copy is now permanently wrong.
    /// Left alone it auto-prompts, passes, and fails on every launch forever.
    func testAWrongStoredPasswordClearsTheEnrollment() {
        XCTAssertTrue(BiometricUnlockRecovery.shouldClearEnrollment(afterOpenFailedWith: .wrongCredentials))
    }

    /// The narrowness is the point. Every other `VaultError` is about the FILE, not the secret —
    /// an evicted iCloud placeholder is `.io` and happens in normal use — and discarding a working
    /// enrollment over one would force a re-enrol, which WRITES a database ID into the user's
    /// file. `nil` is a successful open and must obviously clear nothing.
    func testAFileLevelFailureNeverClearsAWorkingEnrollment() {
        let fileErrors: [VaultError] = [
            .io("the file is an iCloud placeholder"),
            .notAKDBXFile,
            .unsupportedVersion("2.0"),
            .unsupportedFeature("Twofish"),
            .corrupted("The database header is damaged.", diagnostic: nil)
        ]
        for error in fileErrors {
            XCTAssertFalse(
                BiometricUnlockRecovery.shouldClearEnrollment(afterOpenFailedWith: error),
                "\(error) says nothing about the stored password and must not discard it"
            )
        }
        XCTAssertFalse(BiometricUnlockRecovery.shouldClearEnrollment(afterOpenFailedWith: nil))
    }

    /// The sentence has to survive a reader who is already confused about why Touch ID "worked"
    /// and the vault still did not open: the stored password is gone, type the current one, and
    /// Touch ID is still available to set up again.
    func testTheStaleSecretMessageSaysWhatHappenedAndHowToRecover() {
        let message = BiometricUnlockRecovery.messageAfterStoredSecretRejected()
        XCTAssertTrue(message.lowercased().contains("master password"))
        XCTAssertTrue(message.lowercased().contains("touch id"))
        XCTAssertTrue(message.lowercased().contains("discarded"))
        // Not the store's own line: that one hedges about key files (see `VaultError`'s
        // `displayMessage`), which is noise on a path that knows exactly what went wrong.
        XCTAssertNotEqual(message, VaultError.wrongCredentials.displayMessage)
    }

    /// The recovery is only useful if the user can SEE it. Both messages are set on this path —
    /// the store's `lastError` is `.wrongCredentials` (true of the secret that was just thrown
    /// away) and the biometric one explains the discard — and the original
    /// `lastError ?? biometricFailure` precedence showed the wrong half.
    func testTheStaleSecretMessageWinsOverTheStoresOwnLine() {
        let shown = BiometricUnlockRecovery.visibleUnlockMessage(
            storeMessage: VaultError.wrongCredentials.displayMessage,
            biometricMessage: BiometricUnlockRecovery.messageAfterStoredSecretRejected()
        )
        XCTAssertEqual(shown, BiometricUnlockRecovery.messageAfterStoredSecretRejected())
    }

    /// With no biometric failure pending — every typed unlock — the store's message is still what
    /// shows, and a screen with nothing wrong shows no red line at all.
    func testTheStoreMessageStillShowsWhenNoBiometricFailureIsPending() {
        XCTAssertEqual(
            BiometricUnlockRecovery.visibleUnlockMessage(
                storeMessage: VaultError.wrongCredentials.displayMessage,
                biometricMessage: nil
            ),
            VaultError.wrongCredentials.displayMessage
        )
        XCTAssertNil(BiometricUnlockRecovery.visibleUnlockMessage(storeMessage: nil, biometricMessage: nil))
    }

    /// Clearing an enrollment must be safe to run twice — the invalidated-item path and the
    /// stale-secret path both reach it, and a second pass hits a keychain item that is already
    /// gone. `delete` treats `errSecItemNotFound` as success, so the second call is a no-op rather
    /// than an error thrown out of the middle of a recovery.
    func testClearingAnEnrollmentTwiceIsNotAnError() throws {
        let store = FakeSecretStore()
        let unlock = BiometricUnlock(store: store)
        try unlock.enable(masterPassword: SecureBytes(string: "stale"), for: vaultA)

        XCTAssertNoThrow(try unlock.disable(for: vaultA))
        XCTAssertNoThrow(try unlock.disable(for: vaultA))
        XCTAssertFalse(unlock.isEnabled(for: vaultA))
    }

    /// Cancelling the system sheet is a request to type, not a failure. A red
    /// "Touch ID was cancelled." line reads as the opposite.
    func testCancellingTouchIDShowsNoVisibleError() {
        XCTAssertNil(BiometricUnlockRecovery.visibleMessage(after: .userCancelled))
        XCTAssertFalse(BiometricUnlockRecovery.shouldClearEnrollment(after: .userCancelled))
    }

    func testAuthenticationFailureKeepsItsUserMessage() {
        XCTAssertEqual(
            BiometricUnlockRecovery.visibleMessage(after: .authenticationFailed),
            BiometricUnlockError.authenticationFailed.userMessage
        )
    }

    /// A Button action can capture a View copy whose `@State identifier` is still nil. Retrieve
    /// must then resolve, not `return` (issue #138: click did nothing).
    func testIdentifierForRetrievePrefersTheCachedValue() {
        let cached = VaultKeyIdentifier("cached")
        let resolved = BiometricUnlockRecovery.identifierForRetrieve(cached: cached) {
            VaultKeyIdentifier("fresh")
        }
        XCTAssertEqual(resolved, cached)
    }

    func testIdentifierForRetrieveResolvesWhenTheCacheIsNil() {
        let fresh = VaultKeyIdentifier("fresh")
        XCTAssertEqual(
            BiometricUnlockRecovery.identifierForRetrieve(cached: nil) { fresh },
            fresh
        )
    }

    func testIdentifierForRetrieveIsNilOnlyWhenResolutionAlsoFails() {
        XCTAssertNil(BiometricUnlockRecovery.identifierForRetrieve(cached: nil, resolving: { nil }))
    }

    func testAMissingIdentifierProducesAVisibleFailureNotASilentReturn() {
        let message = BiometricUnlockRecovery.visibleMessageWhenIdentifierMissing()
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.lowercased().contains("master password"))
    }

    /// Every non-cancel error still surfaces its existing sentence — silence is only for
    /// `.userCancelled`. Enrollment-clearing stays independent of that visibility decision.
    func testEveryNonCancelErrorRemainsVisible() {
        let others: [BiometricUnlockError] = [
            .biometricsUnavailable, .biometricsNotEnrolled, .biometricsLockedOut,
            .authenticationFailed, .notEnrolledForThisVault, .invalidatedByBiometryChange,
            .keychain(errSecItemNotFound)
        ]
        for error in others {
            XCTAssertEqual(
                BiometricUnlockRecovery.visibleMessage(after: error),
                error.userMessage,
                "\(error) must still show its userMessage"
            )
        }
        XCTAssertTrue(BiometricUnlockRecovery.shouldClearEnrollment(after: .invalidatedByBiometryChange))
    }

    func testUnlockPropagatesStoreErrors() throws {
        let store = FakeSecretStore()
        let unlock = BiometricUnlock(store: store)
        try unlock.enable(masterPassword: SecureBytes(string: "master"), for: vaultA)

        store.nextError = .userCancelled
        XCTAssertThrowsError(try unlock.unlock(vaultA, reason: "")) {
            XCTAssertEqual($0 as? BiometricUnlockError, .userCancelled)
        }
    }

    // MARK: - Error mapping

    /// The mapping is pure and static precisely so it can be tested without a keychain. It is also
    /// the part most likely to rot, because new failure modes only show up in the field.
    func testOSStatusMapping() {
        XCTAssertEqual(KeychainSecretStore.mapped(status: errSecItemNotFound), .notEnrolledForThisVault)
        XCTAssertEqual(KeychainSecretStore.mapped(status: errSecUserCanceled), .userCancelled)
        XCTAssertEqual(KeychainSecretStore.mapped(status: errSecAuthFailed), .authenticationFailed)
        // The signature of a `.biometryCurrentSet` item whose enrolment set has changed.
        XCTAssertEqual(KeychainSecretStore.mapped(status: errSecInteractionNotAllowed), .invalidatedByBiometryChange)
        XCTAssertEqual(KeychainSecretStore.mapped(status: errSecDuplicateItem), .keychain(errSecDuplicateItem))
    }

    func testLAErrorMapping() {
        XCTAssertEqual(KeychainSecretStore.mapped(laErrorCode: .biometryNotAvailable), .biometricsUnavailable)
        XCTAssertEqual(KeychainSecretStore.mapped(laErrorCode: .passcodeNotSet), .biometricsUnavailable)
        XCTAssertEqual(KeychainSecretStore.mapped(laErrorCode: .biometryNotEnrolled), .biometricsNotEnrolled)
        XCTAssertEqual(KeychainSecretStore.mapped(laErrorCode: .biometryLockout), .biometricsLockedOut)
        XCTAssertEqual(KeychainSecretStore.mapped(laErrorCode: .authenticationFailed), .authenticationFailed)
        XCTAssertEqual(KeychainSecretStore.mapped(laErrorCode: .userCancel), .userCancelled)
        XCTAssertEqual(KeychainSecretStore.mapped(laErrorCode: .appCancel), .userCancelled)
        XCTAssertEqual(KeychainSecretStore.mapped(laErrorCode: .systemCancel), .userCancelled)
        // "Enter Password" is a cancel from this type's point of view: either way the caller's next
        // move is the master-password field.
        XCTAssertEqual(KeychainSecretStore.mapped(laErrorCode: .userFallback), .userCancelled)
    }

    /// Every case must produce something showable. An empty or placeholder message here surfaces in
    /// front of a user who is already stuck.
    func testEveryErrorHasAUserPresentableMessage() {
        let errors: [BiometricUnlockError] = [
            .biometricsUnavailable, .biometricsNotEnrolled, .biometricsLockedOut, .userCancelled,
            .authenticationFailed, .notEnrolledForThisVault, .invalidatedByBiometryChange,
            .keychain(errSecItemNotFound)
        ]
        for error in errors {
            XCTAssertFalse(error.userMessage.isEmpty, "\(error) has no message")
            XCTAssertFalse(error.userMessage.contains("Optional("), "\(error) leaks an Optional into the UI")
        }
    }

    /// The invalidation message has to explain the `.biometryCurrentSet` behaviour, because from
    /// the user's side "Touch ID stopped working after I added a finger" is otherwise inexplicable
    /// and reads as a bug.
    func testBiometryChangeMessageExplainsWhatToDo() {
        let message = BiometricUnlockError.invalidatedByBiometryChange.userMessage
        XCTAssertTrue(message.lowercased().contains("fingerprint"))
        XCTAssertTrue(message.lowercased().contains("master password"))
    }

    // MARK: - What is deliberately not tested

    /// **There is no test that writes to the real keychain or evaluates a real Touch ID policy, on
    /// purpose.**
    ///
    /// `KeychainSecretStore.store` creates its item with `.biometryCurrentSet` access control, so
    /// reading it back *always* puts a system Touch ID sheet on screen. A test that did that would
    /// hang forever in CI (nothing there has a finger), would hang in `make test` on a developer
    /// machine until someone noticed the prompt, and would leave a real item in the login keychain
    /// afterwards. There is also nothing left to learn from it: `SecItemAdd` and
    /// `SecItemCopyMatching` are Apple's code, the query construction is a handful of dictionary
    /// keys, and the error mapping — the only logic in the file — is tested above without them.
    ///
    /// `hasSecret` (issue #138) sets `kSecUseAuthenticationUIFail` and treats
    /// `errSecInteractionNotAllowed` as "the item exists". It must not also pass an
    /// `LAContext` — that combination is `errSecParam`, and `isEnabled` then reports false
    /// while the keychain item is still there. The query itself is asserted below without
    /// touching the real keychain.

    /// Existence must never present a sheet. The flags that caused the original #138 prompt
    /// (no UI-fail, or UI-fail combined with an `LAContext`) must not come back.
    func testHasSecretQueryRefusesUIAndDoesNotAttachLAContext() {
        let query = KeychainSecretStore().existenceQuery(for: vaultA)
        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUIFail as String
        )
        XCTAssertNil(
            query[kSecUseAuthenticationContext as String],
            "LAContext + kSecUseAuthenticationUIFail is errSecParam and hid the button (#138)"
        )
        XCTAssertNil(query[kSecReturnData as String], "asking for data is what prompts")
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }

    /// The real store is verified by hand on a machine with Touch ID. This method is a skip
    /// rather than a comment so the decision shows up in the test report instead of being
    /// invisible.
    func testRealKeychainIsNotExercisedByThisSuite() throws {
        throw XCTSkip(
            "KeychainSecretStore is verified manually: reading a .biometryCurrentSet item always "
            + "prompts for Touch ID, which cannot be satisfied unattended. See this test's comment."
        )
    }

    /// `LAContext.canEvaluatePolicy` does not prompt — it only reports whether biometrics *could*
    /// be evaluated — so this one is safe to call. It asserts consistency rather than a value,
    /// because the answer legitimately differs between a Touch ID MacBook and a CI runner.
    func testAvailabilityCheckIsConsistentAndDoesNotPrompt() {
        let error = BiometricUnlock.availabilityError()
        XCTAssertEqual(BiometricUnlock.isAvailable, error == nil)
        if let error {
            XCTAssertFalse(error.userMessage.isEmpty)
        }
    }
}
