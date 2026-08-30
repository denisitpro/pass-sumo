import SwiftUI

/// What to do after a Touch ID unlock attempt fails. Pulled out of the view body as a pure,
/// `@testable`-reachable function rather than left inline, specifically so the one case that must
/// self-heal is unit-testable without XCTest driving real SwiftUI (see
/// `SecurityBiometricUnlockTests`).
enum BiometricUnlockRecovery {
    /// `.invalidatedByBiometryChange` is the one case that must actively clean up. The stored
    /// keychain item is unusable and will STAY unusable — `.biometryCurrentSet` invalidates an
    /// item when the enrolled fingerprints change, it does not delete it (see
    /// `KeychainSecretStore`'s access-control doc comment) — so leaving it in place would keep
    /// `isEnabled` reporting "still enrolled" forever, and the "Remember with Touch ID" offer would
    /// never come back. Every other error says something about *this attempt* (cancelled, wrong
    /// finger, hardware locked out), not about whether the stored item is still good, so nothing
    /// else clears anything.
    static func shouldClearEnrollment(after error: BiometricUnlockError) -> Bool {
        error == .invalidatedByBiometryChange
    }
}

/// Unlocks one database at `url`. The single screen for `VaultStore.state == .locked(url)`,
/// whichever way the store got there: a file the user just picked (`VaultStore.select(url:)`), a
/// wrong password on a previous attempt, or a lock.
struct UnlockView: View {
    let environment: AppEnvironment
    let url: URL

    @State private var password = ""
    @State private var biometricFailure: String?
    /// Resolved once via `.task`, not recomputed on every render: `AppEnvironment.biometricsIdentifier`
    /// mints a security-scoped bookmark, which is real (if cheap) file-system work, not something a
    /// view body should redo on every observation-triggered re-render.
    @State private var identifier: VaultKeyIdentifier?
    /// The "Remember with Touch ID" checkbox on the master-password field — see `canOfferEnrollment`
    /// for why a checkbox rather than a post-unlock modal, and why it is not offered on every unlock.
    @State private var rememberWithTouchID = false

    private var isUnlocking: Bool {
        if case .unlocking = environment.store.state { return true }
        return false
    }

    private var canOfferBiometrics: Bool {
        // `BiometricUnlock.isAvailable` asks about this Mac's hardware; `.isEnabled(for:)` asks
        // whether a secret is actually stored for THIS database. Both must hold — showing the
        // button when nothing is enrolled for this vault would just be a button that always fails.
        // Under `-ui-testing 1` `environment.biometrics` is backed by a store that reports nothing
        // enrolled for anything (see `AppEnvironment.uiTesting()`), so this is `false` there with no
        // extra check needed.
        guard BiometricUnlock.isAvailable, let identifier else { return false }
        return environment.biometrics.isEnabled(for: identifier)
    }

    /// Whether to show the "Remember with Touch ID" checkbox.
    ///
    /// **Design choice: a checkbox on the unlock screen, checked before submitting, rather than a
    /// prompt shown after the fact.** The alternative — asking only once the vault is already open
    /// — needs the master password to survive the transition from this view to whatever shows the
    /// unlocked vault, which means threading a plaintext secret across a view boundary for no
    /// reason: `submit()` already has the typed password in scope for exactly as long as it takes
    /// to call `VaultStore.open`, and enrolling right there (see `submit()`) means the secret never
    /// needs to live anywhere else. A checkbox is also non-blocking by construction — there is
    /// nothing to dismiss, nothing that can "block the vault" — which the brief requires.
    ///
    /// Hidden once already enrolled (`isEnabled`), which is what makes this "once per database, not
    /// on every unlock": after the first successful enrollment this checkbox simply stops
    /// appearing, and `SettingsView` is where the user manages it from then on. Never shown when
    /// `BiometricUnlock.availabilityError()` is non-nil, per the brief.
    private var canOfferEnrollment: Bool {
        guard BiometricUnlock.availabilityError() == nil, let identifier else { return false }
        return !environment.biometrics.isEnabled(for: identifier)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(url.lastPathComponent)
                .font(.headline)

            // The full path, not just the filename — pass-sumo deliberately shows the machinery
            // (repo CLAUDE.md's positioning notes): this user wants to know exactly which file on
            // disk they are about to decrypt, not have that hidden behind a friendly display name.
            Text(url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("unlock.path")

            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .disabled(isUnlocking)
                .accessibilityIdentifier("unlock.password")
                .onSubmit { Task { await submit() } }

            // A wrong password must show inline WITHOUT clearing the field (brief) — `password`
            // here is never reset on failure, only on a successful transition away from this view
            // (which un-mounts it entirely).
            if let message = environment.store.lastError?.displayMessage ?? biometricFailure {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("unlock.error")
            }

            if canOfferEnrollment {
                Toggle("Remember with Touch ID", isOn: $rememberWithTouchID)
                    .disabled(isUnlocking)
                    .accessibilityIdentifier("unlock.rememberWithTouchID")
            }

            if isUnlocking {
                ProgressView()
                    .controlSize(.small)
            }

            HStack {
                if canOfferBiometrics {
                    Button {
                        Task { await unlockWithBiometrics() }
                    } label: {
                        Label("Unlock with Touch ID", systemImage: "touchid")
                    }
                    .disabled(isUnlocking)
                    .accessibilityIdentifier("unlock.biometric")
                }

                Spacer()

                Button("Unlock") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isUnlocking || password.isEmpty)
                    .accessibilityIdentifier("unlock.submit")
            }
        }
        .padding(32)
        .frame(minWidth: 380)
        .task { identifier = environment.biometricsIdentifier(for: url) }
    }

    private func submit() async {
        guard !password.isEmpty, !isUnlocking else { return }
        biometricFailure = nil
        // Captured locally, not read back from `password` after the `await` below: nothing about
        // enrollment needs `password` to survive as `@State` past this point, and keeping the read
        // to one spot is what makes "never lives in `@State` longer than the unlock" checkable by
        // inspection instead of by tracing every later use of the property.
        let typedPassword = password
        let shouldEnroll = rememberWithTouchID
        await environment.store.open(url: url, credentials: VaultCredentials(password: typedPassword, keyFile: nil))

        guard shouldEnroll, case .unlocked = environment.store.state else { return }
        await enrollBiometrics(masterPassword: typedPassword)
    }

    /// Runs after a successful master-password unlock when the "Remember with Touch ID" checkbox
    /// was on. Never blocks the transition to the unlocked vault — by the time this `await`s
    /// anything, `environment.store.state` has already moved past `.unlocking` and the rest of the
    /// app is free to show it; this only keeps running in the background to finish the enrollment.
    private func enrollBiometrics(masterPassword plainPassword: String) async {
        // Assigning a database ID is a WRITE to the user's file (see `KDBXKitCodec.assigningDatabaseID`
        // and `VaultStore.assignDatabaseIDIfNeeded`'s own doc comments) — enrollment is genuinely
        // not a no-op, which is exactly the honesty the brief asks for. `assignDatabaseIDIfNeeded()`
        // itself only performs that write once per database (idempotent after the first call), and
        // returns `nil` for a codec with no notion of a stable identity at all (`InMemoryVaultCodec`,
        // i.e. under `-ui-testing 1`), in which case there is nothing to enroll and this silently
        // does nothing — never a crash, never a hang.
        guard let stableID = await environment.store.assignDatabaseIDIfNeeded() else {
            if let error = environment.store.lastError {
                biometricFailure = error.displayMessage
            }
            return
        }

        let stableIdentifier = VaultKeyIdentifier(stableID.uuidString)
        do {
            try environment.biometrics.enable(masterPassword: SecureBytes(string: plainPassword), for: stableIdentifier)
            // Records the bookmark-hash → real-UUID mapping so the NEXT pre-unlock visit to this
            // screen (which cannot decrypt the file to read the UUID back out) still resolves to
            // the identifier the secret was actually stored under — see
            // `AppEnvironment.biometricsIdentifier(for:)`'s doc comment.
            environment.rememberBiometricsEnrollment(stableID, for: url)
        } catch let error as BiometricUnlockError {
            biometricFailure = error.userMessage
        } catch {
            biometricFailure = error.localizedDescription
        }
    }

    private func unlockWithBiometrics() async {
        guard let identifier else { return }
        biometricFailure = nil
        do {
            let secret = try environment.biometrics.unlock(identifier, reason: "Unlock \(url.lastPathComponent)")
            guard let revealed = secret.revealedString() else {
                biometricFailure = "The stored password isn't valid text. Enter it manually instead."
                return
            }
            await environment.store.open(url: url, credentials: VaultCredentials(password: revealed, keyFile: nil))
        } catch let error as BiometricUnlockError {
            biometricFailure = error.userMessage
            // `.invalidatedByBiometryChange` is *expected* (the Mac's enrolled fingerprints
            // changed) and must lead back to the master password field with enrollment re-offered,
            // not read like a bug — see `BiometricUnlockRecovery`'s doc comment. The stale item is
            // actively removed here rather than left in place, because `.biometryCurrentSet`
            // invalidates an item without deleting it, and a still-present-but-unusable item would
            // keep `isEnabled` (hence `canOfferBiometrics`/`canOfferEnrollment`) reporting "already
            // enrolled" forever.
            if BiometricUnlockRecovery.shouldClearEnrollment(after: error) {
                try? environment.biometrics.disable(for: identifier)
                environment.forgetBiometricsEnrollment(for: url)
            }
        } catch {
            biometricFailure = error.localizedDescription
        }
    }
}

#Preview("Empty") {
    UnlockView(environment: .uiTesting(), url: URL(fileURLWithPath: "/Users/den/Documents/Personal.kdbx"))
}
