import XCTest
@testable import PassSumo

/// `VaultStore` integration tests. Pairs `InMemoryVaultCodec` (no real crypto — see its doc
/// comment) with a REAL `SandboxedVaultFileAccess` pointed at a throwaway temp directory, so the
/// backup/rotation logic under test is the actual production code path, not a fake standing in
/// for it. Every test gets its own subdirectory under `FileManager.default.temporaryDirectory`,
/// removed in `tearDown` — never touches the user's real filesystem.
@MainActor
final class VaultStoreTests: XCTestCase {
    // `XCTestCase.setUpWithError()`/`tearDownWithError()` are declared `nonisolated` by XCTest
    // (they predate Swift concurrency), so a `@MainActor`-isolated stored property can't be
    // mutated from them directly. `nonisolated(unsafe)` is safe here specifically because XCTest
    // runs one test method at a time per `XCTestCase` instance — setUp, the test body, and
    // tearDown never execute concurrently with each other for the same instance.
    nonisolated(unsafe) private var tempDirectory: URL!

    override nonisolated func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassSumoVaultStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
    }

    override nonisolated func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    /// Hands out strictly increasing, whole-second-spaced timestamps without a real sleep, so a
    /// test can exercise 12 back-to-back saves (backup rotation) and stay well under the suite's
    /// <2s budget — with the real wall clock, `SandboxedVaultFileAccess`'s second-resolution
    /// backup filenames would force an actual 1s+ sleep between saves to avoid two of them
    /// colliding on the same rotation slot.
    private final class TestClock: @unchecked Sendable {
        // `@unchecked`: `counter` is only ever touched while holding `lock`.
        private let lock = NSLock()
        private var counter: TimeInterval = 0

        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            counter += 1
            return Date(timeIntervalSince1970: 1_700_000_000 + counter)
        }
    }

    private func makeFileAccess(maxKept: Int = 10, clock: TestClock = TestClock()) -> SandboxedVaultFileAccess {
        SandboxedVaultFileAccess(
            backupPolicy: .init(
                directory: { $0.deletingLastPathComponent() },
                maxKept: maxKept,
                now: { clock.next() }
            )
        )
    }

    private func makeEntry(title: String) -> VaultEntry {
        VaultEntry(
            id: UUID(), groupID: nil, title: title, username: "", password: "",
            url: "", notes: "", otpAuthURL: nil, customFields: [:],
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0)
        )
    }

    func testCreateUpsertSaveOpenRoundTrip() async {
        let vaultURL = tempDirectory.appendingPathComponent("roundtrip.kdbx")
        let codec = InMemoryVaultCodec()
        let credentials = VaultCredentials(password: "hunter2", keyFile: nil)

        let writer = VaultStore(codec: codec, fileAccess: makeFileAccess())
        await writer.createNew(at: vaultURL, credentials: credentials)
        guard case .unlocked = writer.state else {
            return XCTFail("createNew should unlock immediately")
        }

        let entry = makeEntry(title: "Round Trip")
        writer.upsert(entry)
        await writer.save()
        XCTAssertFalse(writer.isDirty)
        XCTAssertNil(writer.lastError)

        // A SECOND, independent VaultStore reads the same file back from disk — this is the part
        // that actually exercises the codec + fileAccess round trip, not just in-memory state
        // the first store already had.
        let reader = VaultStore(codec: codec, fileAccess: makeFileAccess())
        await reader.open(url: vaultURL, credentials: credentials)
        guard case .unlocked(let reopened) = reader.state else {
            return XCTFail("open should unlock a freshly saved vault")
        }
        XCTAssertTrue(reopened.entries.contains { $0.id == entry.id && $0.title == "Round Trip" })
    }

    func testWrongPasswordFailsClosed() async {
        let vaultURL = tempDirectory.appendingPathComponent("wrongpass.kdbx")
        let codec = InMemoryVaultCodec()
        let owner = VaultStore(codec: codec, fileAccess: makeFileAccess())
        await owner.createNew(at: vaultURL, credentials: VaultCredentials(password: "correct", keyFile: nil))
        await owner.save()

        let attacker = VaultStore(codec: codec, fileAccess: makeFileAccess())
        await attacker.open(url: vaultURL, credentials: VaultCredentials(password: "wrong", keyFile: nil))

        XCTAssertEqual(attacker.lastError, .wrongCredentials)
        guard case .locked(let lockedURL) = attacker.state else {
            return XCTFail("a wrong password must not unlock the store")
        }
        XCTAssertEqual(lockedURL, vaultURL)
    }

    func testLockDropsTheVault() async {
        let vaultURL = tempDirectory.appendingPathComponent("lock.kdbx")
        let codec = InMemoryVaultCodec()
        let store = VaultStore(codec: codec, fileAccess: makeFileAccess())
        await store.createNew(at: vaultURL, credentials: VaultCredentials(password: "pw", keyFile: nil))
        guard case .unlocked = store.state else {
            return XCTFail("expected unlocked after createNew")
        }

        store.lock()

        guard case .locked(let lockedURL) = store.state else {
            return XCTFail("lock() must move the store to .locked, not just clear a flag")
        }
        XCTAssertEqual(lockedURL, vaultURL)
        XCTAssertFalse(store.isDirty)
    }

    // MARK: - select(url:)

    func testSelectEntersLockedWithoutDecodingAnything() async {
        // The whole point of `select`: a file the user just picked, with NO password tried yet.
        // Note the URL does not even exist on disk here — if `select` decoded (or read) anything,
        // this would have to fail with an `.io` error instead of landing cleanly in `.locked`.
        let vaultURL = tempDirectory.appendingPathComponent("never-created.kdbx")
        let store = VaultStore(codec: InMemoryVaultCodec(), fileAccess: makeFileAccess())

        store.select(url: vaultURL)

        guard case .locked(let lockedURL) = store.state else {
            return XCTFail("select(url:) must move the store to .locked")
        }
        XCTAssertEqual(lockedURL, vaultURL)
        XCTAssertEqual(store.currentURL, vaultURL)
        XCTAssertNil(store.lastError, "a freshly picked file has not failed at anything yet")
        XCTAssertFalse(store.isDirty)
    }

    func testSelectClearsAPreviousFilesError() async {
        // `UnlockView` renders `store.lastError` unconditionally, so an error left over from the
        // previous file would greet the user with a red "wrong password" about a database they are
        // no longer looking at.
        let vaultURL = tempDirectory.appendingPathComponent("stale-error.kdbx")
        let codec = InMemoryVaultCodec()
        let store = VaultStore(codec: codec, fileAccess: makeFileAccess())
        await store.createNew(at: vaultURL, credentials: VaultCredentials(password: "correct", keyFile: nil))
        await store.save()
        store.lock()
        await store.open(url: vaultURL, credentials: VaultCredentials(password: "wrong", keyFile: nil))
        XCTAssertEqual(store.lastError, .wrongCredentials)

        store.select(url: tempDirectory.appendingPathComponent("other.kdbx"))

        XCTAssertNil(store.lastError)
    }

    func testSelectDropsRetainedSecrets() async {
        // Selecting a different file while one is open must not leave the previous vault's
        // plaintext (or its credentials) alive in memory behind a "locked" label — same reasoning
        // as `lock()`.
        let vaultURL = tempDirectory.appendingPathComponent("retained.kdbx")
        let store = VaultStore(codec: InMemoryVaultCodec(), fileAccess: makeFileAccess())
        await store.createNew(at: vaultURL, credentials: VaultCredentials(password: "pw", keyFile: nil))
        store.upsert(makeEntry(title: "Secret"))
        XCTAssertTrue(store.isDirty)

        store.select(url: tempDirectory.appendingPathComponent("elsewhere.kdbx"))

        XCTAssertFalse(store.isDirty)
        XCTAssertNil(store.currentDatabaseID, "select must drop the decoded origin, not keep it")
        // `save()` guards on `.unlocked`, so this proves the credentials went too: a store that
        // still held them would have nothing else stopping it.
        await store.save()
        XCTAssertNil(store.lastError)
    }

    func testCurrentDatabaseIDIsNilForACodecThatHasNoNotionOfOne() async {
        // `InMemoryVaultCodec` does not conform to `DatabaseIdentifyingCodec` — the accessor must
        // report "no ID" rather than inventing one, because inventing one is a write to the user's file.
        let vaultURL = tempDirectory.appendingPathComponent("noid.kdbx")
        let store = VaultStore(codec: InMemoryVaultCodec(), fileAccess: makeFileAccess())
        await store.createNew(at: vaultURL, credentials: VaultCredentials(password: "pw", keyFile: nil))
        XCTAssertNil(store.currentDatabaseID)
    }

    func testBackupExistsAfterFirstSaveToAPreexistingFile() async {
        let vaultURL = tempDirectory.appendingPathComponent("preexisting.kdbx")
        // A database that already exists on disk before this VaultStore ever touches it — e.g.
        // created by a previous app run, or by another KDBX client entirely. This is the exact
        // scenario the backup requirement exists for.
        try? Data("not a real kdbx file yet".utf8).write(to: vaultURL)

        let codec = InMemoryVaultCodec()
        let store = VaultStore(codec: codec, fileAccess: makeFileAccess())
        await store.createNew(at: vaultURL, credentials: VaultCredentials(password: "pw", keyFile: nil))
        await store.save()

        XCTAssertNotNil(store.lastBackupURL, "the very first save over a pre-existing file must produce a backup")
        if let backupURL = store.lastBackupURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        }
    }

    func testBackupRotationKeepsOnlyTheNewestTen() async {
        let vaultURL = tempDirectory.appendingPathComponent("rotate.kdbx")
        let codec = InMemoryVaultCodec()
        let credentials = VaultCredentials(password: "pw", keyFile: nil)
        let clock = TestClock()
        let store = VaultStore(codec: codec, fileAccess: makeFileAccess(clock: clock))
        await store.createNew(at: vaultURL, credentials: credentials)

        // 12 saves of a brand-new file: save #1 has nothing to back up yet (covered by
        // `testBackupExistsAfterFirstSaveToAPreexistingFile`), so saves #2–12 each produce one
        // backup — 11 backups total, already more than the default cap of 10.
        for i in 0..<12 {
            store.upsert(makeEntry(title: "Entry \(i)"))
            await store.save()
        }

        let contents = try! FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
        let backups = contents.filter { $0.lastPathComponent.hasPrefix("rotate.kdbx.bak-") }
        XCTAssertEqual(backups.count, 10)
    }
}
