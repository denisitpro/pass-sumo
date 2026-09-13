import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Collects a master password twice (with a mismatch check and a strength meter) before ever
/// showing a save panel — asking "are you sure this is the password you want" before "where should
/// this live" means cancelling out of the password step never has to also undo a file the user
/// already picked a name for.
///
/// Presented from `RootView` so File → New, the tab-bar + menu, and Welcome's Create button all
/// hit the same sheet (issue #165). Kept `internal` so tests and previews can construct it.
struct CreateDatabaseSheet: View {
    let environment: AppEnvironment

    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmation = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var passwordsMatch: Bool { !password.isEmpty && password == confirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s6) {
            Text("Create New Database")
                .font(Typography.headline)
                .foregroundStyle(Palette.text)

            MasterPasswordField(
                placeholder: "Master Password",
                text: $password,
                isDisabled: isCreating,
                fieldIdentifier: "welcome.create.password",
                revealIdentifier: "welcome.create.password.reveal"
            )

            MasterPasswordField(
                placeholder: "Confirm Password",
                text: $confirmation,
                isDisabled: isCreating,
                fieldIdentifier: "welcome.create.confirm",
                revealIdentifier: "welcome.create.confirm.reveal"
            )

            if environment.settings.showPasswordStrength, !password.isEmpty {
                PasswordStrengthMeter(bits: environment.generator.strength(of: password))
            }

            if !confirmation.isEmpty && !passwordsMatch {
                Text("Passwords don't match.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("welcome.create.mismatch")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("welcome.create.error")
            }

            if isCreating {
                ProgressView().controlSize(.small)
            }

            HStack(spacing: Spacing.s3) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.tokenQuiet)
                    .disabled(isCreating)
                Spacer()
                Button("Choose Location & Create…") {
                    Task { await chooseLocationAndCreate() }
                }
                .buttonStyle(.tokenPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!passwordsMatch || isCreating)
                .accessibilityIdentifier("welcome.create.confirmButton")
            }
            .padding(.top, Spacing.s5)
        }
        .padding(Spacing.s7)
        .frame(width: 380)
        .background(Palette.surface)
    }

    /// Same "never a pre-set default path" reasoning as `WelcomeView.openExistingDatabase()` — see
    /// that method's doc comment. `panel.nameFieldStringValue` is only a suggested filename shown
    /// inside the panel, not a location the panel is skipped for; the user still confirms both the
    /// name and the directory.
    private func chooseLocationAndCreate() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "New Database.kdbx"
        if let kdbxType = UTType(filenameExtension: "kdbx") {
            panel.allowedContentTypes = [kdbxType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isCreating = true
        let created = await environment.createDatabase(
            at: url,
            credentials: VaultCredentials(password: password, keyFile: nil)
        )
        isCreating = false

        if case .unlocked = created.state {
            dismiss()
        } else {
            errorMessage = created.lastError?.displayMessage ?? "Couldn't create the database."
        }
    }
}

/// A rough, honest strength indicator — see `PasswordGenerator.strength(of:)`'s own doc comment on
/// exactly what this number is and, more importantly, is NOT (no dictionary, no leaked-password
/// list; a strict upper bound, never a verdict). The label says "rough guide" for the same reason.
private struct PasswordStrengthMeter: View {
    let bits: Double

    /// Thresholds chosen for where they change the user's next action, not for decorative even
    /// spacing: below 40 bits is "type more"; 40–80 is "acceptable for most sites"; above 80 is
    /// comfortably past what any KDBX brute-force budget threatens today.
    private var fraction: Double { min(bits / 100, 1.0) }

    /// Thresholds unchanged; only the colours moved onto the token layer's strength ramp.
    private var tint: Color {
        switch bits {
        case ..<40: return Palette.strengthWeak
        case ..<80: return Palette.strengthFair
        default: return Palette.strengthStrong
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s1) {
            ProgressView(value: fraction)
                .tint(tint)
                .accessibilityIdentifier("welcome.create.strength")
            Text("Rough guide: ~\(Int(bits)) bits")
                .font(Typography.monoCaption2)
                .foregroundStyle(Palette.textTertiary)
        }
    }
}
