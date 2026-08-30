import Foundation
import Observation

/// The composition root: the one place that constructs every long-lived collaborator and decides
/// which concrete types back them. No view, and no other file in `Sources/App`, ever constructs a
/// `VaultStore`, a codec, or a `VaultFileAccess` itself — they all receive this object (or values
/// read off it) instead. That is Dependency Inversion applied one level up from `VaultStore` itself:
/// the store already refuses to construct its own codec/file-access (see its doc comment), and this
/// type is what stops that decision from being re-made — differently, and inconsistently — at every
/// call site above it.
///
/// **This is the seam the whole e2e suite depends on.** `live()` is a real launch; `uiTesting()` is
/// what `-ui-testing 1` selects (see `PassSumoApp`): no real crypto, no real file I/O, no Touch ID
/// prompt, a deterministic `Vault.sample` already loaded. Every `PassSumoUITests` assertion is only
/// as trustworthy as this one switch being wired correctly, hence the comment density below.
@MainActor
@Observable
final class AppEnvironment {
    let store: VaultStore
    let clipboard: ClipboardService
    let autoLock: AutoLockController
    let generator: PasswordGenerator
    let codec: any VaultCodec
    let biometrics: BiometricUnlock
    // `var`, not `let`: `SettingsView` reaches it as `$environment.settings.autoLockTimeout` via
    // `@Bindable`, and a keypath-derived `Binding` requires every component along the path to be
    // settable — even though `settings` itself is never reassigned, and even though it is a
    // reference type whose *contents* were always mutable through a `let`. This property is never
    // actually written to a second time; the setter exists only to satisfy that keypath requirement.
    var settings: AppSettings

    /// True when launched with `-ui-testing 1`. Read once here rather than re-queried from
    /// `UserDefaults` all over the app, so every call site agrees on which mode is active even if
    /// something later in the process flips the default (the previous placeholder `AppEnvironment`
    /// read `UserDefaults.standard` directly for this; that direct read now lives only in
    /// `PassSumoApp`, once, to decide which factory to call).
    let isUITesting: Bool

    /// Never exposed publicly: nothing above `VaultStore.open`/`.save` needs raw file access, and
    /// keeping it private is what stops a future view from reaching around the store to read a
    /// `.kdbx` file directly. The two narrow capabilities the UI layer legitimately needs from it —
    /// "mint me a Touch ID identifier", "remember this as a recent database" — are the methods
    /// below, not the type itself.
    private let fileAccess: any VaultFileAccess

    // MARK: - Cross-cutting UI state
    //
    // These two properties exist because `AppCommands` and the views need a shared place to
    // coordinate with each other across a boundary they have no direct reference over: SwiftUI's
    // `Commands` body is built OUTSIDE the view tree, and `WelcomeView`/`VaultBrowserView` are
    // siblings under `RootView`, never parent and child. `AppEnvironment` is already the object
    // every one of those holds, so it is the shared blackboard.
    //
    // **This is the app's single menu↔view mechanism; there is deliberately no second one.** The
    // idiomatic SwiftUI alternative — `.focusedSceneValue` + `@FocusedValue` in `AppCommands` —
    // was considered and rejected for two concrete reasons. First, half of this channel was
    // already load-bearing: `WelcomeView` consumes `.openDatabase`/`.newDatabase` through
    // `menuRequest` today, so adopting focused values would have meant rebuilding a working half
    // to avoid leaving two mechanisms half-wired. Second, focused *scene* values model a
    // per-window selection, and this app has exactly one `VaultStore` holding exactly one vault
    // (see its doc comment) — a second window would show the same vault, so a per-scene selection
    // is state the model cannot actually back. The concrete win is testability: `AppShellTests`
    // exercises every enablement rule below by setting these directly, with no window and no
    // focus, which a `@FocusedValue` in a `Commands` struct cannot offer.

    /// The entry the vault browser currently has selected, or `nil`. `VaultBrowserView` mirrors its
    /// own `@State` selection into this (see its `.onChange(of: selectedEntryID)`), and clears it on
    /// disappear so a lock cannot leave a stale id behind; `AppCommands` reads it to decide whether
    /// Edit/Delete/Copy Username/Copy Password are enabled, per the rule that a shortcut needing a
    /// selection must be disabled when there is none rather than silently no-op.
    var selectedEntryID: UUID?

    /// A pending ask from the menu bar for a view that owns the relevant UI — see `MenuRequest`'s
    /// own doc comment (`AppCommands.swift`) for the full reasoning and which view handles which
    /// case.
    var menuRequest: MenuRequest?

    private init(
        store: VaultStore,
        clipboard: ClipboardService,
        autoLock: AutoLockController,
        generator: PasswordGenerator,
        codec: any VaultCodec,
        biometrics: BiometricUnlock,
        fileAccess: any VaultFileAccess,
        settings: AppSettings,
        isUITesting: Bool
    ) {
        self.store = store
        self.clipboard = clipboard
        self.autoLock = autoLock
        self.generator = generator
        self.codec = codec
        self.biometrics = biometrics
        self.fileAccess = fileAccess
        self.settings = settings
        self.isUITesting = isUITesting
    }

    // MARK: - Factories

    /// A real launch: sandboxed, backed-up file I/O and Touch ID for real.
    static func live() -> AppEnvironment {
        let fileAccess: any VaultFileAccess = SandboxedVaultFileAccess()
        // The real KDBX 4.x codec (`Sources/KDBX`, owner: KDBX) — landed mid-session; `Sources/KDBX`
        // was empty when this file was first written, so this line started as `InMemoryVaultCodec()`
        // with a TODO to swap it the moment a real codec existed. `KDBXKitCodec` is stateless
        // (`struct ...: VaultCodec`, no stored state), so constructing it here costs nothing.
        let codec: any VaultCodec = KDBXKitCodec()

        let store = VaultStore(codec: codec, fileAccess: fileAccess)
        let autoLock = AutoLockController(onLock: { [weak store] in store?.lock() })
        let settings = AppSettings(defaults: .standard)
        autoLock.idleTimeout = settings.autoLockTimeout
        let clipboard = ClipboardService(clearInterval: settings.clipboardClearTimeout)

        return AppEnvironment(
            store: store,
            clipboard: clipboard,
            autoLock: autoLock,
            generator: PasswordGenerator(),
            codec: codec,
            biometrics: BiometricUnlock(),
            fileAccess: fileAccess,
            settings: settings,
            isUITesting: false
        )
    }

    /// The whole `-ui-testing 1` seam: `InMemoryVaultCodec` + `InMemoryVaultFileAccess`, biometrics
    /// bypassed, `Vault.sample` pre-loaded. Every `PassSumoUITests` case depends on this being wired
    /// correctly.
    ///
    /// Returns synchronously with `store.state` still `.empty` — `VaultStore.open` is `async` (it
    /// always round-trips through a detached `Task`, even against a fake codec with nothing slow to
    /// do; see that method's doc comment), and a synchronous factory called from a `View`/`App`'s
    /// `@State` initial value cannot `await` anything. Call `loadUITestingFixture()` once, from an
    /// `async` context, to actually reach `.unlocked` — `RootView` does this via `.task`;
    /// `AppShellTests` awaits it directly so the assertion has no race to lose.
    static func uiTesting() -> AppEnvironment {
        let fileAccess: any VaultFileAccess = InMemoryVaultFileAccess()
        let codec: any VaultCodec = InMemoryVaultCodec()

        // Seed the fake "file" synchronously — `encode`/`write` are plain synchronous `throws`
        // calls on both fakes, unlike `VaultStore.open`, so this much can happen right here with no
        // `Task` involved. `try?`: if this somehow failed, `loadUITestingFixture()` would simply
        // find nothing at the URL and fail closed into `.locked`, never a crash.
        if let bytes = try? codec.encode(Vault.sample, credentials: uiTestingCredentials, origin: nil) {
            _ = try? fileAccess.write(bytes, to: uiTestingVaultURL)
        }

        let store = VaultStore(codec: codec, fileAccess: fileAccess)
        let autoLock = AutoLockController(onLock: { [weak store] in store?.lock() })
        // A real `UserDefaults.standard` is fine here too: `AppShellTests` exercises `AppSettings`
        // against its own scratch suite directly, never through this factory, so there is no
        // pollution risk specific to `uiTesting()` reusing the app's real preferences domain.
        let settings = AppSettings(defaults: .standard)
        autoLock.idleTimeout = settings.autoLockTimeout
        let clipboard = ClipboardService(clearInterval: settings.clipboardClearTimeout)

        // `NoBiometricsSecretStore` (below) rather than the real `KeychainSecretStore`: a hosted
        // `make e2e` run must never depend on this Mac's keychain state or prompt for Touch ID, and
        // a CI machine has no fingerprints enrolled to prompt for anyway. `BiometricUnlock.isEnabled`
        // becomes unconditionally `false` against it, which is exactly "bypasses biometrics".
        let biometrics = BiometricUnlock(store: NoBiometricsSecretStore())

        return AppEnvironment(
            store: store,
            clipboard: clipboard,
            autoLock: autoLock,
            generator: PasswordGenerator(),
            codec: codec,
            biometrics: biometrics,
            fileAccess: fileAccess,
            settings: settings,
            isUITesting: true
        )
    }

    /// URL and credentials the `-ui-testing` fixture is seeded and unlocked with. `static let`
    /// rather than a value buried inside `uiTesting()` so `loadUITestingFixture()` can reference the
    /// exact same constants without either method having to hand them to the other.
    static let uiTestingVaultURL = URL(fileURLWithPath: "/ui-testing/sample.kdbx")
    static let uiTestingCredentials = VaultCredentials(password: "ui-testing-fixture", keyFile: nil)

    /// Actually unlocks the fixture `uiTesting()` seeded. No-op when not in UI-testing mode or when
    /// something has already moved `store.state` past `.empty` (calling it twice must not re-run a
    /// second, redundant `open`).
    func loadUITestingFixture() async {
        guard isUITesting, case .empty = store.state else { return }
        await store.open(url: Self.uiTestingVaultURL, credentials: Self.uiTestingCredentials)
    }

    // MARK: - Narrow file-access capabilities for the UI layer

    /// Stable identity for the database at `url`, for the one question `UnlockView` needs answered:
    /// "is Touch ID set up for this database".
    ///
    /// Prefers the database's OWN identifier — a UUID KDBX keeps in `Meta/CustomData`, read back by
    /// `VaultStore.currentDatabaseID` — because that is the only candidate that survives a rename, a
    /// move, an iCloud relocation, and a round-trip through another KDBX client, and (unlike the
    /// header's master seed) does not change on every save.
    ///
    /// **A read must never mutate the user's vault, so this never assigns one.** Giving a database
    /// an ID means appending to `Meta/CustomData`, which reaches disk on the next save — merely
    /// opening a file, possibly from a synced folder or a read-only backup, must not rewrite it.
    /// Assignment belongs to the moment the user opts into Touch ID for that database (via
    /// `KDBXKitCodec.assigningDatabaseID`, followed by a deliberate save); until then this falls
    /// back to hashing the security-scoped bookmark's bytes, which is what macOS itself uses to keep
    /// tracking a file across renames/moves inside the sandbox grant — weaker than the in-file ID,
    /// but far better than a bare path (see `VaultKeyIdentifier.derived(from:)`'s own caveat).
    ///
    /// At `UnlockView`'s call site the vault is by definition still locked, so `currentDatabaseID`
    /// is `nil` there and reading the in-file UUID directly is not an option — that requires the
    /// Argon2-derived key. So a pre-unlock lookup instead consults
    /// `enrolledDatabaseIDsByBookmarkHash`, a small persisted map from the bookmark-hash identifier
    /// (the best pre-decrypt stand-in for identity) to the real in-file UUID, written once by
    /// `rememberBiometricsEnrollment(_:for:)` at the moment the user enables Touch ID. Without that
    /// map, this method would answer two different questions before and after unlock — bookmark
    /// hash pre-unlock, in-file UUID post-unlock — and the keychain item enrolled under the latter
    /// would never be found by a pre-unlock lookup asking the former, so "Unlock with Touch ID"
    /// would never reappear after the very first enrollment. The map closes that gap.
    func biometricsIdentifier(for url: URL) -> VaultKeyIdentifier? {
        if let databaseID = store.currentDatabaseID {
            return VaultKeyIdentifier(databaseID.uuidString)
        }
        guard let bookmark = try? fileAccess.bookmark(for: url) else { return nil }
        let bookmarkIdentifier = VaultKeyIdentifier.derived(from: bookmark)
        if let mappedUUID = enrolledDatabaseIDsByBookmarkHash[bookmarkIdentifier.rawValue] {
            return VaultKeyIdentifier(mappedUUID)
        }
        return bookmarkIdentifier
    }

    private static let enrolledDatabaseIDsDefaultsKey = "biometrics.enrolledDatabaseIDsByBookmarkHash"

    /// Persisted map from a pre-unlock bookmark-hash identifier to the database's own stable
    /// `Meta/CustomData` UUID — see `biometricsIdentifier(for:)`'s doc comment for why this exists.
    ///
    /// This is **not** secret — a UUID association, never the master password itself — so
    /// `UserDefaults` is an appropriate place for it, same reasoning as `recentDatabaseBookmarks`
    /// just below. Keyed by the bookmark-hash's raw hex string rather than `VaultKeyIdentifier`
    /// itself, since `UserDefaults` needs a plist-representable dictionary.
    private var enrolledDatabaseIDsByBookmarkHash: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: Self.enrolledDatabaseIDsDefaultsKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.enrolledDatabaseIDsDefaultsKey) }
    }

    /// Records that `databaseID` is the identifier Touch ID was enrolled under for the database at
    /// `url`, so a later pre-unlock `biometricsIdentifier(for:)` call can still resolve to it (see
    /// that method's doc comment). Called once, right after `VaultStore.assignDatabaseIDIfNeeded()`
    /// and `BiometricUnlock.enable` both succeed.
    ///
    /// Best-effort and silent on failure, same reasoning as `rememberRecentDatabase(_:)`: by the
    /// time this runs the keychain item already exists, and a lookup that fails to fast-path
    /// through the map merely falls back to decrypting normally next time — not a correctness bug,
    /// just a missed convenience. Guarded by `!isUITesting` for the same reason
    /// `rememberRecentDatabase(_:)` is: an e2e run must never write into the developer's real
    /// `UserDefaults.standard` domain.
    func rememberBiometricsEnrollment(_ databaseID: UUID, for url: URL) {
        guard !isUITesting, let bookmark = try? fileAccess.bookmark(for: url) else { return }
        var map = enrolledDatabaseIDsByBookmarkHash
        map[VaultKeyIdentifier.derived(from: bookmark).rawValue] = databaseID.uuidString
        enrolledDatabaseIDsByBookmarkHash = map
    }

    /// Removes whatever `rememberBiometricsEnrollment(_:for:)` recorded for `url`. Called when the
    /// user turns Touch ID off (`SettingsView`) and when a stale, invalidated-by-biometry-change
    /// keychain item is cleared out (`UnlockView`) — in both cases the mapping must not keep
    /// pointing an `isEnabled` check at a secret that no longer exists.
    func forgetBiometricsEnrollment(for url: URL) {
        guard !isUITesting, let bookmark = try? fileAccess.bookmark(for: url) else { return }
        var map = enrolledDatabaseIDsByBookmarkHash
        map.removeValue(forKey: VaultKeyIdentifier.derived(from: bookmark).rawValue)
        enrolledDatabaseIDsByBookmarkHash = map
    }

    /// Resolves a bookmark minted by `rememberRecentDatabase(_:)`, for `WelcomeView`'s recent-
    /// databases list. `nil` when the bookmark can no longer be resolved at all (file deleted,
    /// volume unmounted) — `WelcomeView` is expected to simply drop that entry rather than show it.
    func resolveRecentDatabase(_ bookmark: Data) -> URL? {
        (try? fileAccess.resolveBookmark(bookmark))?.url
    }

    private static let recentDatabasesDefaultsKey = "recentDatabaseBookmarks"
    private static let maxRecentDatabases = 5

    /// Bookmarks of databases opened or created before, newest first — `WelcomeView`'s recent-
    /// databases list reads this directly. Stored as raw bookmark `Data`, never a path (see
    /// `VaultFileAccess.bookmark(for:)`'s own doc comment on why a bookmark, not a path, is what
    /// regains sandboxed access on a later launch without re-prompting via `NSOpenPanel`).
    var recentDatabaseBookmarks: [Data] {
        get { UserDefaults.standard.array(forKey: Self.recentDatabasesDefaultsKey) as? [Data] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.recentDatabasesDefaultsKey) }
    }

    /// Records `url` as the most recently used database, minting a fresh bookmark for it. Best-
    /// effort and silent on failure: the database was already opened/created successfully by the
    /// time this runs, and a recent-databases list that fails to grow is not worth surfacing as an
    /// error over. No-ops under `-ui-testing 1` so an e2e run never writes into the developer's real
    /// `UserDefaults.standard` domain.
    func rememberRecentDatabase(_ url: URL) {
        guard !isUITesting, let bookmark = try? fileAccess.bookmark(for: url) else { return }
        var bookmarks = recentDatabaseBookmarks
        // De-duped by the URL a bookmark *resolves to*, not by raw bookmark bytes — two bookmarks
        // minted for the same file are not byte-identical, so a byte comparison would never dedupe
        // and the list would grow by one every time the same database is reopened.
        bookmarks.removeAll { resolveRecentDatabase($0) == url }
        bookmarks.insert(bookmark, at: 0)
        recentDatabaseBookmarks = Array(bookmarks.prefix(Self.maxRecentDatabases))
    }
}

/// What a `VaultError` should say to the person looking at `UnlockView` or `WelcomeView`'s create
/// sheet. Kept here, not on `VaultError` itself: `Domain.swift`'s own doc comment says the type is
/// deliberately flat so it is "directly displayable... without unwrapping a chain of causes" — the
/// exact wording of that display is this layer's job, not the model's. `internal` (not `private`)
/// because both of those files need the same wording; duplicating this switch per-file would be the
/// kind of drift a shared error type exists to avoid.
extension VaultError {
    var displayMessage: String {
        switch self {
        case .wrongCredentials:
            return "Wrong password. Try again."
        case .notAKDBXFile:
            return "This isn't a KDBX database file."
        case .unsupportedVersion(let version):
            return "Unsupported KDBX version: \(version)."
        case .corrupted(let detail):
            return "The database file looks corrupted: \(detail)"
        case .unsupportedFeature(let feature):
            return "This database uses a feature pass-sumo doesn't support yet: \(feature)"
        case .io(let detail):
            return "Couldn't read the file: \(detail)"
        }
    }
}

/// A `SecretStore` that stores nothing and reports nothing enrolled — see `uiTesting()`'s comment
/// on why the fake wraps this instead of ever constructing a real `KeychainSecretStore`. `private`:
/// nothing outside this file has a reason to construct one directly.
private struct NoBiometricsSecretStore: SecretStore {
    func store(_ secret: SecureBytes, for id: VaultKeyIdentifier) throws {}

    func retrieve(for id: VaultKeyIdentifier, reason: String) throws -> SecureBytes {
        throw BiometricUnlockError.notEnrolledForThisVault
    }

    func delete(for id: VaultKeyIdentifier) throws {}

    func hasSecret(for id: VaultKeyIdentifier) throws -> Bool { false }
}
