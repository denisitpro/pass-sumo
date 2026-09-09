import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The very first thing a user with no database open sees.
///
/// Two actions and nothing else — no onboarding carousel, no upsell banner. That restraint is not
/// an oversight; it IS the product's positioning (repo CLAUDE.md: "what Strongbox was before the
/// feature creep"). Any third action added to this screen later should be treated as a decision
/// that needs its own justification, not a natural extension of this one.
struct WelcomeView: View {
    let environment: AppEnvironment

    @State private var isPresentingCreateSheet = false
    @State private var pickerError: String?
    @State private var recents: [RecentDatabase] = []

    var body: some View {
        VStack(spacing: Spacing.s8) {
            VStack(spacing: Spacing.s4) {
                Image(systemName: "lock.shield")
                    .font(.system(size: Metrics.heroGlyphSize, weight: .light))
                    .foregroundStyle(Palette.accent600)
                Text("PassSumo")
                    .font(Typography.title2)
                    .foregroundStyle(Palette.text)
            }

            VStack(spacing: Spacing.s5) {
                Button("Open Database…") { openExistingDatabase() }
                    .buttonStyle(.tokenPrimary)
                    .accessibilityIdentifier("welcome.open")

                Button("Create New Database…") { isPresentingCreateSheet = true }
                    .buttonStyle(.tokenSecondary)
                    .accessibilityIdentifier("welcome.create")
            }

            if let pickerError {
                Text(pickerError)
                    .font(Typography.body)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("welcome.error")
            }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    Text("Recent")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    ForEach(recents) { recent in
                        Button {
                            environment.store.select(url: recent.url)
                        } label: {
                            Label(recent.url.lastPathComponent, systemImage: "clock")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.tokenQuiet)
                        .accessibilityIdentifier("welcome.recent.\(recent.id)")
                    }
                }
                .frame(maxWidth: 320)
            }
        }
        .padding(Spacing.s10)
        .cardSurface()
        .padding(Spacing.s10)
        .frame(minWidth: 420, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
        .task { loadRecents() }
        .onChange(of: environment.menuRequest) { _, request in
            switch request {
            case .openDatabase:
                openExistingDatabase()
                environment.menuRequest = nil
            case .newDatabase:
                isPresentingCreateSheet = true
                environment.menuRequest = nil
            case .newEntry, .editEntry, .deleteEntry, .emptyRecycleBin, .focusSearch, nil:
                break
            }
        }
        .sheet(isPresented: $isPresentingCreateSheet) {
            CreateDatabaseSheet(environment: environment)
        }
    }

    /// Real `NSOpenPanel`, never a pre-set default path.
    ///
    /// A sibling app by the same developer was rejected under App Review Guideline 2.4.5(i) for
    /// shipping a file-access entitlement backed only by a remembered default path, with no picker
    /// anywhere in the flow. A user-driven `NSOpenPanel` invocation is what justifies pass-sumo's
    /// read/write file entitlement to a reviewer, so `panel.directoryURL` is deliberately never set
    /// here — the panel must always ask, never assume.
    private func openExistingDatabase() {
        pickerError = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let kdbxType = UTType(filenameExtension: "kdbx") {
            panel.allowedContentTypes = [kdbxType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // `select`, not `open`: no password has been typed yet, so there is nothing to decode with.
        // This moves the store to `.locked(url)`, which is what puts `UnlockView` on screen (see
        // `VaultStore.select(url:)` and `RootView`).
        environment.store.select(url: url)
    }

    private func loadRecents() {
        recents = environment.recentDatabaseBookmarks.compactMap { bookmark in
            environment.resolveRecentDatabase(bookmark).map { RecentDatabase(url: $0) }
        }
    }
}

private struct RecentDatabase: Identifiable {
    let url: URL
    var id: String { url.path }
}

// MARK: - Create New Database

/// Collects a master password twice (with a mismatch check and a strength meter) before ever
/// showing a save panel — asking "are you sure this is the password you want" before "where should
/// this live" means cancelling out of the password step never has to also undo a file the user
/// already picked a name for.
private struct CreateDatabaseSheet: View {
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
        await environment.store.createNew(at: url, credentials: VaultCredentials(password: password, keyFile: nil))
        isCreating = false

        if case .unlocked = environment.store.state {
            dismiss()
        } else {
            errorMessage = environment.store.lastError?.displayMessage ?? "Couldn't create the database."
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

#Preview("Welcome") {
    WelcomeView(environment: .uiTesting())
}
