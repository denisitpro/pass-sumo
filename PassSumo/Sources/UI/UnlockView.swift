import SwiftUI

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
        await environment.store.open(url: url, credentials: VaultCredentials(password: password, keyFile: nil))
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
        } catch {
            biometricFailure = error.localizedDescription
        }
    }
}

#Preview("Empty") {
    UnlockView(environment: .uiTesting(), url: URL(fileURLWithPath: "/Users/den/Documents/Personal.kdbx"))
}
