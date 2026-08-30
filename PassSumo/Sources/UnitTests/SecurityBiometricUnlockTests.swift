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
    /// The real store is therefore verified by hand on a machine with Touch ID, and the protocol
    /// boundary exists so that everything above it can be tested without one. This method is a
    /// skip rather than a comment so the decision shows up in the test report instead of being
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
