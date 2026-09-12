import XCTest
@testable import PassSumo

/// Issue #47: one window, several databases as tabs. Against `VaultSessionList` and
/// `AppEnvironment` directly — no window, no SwiftUI — so the session container's rules are
/// asserted without depending on the tab bar rendering them.
@MainActor
final class VaultSessionTests: XCTestCase {

    nonisolated(unsafe) private var tempDirectory: URL!

    override nonisolated func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassSumoVaultSessionTests-\(UUID().uuidString)", isDirectory: true)
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

    private func url(_ name: String) -> URL {
        tempDirectory.appendingPathComponent(name)
    }

    private func openVault(at url: URL, in list: VaultSessionList) async -> VaultSession {
        let session = list.open(url)
        await session.store.createNew(
            at: url,
            credentials: VaultCredentials(password: "pw-\(url.lastPathComponent)", keyFile: nil)
        )
        await session.store.save()
        XCTAssertTrue(session.isUnlocked, "precondition: \(url.lastPathComponent) should be unlocked")
        XCTAssertFalse(session.store.isDirty, "precondition: \(url.lastPathComponent) starts clean")
        return session
    }

    // MARK: - Open second URL adds a tab

    func testOpeningASecondURLAddsATab() async {
        let list = makeList()
        let first = url("first.kdbx")
        let firstSession = await openVault(at: first, in: list)
        let second = url("second.kdbx")

        let added = list.open(second)

        XCTAssertEqual(list.sessions.count, 2)
        XCTAssertEqual(list.selectedID, added.id)
        XCTAssertEqual(added.store.state, .locked(second))
        XCTAssertTrue(firstSession.isUnlocked, "the first tab must stay unlocked")
        XCTAssertFalse(added.isUnlocked)
    }

    // MARK: - Open same URL focuses existing

    func testOpeningTheSameURLFocusesTheExistingTab() async {
        let list = makeList()
        let vaultURL = url("open.kdbx")
        let original = await openVault(at: vaultURL, in: list)
        list.open(url("other.kdbx"))
        XCTAssertEqual(list.sessions.count, 2)
        XCTAssertNotEqual(list.selectedID, original.id)

        let focused = list.open(vaultURL)

        XCTAssertEqual(list.sessions.count, 2, "must not duplicate the tab")
        XCTAssertEqual(focused.id, original.id)
        XCTAssertEqual(list.selectedID, original.id)
        XCTAssertTrue(original.isUnlocked, "focusing must not lock or reload")
    }

    func testSamenessIsDecidedByTheResolvedPathNotTheSpelling() async {
        let list = makeList()
        let vaultURL = url("aliased.kdbx")
        let original = await openVault(at: vaultURL, in: list)

        let awkward = vaultURL
            .deletingLastPathComponent()
            .appendingPathComponent(".")
            .appendingPathComponent(vaultURL.lastPathComponent)
        XCTAssertNotEqual(awkward.absoluteString, vaultURL.absoluteString, "precondition: a different spelling")

        let focused = list.open(awkward)
        XCTAssertEqual(list.sessions.count, 1)
        XCTAssertEqual(focused.id, original.id)
        XCTAssertEqual(original.url, vaultURL, "the session keeps the URL it was opened with")
    }

    // MARK: - Close last tab returns to Welcome

    func testClosingTheLastTabLeavesNoSessions() async {
        let list = makeList()
        let session = await openVault(at: url("only.kdbx"), in: list)

        XCTAssertEqual(list.requestClose(session.id), .closed)
        XCTAssertTrue(list.sessions.isEmpty)
        XCTAssertNil(list.selectedID)
    }

    func testClosingAMiddleTabSelectsANeighbor() async {
        let list = makeList()
        let a = list.open(url("a.kdbx"))
        let b = list.open(url("b.kdbx"))
        let c = list.open(url("c.kdbx"))
        list.select(b.id)

        XCTAssertEqual(list.requestClose(b.id), .closed)
        XCTAssertEqual(list.sessions.map(\.id), [a.id, c.id])
        XCTAssertEqual(list.selectedID, c.id, "the tab that occupied b's index takes focus")
    }

    // MARK: - Independent stores

    func testTwoSessionsCanBeInDifferentStatesWithoutSharingAStore() async {
        let list = makeList()
        let first = await openVault(at: url("unlocked.kdbx"), in: list)
        let second = list.open(url("locked.kdbx"))

        XCTAssertTrue(first.isUnlocked)
        XCTAssertEqual(second.store.state, .locked(second.url))
        XCTAssertFalse(
            first.store === second.store,
            "each tab must own its own VaultStore; sharing one is the single-vault leftover"
        )
        XCTAssertFalse(first.autoLock === second.autoLock)
    }

    func testAppEnvironmentStoreFollowsTheSelectedSession() async {
        let environment = AppEnvironment.uiTesting()
        await environment.loadUITestingFixture()
        let fixtureStore = environment.store
        XCTAssertEqual(environment.sessionList.sessions.count, 1)

        let other = url("other.kdbx")
        environment.openRouter.requestOpen(other)

        XCTAssertEqual(environment.sessionList.sessions.count, 2)
        XCTAssertFalse(environment.store === fixtureStore)
        XCTAssertEqual(environment.store.state, .locked(other))
        XCTAssertTrue(
            environment.sessionList.sessions.contains { $0.store === fixtureStore && $0.isUnlocked },
            "the fixture tab must still be unlocked behind the new one"
        )
    }

    func testHasUnlockedSessionIsTrueIfAnyTabIsUnlocked() async {
        let environment = AppEnvironment.uiTesting()
        XCTAssertFalse(environment.hasUnlockedSession)

        await environment.loadUITestingFixture()
        XCTAssertTrue(environment.hasUnlockedSession)

        environment.openRouter.requestOpen(url("locked.kdbx"))
        XCTAssertTrue(
            environment.hasUnlockedSession,
            "a locked front tab must not shrink the window while another tab is still unlocked"
        )

        for session in environment.sessionList.sessions {
            session.store.lock()
        }
        XCTAssertFalse(environment.hasUnlockedSession)
    }

    // MARK: - Close dirty tab

    func testClosingADirtyTabAsksFirst() async {
        let list = makeList()
        let session = await openVault(at: url("dirty.kdbx"), in: list)
        session.store.upsert(
            VaultEntry(
                id: UUID(), groupID: nil, title: "Unsaved", username: "", password: "",
                url: "", notes: "", otpAuthURL: nil, customFields: [:],
                created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0)
            )
        )
        XCTAssertTrue(session.store.isDirty)

        XCTAssertEqual(list.requestClose(session.id), .confirmUnsavedChanges)
        XCTAssertEqual(list.unsavedChangesCloseID, session.id)
        XCTAssertEqual(list.sessions.count, 1)
        XCTAssertTrue(session.isUnlocked)
    }

    func testDiscardingADirtyTabDropsIt() async {
        let list = makeList()
        let session = await openVault(at: url("dirty.kdbx"), in: list)
        session.store.upsert(
            VaultEntry(
                id: UUID(), groupID: nil, title: "Unsaved", username: "", password: "",
                url: "", notes: "", otpAuthURL: nil, customFields: [:],
                created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0)
            )
        )
        _ = list.requestClose(session.id)

        list.discardThenClosePending()

        XCTAssertTrue(list.sessions.isEmpty)
        XCTAssertNil(list.unsavedChangesCloseID)
    }
}
