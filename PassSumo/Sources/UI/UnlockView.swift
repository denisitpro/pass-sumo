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

    /// Whether this window is the active one, and by extension whether the app is active at all:
    /// SwiftUI reports `false` for every window of an inactive app, and for a window of an active
    /// app that is not the front one.
    ///
    /// **This is as close to "the app is active and the vault window is key" as SwiftUI states
    /// it, and the gap is worth naming.** `appearsActive` is about the window that *appears*
    /// active — AppKit's main window — which is not literally `NSWindow.isKeyWindow`; the two
    /// diverge when a panel or a sheet holds key while the document window stays main. That
    /// divergence cannot matter here, because this view IS the whole window's content and there is
    /// nothing else in the app that could hold key over it. The alternative, reaching for
    /// `NSApp.keyWindow` from a view body, would be both untestable and a guess about which window
    /// is ours. (`controlActiveState == .key` says key literally, and is deprecated in favour of
    /// exactly this property.)
    @Environment(\.appearsActive) private var appearsActive

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

    /// Why there is no Touch ID affordance on this screen at all, when that is worth saying.
    ///
    /// Without this, a Mac with no sensor (or no enrolled finger) simply shows neither the
    /// "Unlock with Touch ID" button nor the "Remember with Touch ID" checkbox, and says nothing
    /// — the explanation existed only in Settings, which is not where anyone looks when a thing
    /// they expected is merely absent.
    ///
    /// **Only the two permanent-state cases**, per issue #69. `.biometricsLockedOut` also hides
    /// the affordance, and is deliberately not reported here: it is transient (one login-password
    /// unlock clears it), it is not a property of this Mac, and widening this to "any availability
    /// error" would put a scary sentence on the unlock screen for a condition that fixes itself.
    /// Every other case of `BiometricUnlockError` describes an *attempt*, not the absence of the
    /// affordance, and reaches the user through `biometricFailure` instead.
    private var biometricsUnavailableNote: String? {
        guard let error = BiometricUnlock.availabilityError() else { return nil }
        switch error {
        case .biometricsUnavailable, .biometricsNotEnrolled:
            return error.userMessage
        default:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: Spacing.s6) {
            Image(systemName: "lock.doc")
                .font(.system(size: Metrics.heroGlyphSize, weight: .light))
                .foregroundStyle(Palette.textTertiary)

            Text(url.lastPathComponent)
                .font(Typography.headline)
                .foregroundStyle(Palette.text)

            // The full path, not just the filename — pass-sumo deliberately shows the machinery
            // (repo CLAUDE.md's positioning notes): this user wants to know exactly which file on
            // disk they are about to decrypt, not have that hidden behind a friendly display name.
            Text(url.path)
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("unlock.path")

            // The field sits next to the button that submits it (issue #32: the old `Spacer()`
            // pinned "Unlock" to the far right edge of a wide window, metres from the field).
            HStack(spacing: Spacing.s4) {
                MasterPasswordField(
                    placeholder: "Master Password",
                    text: $password,
                    isDisabled: isUnlocking,
                    fieldIdentifier: "unlock.password",
                    revealIdentifier: "unlock.password.reveal"
                )

                // The one accent-filled action on this screen — everything else here is quiet by
                // comparison, which is the whole point of the primary style (design/BRAND.md).
                Button("Unlock") { Task { await submit() } }
                    .buttonStyle(.tokenPrimary)
                    .frame(height: Metrics.fieldHeight)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isUnlocking || password.isEmpty)
                    .accessibilityIdentifier("unlock.submit")
            }
            // A wrong password must show inline WITHOUT clearing the field (brief) — `password`
            // here is never reset on failure, only on a successful transition away from this view
            // (which un-mounts it entirely).
            .onSubmit { Task { await submit() } }

            if let message = environment.store.lastError?.displayMessage ?? biometricFailure {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("unlock.error")
            }

            // The library's own words, kept out of the line above and selectable so they can be
            // pasted into a bug report. Quiet and monospaced on purpose: a user cannot act on it,
            // but without it a "PassSumo could not read this database" report carries no evidence.
            if let diagnostic = environment.store.lastError?.diagnosticDetail {
                Text(diagnostic)
                    .font(Typography.monoCaption2)
                    .foregroundStyle(Palette.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("unlock.errorDetail")
            }

            if canOfferEnrollment {
                Toggle("Remember with Touch ID", isOn: $rememberWithTouchID)
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                    .disabled(isUnlocking)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("unlock.rememberWithTouchID")
            }

            if isUnlocking {
                ProgressView()
                    .controlSize(.small)
            }

            if canOfferBiometrics {
                Button {
                    Task { await unlockWithBiometrics() }
                } label: {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.tokenSecondary)
                .disabled(isUnlocking)
                .accessibilityIdentifier("unlock.biometric")
            } else if let note = biometricsUnavailableNote {
                // Tertiary and quiet, not `danger`: nothing has failed and there is nothing to
                // retry — this is a standing fact about the Mac, in the space where the Touch ID
                // button would otherwise be.
                Text(note)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("unlock.biometricUnavailable")
            }
        }
        .padding(Spacing.s9)
        // The content column's width breathes with the window (issue #102) — the same treatment as
        // `WelcomeView`'s card, and its doc comment there says why this can't instead cap the
        // *window*. It still stays an upper bound, never unlimited: #32's original complaint was a
        // `minWidth`-only frame that let a wide window stretch the master-password field into an
        // unreadable hairline running edge to edge, and `Metrics.authCardMaxWidth` is what keeps
        // that from coming back at any window size.
        .containerRelativeFrame(.horizontal) { width, _ in
            min(max(width * Metrics.authCardWidthFraction, Metrics.authCardMinWidth), Metrics.authCardMaxWidth)
        }
        // The card the mockup centres on the canvas — `surface` ground, hairline edge, card shadow.
        .cardSurface()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
        .task {
            // Held in a local as well as in `@State`: the automatic attempt below needs the value
            // resolved by THIS call, not whatever a re-render might have left in the property.
            let resolved = environment.biometricsIdentifier(for: url)
            identifier = resolved
            await attemptAutomaticBiometricUnlockIfAllowed(identifier: resolved)
        }
        // The app can be launched, or brought to this screen, while it is not the active app —
        // and the policy refuses in that case WITHOUT spending the session's one attempt (see
        // `claimAutomaticAttempt`). Asking again the moment the window becomes active is what
        // turns that refusal into "not yet" instead of "never", and is also the cold-launch path
        // that matters most: `.task` above can run before the window has finished becoming
        // active. It cannot double-prompt — the first call that is allowed to prompt claims the
        // attempt, and every later call is refused on that.
        .onChange(of: appearsActive) {
            Task { await attemptAutomaticBiometricUnlockIfAllowed(identifier: identifier) }
        }
    }

    /// The whole of issue #69's headline behaviour: present a locked, enrolled database and the
    /// system Touch ID sheet comes up on its own, with no click.
    ///
    /// This function deliberately contains no policy. It gathers the four facts the decision needs
    /// and hands them to `AutomaticBiometricUnlockPolicy`, which is where the rules live and where
    /// they are unit-tested — this Mac has no Touch ID sensor, so a rule expressed inline here
    /// would be a rule nothing on this machine could check.
    private func attemptAutomaticBiometricUnlockIfAllowed(identifier: VaultKeyIdentifier?) async {
        guard let identifier else { return }
        let conditions = AutomaticBiometricUnlockPolicy.Conditions(
            isEnrolledForThisVault: environment.biometrics.isEnabled(for: identifier),
            availabilityError: BiometricUnlock.availabilityError(),
            isWindowActive: appearsActive,
            lastLockReason: environment.autoLock.lastLockReason
        )
        guard environment.automaticBiometricUnlock.claimAutomaticAttempt(conditions) else { return }

        // Exactly the manual button's code path, not a variant of it. Whatever happens next —
        // success, a cancel, a wrong finger, an invalidated keychain item and its recovery — is
        // already handled there, and the button stays on screen as the way back in, which is what
        // makes a cancelled automatic prompt a dead end rather than a loop.
        await unlockWithBiometrics()
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
