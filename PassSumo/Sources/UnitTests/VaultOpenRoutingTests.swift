import XCTest
@testable import PassSumo

/// Issue #84, retargeted by #47: what an "open this `.kdbx`" request does to an app that holds a
/// list of database tabs.
///
/// Against a real `VaultSessionList` driven into each state, never through the UI — the whole
/// reason `VaultOpenRouter` is its own type is that the same rule serves three entry points
/// (Launch Services, ⌘O, `WelcomeView`'s button) and none of them is a good place to assert it
/// from.
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

    private func makeList() -> VaultSessionList {
        VaultSessionList(
            codec: InMemoryVaultCodec(),
            fileAccess: InMemoryVaultFileAccess(),
            autoLockTimeout: 300
        )
    }

    private func makeRouter(_ list: VaultSessionList) -> VaultOpenRouter {
        VaultOpenRouter(sessionList: list)
    }

    private func url(_ name: String) -> URL {
        tempDirectory.appendingPathComponent(name)
    }

    /// Opens a vault at `url` and leaves it unlocked.
    private func openVault(at url: URL, in list: VaultSessionList) async -> VaultSession {
        let session = list.open(url)
        await session.store.createNew(
            at: url,
            credentials: VaultCredentials(password: "pw-\(url.lastPathComponent)", keyFile: nil)
        )
        await session.store.save()
        XCTAssertTrue(session.isUnlocked, "precondition: the vault under test starts unlocked")
        XCTAssertFalse(session.store.isDirty, "precondition: the vault under test starts clean")
        return session
    }

    // MARK: - Case 1: nothing open

    func testRequestWithNothingOpenSelectsTheFile() {
        let list = makeList()
        let router = makeRouter(list)
        let requested = url("first.kdbx")

        XCTAssertEqual(router.requestOpen(requested), .open(requested))

        XCTAssertEqual(list.sessions.count, 1)
        XCTAssertEqual(list.selected?.url, requested)
        XCTAssertEqual(list.selected?.store.state, .locked(requested))
    }

    // MARK: - Case 2: the same file is already a tab

    func testRequestForTheFileAlreadyOpenChangesNothing() async {
        let list = makeList()
        let router = makeRouter(list)
        let vaultURL = url("open.kdbx")
        let session = await openVault(at: vaultURL, in: list)
        let stateBefore = session.store.state

        XCTAssertEqual(router.requestOpen(vaultURL), .alreadyOpen(vaultURL))

        XCTAssertEqual(list.sessions.count, 1)
        XCTAssertEqual(session.store.state, stateBefore)
        XCTAssertEqual(list.selectedID, session.id)
    }

    func testRequestForTheFileAlreadyPickedButStillLockedChangesNothing() {
        let list = makeList()
        let router = makeRouter(list)
        let vaultURL = url("picked.kdbx")
        list.open(vaultURL)

        XCTAssertEqual(router.requestOpen(vaultURL), .alreadyOpen(vaultURL))
        XCTAssertEqual(list.sessions.count, 1)
        XCTAssertEqual(list.selected?.store.state, .locked(vaultURL))
    }

    func testSamenessIsDecidedByTheResolvedPathNotTheSpelling() async {
        let list = makeList()
        let router = makeRouter(list)
        let vaultURL = url("aliased.kdbx")
        let session = await openVault(at: vaultURL, in: list)

        let awkward = vaultURL
            .deletingLastPathComponent()
            .appendingPathComponent(".")
            .appendingPathComponent(vaultURL.lastPathComponent)
        XCTAssertNotEqual(awkward.absoluteString, vaultURL.absoluteString, "precondition: a different spelling")

        XCTAssertEqual(router.requestOpen(awkward), .alreadyOpen(awkward))
        XCTAssertEqual(list.sessions.count, 1)
        XCTAssertEqual(session.url, vaultURL, "the session must keep the URL it already had")
    }

    // MARK: - Case 3: a different file becomes another tab

    func testRequestForADifferentFileAddsATab() async {
        let list = makeList()
        let router = makeRouter(list)
        let first = await openVault(at: url("first.kdbx"), in: list)
        let second = url("second.kdbx")

        XCTAssertEqual(router.requestOpen(second), .addTab(second))

        XCTAssertEqual(list.sessions.count, 2)
        XCTAssertEqual(list.selected?.url, second)
        XCTAssertEqual(list.selected?.store.state, .locked(second))
        XCTAssertTrue(first.isUnlocked, "opening another database must not lock the one that was open")
    }

    func testRequestForADifferentFileWithUnsavedChangesStillAddsATab() async {
        let list = makeList()
        let router = makeRouter(list)
        let first = await openVault(at: url("first.kdbx"), in: list)
        first.store.upsert(
            VaultEntry(
                id: UUID(), groupID: nil, title: "Unsaved", username: "", password: "",
                url: "", notes: "", otpAuthURL: nil, customFields: [:],
                created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0)
            )
        )
        XCTAssertTrue(first.store.isDirty)
        let second = url("second.kdbx")

        XCTAssertEqual(router.requestOpen(second), .addTab(second))

        XCTAssertEqual(list.sessions.count, 2)
        XCTAssertTrue(first.store.isDirty, "the first tab keeps its unsaved edits")
        XCTAssertTrue(first.isUnlocked)
        XCTAssertEqual(list.selected?.url, second)
    }

    // MARK: - The decision is answerable without acting on it

    func testDecisionDoesNotTouchTheList() async {
        let list = makeList()
        let router = makeRouter(list)
        let first = url("first.kdbx")
        _ = await openVault(at: first, in: list)
        let stateBefore = list.selected?.store.state
        let idBefore = list.selectedID

        XCTAssertEqual(router.decision(for: url("second.kdbx")), .addTab(url("second.kdbx")))

        XCTAssertEqual(list.sessions.count, 1)
        XCTAssertEqual(list.selected?.store.state, stateBefore)
        XCTAssertEqual(list.selectedID, idBefore)
    }
}
