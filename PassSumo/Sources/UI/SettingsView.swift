import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Persisted settings

/// Everything the Settings window lets the user change, persisted across launches.
///
/// Deliberately flat and small — four knobs, no more — because this screen is itself part of the
/// anti-Strongbox positioning (repo CLAUDE.md: "what Strongbox was before the feature creep"):
/// there is no accounts/cloud/purchases section because v1 has none of those, and adding one here
/// "just in case" would be exactly the feature creep this product is positioned against.
///
/// `defaults` is injected (default `.standard`) so `AppShellTests` can round-trip this type through
/// a scratch `UserDefaults(suiteName:)` instead of ever touching the app's real preferences —
/// `AppEnvironment.live()` passes `.standard`; `uiTesting()` uses its own throwaway suite so an
/// e2e run cannot inherit a hidden inspector or a leftover generator recipe from `make local`.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let autoLockTimeout = "settings.autoLockTimeout"
        static let clipboardClearTimeout = "settings.clipboardClearTimeout"
        static let showPasswordStrength = "settings.showPasswordStrength"
        static let detailPaneVisible = "settings.detailPaneVisible"
        static let generatorLength = "settings.generator.length"
        static let generatorLowercase = "settings.generator.lowercase"
        static let generatorUppercase = "settings.generator.uppercase"
        static let generatorDigits = "settings.generator.digits"
        static let generatorSymbols = "settings.generator.symbols"
        static let defaultUsername = "settings.defaultUsername"
    }

    /// Mirrors `AutoLockController.idleTimeout`'s own default (300s) so a database that has never
    /// touched Settings still auto-locks on the same schedule the controller would pick on its own.
    static let defaultAutoLockTimeout: TimeInterval = 300
    /// Mirrors `ClipboardService.clearInterval`'s own default.
    static let defaultClipboardClearTimeout: TimeInterval = 30

    private let defaults: UserDefaults

    var autoLockTimeout: TimeInterval {
        didSet { defaults.set(autoLockTimeout, forKey: Key.autoLockTimeout) }
    }

    var clipboardClearTimeout: TimeInterval {
        didSet { defaults.set(clipboardClearTimeout, forKey: Key.clipboardClearTimeout) }
    }

    var showPasswordStrength: Bool {
        didSet { defaults.set(showPasswordStrength, forKey: Key.showPasswordStrength) }
    }

    /// Whether `VaultBrowserView`'s entry-detail inspector is shown (issue #49). Not surfaced in
    /// this screen — it's window chrome the browser's own toolbar toggle drives, not a preference
    /// a user goes looking for in Settings — but persisted the same `Key`/`didSet` way as every
    /// other setting here rather than through a second mechanism.
    var detailPaneVisible: Bool {
        didSet { defaults.set(detailPaneVisible, forKey: Key.detailPaneVisible) }
    }

    /// Only `length` and the four character classes are user-facing (see `SettingsView`'s body) —
    /// `excludeAmbiguous`/`customSymbols` stay at `PasswordGenerator.Recipe`'s own defaults, which
    /// is exactly "few controls, no clutter" applied to the recipe itself, not just the screen.
    var generatorRecipe: PasswordGenerator.Recipe {
        didSet { persistRecipe() }
    }

    /// Prefill for a brand-new entry's username (issue #140). Empty means leave it blank.
    var defaultUsername: String {
        didSet { defaults.set(defaultUsername, forKey: Key.defaultUsername) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        autoLockTimeout = Self.storedDouble(defaults, Key.autoLockTimeout) ?? Self.defaultAutoLockTimeout
        clipboardClearTimeout = Self.storedDouble(defaults, Key.clipboardClearTimeout) ?? Self.defaultClipboardClearTimeout
        showPasswordStrength = (defaults.object(forKey: Key.showPasswordStrength) as? Bool) ?? true
        detailPaneVisible = (defaults.object(forKey: Key.detailPaneVisible) as? Bool) ?? true

        var recipe = PasswordGenerator.Recipe()
        if let length = defaults.object(forKey: Key.generatorLength) as? Int { recipe.length = length }
        if let value = defaults.object(forKey: Key.generatorLowercase) as? Bool { recipe.lowercase = value }
        if let value = defaults.object(forKey: Key.generatorUppercase) as? Bool { recipe.uppercase = value }
        if let value = defaults.object(forKey: Key.generatorDigits) as? Bool { recipe.digits = value }
        if let value = defaults.object(forKey: Key.generatorSymbols) as? Bool { recipe.symbols = value }
        defaultUsername = defaults.string(forKey: Key.defaultUsername) ?? ""
        generatorRecipe = recipe
        // Note on `didSet` during `init`: assigning the stored properties above does run their
        // `didSet` (Swift only skips observers for a property's own *declaration-time* default, not
        // for an explicit assignment in `init`'s body), so this constructor writes each value
        // straight back to `defaults` a second time. That is a harmless no-op — it writes back
        // exactly what was just read — not a bug, so it is left alone rather than worked around.
    }

    private func persistRecipe() {
        defaults.set(generatorRecipe.length, forKey: Key.generatorLength)
        defaults.set(generatorRecipe.lowercase, forKey: Key.generatorLowercase)
        defaults.set(generatorRecipe.uppercase, forKey: Key.generatorUppercase)
        defaults.set(generatorRecipe.digits, forKey: Key.generatorDigits)
        defaults.set(generatorRecipe.symbols, forKey: Key.generatorSymbols)
    }

    /// `UserDefaults.double(forKey:)` returns `0` for a missing key, indistinguishable from a
    /// genuinely-stored `0` — this checks presence first so "never set" and "set to zero" don't
    /// collapse into the same case.
    private static func storedDouble(_ defaults: UserDefaults, _ key: String) -> TimeInterval? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }
}

// MARK: - Version info

/// The version/build/revision/OS line shown, and made copyable, by the Settings "About" section
/// (issue #51) — assembled for pasting whole into a bug report.
///
/// Built from explicit inputs rather than reading `Bundle.main`/`ProcessInfo` inside the view, the
/// same seam-over-hard-wiring rule the rest of this codebase follows (repo CLAUDE.md's
/// dependency-inversion rule) — `AppVersionInfoTests` exercises the assembly, including a plist
/// missing the git-stamping keys entirely, without touching the real bundle.
///
/// This is **data**, never UI copy: issue #46's localization pass must never reach `summary` or
/// reformat any part of it — a bug report needs the exact byte-for-byte string regardless of the
/// reporter's locale.
struct AppVersionInfo {
    let shortVersion: String
    let build: String
    let gitRevision: String
    let osVersion: String

    /// project.yml's Info.plist template placeholders (see its "Stamp Info.plist from git"
    /// `preBuildScripts` phase) — used here too, so a plist missing a key shows the same value a
    /// developer already sees in that template rather than inventing a different "unknown" marker.
    static let unknownShortVersion = "0.0.0"
    static let unknownBuild = "1"
    static let unknownGitRevision = "dev"

    /// Reads the three git-stamped `Info.plist` keys plus the running macOS version.
    /// `infoDictionary`/`osVersion` are injectable so tests can supply a dictionary missing one or
    /// all of the git-stamping keys without touching `Bundle.main`.
    static func current(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> AppVersionInfo {
        AppVersionInfo(
            shortVersion: infoDictionary?["CFBundleShortVersionString"] as? String ?? unknownShortVersion,
            build: infoDictionary?["CFBundleVersion"] as? String ?? unknownBuild,
            gitRevision: infoDictionary?["GitRevision"] as? String ?? unknownGitRevision,
            // Plain integer interpolation, never a number formatter — see the type's doc comment.
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        )
    }

    /// The exact bug-report string. Never localized, never run through a locale-aware formatter.
    var summary: String {
        "PassSumo \(shortVersion) (build \(build)) · \(gitRevision) · macOS \(osVersion)"
    }

    /// Compact stamp for the window corner / status bar so a leftover build is obvious at a
    /// glance (issue #153). Not `summary` — that is the copyable bug-report line and includes
    /// macOS, which this readout does not need.
    var shortLabel: String {
        "\(shortVersion) (\(build)) · \(gitRevision)"
    }
}

// MARK: - View

/// The one Settings window. Few controls, no clutter — this is the anti-Strongbox screen the repo's
/// positioning notes describe: auto-lock, clipboard clear, the generator's default recipe, and
/// whether to show a strength meter at all. Nothing about accounts, sync, or purchases, because v1
/// ships none of those.
struct SettingsView: View {
    @Bindable var environment: AppEnvironment

    /// Local, transient UI state for the Touch ID toggle below — neither persisted (that's what
    /// `BiometricUnlock`/the keychain are for) nor observed by anything outside this view.
    @State private var isTouchIDBusy = false
    @State private var touchIDError: String?
    /// Cached so the toggle's `get` does not hit the keychain on every `body` pass (issue #138).
    @State private var isTouchIDEnabled = false

    /// Whether the About row's label is currently showing "Copied to clipboard" instead of the
    /// version string — local, transient UI state, reset by `copyVersionInfo`'s own timer.
    @State private var didCopyVersionInfo = false

    private let versionInfo = AppVersionInfo.current()

    var body: some View {
        Form {
            Section("Touch ID") {
                touchIDContent
            }

            Section("Locking") {
                Stepper(
                    "Auto-lock after \(Int(environment.settings.autoLockTimeout))s of inactivity",
                    value: $environment.settings.autoLockTimeout,
                    in: 30...3600,
                    step: 30
                )
                .accessibilityIdentifier("settings.autoLockTimeout")
            }

            Section("Clipboard") {
                Stepper(
                    "Clear clipboard after \(Int(environment.settings.clipboardClearTimeout))s",
                    value: $environment.settings.clipboardClearTimeout,
                    in: 5...300,
                    step: 5
                )
                .accessibilityIdentifier("settings.clipboardClearTimeout")
            }

            Section("New Entries") {
                TextField("Default username", text: $environment.settings.defaultUsername)
                    .accessibilityIdentifier("settings.defaultUsername")
            }

            Section("Password Generator") {
                Stepper(
                    "Length: \(environment.settings.generatorRecipe.length)",
                    value: $environment.settings.generatorRecipe.length,
                    in: 8...64
                )
                .accessibilityIdentifier("settings.generatorLength")
                Toggle("Lowercase (a-z)", isOn: $environment.settings.generatorRecipe.lowercase)
                    .accessibilityIdentifier("settings.generatorLowercase")
                Toggle("Uppercase (A-Z)", isOn: $environment.settings.generatorRecipe.uppercase)
                    .accessibilityIdentifier("settings.generatorUppercase")
                Toggle("Digits (0-9)", isOn: $environment.settings.generatorRecipe.digits)
                    .accessibilityIdentifier("settings.generatorDigits")
                Toggle("Symbols (!#$…)", isOn: $environment.settings.generatorRecipe.symbols)
                    .accessibilityIdentifier("settings.generatorSymbols")
            }

            Section {
                Toggle("Show password strength", isOn: $environment.settings.showPasswordStrength)
                    .accessibilityIdentifier("settings.showPasswordStrength")
            }

            Section("About") {
                Button {
                    copyVersionInfo()
                } label: {
                    Text(didCopyVersionInfo ? "Copied to clipboard" : versionInfo.summary)
                        .font(Typography.monoCaption)
                        .contentTransition(.opacity)
                }
                .buttonStyle(.plain)
                .help("Click to copy version")
                .accessibilityIdentifier("settings.about.version")
            }
        }
        .formStyle(.grouped)
        .font(Typography.body)
        .foregroundStyle(Palette.text)
        .frame(width: 420, height: 480)
        .background(Palette.canvas)
        .accessibilityIdentifier("root.settings")
        // Push edits into the already-running services immediately — a timeout change should take
        // effect on the vault the user has open right now, not only on the next launch. `settings`
        // itself is the thing that survives a relaunch; these two lines are the live-wiring on top.
        .onChange(of: environment.settings.autoLockTimeout) { _, newValue in
            environment.autoLock.idleTimeout = newValue
        }
        .onAppear { refreshTouchIDEnabled() }
        .onChange(of: environment.settings.clipboardClearTimeout) { _, newValue in
            environment.clipboard.clearInterval = newValue
        }
    }

    // MARK: - Touch ID

    /// Three mutually exclusive states, in order of precedence: no database open, hardware
    /// unavailable, or the real toggle. Each of the first two explains itself rather than silently
    /// doing nothing — the brief's explicit requirement for "no database open."
    @ViewBuilder
    private var touchIDContent: some View {
        if case .unlocked = environment.store.state {
            if let unavailable = BiometricUnlock.availabilityError() {
                Text(unavailable.userMessage)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityIdentifier("settings.touchID.unavailable")
            } else {
                Toggle("Unlock with Touch ID", isOn: touchIDBinding)
                    .disabled(isTouchIDBusy)
                    .accessibilityIdentifier("settings.touchID.toggle")
                if isTouchIDBusy {
                    ProgressView().controlSize(.small)
                }
                if let touchIDError {
                    Text(touchIDError)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("settings.touchID.error")
                }
            }
        } else {
            Text("Open a database to set up Touch ID unlock.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityIdentifier("settings.touchID.noDatabase")
        }
    }

    /// `set` is async (keychain + maybe a save); a `Binding` cannot be. `get` reads the cache
    /// filled by `refreshTouchIDEnabled`, not the keychain — a body pass must not call `isEnabled`.
    private var touchIDBinding: Binding<Bool> {
        Binding(
            get: { isTouchIDEnabled },
            set: { newValue in
                Task { await setTouchIDEnabled(newValue) }
            }
        )
    }

    private func refreshTouchIDEnabled() {
        guard let id = environment.store.currentDatabaseID else {
            isTouchIDEnabled = false
            return
        }
        isTouchIDEnabled = environment.biometrics.isEnabled(for: VaultKeyIdentifier(id.uuidString))
    }

    private func setTouchIDEnabled(_ enabled: Bool) async {
        touchIDError = nil
        isTouchIDBusy = true
        defer {
            isTouchIDBusy = false
            refreshTouchIDEnabled()
        }

        guard enabled else {
            // Turning off is a pure keychain deletion — `currentDatabaseID` is only a read here, so
            // this path never touches the vault file.
            guard let id = environment.store.currentDatabaseID, let url = environment.store.currentURL else { return }
            do {
                try environment.biometrics.disable(for: VaultKeyIdentifier(id.uuidString))
                environment.forgetBiometricsEnrollment(for: url)
            } catch let error as BiometricUnlockError {
                touchIDError = error.userMessage
            } catch {
                touchIDError = error.localizedDescription
            }
            return
        }

        // Turning on: be honest that this is not a no-op. If this database has never had a stable
        // ID assigned, `assignDatabaseIDIfNeeded()` mints one and immediately saves the vault file
        // — see that method's own doc comment. `currentMasterPassword` and `currentURL` are only
        // `nil` if nothing is unlocked, which the `touchIDContent` gating above already excludes.
        guard let url = environment.store.currentURL,
              let masterPassword = environment.store.currentMasterPassword
        else { return }

        guard let id = await environment.store.assignDatabaseIDIfNeeded() else {
            touchIDError = environment.store.lastError?.displayMessage
                ?? "Couldn't prepare this database for Touch ID."
            return
        }

        do {
            try environment.biometrics.enable(masterPassword: SecureBytes(string: masterPassword), for: VaultKeyIdentifier(id.uuidString))
            environment.rememberBiometricsEnrollment(id, for: url)
        } catch let error as BiometricUnlockError {
            touchIDError = error.userMessage
        } catch {
            touchIDError = error.localizedDescription
        }
    }

    // MARK: - About

    /// Copies `versionInfo.summary` and swaps the row's label to "Copied to clipboard" for 1.4s —
    /// ShotSumo's exact pattern (issue #51): no toast, no sound, no checkmark, just the label
    /// itself changing under a `.contentTransition(.opacity)`.
    private func copyVersionInfo() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(versionInfo.summary, forType: .string)

        withAnimation {
            didCopyVersionInfo = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation {
                didCopyVersionInfo = false
            }
        }
    }
}

#Preview {
    SettingsView(environment: .uiTesting())
}
