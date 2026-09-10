import XCTest
@testable import PassSumo

/// Issue #84: what an "open this `.kdbx`" request does to an app that holds exactly one vault.
///
/// Against a real `VaultStore` driven into each state, never through the UI — the whole reason
/// `VaultOpenRouter` is its own type is that the same rule serves three entry points (Launch
/// Services, ⌘O, `WelcomeView`'s button) and none of them is a good place to assert it from.
@MainActor
final class VaultOpenRoutingTests: XCTestCase {

    // `nonisolated(unsafe)` for the same reason `VaultStoreTests` uses it: XCTest declares
    // `setUpWithError()`/`tearDownWithError()` `nonisolated`, and one `XCTestCase` instance runs
    // setUp, the test body and tearDown strictly in sequence, never concurrently.
    nonisolated(unsafe) private var tempDirectory: URL!

    override nonisolated func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassSumoVaultOpenRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
    }

    override nonisolated func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    private func makeStore() -> VaultStore {
        VaultStore(codec: InMemoryVaultCodec(), fileAccess: InMemoryVaultFileAccess())
    }

    private func url(_ name: String) -> URL {
        tempDirectory.appendingPathComponent(name)
    }

    private func makeEntry(title: String) -> VaultEntry {
        VaultEntry(
            id: UUID(), groupID: nil, title: title, username: "", password: "",
            url: "", notes: "", otpAuthURL: nil, customFields: [:],
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0)
        )
    }

    /// Opens a vault at `url` and leaves it unlocked and clean.
    private func openVault(at url: URL, in store: VaultStore) async {
        await store.createNew(at: url, credentials: VaultCredentials(password: "pw", keyFile: nil))
        await store.save()
        XCTAssertFalse(store.isDirty, "precondition: the vault under test starts clean")
    }

    // MARK: - Case 1: nothing open

    func testRequestWithNothingOpenSelectsTheFile() {
        let store = makeStore()
        let router = VaultOpenRouter(store: store)
        let requested = url("first.kdbx")

        XCTAssertEqual(router.requestOpen(requested), .open(requested))

        XCTAssertEqual(store.state, .locked(requested))
        XCTAssertEqual(store.currentURL, requested)
        XCTAssertNil(router.unsavedChangesPrompt)
    }

    // MARK: - Case 2: the same file is already open

    func testRequestForTheFileAlreadyOpenChangesNothing() async {
        let store = makeStore()
        let router = VaultOpenRouter(store: store)
        let vaultURL = url("open.kdbx")
        await openVault(at: vaultURL, in: store)
        let stateBefore = store.state

        XCTAssertEqual(router.requestOpen(vaultURL), .alreadyOpen(vaultURL))

        // "Change nothing" is the whole acceptance criterion here: no lock, no reload, no
        // re-selection — the owner double-clicked the database they are already looking at.
        XCTAssertEqual(store.state, stateBefore)
        XCTAssertEqual(store.currentURL, vaultURL)
        XCTAssertNil(router.unsavedChangesPrompt)
    }

    func testRequestForTheFileAlreadyPickedButStillLockedChangesNothing() {
        // Same rule one state earlier: the unlock screen is up for this file and the user
        // double-clicked it again. Re-selecting would clear the password field for nothing.
        let store = makeStore()
        let router = VaultOpenRouter(store: store)
        let vaultURL = url("picked.kdbx")
        store.select(url: vaultURL)

        XCTAssertEqual(router.requestOpen(vaultURL), .alreadyOpen(vaultURL))
        XCTAssertEqual(store.state, .locked(vaultURL))
    }

    func testSamenessIsDecidedByTheResolvedPathNotTheSpelling() async {
        // `/var` is a symlink to `/private/var` on macOS, which is where `NSTemporaryDirectory()`
        // lives — so the same file genuinely reaches the app under two spellings depending on
        // whether it came from Launch Services, an `NSOpenPanel` pick or a resolved bookmark. A
        // raw string comparison here would close and reopen the database the user already had up.
        let store = makeStore()
        let router = VaultOpenRouter(store: store)
        let vaultURL = url("aliased.kdbx")
        await openVault(at: vaultURL, in: store)

        let awkward = vaultURL
            .deletingLastPathComponent()
            .appendingPathComponent(".")
            .appendingPathComponent(vaultURL.lastPathComponent)
        XCTAssertNotEqual(awkward.absoluteString, vaultURL.absoluteString, "precondition: a different spelling")

        XCTAssertEqual(router.requestOpen(awkward), .alreadyOpen(awkward))
        XCTAssertEqual(store.currentURL, vaultURL, "the store must keep the URL it already had")
    }

    // MARK: - Case 3: a different file, nothing unsaved

    func testRequestForADifferentFileWithNothingUnsavedReplacesTheOpenVault() async {
        let store = makeStore()
        let router = VaultOpenRouter(store: store)
        await openVault(at: url("first.kdbx"), in: store)
        let second = url("second.kdbx")

        XCTAssertEqual(router.requestOpen(second), .replace(second))

        XCTAssertEqual(store.state, .locked(second))
        XCTAssertEqual(store.currentURL, second)
        XCTAssertNil(router.unsavedChangesPrompt)
    }

    // MARK: - Case 4: a different file, unsaved changes

    func testRequestForADifferentFileWithUnsavedChangesAsksFirst() async {
        let store = makeStore()
        let router = VaultOpenRouter(store: store)
        let first = url("first.kdbx")
        await openVault(at: first, in: store)
        store.upsert(makeEntry(title: "Unsaved"))
        XCTAssertTrue(store.isDirty)
        let second = url("second.kdbx")

        XCTAssertEqual(router.requestOpen(second), .confirmUnsavedChanges(second))

        // Nothing has happened yet — the request is parked on the prompt.
        XCTAssertEqual(router.unsavedChangesPrompt, second)
        XCTAssertEqual(store.currentURL, first)
        XCTAssertTrue(store.isDirty)
        guard case .unlocked = store.state else {
            return XCTFail("the open vault must still be unlocked while the question is unanswered")
        }
    }

    func testCancellingAnUnsavedChangesPromptIsATrueNoOp() async {
        let store = makeStore()
        let router = VaultOpenRouter(store: store)
        let first = url("first.kdbx")
        await openVault(at: first, in: store)
        store.upsert(makeEntry(title: "Unsaved"))
        let stateBefore = store.state
        router.requestOpen(url("second.kdbx"))

        router.cancelPending()

        XCTAssertNil(router.unsavedChangesPrompt)
        XCTAssertEqual(store.state, stateBefore)
        XCTAssertEqual(store.currentURL, first)
        XCTAssertTrue(store.isDirty, "cancel must not quietly mark the vault clean")
    }

    func testDiscardingUnsavedChangesOpensTheRequestedFile() async {
        let store = makeStore()
        let router = VaultOpenRouter(store: store)
        await openVault(at: url("first.kdbx"), in: store)
        store.upsert(makeEntry(title: "Unsaved"))
        let second = url("second.kdbx")
        router.requestOpen(second)

        router.discardThenOpenPending()

        XCTAssertNil(router.unsavedChangesPrompt)
        XCTAssertEqual(store.state, .locked(second))
        XCTAssertFalse(store.isDirty)
    }

    func testSavingBeforeOpeningWritesTheOpenVaultFirst() async {
        let store = makeStore()
        let router = VaultOpenRouter(store: store)
        let first = url("first.kdbx")
        await openVault(at: first, in: store)
        store.upsert(makeEntry(title: "Unsaved"))
        let second = url("second.kdbx")
        router.requestOpen(second)

        await router.saveThenOpenPending()

        XCTAssertNil(router.unsavedChangesPrompt)
        XCTAssertFalse(store.isDirty, "the edits must be on disk before the vault is closed")
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.state, .locked(second))

        // And the edit really did reach the file, rather than the dirty flag merely being cleared.
        await store.open(url: first, credentials: VaultCredentials(password: "pw", keyFile: nil))
        guard case .unlocked(let reopened) = store.state else {
            return XCTFail("the first database must reopen")
        }
        XCTAssertTrue(reopened.entries.contains { $0.title == "Unsaved" })
    }

    // MARK: - The decision is answerable without acting on it

    func testDecisionDoesNotTouchTheStore() async {
        let store = makeStore()
        let router = VaultOpenRouter(store: store)
        let first = url("first.kdbx")
        await openVault(at: first, in: store)
        let stateBefore = store.state

        XCTAssertEqual(router.decision(for: url("second.kdbx")), .replace(url("second.kdbx")))

        XCTAssertEqual(store.state, stateBefore)
        XCTAssertEqual(store.currentURL, first)
    }
}
