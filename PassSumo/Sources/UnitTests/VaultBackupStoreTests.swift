import XCTest
@testable import PassSumo

/// `VaultBackupStore` — where a pre-save backup goes, how it is named per database, and what
/// retention keeps.
///
/// Everything here runs against a real filesystem, in a per-test temp directory that `tearDown`
/// removes, because every property under test is a property of the filesystem: which directory a
/// file lands in, which files a prune deletes, what happens when the destination cannot be created.
/// A fake `FileManager` would be a re-implementation of the thing being tested.
///
/// The one thing NOT exercised here is the production root. `VaultBackupStore.defaultRoot` resolves
/// to `<Application Support>/PassSumo/Backups`, which under an unsigned `make test` is the
/// developer's own shared Application Support — so a test that wrote there would litter a directory
/// it does not own. Its shape is asserted instead (`testDefaultRootIsUnderApplicationSupport`), and
/// that it is actually writable inside a real App Sandbox container is
/// `DurabilityTests/AtomicWriteTests.testAtomicWriteWorksInsideTheRealAppSandboxContainer`'s job,
/// under `make durability-signed`.
final class VaultBackupStoreTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassSumoBackupStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
        temp = nil
    }

    // MARK: - Helpers

    /// The epoch every clock below is offset from. A fixed instant rather than "now" so a failing
    /// run prints the same filenames every time.
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Hands out strictly increasing timestamps `step` apart, so a test can drive a dozen saves
    /// without a dozen real seconds of sleeping — a backup filename's resolution is one second, so
    /// the real clock would collide back-to-back saves into a single slot.
    ///
    /// Note that one `backUp` call reads the clock TWICE (once to stamp the file, once for the age
    /// comparison in `prune`), so consecutive backups land two steps apart, not one. That is
    /// harmless for these tests — all they need is a strictly increasing sequence — but it is why
    /// the age test drives the clock by hand instead.
    private final class TickingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var counter = 0
        private let step: TimeInterval

        init(step: TimeInterval = 1) { self.step = step }

        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            counter += 1
            return VaultBackupStoreTests.epoch.addingTimeInterval(Double(counter) * step)
        }
    }

    /// A clock stuck at one instant, for the age test: `prune` must compare a backup's stamp
    /// against a "now" the test chose, not against one that drifted while the backup was taken.
    private final class FrozenClock: @unchecked Sendable {
        private let at: Date
        init(daysAfterEpoch: Double) {
            at = VaultBackupStoreTests.epoch.addingTimeInterval(daysAfterEpoch * 24 * 60 * 60)
        }
        func read() -> Date { at }
    }

    private func makeStore(
        root: URL? = nil,
        maxCount: Int = 10,
        maxAge: TimeInterval = VaultBackupPolicy.default.maxAge,
        maxTotalBytes: Int = VaultBackupPolicy.default.maxTotalBytes,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> VaultBackupStore {
        let resolved = root ?? temp.appendingPathComponent("Backups", isDirectory: true)
        return VaultBackupStore(policy: .init(
            root: { resolved },
            maxCount: maxCount,
            maxAge: maxAge,
            maxTotalBytes: maxTotalBytes,
            now: now
        ))
    }

    /// A `.kdbx`-shaped file of `byteCount` bytes at `path` under `temp`.
    @discardableResult
    private func makeVault(_ path: String, byteCount: Int = 64) throws -> URL {
        let url = temp.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: byteCount).write(to: url)
        return url
    }

    // MARK: - Location

    /// The destination is inside the app's own Application Support, obtained from `FileManager` —
    /// which under the App Sandbox is the app's container, needing no entitlement. The assertion is
    /// on the shape, not on a literal path: a hardcoded `~/Library/Containers/...` is exactly what
    /// this code must never contain.
    func testDefaultRootIsUnderApplicationSupport() throws {
        let root = try VaultBackupStore.defaultRoot(fileManager: .default)
        XCTAssertEqual(root.lastPathComponent, "Backups")
        XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "PassSumo")
        XCTAssertTrue(
            root.path.contains("/Library/Application Support/"),
            "the backup root is not under Application Support: \(root.path)"
        )
        XCTAssertFalse(root.path.contains("~"), "the path was built by string expansion")
    }

    /// The backup lands in the backup root and nowhere near the user's database — the whole point
    /// of issue #26, since a `.kdbx` picked through `NSOpenPanel` is granted as a file, not as its
    /// directory.
    func testTheBackupLandsInTheBackupRootAndNotBesideTheVault() throws {
        let vault = try makeVault("Documents/Personal.kdbx")
        let root = temp.appendingPathComponent("Backups", isDirectory: true)

        let outcome = makeStore().backUp(vault)

        let backup = try XCTUnwrap(outcome.url, "expected a backup, got \(outcome)")
        XCTAssertTrue(
            backup.path.hasPrefix(root.path + "/"),
            "the backup is outside the backup root: \(backup.path)"
        )
        XCTAssertEqual(
            try Data(contentsOf: backup), try Data(contentsOf: vault),
            "the backup is not a copy of the file"
        )

        let siblings = try FileManager.default.contentsOfDirectory(
            at: vault.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            siblings.map(\.lastPathComponent), ["Personal.kdbx"],
            "something was written next to the user's database"
        )
    }

    /// A backup keeps the `.kdbx` extension, so what the user finds through "Show Backups in
    /// Finder" opens in this app, KeePassXC or Strongbox by double-clicking — unlike the old
    /// `<name>.kdbx.bak-<stamp>`, which no KDBX client recognises.
    func testABackupIsStillNamedLikeADatabase() throws {
        let vault = try makeVault("Personal.kdbx")
        let clock = TickingClock()
        let outcome = makeStore(now: { clock.next() }).backUp(vault)

        let backup = try XCTUnwrap(outcome.url)
        XCTAssertEqual(backup.pathExtension, "kdbx")
        XCTAssertTrue(
            backup.deletingPathExtension().lastPathComponent.hasPrefix("Personal-"),
            "the backup does not name the database it came from: \(backup.lastPathComponent)"
        )
    }

    /// A brand-new database — the first save is what creates the file — has no previous version, so
    /// there is nothing to back up. That is `.notNeeded`, which must not read as a failure: it would
    /// otherwise put a warning in the UI on every "New Database…".
    func testNothingToBackUpIsNotAFailure() throws {
        let missing = temp.appendingPathComponent("never-existed.kdbx")
        let outcome = makeStore().backUp(missing)

        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertNil(outcome.error)
    }

    // MARK: - Per-database identity

    /// Two databases must never share a backup directory, so one's retention cannot prune the
    /// other's copies.
    func testEachDatabaseGetsItsOwnBackupDirectory() throws {
        let personal = try makeVault("Personal.kdbx")
        let work = try makeVault("Work.kdbx")
        let store = makeStore()

        let personalBackup = try XCTUnwrap(store.backUp(personal).url)
        let workBackup = try XCTUnwrap(store.backUp(work).url)

        XCTAssertNotEqual(
            personalBackup.deletingLastPathComponent(),
            workBackup.deletingLastPathComponent()
        )
        XCTAssertEqual(store.backups(of: personal).count, 1)
        XCTAssertEqual(store.backups(of: work).count, 1)
    }

    /// The collision the plain filename would cause: `Personal.kdbx` in two different folders is
    /// two different databases, and mixing their backups would mean one's retention silently
    /// deleting the other's — the worst kind of bug for a backup directory to have.
    func testTwoDatabasesWithTheSameFilenameInDifferentFoldersDoNotCollide() throws {
        let home = try makeVault("home/Personal.kdbx", byteCount: 100)
        let stick = try makeVault("stick/Personal.kdbx", byteCount: 200)
        let store = makeStore()

        let homeBackup = try XCTUnwrap(store.backUp(home).url)
        let stickBackup = try XCTUnwrap(store.backUp(stick).url)

        XCTAssertNotEqual(
            homeBackup.deletingLastPathComponent(),
            stickBackup.deletingLastPathComponent(),
            "two same-named databases were given the same backup directory"
        )
        // And each backup is the right file, not merely in a different folder.
        XCTAssertEqual(try Data(contentsOf: homeBackup).count, 100)
        XCTAssertEqual(try Data(contentsOf: stickBackup).count, 200)
    }

    /// The identity is derived from the path, but the path itself must not appear in the directory
    /// name: a filesystem path routinely carries an account name, an employer or a client, and a
    /// directory listing ends up in screenshots and support logs.
    func testTheDirectoryNameIsRecognisableWithoutContainingThePath() throws {
        let vault = URL(fileURLWithPath: "/Users/somebody/Employer Ltd/Personal.kdbx")
        let name = VaultBackupStore.directoryName(for: vault)

        XCTAssertTrue(name.hasPrefix("Personal-"), "not recognisable: \(name)")
        XCTAssertFalse(name.contains("somebody"), "the path leaked into the name: \(name)")
        XCTAssertFalse(name.contains("Employer"), "the path leaked into the name: \(name)")
        XCTAssertFalse(name.contains("/"), "the name is not a single path component: \(name)")
        // Stable across calls — a per-launch identity would scatter one database's backups.
        XCTAssertEqual(name, VaultBackupStore.directoryName(for: vault))
    }

    /// A filename is user input. `/` and `:` are both legal in a name macOS shows the user, a
    /// leading dot would hide the directory the "Show Backups in Finder" command exists to reveal,
    /// and `..` would put the directory somewhere else entirely.
    func testHostileDatabaseNamesCannotEscapeOrHideTheBackupDirectory() {
        let names = [
            ".hidden.kdbx",
            "a:b.kdbx",
            "back\\slash.kdbx",
            String(repeating: "long", count: 100) + ".kdbx",
            " .kdbx",
        ]
        for name in names {
            let derived = VaultBackupStore.directoryName(for: URL(fileURLWithPath: "/tmp/\(name)"))
            XCTAssertFalse(derived.contains("/"), "\(name) produced a multi-component name: \(derived)")
            XCTAssertFalse(derived.contains(":"), "\(name) kept a colon: \(derived)")
            XCTAssertFalse(derived.contains("\\"), "\(name) kept a backslash: \(derived)")
            XCTAssertFalse(derived.hasPrefix("."), "\(name) produced a hidden directory: \(derived)")
            XCTAssertFalse(derived.hasPrefix("-"), "\(name) produced an empty stem: \(derived)")
            XCTAssertLessThanOrEqual(derived.count, 80, "\(name) produced an unbounded name")
        }
    }

    // MARK: - Retention

    /// The count cap: oldest-first, and the survivors are the newest ones — not an arbitrary ten.
    func testRetentionPrunesOldestFirstAgainstTheCountCap() throws {
        let vault = try makeVault("Personal.kdbx")
        let clock = TickingClock()
        let store = makeStore(maxCount: 3, now: { clock.next() })

        var made: [URL] = []
        for _ in 0 ..< 6 {
            made.append(try XCTUnwrap(store.backUp(vault).url))
        }

        let surviving = store.backups(of: vault).map(\.url.lastPathComponent)
        XCTAssertEqual(surviving.count, 3)
        XCTAssertEqual(
            surviving, made.suffix(3).map(\.lastPathComponent),
            "retention kept the wrong three — it must delete oldest first"
        )
        for gone in made.prefix(3) {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: gone.path),
                "\(gone.lastPathComponent) should have been pruned"
            )
        }
    }

    /// The byte cap, which binds instead of the count cap for a vault much larger than typical.
    func testRetentionPrunesAgainstTheTotalByteCap() throws {
        // 1 KB per backup, 2.5 KB allowed: two survive, and the newest of them is the last written.
        let vault = try makeVault("Big.kdbx", byteCount: 1024)
        let clock = TickingClock()
        let store = makeStore(maxCount: 100, maxTotalBytes: 2560, now: { clock.next() })

        var made: [URL] = []
        for _ in 0 ..< 5 {
            made.append(try XCTUnwrap(store.backUp(vault).url))
        }

        let surviving = store.backups(of: vault)
        XCTAssertEqual(surviving.count, 2, "expected the byte cap to bind: \(surviving.map(\.url.lastPathComponent))")
        XCTAssertEqual(surviving.map(\.url.lastPathComponent), made.suffix(2).map(\.lastPathComponent))
        XCTAssertLessThanOrEqual(surviving.reduce(0) { $0 + $1.byteCount }, 2560)
    }

    /// The age cap, which is the only one that binds for a database saved a handful of times a
    /// year: without it, ten backups from three years ago would be kept forever.
    func testRetentionPrunesAgainstTheAgeCap() throws {
        let vault = try makeVault("Rare.kdbx")
        let day: TimeInterval = 24 * 60 * 60

        // Three saves on days 0, 1 and 2, each through a store frozen at that day, so the stamps
        // are exactly the dates this test names.
        var made: [String] = []
        for dayOffset in [0.0, 1.0, 2.0] {
            let clock = FrozenClock(daysAfterEpoch: dayOffset)
            let store = makeStore(maxCount: 100, maxAge: 90 * day, now: { clock.read() })
            made.append(try XCTUnwrap(store.backUp(vault).url).lastPathComponent)
        }
        XCTAssertEqual(
            makeStore().backups(of: vault).count, 3, "nothing is old enough to prune yet"
        )

        // A fourth save on day 100, with the cap at 99 days. Only the day-0 backup is past it —
        // the day-1 one is exactly 99 days old, which is not MORE than 99 — so the prune must stop
        // after a single deletion rather than sweeping the lot.
        let late = FrozenClock(daysAfterEpoch: 100)
        let laterStore = makeStore(maxCount: 100, maxAge: 99 * day, now: { late.read() })
        made.append(try XCTUnwrap(laterStore.backUp(vault).url).lastPathComponent)

        let surviving = laterStore.backups(of: vault).map(\.url.lastPathComponent)
        XCTAssertEqual(
            surviving, Array(made.suffix(3)),
            "the age cap pruned the wrong set: \(surviving)"
        )
    }

    /// **The floor, and it outranks every cap.** A vault whose last save was years ago still has
    /// exactly one copy of itself; a single backup can never be pruned to none. Asserted against
    /// all three caps set to zero, which is the most hostile configuration there is.
    func testRetentionNeverDeletesTheNewestBackup() throws {
        let vault = try makeVault("Ancient.kdbx")
        let clock = TickingClock()
        let store = makeStore(maxCount: 0, maxAge: 0, maxTotalBytes: 0, now: { clock.next() })

        let first = try XCTUnwrap(store.backUp(vault).url)
        XCTAssertEqual(
            store.backups(of: vault).map(\.url.lastPathComponent), [first.lastPathComponent],
            "the only backup there was got pruned"
        )

        let second = try XCTUnwrap(store.backUp(vault).url)
        XCTAssertEqual(
            store.backups(of: vault).map(\.url.lastPathComponent), [second.lastPathComponent],
            "the newest backup must survive whatever the caps say"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    /// The backup directory is one the app opens in Finder, so people will put things in it.
    /// Pruning must recognise only the files it wrote — matched by an exact name shape, not by a
    /// prefix — and leave everything else alone.
    func testRetentionIgnoresFilesItDidNotWrite() throws {
        let vault = try makeVault("Personal.kdbx")
        let clock = TickingClock()
        let store = makeStore(maxCount: 1, now: { clock.next() })

        _ = store.backUp(vault)
        let directory = try store.directory(for: vault)

        // Names that a prefix check would have swallowed, plus one unrelated file and one
        // subdirectory.
        let strangers = [
            "Personal-notes.txt",
            "Personal-20260909.kdbx",              // stamp too short
            "Personal-not-a-timestamp!.kdbx",
            "Personal.kdbx",                       // the user's own copy, dropped in by hand
            "README.txt",
        ]
        for stranger in strangers {
            try Data("keep me".utf8).write(to: directory.appendingPathComponent(stranger))
        }
        let nested = directory.appendingPathComponent("Personal-20260101-000000.kdbx", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        // Two more saves, with maxCount 1 — retention has every reason to be deleting things.
        _ = store.backUp(vault)
        _ = store.backUp(vault)

        for stranger in strangers {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(stranger).path),
                "retention deleted '\(stranger)', which it did not write"
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nested.path),
            "retention deleted a directory whose name matched the backup shape"
        )
        XCTAssertEqual(store.backups(of: vault).count, 1, "its own backups were not pruned")
    }

    // MARK: - Failure

    /// A destination that cannot be created reports `.failed` rather than throwing, because the
    /// caller (`SandboxedVaultFileAccess.write`) must go on to write the user's data either way.
    func testAnUnusableBackupRootIsReportedAsAFailureRatherThanThrowing() throws {
        let vault = try makeVault("Personal.kdbx")
        // A regular file where the root directory would go: `createDirectory` cannot succeed
        // against it regardless of permissions, and no `chmod` a root-running test would ignore.
        let blocked = temp.appendingPathComponent("blocked", isDirectory: true)
        try Data("not a directory".utf8).write(to: blocked)

        let outcome = makeStore(root: blocked).backUp(vault)

        guard case .failed(let error) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        guard case .io(let detail) = error else {
            return XCTFail("expected VaultError.io, got \(error)")
        }
        XCTAssertTrue(
            detail.contains("Personal.kdbx"),
            "the message must say which database went unprotected: \(detail)"
        )
    }
}
