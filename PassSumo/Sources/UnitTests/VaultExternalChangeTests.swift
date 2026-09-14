import XCTest
@testable import PassSumo

/// Issue #173 — a save must not replace a file that changed since this process decoded it.
///
/// Three layers, deliberately, because the defect needs all three proved:
///
/// 1. `ExternalChangeCheck` on its own, where every branch is one assertion rather than a store
///    state to reverse-engineer.
/// 2. `VaultStore` against a fake whose fingerprints can be doctored — which is what "the other
///    Mac wrote it" looks like without a second Mac, and the only way to produce the nastiest
///    case: same length, different modification date.
/// 3. `VaultStore` against the REAL `SandboxedVaultFileAccess` on a temp directory, because the
///    expensive way to get this wrong is a check that passes against a fake and cries wolf on
///    every second real save.
@MainActor
final class VaultExternalChangeTests: XCTestCase {
    nonisolated(unsafe) private var tempDirectory: URL!

    override nonisolated func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassSumoExternalChangeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
    }

    override nonisolated func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    // MARK: - The rule on its own

    func testUnchangedFingerprintIsNotAConflict() {
        let fingerprint = FileFingerprint(modificationDate: Date(timeIntervalSince1970: 10), size: 42)
        XCTAssertFalse(ExternalChangeCheck.isConflict(expected: fingerprint, current: fingerprint))
    }

    func testADifferentModificationDateIsAConflictEvenAtTheSameSize() {
        // The case a size-only check would miss: another client rewrote the database and it came
        // out the same length, which for a fixed-layout format is not at all unlikely.
        let expected = FileFingerprint(modificationDate: Date(timeIntervalSince1970: 10), size: 42)
        let current = FileFingerprint(modificationDate: Date(timeIntervalSince1970: 11), size: 42)
        XCTAssertTrue(ExternalChangeCheck.isConflict(expected: expected, current: current))
    }

    func testADifferentSizeIsAConflictEvenAtTheSameModificationDate() {
        let expected = FileFingerprint(modificationDate: Date(timeIntervalSince1970: 10), size: 42)
        let current = FileFingerprint(modificationDate: Date(timeIntervalSince1970: 10), size: 43)
        XCTAssertTrue(ExternalChangeCheck.isConflict(expected: expected, current: current))
    }

    func testNoBaselineIsNeverAConflict() {
        let current = FileFingerprint(modificationDate: Date(timeIntervalSince1970: 10), size: 42)
        XCTAssertFalse(ExternalChangeCheck.isConflict(expected: nil, current: current))
    }

    func testAMissingFileIsNotAConflict() {
        // Nothing at the path to lose, so writing it back destroys nothing. A volume that really
        // went away is reported by the write itself, not by this check.
        let expected = FileFingerprint(modificationDate: Date(timeIntervalSince1970: 10), size: 42)
        XCTAssertFalse(ExternalChangeCheck.isConflict(expected: expected, current: nil))
    }

    // MARK: - The store, against a doctored fingerprint

    func testSaveRefusesWhenTheFileChangedSinceDecodeAndWritesNothing() async throws {
        let harness = try await makeOpenedVault()
        let before = try harness.fileAccess.read(from: harness.url)

        harness.fileAccess.simulateExternalWrite(to: harness.url)

        harness.store.upsert(makeEntry(title: "Added here"))
        XCTAssertTrue(harness.store.isDirty)
        await harness.store.save()

        XCTAssertEqual(harness.store.lastError, .externallyModified)
        XCTAssertTrue(
            harness.store.isDirty,
            "the edits are not on disk, so the store must not report them as saved"
        )
        XCTAssertEqual(
            try harness.fileAccess.read(from: harness.url),
            before,
            "the other copy must still be on disk, byte for byte"
        )
    }

    func testARefusedSaveKeepsRefusingUntilItIsAnswered() async throws {
        // The regression this guards: adopting the file we just declined to overwrite as the new
        // baseline would let the user's next ⌘S sail straight through and clobber it in silence.
        let harness = try await makeOpenedVault()
        harness.fileAccess.simulateExternalWrite(to: harness.url)
        harness.store.upsert(makeEntry(title: "Added here"))

        await harness.store.save()
        XCTAssertEqual(harness.store.lastError, .externallyModified)

        await harness.store.save()
        XCTAssertEqual(harness.store.lastError, .externallyModified)
        XCTAssertTrue(harness.store.isDirty)
    }

    func testOverwriteWritesAndTakesTheFileBackAsTheBaseline() async throws {
        let harness = try await makeOpenedVault()
        harness.fileAccess.simulateExternalWrite(to: harness.url)
        harness.store.upsert(makeEntry(title: "Added here"))
        await harness.store.save()
        XCTAssertEqual(harness.store.lastError, .externallyModified)

        await harness.store.save(overwritingExternalChanges: true)
        XCTAssertNil(harness.store.lastError)
        XCTAssertFalse(harness.store.isDirty)

        // And the save after the overwrite is an ordinary save again: the store adopted what it
        // wrote, so it is not still comparing against the copy it was asked about.
        harness.store.upsert(makeEntry(title: "Added later"))
        await harness.store.save()
        XCTAssertNil(harness.store.lastError)
        XCTAssertFalse(harness.store.isDirty)
    }

    func testAcknowledgeClearsOnlyTheExternalChangeRefusal() async throws {
        let harness = try await makeOpenedVault()
        harness.fileAccess.simulateExternalWrite(to: harness.url)
        harness.store.upsert(makeEntry(title: "Added here"))
        await harness.store.save()

        harness.store.acknowledgeExternalChange()
        XCTAssertNil(harness.store.lastError)
        XCTAssertTrue(harness.store.isDirty, "Cancel settles the dialog, not the edits")
    }

    func testAcknowledgeLeavesAnUnrelatedFailureAlone() async throws {
        let harness = try await makeOpenedVault()
        harness.fileAccess.refusesWrites = true
        harness.store.upsert(makeEntry(title: "Added here"))
        await harness.store.save()
        XCTAssertEqual(harness.store.lastError, .io("the volume went away"))

        harness.store.acknowledgeExternalChange()
        XCTAssertEqual(
            harness.store.lastError,
            .io("the volume went away"),
            "a dialog about one failure must not dismiss a different one"
        )
    }

    func testReloadDiscardsTheEditsAndMakesTheVaultSaveableAgain() async throws {
        let harness = try await makeOpenedVault()
        harness.fileAccess.simulateExternalWrite(to: harness.url)
        harness.store.upsert(makeEntry(title: "Added here"))
        await harness.store.save()
        XCTAssertEqual(harness.store.lastError, .externallyModified)

        // What the other Mac's copy decodes to. Seeded HERE and not before the refused save,
        // because that save ran `encode` before it hit the check — the check sits after the
        // encode on purpose (see `VaultStore.performSave`) — and `InMemoryVaultCodec.encode`
        // publishes what it encodes. A real codec writes nothing until `write` is called; this
        // one has no file to write to, so the test restores what the file would still hold.
        _ = try harness.codec.encode(
            Vault(name: "From the other Mac", groups: [], entries: []),
            credentials: harness.credentials,
            origin: nil
        )

        await harness.store.reloadFromDisk()

        guard case .unlocked(let reloaded) = harness.store.state else {
            return XCTFail("reload should leave the vault unlocked, got \(harness.store.state)")
        }
        XCTAssertEqual(reloaded.name, "From the other Mac")
        XCTAssertFalse(reloaded.entries.contains { $0.title == "Added here" })
        XCTAssertFalse(harness.store.isDirty)
        XCTAssertNil(harness.store.lastError)

        // The point of reloading rather than just dismissing the error: saving works again,
        // because the store now agrees with the file it is about to replace.
        harness.store.upsert(makeEntry(title: "Added after the reload"))
        await harness.store.save()
        XCTAssertNil(harness.store.lastError)
        XCTAssertFalse(harness.store.isDirty)
    }

    func testReloadIsANoOpWhenNothingIsUnlocked() async {
        let store = VaultStore(codec: InMemoryVaultCodec(), fileAccess: InMemoryVaultFileAccess())
        await store.reloadFromDisk()
        XCTAssertEqual(store.state, .empty)
        XCTAssertNil(store.lastError)
    }

    // MARK: - The store, against the real filesystem

    /// The false-positive test, and the reason it uses `SandboxedVaultFileAccess` and a real file:
    /// a fingerprint re-read that returned a cached value (which `URL.resourceValues` does — see
    /// `SandboxedVaultFileAccess.fingerprint`) would make every save after the first report a
    /// conflict that never happened. That failure is invisible to a fake.
    func testRepeatedSavesToAnUnchangedFileNeverReportAConflict() async {
        let store = VaultStore(codec: InMemoryVaultCodec(), fileAccess: makeRealFileAccess())
        let url = tempDirectory.appendingPathComponent("Vault.kdbx")

        await store.createNew(at: url, credentials: .init(password: "pw", keyFile: nil))
        await store.save()
        XCTAssertNil(store.lastError, "the first save creates the file and has nothing to compare")

        for index in 0..<5 {
            store.upsert(makeEntry(title: "Entry \(index)"))
            await store.save()
            XCTAssertNil(store.lastError, "save \(index + 2) must not invent a conflict")
            XCTAssertFalse(store.isDirty)
        }
    }

    /// The same stack with a genuine out-of-band write between two saves — `Data.write(.atomic)`
    /// straight to the path, which is exactly what another process's rename looks like from here.
    func testARealOutOfBandWriteIsCaught() async throws {
        let store = VaultStore(codec: InMemoryVaultCodec(), fileAccess: makeRealFileAccess())
        let url = tempDirectory.appendingPathComponent("Vault.kdbx")

        await store.createNew(at: url, credentials: .init(password: "pw", keyFile: nil))
        await store.save()
        XCTAssertNil(store.lastError)

        let intruder = Data("written by somebody else".utf8)
        try intruder.write(to: url, options: [.atomic])

        store.upsert(makeEntry(title: "Added here"))
        await store.save()

        XCTAssertEqual(store.lastError, .externallyModified)
        XCTAssertEqual(try Data(contentsOf: url), intruder)
        XCTAssertTrue(store.isDirty)
    }

    // MARK: - Harness

    private struct Harness {
        let store: VaultStore
        let codec: InMemoryVaultCodec
        let fileAccess: DoctorableVaultFileAccess
        let url: URL
        let credentials: VaultCredentials
    }

    /// An unlocked vault decoded out of `fileAccess`, so the store holds a real baseline — the
    /// state every doctored-fingerprint test above starts from.
    private func makeOpenedVault() async throws -> Harness {
        let codec = InMemoryVaultCodec()
        let fileAccess = DoctorableVaultFileAccess()
        let url = URL(fileURLWithPath: "/fake/Vault.kdbx")
        let credentials = VaultCredentials(password: "correct horse", keyFile: nil)

        let onDisk = try codec.encode(
            Vault(name: "Opened", groups: [], entries: []),
            credentials: credentials,
            origin: nil
        )
        try fileAccess.write(onDisk, to: url)

        let store = VaultStore(codec: codec, fileAccess: fileAccess)
        await store.open(url: url, credentials: credentials)
        guard case .unlocked = store.state else {
            throw XCTSkip("could not open the fixture vault: \(String(describing: store.lastError))")
        }
        return Harness(store: store, codec: codec, fileAccess: fileAccess, url: url, credentials: credentials)
    }

    /// A real `SandboxedVaultFileAccess` whose backups land under this test's own temp directory
    /// rather than the production `<Application Support>` root, which an unsigned `make test`
    /// would resolve to the developer's real, shared one.
    private func makeRealFileAccess() -> SandboxedVaultFileAccess {
        var policy = VaultBackupPolicy.default
        let root = tempDirectory.appendingPathComponent("Backups", isDirectory: true)
        policy.root = { root }
        return SandboxedVaultFileAccess(backupPolicy: policy)
    }

    private func makeEntry(title: String) -> VaultEntry {
        VaultEntry(
            id: UUID(), groupID: nil, title: title, username: "", password: "",
            url: "", notes: "", otpAuthURL: nil, customFields: [:],
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0)
        )
    }

    /// `InMemoryVaultFileAccess` plus the one thing a conflict test needs and no production code
    /// should have: a way to make the file look like somebody else wrote it.
    ///
    /// A wrapper here rather than a mutator on the production fake, following
    /// `SessionLockAndQuitTests.RefusingVaultFileAccess`. `InMemoryVaultFileAccess` ships inside
    /// the app target — previews and the `-ui-testing 1` seam run on it — and a method only tests
    /// call has no business being reachable from there.
    private final class DoctorableVaultFileAccess: VaultFileAccess, @unchecked Sendable {
        private let lock = NSLock()
        private let backing = InMemoryVaultFileAccess()
        private var refusing = false
        private var overrides: [URL: FileFingerprint] = [:]

        var refusesWrites: Bool {
            get { lock.lock(); defer { lock.unlock() }; return refusing }
            set { lock.lock(); refusing = newValue; lock.unlock() }
        }

        /// Moves the file's fingerprint on without touching its bytes or telling the store — the
        /// hardest case to catch, and the one a content-length check alone would sail past.
        func simulateExternalWrite(to url: URL) {
            lock.lock(); defer { lock.unlock() }
            let current = backing.fingerprint(of: url)
            overrides[url] = FileFingerprint(
                modificationDate: Date(timeIntervalSince1970: 2_000_000_000),
                size: current?.size ?? 0
            )
        }

        func read(from url: URL) throws -> Data { try backing.read(from: url) }

        func fingerprint(of url: URL) -> FileFingerprint? {
            lock.lock()
            let override = overrides[url]
            lock.unlock()
            return override ?? backing.fingerprint(of: url)
        }

        @discardableResult
        func write(_ data: Data, to url: URL) throws -> VaultBackupOutcome {
            guard !refusesWrites else { throw VaultError.io("the volume went away") }
            let outcome = try backing.write(data, to: url)
            // Our own write ends the pretence: the file really is ours now, so the doctored
            // fingerprint must stop shadowing the backing store's.
            lock.lock(); overrides[url] = nil; lock.unlock()
            return outcome
        }

        func bookmark(for url: URL) throws -> Data { try backing.bookmark(for: url) }

        func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
            try backing.resolveBookmark(data)
        }

        func backupDirectory(for url: URL?) -> URL? { backing.backupDirectory(for: url) }
    }
}
