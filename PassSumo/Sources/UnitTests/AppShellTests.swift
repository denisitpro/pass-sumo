import XCTest
@testable import PassSumo

/// Fast, hosted unit tests for the app shell's composition root (`AppEnvironment`), the persisted
/// settings type, and the menu-bar enablement logic (`AppCommands`) — no UI driving anywhere in
/// this file. `PassSumoUITests` is where an actual window gets exercised.
@MainActor
final class AppShellTests: XCTestCase {

    // MARK: - AppEnvironment.uiTesting()

    func testUITestingEnvironmentLoadsSampleVault() async {
        let environment = AppEnvironment.uiTesting()
        // `uiTesting()` only seeds the fake in-memory file synchronously — see its doc comment on
        // why the actual unlock is a separate `async` step. Awaiting it directly here is what keeps
        // this assertion race-free instead of polling for a fire-and-forget `Task` to finish.
        await environment.loadUITestingFixture()
        XCTAssertEqual(environment.store.state, .unlocked(Vault.sample))
        XCTAssertTrue(environment.isUITesting)
    }

    func testUITestingEnvironmentIsIdempotent() async {
        // Calling it twice (e.g. once from `RootView`'s `.task`, once from a test that also awaits
        // it) must not attempt a second, redundant `open` against state that already moved on.
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        await environment.loadUITestingFixture()
        XCTAssertEqual(environment.store.state, .unlocked(Vault.sample))
    }

    func testUITestingEnvironmentSkipsBiometrics() {
        // "Bypasses biometrics" (brief) means no secret is ever reported as enrolled, for any
        // identifier — never a real Touch ID prompt, never a real keychain lookup.
        let environment = AppEnvironment.uiTesting()
        XCTAssertFalse(environment.biometrics.isEnabled(for: VaultKeyIdentifier("any-database")))
    }

    // MARK: - Copy toast (issue #167)

    /// `copy(_:notice:)` is the single write path for username / password / TOTP copies. The
    /// toast string is what `VaultBrowserView` overlays; a test that only checked the pasteboard
    /// would miss a notice that never got published.
    func testCopyPublishesTheNotice() {
        let pasteboard = FakePasteboard()
        let environment = AppEnvironment.uiTesting(
            clipboard: ClipboardService(pasteboard: pasteboard, clearInterval: 30)
        )
        XCTAssertNil(environment.copyNotice)

        environment.copy("alice", notice: "Copied username")
        XCTAssertEqual(environment.copyNotice?.message, "Copied username")
        XCTAssertEqual(pasteboard.currentString, "alice")
    }

    func testSecondCopyReplacesTheNotice() {
        let pasteboard = FakePasteboard()
        let environment = AppEnvironment.uiTesting(
            clipboard: ClipboardService(pasteboard: pasteboard, clearInterval: 30)
        )
        environment.copy("alice", notice: "Copied username")
        let firstID = environment.copyNotice?.id

        environment.copy("s3cret", notice: "Copied password")
        XCTAssertEqual(environment.copyNotice?.message, "Copied password")
        XCTAssertEqual(pasteboard.currentString, "s3cret")
        XCTAssertNotEqual(environment.copyNotice?.id, firstID)
    }

    // MARK: - AppSettings round-trip

    /// A fresh scratch suite per test, removed in a `defer` — never `UserDefaults.standard`, which
    /// is the app's real preferences domain.
    private func makeScratchDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "app.passsumo.tests.\(UUID().uuidString)"
        guard let scratch = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create a scratch UserDefaults suite")
            return (.standard, {})
        }
        return (scratch, { scratch.removePersistentDomain(forName: suiteName) })
    }

    func testSettingsRoundTripThroughScratchDefaults() {
        let (scratch, cleanup) = makeScratchDefaults()
        defer { cleanup() }

        var recipe = PasswordGenerator.Recipe()
        recipe.length = 32
        recipe.symbols = false

        // A separate scope: the write happens through one `AppSettings` instance and is verified
        // through a second one built fresh over the same suite, so the assertion below can only
        // pass if the values genuinely reached `UserDefaults` rather than just living in the first
        // instance's memory.
        do {
            let settings = AppSettings(defaults: scratch)
            settings.autoLockTimeout = 120
            settings.clipboardClearTimeout = 15
            settings.showPasswordStrength = false
            settings.generatorRecipe = recipe
            settings.detailPaneVisible = false
            settings.defaultUsername = "user@example.com"
        }

        let reloaded = AppSettings(defaults: scratch)
        XCTAssertEqual(reloaded.autoLockTimeout, 120)
        XCTAssertEqual(reloaded.clipboardClearTimeout, 15)
        XCTAssertEqual(reloaded.showPasswordStrength, false)
        XCTAssertEqual(reloaded.generatorRecipe, recipe)
        XCTAssertEqual(reloaded.detailPaneVisible, false)
        XCTAssertEqual(reloaded.defaultUsername, "user@example.com")
    }

    func testSettingsDefaultsWhenNothingStoredYet() {
        let (scratch, cleanup) = makeScratchDefaults()
        defer { cleanup() }

        let settings = AppSettings(defaults: scratch)
        XCTAssertEqual(settings.autoLockTimeout, AppSettings.defaultAutoLockTimeout)
        XCTAssertEqual(settings.clipboardClearTimeout, AppSettings.defaultClipboardClearTimeout)
        XCTAssertTrue(settings.showPasswordStrength)
        XCTAssertEqual(settings.generatorRecipe, PasswordGenerator.Recipe())
        // The detail inspector starts shown — issue #49's default matches the pane's old,
        // always-visible `detail:` column behavior, so upgrading from a build with no saved
        // preference does not silently hide it.
        XCTAssertTrue(settings.detailPaneVisible)
        XCTAssertEqual(settings.defaultUsername, "")
    }

    // MARK: - AppCommands enablement

    func testEntrySelectionEnablementWithNoSelection() {
        let environment = AppEnvironment.uiTesting()
        environment.selectedEntryID = nil
        XCTAssertNil(AppCommands(environment: environment).selectedEntry)
    }

    func testEntrySelectionEnablementWithASelectionOnAnUnlockedVault() async {
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        guard case .unlocked(let vault) = environment.store.state, let entry = vault.entries.first else {
            XCTFail("expected the sample vault to be unlocked with at least one entry")
            return
        }

        environment.selectedEntryID = entry.id
        XCTAssertEqual(AppCommands(environment: environment).selectedEntry?.id, entry.id)
    }

    func testEntrySelectionIgnoredWhileLocked() async {
        // A selection surviving a lock (e.g. the idle timer firing) must not let Copy/Edit/Delete
        // act on an entry from a vault that is no longer decrypted.
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        guard case .unlocked(let vault) = environment.store.state, let entry = vault.entries.first else {
            XCTFail("expected the sample vault to be unlocked with at least one entry")
            return
        }
        environment.selectedEntryID = entry.id
        environment.store.lock()

        XCTAssertNil(AppCommands(environment: environment).selectedEntry)
    }

    func testNewDatabaseDisabledOnceAVaultIsOpen() async {
        let environment = AppEnvironment.uiTesting()
        XCTAssertTrue(AppCommands(environment: environment).canCreateNewDatabase)

        await environment.loadUITestingFixture()
        XCTAssertFalse(AppCommands(environment: environment).canCreateNewDatabase)
    }

    func testNewDatabaseDisabledOnceAFileIsPicked() {
        // Picking a file used to leave `store.state` at `.empty` (the URL lived in an app-level
        // bridge), so this check had to consult that bridge separately. `VaultStore.select(url:)`
        // now lands in `.locked` immediately, which is what makes the single state check correct.
        let environment = AppEnvironment.uiTesting()
        environment.openRouter.requestOpen(URL(fileURLWithPath: "/tmp/example.kdbx"))
        XCTAssertFalse(AppCommands(environment: environment).canCreateNewDatabase)
    }

    func testOpenDatabaseStaysEnabledWhileAVaultIsOpen() async {
        // The inverse of the rule above, and the menu-bar half of issue #84: the app owns the
        // `.kdbx` type, so the system hands it "open this other database" whether or not the item
        // was enabled. Greying it out only hid a capability `VaultOpenRouter` now provides.
        let picked = AppEnvironment.uiTesting()
        XCTAssertTrue(AppCommands(environment: picked).canOpenDatabase)
        picked.openRouter.requestOpen(URL(fileURLWithPath: "/tmp/example.kdbx"))
        XCTAssertTrue(AppCommands(environment: picked).canOpenDatabase)

        // A separate environment for the unlocked case: `loadUITestingFixture()` only runs from
        // `.empty`, so it would no-op on the one above.
        let unlocked = AppEnvironment.uiTesting()
        await unlocked.loadUITestingFixture()
        XCTAssertTrue(AppCommands(environment: unlocked).canOpenDatabase)
    }

    // MARK: - Biometric identity

    /// The `nil`-database-ID fallback: `InMemoryVaultCodec` has no `Meta/CustomData` to keep an ID
    /// in, so `currentDatabaseID` is `nil` and the identifier must still be produced — from the
    /// bookmark bytes — rather than the whole Touch ID question going unanswerable.
    func testBiometricsIdentifierFallsBackToTheBookmarkWhenTheDatabaseHasNoID() async {
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        XCTAssertNil(environment.store.currentDatabaseID)

        let identifier = environment.biometricsIdentifier(for: AppEnvironment.uiTestingVaultURL)
        XCTAssertNotNil(identifier)
        // Never the raw path: a renamed or iCloud-relocated file would orphan the keychain item
        // (see `VaultKeyIdentifier.derived(from:)`).
        XCTAssertNotEqual(identifier?.rawValue, AppEnvironment.uiTestingVaultURL.path)
    }

    /// After Lock, `currentDatabaseID` is gone with the decrypted origin. A Touch ID click
    /// that finds `@State identifier` still nil must still be able to resolve (issue #138).
    func testBiometricsIdentifierResolvesWhileTheVaultIsLocked() {
        let environment = AppEnvironment.uiTesting()
        let url = URL(fileURLWithPath: "/tmp/locked-touchid.kdbx")
        XCTAssertTrue(environment.store.select(url: url))
        XCTAssertNil(environment.store.currentDatabaseID)
        XCTAssertNotNil(environment.biometricsIdentifier(for: url))
    }

    /// Opening a database must not give it an ID as a side effect — that is a mutation, and it
    /// would reach the user's file on the next save (see `VaultStore.currentDatabaseID`).
    func testOpeningAVaultNeverAssignsADatabaseID() async {
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        XCTAssertNil(environment.store.currentDatabaseID)
        XCTAssertFalse(environment.store.isDirty, "opening a database marked it dirty")
    }

    // MARK: - Menu requests

    func testEditEntryCommandPublishesARequestForTheSelectedEntry() async {
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        guard case .unlocked(let vault) = environment.store.state, let entry = vault.entries.first else {
            XCTFail("expected the sample vault to be unlocked with at least one entry")
            return
        }
        environment.selectedEntryID = entry.id

        // `AppCommands`' Edit button body, exercised without a menu bar: it is the only command that
        // has to carry the selection into the request, and getting that id wrong is invisible until
        // the wrong entry opens for edit.
        if let id = environment.selectedEntryID { environment.menuRequest = .editEntry(id) }
        XCTAssertEqual(environment.menuRequest, .editEntry(entry.id))
    }

    func testCopyCommandsResolveTheSelectedEntrysFields() async {
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        guard case .unlocked(let vault) = environment.store.state,
              let entry = vault.entries.first(where: { !$0.password.isEmpty })
        else {
            XCTFail("expected the sample vault to have an entry with a password")
            return
        }
        environment.selectedEntryID = entry.id

        // Asserts the value the Copy Password command WOULD hand to `ClipboardService`, without
        // performing the copy: this suite runs on a developer's Mac, and a test that writes a
        // password onto the real system pasteboard is a test that leaks it there.
        let commands = AppCommands(environment: environment)
        XCTAssertEqual(commands.selectedEntry?.password, entry.password)
        XCTAssertEqual(commands.selectedEntry?.username, entry.username)
    }

    func testNewGroupMenuRequestRoundTrips() async {
        // Same shape as `testEditEntryCommandPublishesARequestForTheSelectedEntry`: `AppCommands`'
        // "New Group" button body, exercised without a menu bar or `VaultBrowserView`'s own
        // `groupNamePrompt` state.
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        environment.menuRequest = .newGroup
        XCTAssertEqual(environment.menuRequest, .newGroup)
    }

    // MARK: - Copy URL / Copy One-Time Code (issue #16)

    func testSelectedEntryURLResolvesAValidHTTPSURL() async {
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        guard case .unlocked(let vault) = environment.store.state,
              let entry = vault.entries.first(where: { $0.url == "https://accounts.google.com" })
        else {
            XCTFail("expected the sample vault's Gmail entry")
            return
        }
        environment.selectedEntryID = entry.id

        XCTAssertEqual(AppCommands(environment: environment).selectedEntryURL, URL(string: entry.url))
    }

    func testSelectedEntryURLIsNilWhenNothingResolves() async {
        // A bare host with no scheme (`URL(string:)` accepts it; `NSWorkspace` would silently fail
        // on it) must disable "Launch URL" / "Copy Password and Launch URL" rather than firing on
        // a value that cannot actually be opened.
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        guard case .unlocked(let vault) = environment.store.state, var entry = vault.entries.first
        else {
            XCTFail("expected the sample vault to have at least one entry")
            return
        }
        entry.url = "example.com"
        environment.store.upsert(entry)
        environment.selectedEntryID = entry.id

        XCTAssertNil(AppCommands(environment: environment).selectedEntryURL)
    }

    func testSelectedEntryTOTPGeneratorProducesACodeForAnEntryWithAOneTimeSecret() async {
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        guard case .unlocked(let vault) = environment.store.state,
              let entry = vault.entries.first(where: { $0.otpAuthURL != nil })
        else {
            XCTFail("expected the sample vault to have an entry with a one-time secret")
            return
        }
        environment.selectedEntryID = entry.id

        let generator = AppCommands(environment: environment).selectedEntryTOTPGenerator
        XCTAssertNotNil(generator)
        // `try?` flattens (SE-0230), so this is `String?`, not `String??`.
        let code = try? generator?.code(at: Date())
        XCTAssertEqual(code?.count, generator?.config.digits)
    }

    func testSelectedEntryTOTPGeneratorIsNilForAnEntryWithNoOneTimeSecret() async {
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        guard case .unlocked(let vault) = environment.store.state,
              let entry = vault.entries.first(where: { $0.otpAuthURL == nil })
        else {
            XCTFail("expected the sample vault to have an entry with no one-time secret")
            return
        }
        environment.selectedEntryID = entry.id

        XCTAssertNil(AppCommands(environment: environment).selectedEntryTOTPGenerator)
    }

    // MARK: - Document type (issue #131)

    /// Gatekeeper treated PassSumo-created `.kdbx` files as malware when Strongbox opened them,
    /// because this bundle *exported* the UTI (claiming to define the type) and ranked itself
    /// Owner. The regression is exactly those two keys.
    func testKDBXTypeIsImportedAtAlternateRank() {
        let info = Bundle.main.infoDictionary
        XCTAssertNil(
            info?["UTExportedTypeDeclarations"],
            "exporting the UTI claims we invented KDBX; that is what made Gatekeeper block Strongbox"
        )

        let imported = info?["UTImportedTypeDeclarations"] as? [[String: Any]]
        XCTAssertEqual(
            imported?.first?["UTTypeIdentifier"] as? String,
            "app.passsumo.kdbx"
        )
        XCTAssertEqual(
            imported?.first?["UTTypeConformsTo"] as? [String],
            ["public.data"]
        )
        let tags = imported?.first?["UTTypeTagSpecification"] as? [String: Any]
        XCTAssertEqual(tags?["public.filename-extension"] as? [String], ["kdbx"])

        let types = info?["CFBundleDocumentTypes"] as? [[String: Any]]
        XCTAssertEqual(
            types?.first?["LSHandlerRank"] as? String,
            "Alternate",
            "Owner is deferred to issue #132, after the shipping binary is notarized"
        )
        XCTAssertEqual(types?.first?["CFBundleTypeRole"] as? String, "Editor")
        XCTAssertEqual(
            types?.first?["LSItemContentTypes"] as? [String],
            ["app.passsumo.kdbx"]
        )
    }
}
