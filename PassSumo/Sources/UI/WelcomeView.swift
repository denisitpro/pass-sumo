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
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary)
                Text("PassSumo")
                    .font(.title)
            }

            VStack(spacing: 12) {
                Button("Open Database…") { openExistingDatabase() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("welcome.open")

                Button("Create New Database…") { isPresentingCreateSheet = true }
                    .accessibilityIdentifier("welcome.create")
            }

            if let pickerError {
                Text(pickerError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("welcome.error")
            }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(recents) { recent in
                        Button {
                            environment.store.select(url: recent.url)
                        } label: {
                            Label(recent.url.lastPathComponent, systemImage: "clock")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("welcome.recent.\(recent.id)")
                    }
                }
                .frame(maxWidth: 320)
            }
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 360)
        .task { loadRecents() }
        .onChange(of: environment.menuRequest) { _, request in
            switch request {
            case .openDatabase:
                openExistingDatabase()
                environment.menuRequest = nil
            case .newDatabase:
                isPresentingCreateSheet = true
                environment.menuRequest = nil
            case .newEntry, .editEntry, .focusSearch, nil:
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Create New Database")
                .font(.headline)

            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .disabled(isCreating)
                .accessibilityIdentifier("welcome.create.password")

            SecureField("Confirm Password", text: $confirmation)
                .textFieldStyle(.roundedBorder)
                .disabled(isCreating)
                .accessibilityIdentifier("welcome.create.confirm")

            if environment.settings.showPasswordStrength, !password.isEmpty {
                PasswordStrengthMeter(bits: environment.generator.strength(of: password))
            }

            if !confirmation.isEmpty && !passwordsMatch {
                Text("Passwords don't match.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("welcome.create.mismatch")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("welcome.create.error")
            }

            if isCreating {
                ProgressView().controlSize(.small)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .disabled(isCreating)
                Spacer()
                Button("Choose Location & Create…") {
                    Task { await chooseLocationAndCreate() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!passwordsMatch || isCreating)
                .accessibilityIdentifier("welcome.create.confirmButton")
            }
        }
        .padding(24)
        .frame(width: 380)
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

    private var tint: Color {
        switch bits {
        case ..<40: return .red
        case ..<80: return .yellow
        default: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: fraction)
                .tint(tint)
                .accessibilityIdentifier("welcome.create.strength")
            Text("Rough guide: ~\(Int(bits)) bits")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Welcome") {
    WelcomeView(environment: .uiTesting())
}
