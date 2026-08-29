import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Names one database's stored master password inside the keychain.
///
/// **Never derive this from the database's file path.** A path is not an identity: the user renames
/// the file, moves it between folders, or — the case that actually bites — keeps it in iCloud
/// Drive, where the system relocates it between the local container and the evicted-placeholder
/// path without asking. Any of those turns into "Touch ID stopped working and I have no idea why",
/// and worse, a *different* database that later lands on the old path would silently inherit the
/// previous one's stored password.
struct VaultKeyIdentifier: Sendable, Hashable {
    let rawValue: String

    /// The caller supplies something stable. This is the primary constructor, not a fallback.
    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// SHA-256 (hex) of some opaque bytes the caller considers identifying.
    ///
    /// **Caveat that the caller must read before using this with KDBX header bytes.** The obvious
    /// candidate — the KDBX 4 header's master seed — is *not* stable: the format regenerates the
    /// master seed, the Argon2 salt and the encryption IV on **every save**, by design, because
    /// reusing them would be a cryptographic flaw. Hashing them would produce an identifier that
    /// changes the first time the user edits an entry, orphaning the keychain item.
    ///
    /// So this helper is here for a caller that has genuinely stable bytes — a UUID the app itself
    /// writes into the database's `Meta/CustomData` on first use, or the file's `NSURLFileResourceIdentifierKey`
    /// — and it hashes them so the raw value never reaches the keychain's account attribute (which
    /// is readable without authentication). Which stable value pass-sumo will use is a decision for
    /// the KDBX layer; until it is made, callers pass an identifier explicitly.
    static func derived(from stableBytes: Data) -> VaultKeyIdentifier {
        let digest = SHA256.hash(data: stableBytes)
        return VaultKeyIdentifier(digest.map { String(format: "%02x", $0) }.joined())
    }
}

/// Everything the app is allowed to know about secret storage.
///
/// The one real implementation, `KeychainSecretStore`, is the only type in pass-sumo that touches
/// `Security.framework`. Everything above it — `BiometricUnlock`, the view models, the tests —
/// depends on this protocol, so the keychain can be faked wholesale in tests without a single
/// `SecItemAdd` running and without a Touch ID prompt appearing in CI.
protocol SecretStore: Sendable {
    /// Stores (replacing any previous value) the master password for `id`, behind biometrics.
    func store(_ secret: SecureBytes, for id: VaultKeyIdentifier) throws

    /// Reads the master password back. **This is the call that prompts for Touch ID** — `reason` is
    /// the sentence shown in the system sheet.
    func retrieve(for id: VaultKeyIdentifier, reason: String) throws -> SecureBytes

    /// Removes the stored password. Not an error if there was none.
    func delete(for id: VaultKeyIdentifier) throws

    /// Whether a password is stored, **without** prompting. Used to decide whether to offer the
    /// "Unlock with Touch ID" button at all.
    func hasSecret(for id: VaultKeyIdentifier) throws -> Bool
}

/// Failures the unlock UI has to be able to explain.
///
/// Deliberately small: the distinctions that survive are the ones that change what the user should
/// do next. Every other `OSStatus` collapses into `.keychain`, which carries the raw code so a bug
/// report is still actionable.
enum BiometricUnlockError: Error, Equatable {
    /// No Touch ID hardware, or it is not usable in this context.
    case biometricsUnavailable
    /// Hardware exists but no fingerprint is enrolled.
    case biometricsNotEnrolled
    /// Too many failed attempts; macOS requires a password unlock before biometrics work again.
    case biometricsLockedOut
    /// The user dismissed the prompt, or chose "Enter Password".
    case userCancelled
    /// Biometric matching ran and did not succeed.
    case authenticationFailed
    /// Nothing stored for this database.
    case notEnrolledForThisVault
    /// The item exists but its access control no longer authorises it. This is what
    /// `.biometryCurrentSet` produces on purpose when the enrolled fingerprints change.
    case invalidatedByBiometryChange
    case keychain(OSStatus)

    /// Sentences meant to be shown verbatim. They say what happened *and* what to do, because
    /// "authentication failed" on its own leaves the user with no next step.
    var userMessage: String {
        switch self {
        case .biometricsUnavailable:
            return "Touch ID isn't available on this Mac. Unlock with your master password instead."
        case .biometricsNotEnrolled:
            return "No fingerprints are enrolled. Add one in System Settings › Touch ID & Password, then try again."
        case .biometricsLockedOut:
            return "Touch ID is locked after too many attempts. Log in with your Mac password once to re-enable it."
        case .userCancelled:
            return "Touch ID was cancelled."
        case .authenticationFailed:
            return "Touch ID didn't recognise your fingerprint. Try again, or use your master password."
        case .notEnrolledForThisVault:
            return "This database isn't set up for Touch ID yet. Unlock it with your master password to enable it."
        case .invalidatedByBiometryChange:
            return "The fingerprints on this Mac changed, so the saved master password was discarded. "
                + "Unlock with your master password to set Touch ID up again."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
            return "The keychain refused the request: \(detail)"
        }
    }
}

/// The real keychain. Stateless — every call builds its own query — which is what makes it
/// `Sendable` for free and safe to call from any actor.
struct KeychainSecretStore: SecretStore {
    /// One service for every vault key; the database is distinguished by the account attribute.
    static let service = "app.passsumo.vault-key"

    init() {}

    // MARK: - Access control

    /// The access-control object every stored item is created with.
    ///
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — two independent choices in one constant:
    /// *WhenUnlocked* so the item is unreadable while the Mac is locked, and **ThisDeviceOnly** so
    /// it is excluded from keychain migration to a restored or new Mac. A master password should
    /// not travel inside a backup any more than it should travel over the network.
    ///
    /// `.biometryCurrentSet`, **not** `.biometryAny` — this is the choice that matters most here.
    /// `.biometryAny` keeps the item valid across enrolment changes, so anyone who can add their
    /// own fingerprint to the Mac (which requires only the login password) can then unlock every
    /// vault with it. `.biometryCurrentSet` binds the item to the exact set of fingerprints
    /// enrolled at the moment it was stored: enrol, remove, or re-enrol anything and the item is
    /// cryptographically invalidated by the Secure Enclave. The cost is that a legitimate user who
    /// adds a finger has to re-enable Touch ID by entering the master password once — a small,
    /// explicable annoyance in exchange for closing an attack that needs no more than a few
    /// unattended minutes at the keyboard.
    private func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else {
            // The only documented reason this returns nil is an unsupported flag combination, i.e.
            // no biometric hardware to bind to.
            error?.release()
            throw BiometricUnlockError.biometricsUnavailable
        }
        return access
    }

    private func baseQuery(for id: VaultKeyIdentifier) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id.rawValue,
            // **Never** synchronisable. `true` would push the master password into iCloud Keychain,
            // where it is end-to-end encrypted but nonetheless leaves the device, lands on every
            // other Mac and iPhone on the account, and becomes recoverable through iCloud Keychain
            // Escrow with only the device passcode. The entire point of a local KDBX file is that
            // the user chose not to trust a vendor cloud with it; storing its password in Apple's
            // would undo that choice on their behalf. It is also incompatible with
            // `ThisDeviceOnly` above, so setting it would fail anyway — but it is spelled out
            // explicitly rather than left to a default, because a default can change.
            kSecAttrSynchronizable as String: false
        ]
    }

    // MARK: - SecretStore

    func store(_ secret: SecureBytes, for id: VaultKeyIdentifier) throws {
        let access = try makeAccessControl()

        // Delete first rather than `SecItemUpdate`: `SecItemAdd` fails with `errSecDuplicateItem`
        // when an item already exists, and `SecItemUpdate` cannot change `kSecAttrAccessControl` —
        // so an update would silently keep the *old* access control, which after a re-enrolment is
        // an access control bound to fingerprints that no longer exist.
        try delete(for: id)

        var query = baseQuery(for: id)
        query[kSecAttrAccessControl as String] = access
        // `kSecAttrAccessControl` and `kSecAttrAccessible` are mutually exclusive; passing both
        // fails with `errSecParam`. The accessibility is inside the access control object.
        query[kSecValueData as String] = secret.withUnsafeBytes { Data($0) }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.mapped(status: status) }
    }

    func retrieve(for id: VaultKeyIdentifier, reason: String) throws -> SecureBytes {
        // A fresh `LAContext` per call, deliberately. Reusing one caches a successful evaluation
        // for `touchIDAuthenticationAllowableReuseDuration`, which would let a second unlock
        // succeed with no prompt at all — convenient, and exactly wrong for the one operation that
        // hands out the master password.
        let context = LAContext()
        // The modern replacement for `kSecUseOperationPrompt`, which is deprecated on macOS. Same
        // sentence, same sheet, but set on the context rather than smuggled through the query.
        context.localizedReason = reason
        context.localizedCancelTitle = "Use Master Password"

        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Self.mapped(status: status) }
        guard let data = result as? Data else { throw BiometricUnlockError.keychain(errSecInternalError) }
        return SecureBytes(data)
    }

    func delete(for id: VaultKeyIdentifier) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        // "Nothing to delete" is the normal case on first enrolment, not a failure.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.mapped(status: status)
        }
    }

    func hasSecret(for id: VaultKeyIdentifier) throws -> Bool {
        var query = baseQuery(for: id)
        // Attributes only, no `kSecReturnData`: the keychain evaluates the access control when the
        // *data* is requested, so asking only for attributes answers "does it exist" without
        // putting a Touch ID sheet in front of a user who has not asked to unlock anything.
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw Self.mapped(status: status)
        }
    }

    // MARK: - Error mapping

    /// `OSStatus` → typed error. Pure and `static`, so the mapping is unit-testable without a
    /// keychain: it is the part most likely to drift when a new failure mode shows up in the field.
    static func mapped(status: OSStatus) -> BiometricUnlockError {
        switch status {
        case errSecItemNotFound:
            return .notEnrolledForThisVault
        case errSecUserCanceled:
            return .userCancelled
        case errSecAuthFailed:
            return .authenticationFailed
        case errSecInteractionNotAllowed:
            // Returned when the item's access control cannot be satisfied without UI that we did
            // not permit — in practice, a `.biometryCurrentSet` item after the enrolment changed.
            return .invalidatedByBiometryChange
        default:
            return .keychain(status)
        }
    }

    /// `LAError` → typed error. Same reasoning as above; `LAError.Code` gains cases with new
    /// releases, hence the `default`.
    static func mapped(laErrorCode code: LAError.Code) -> BiometricUnlockError {
        switch code {
        case .biometryNotAvailable, .passcodeNotSet:
            return .biometricsUnavailable
        case .biometryNotEnrolled:
            return .biometricsNotEnrolled
        case .biometryLockout:
            return .biometricsLockedOut
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            // `.userFallback` — "Enter Password" — is a cancel from this type's point of view: the
            // caller's next move is the master password field either way.
            return .userCancelled
        case .authenticationFailed:
            return .authenticationFailed
        default:
            return .biometricsUnavailable
        }
    }
}

/// Touch ID unlock for one vault at a time.
///
/// Thin on purpose: the keychain work lives in `SecretStore` and the error mapping lives in static
/// functions, so what remains here is availability checking and the small policy decisions
/// (`isEnabled` should never prompt; `disable` should not fail loudly).
struct BiometricUnlock: Sendable {
    private let store: any SecretStore

    /// Injected, so tests use a fake store and never reach `Security.framework`.
    init(store: any SecretStore = KeychainSecretStore()) {
        self.store = store
    }

    /// `nil` when Touch ID can be used right now, otherwise the reason it cannot.
    ///
    /// `.deviceOwnerAuthenticationWithBiometrics` and not `.deviceOwnerAuthentication`: the latter
    /// falls back to the login password, which would let anyone who knows the Mac's password read
    /// out the vault's master password — a strict downgrade from the master password itself.
    static func availabilityError() -> BiometricUnlockError? {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return nil
        }
        guard let code = error.flatMap({ LAError.Code(rawValue: $0.code) }) else {
            return .biometricsUnavailable
        }
        return KeychainSecretStore.mapped(laErrorCode: code)
    }

    static var isAvailable: Bool { availabilityError() == nil }

    /// Called after a successful master-password unlock, when the user opts in.
    func enable(masterPassword: SecureBytes, for id: VaultKeyIdentifier) throws {
        try store.store(masterPassword, for: id)
    }

    /// Prompts for Touch ID and returns the stored master password.
    func unlock(_ id: VaultKeyIdentifier, reason: String) throws -> SecureBytes {
        try store.retrieve(for: id, reason: reason)
    }

    func disable(for id: VaultKeyIdentifier) throws {
        try store.delete(for: id)
    }

    /// Whether to offer the Touch ID button. Swallows the error into `false`: a keychain that
    /// cannot answer this question is a keychain we should not be offering the feature from, and
    /// there is nothing useful to tell the user at the moment an unlock screen is merely drawing
    /// itself.
    func isEnabled(for id: VaultKeyIdentifier) -> Bool {
        (try? store.hasSecret(for: id)) ?? false
    }
}
