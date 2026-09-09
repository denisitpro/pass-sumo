import XCTest
@testable import PassSumo

/// Issue #27 — **`VaultStore.save()` must serialise, and must not lie about what it wrote.**
///
/// These belong in the hosted unit suite rather than the durability suite: the defect is in
/// `VaultStore`'s own orchestration, not in the crypto or the filesystem, so it reproduces in full
/// against a fake codec — and does so deterministically, because the fake can be *held* inside the
/// save's critical section instead of the test betting on Argon2 taking long enough.
/// `DurabilityTests/ConcurrentSaveTests` covers the same property once more through the real
/// `KDBXKitCodec` + `SandboxedVaultFileAccess` stack.
@MainActor
final class VaultStoreSaveSerializationTests: XCTestCase {
    // `nonisolated(unsafe)` for the same reason `VaultStoreTests` needs it: XCTest's
    // `setUpWithError`/`tearDownWithError` are `nonisolated`, and XCTest runs setUp, the test body
    // and tearDown strictly one after another for a given instance.
    nonisolated(unsafe) private var tempDirectory: URL!

    override nonisolated func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassSumoSaveSerializationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
    }

    override nonisolated func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    // MARK: - Test doubles

    /// Holds the FIRST `encode` inside the save's critical section until the test releases it, so
    /// "a second save arrives while one is in flight" is a fact the test establishes rather than a
    /// timing bet. Also records the widest overlap seen, which is the defect's signature.
    ///
    /// `@unchecked Sendable`: the counters are only ever touched under `lock`, and the two
    /// semaphores are themselves thread-safe.
    private final class SaveGate: @unchecked Sendable {
        private let lock = NSLock()
        private var holdNextEncode = true
        private var inFlight = 0
        private var peak = 0
        private let encodeStarted = DispatchSemaphore(value: 0)
        private let releaseHeld = DispatchSemaphore(value: 0)

        /// Called at the top of `encode` — i.e. the first thing `VaultStore.save()`'s detached body
        /// does, so it marks the start of the critical section.
        func enterEncode() {
            lock.lock()
            inFlight += 1
            peak = max(peak, inFlight)
            let hold = holdNextEncode
            holdNextEncode = false
            lock.unlock()
            encodeStarted.signal()
            guard hold else { return }
            // Bounded so a regression parks the test for ten seconds instead of hanging the suite.
            _ = releaseHeld.wait(timeout: .now() + 10)
        }

        /// Called once `encode` has produced its bytes. The write follows, but the encode is the
        /// only stage this fake needs to straddle to prove two saves are not running at once.
        func leaveEncode() {
            lock.lock(); inFlight -= 1; lock.unlock()
        }

        /// Waits until an `encode` has begun, off the main actor so the held save can actually get
        /// there. Signal-driven, not polled.
        func awaitEncodeStart() async {
            _ = await Task.detached { self.blockingWaitForEncodeStart() }.value
        }

        /// Whether ANOTHER `encode` begins within `seconds`.
        ///
        /// The one timing-dependent step in this file, and the asymmetry is the point: with the
        /// defect present the second encode starts in microseconds, so it trips this immediately;
        /// with saves serialised it can never start while the first is held, so the window simply
        /// runs out. The whole cost is therefore paid on the *passing* path, and 200 ms is three
        /// orders of magnitude more than the task scheduling it has to beat.
        func anotherEncodeStarts(within seconds: Double) async -> Bool {
            await Task.detached { self.blockingWaitForEncodeStart(timeout: seconds) }.value
        }

        func releaseHeldEncode() { releaseHeld.signal() }

        var peakOverlap: Int {
            lock.lock(); defer { lock.unlock() }
            return peak
        }

        private func blockingWaitForEncodeStart(timeout seconds: Double = 10) -> Bool {
            encodeStarted.wait(timeout: .now() + seconds) == .success
        }
    }

    /// A codec whose bytes actually carry the vault's contents, gated by `SaveGate`.
    ///
    /// `InMemoryVaultCodec` cannot be used here: its `encode` returns the *password* and stashes
    /// the vault in a dictionary, so the last **encode** wins there no matter which **write**
    /// reached disk last — and telling those two apart is the whole question in a lost-update test.
    /// The payload is just the entry titles, comma-separated: enough to identify which save's
    /// snapshot is on disk, and nothing more.
    private struct TitleCodec: VaultCodec {
        let gate: SaveGate

        func decode(fileData: Data, credentials: VaultCredentials) throws -> DecodedVault {
            guard let text = String(data: fileData, encoding: .utf8) else { throw VaultError.notAKDBXFile }
            let titles = text.isEmpty ? [] : text.components(separatedBy: ",")
            let now = Date(timeIntervalSince1970: 0)
            let entries = titles.map {
                VaultEntry(
                    id: UUID(), groupID: nil, title: $0, username: "", password: "",
                    url: "", notes: "", otpAuthURL: nil, customFields: [:],
                    created: now, modified: now
                )
            }
            return DecodedVault(vault: Vault(name: "gated", groups: [], entries: entries), opaque: nil)
        }

        func encode(_ vault: Vault, credentials: VaultCredentials, origin: DecodedVault?) throws -> Data {
            gate.enterEncode()
            defer { gate.leaveEncode() }
            return Data(vault.entries.map(\.title).joined(separator: ",").utf8)
        }

        func makeEmpty(name: String, credentials: VaultCredentials) throws -> DecodedVault {
            DecodedVault(vault: Vault(name: name, groups: [], entries: []), opaque: nil)
        }
    }

    // MARK: - Helpers

    /// A real `SandboxedVaultFileAccess` whose backups land in this test's own temp directory, not
    /// in `<Application Support>/PassSumo/Backups` — which an unsigned `make test` would resolve to
    /// the developer's real, shared Application Support.
    private func makeFileAccess() -> SandboxedVaultFileAccess {
        let root = tempDirectory.appendingPathComponent("Backups", isDirectory: true)
        var policy = VaultBackupPolicy.default
        policy.root = { root }
        return SandboxedVaultFileAccess(backupPolicy: policy)
    }

    private func makeEntry(title: String) -> VaultEntry {
        let stamp = Date(timeIntervalSince1970: 0)
        return VaultEntry(
            id: UUID(), groupID: nil, title: title, username: "", password: "",
            url: "", notes: "", otpAuthURL: nil, customFields: [:],
            created: stamp, modified: stamp
        )
    }

    /// The titles `TitleCodec` wrote to `url`, read straight off disk rather than out of any
    /// in-process state — the only way to see which save's bytes actually won.
    private func titlesOnDisk(at url: URL) throws -> [String] {
        let text = try String(decoding: Data(contentsOf: url), as: UTF8.self)
        return text.isEmpty ? [] : text.components(separatedBy: ",")
    }

    /// A store holding a brand-new, in-memory database and the URL it will be written to. Nothing
    /// is on disk yet (`createNew` never writes), so the FIRST `save()` each test issues is the one
    /// the gate holds.
    private func makeStore(named name: String, gate: SaveGate) async -> (VaultStore, URL) {
        let url = tempDirectory.appendingPathComponent("\(name).kdbx")
        let store = VaultStore(codec: TitleCodec(gate: gate), fileAccess: makeFileAccess())
        await store.createNew(at: url, credentials: VaultCredentials(password: "pw", keyFile: nil))
        return (store, url)
    }

    // MARK: - Tests

    /// **The defect itself.** A save issued while another is in flight must not run alongside it.
    ///
    /// The first save is held inside `encode`, which is where the old code released the main actor:
    /// `save()` was `@MainActor`, but its body was an awaited `Task.detached`, so a second `save()`
    /// entering at that suspension went straight on to encode and write in parallel.
    func testASaveIssuedWhileAnotherIsInFlightDoesNotOverlapIt() async throws {
        let gate = SaveGate()
        let (store, _) = await makeStore(named: "overlap", gate: gate)

        store.upsert(makeEntry(title: "first"))
        async let first: Void = store.save()
        await gate.awaitEncodeStart()   // the first save is now parked inside its critical section

        store.upsert(makeEntry(title: "second"))
        async let second: Void = store.save()
        let overlapped = await gate.anotherEncodeStarts(within: 0.2)

        gate.releaseHeldEncode()
        _ = await (first, second)

        XCTAssertFalse(
            overlapped,
            "a second save() began encoding while the first was still inside its critical section"
        )
        XCTAssertEqual(gate.peakOverlap, 1, "two saves were in flight at once")
        XCTAssertNil(store.lastError, "neither save should have failed: \(String(describing: store.lastError))")
    }

    /// **The consequence.** An edit made while a save is in flight must reach disk — not be
    /// overwritten by the older snapshot that save is still carrying.
    ///
    /// This is the lost update the defect produced: both saves reported success, one rename won,
    /// and whichever edit the loser carried was gone. It also pins the queued save's *semantics* —
    /// it encodes the vault as of when it RUNS, so its bytes contain both edits; a save that
    /// snapshotted at request time would write "first" only and undo the edit made during the wait.
    func testAnEditMadeWhileASaveIsInFlightIsNotOverwrittenByIt() async throws {
        let gate = SaveGate()
        let (store, url) = await makeStore(named: "lostupdate", gate: gate)

        store.upsert(makeEntry(title: "first"))
        async let first: Void = store.save()
        await gate.awaitEncodeStart()

        store.upsert(makeEntry(title: "second"))
        async let second: Void = store.save()
        _ = await gate.anotherEncodeStarts(within: 0.2)

        gate.releaseHeldEncode()
        _ = await (first, second)

        XCTAssertNil(store.lastError, "neither save should have failed: \(String(describing: store.lastError))")
        XCTAssertEqual(
            try titlesOnDisk(at: url), ["first", "second"],
            "the edit made during the in-flight save is not the one on disk"
        )
        XCTAssertFalse(store.isDirty, "the last save wrote the current state, so nothing is pending")
    }

    /// **The honesty half.** A save that finishes after an edit it did not include must leave the
    /// vault dirty, however successful it was on its own terms.
    ///
    /// Argon2 takes most of a second, so this window is not exotic — it is every save. Clearing
    /// `isDirty` here would tell the user an edit was on disk when it was not, which is the same
    /// lie the overlap produced, reached without any concurrency at all.
    func testASaveDoesNotClaimAnEditThatLandedWhileItWasRunning() async throws {
        let gate = SaveGate()
        let (store, url) = await makeStore(named: "dirtyflag", gate: gate)

        store.upsert(makeEntry(title: "included"))
        async let inFlight: Void = store.save()
        await gate.awaitEncodeStart()

        store.upsert(makeEntry(title: "landed-late"))
        gate.releaseHeldEncode()
        await inFlight

        XCTAssertNil(store.lastError, "the save itself succeeded: \(String(describing: store.lastError))")
        XCTAssertEqual(
            try titlesOnDisk(at: url), ["included"],
            "the save wrote the snapshot it took, which is all it could write"
        )
        XCTAssertTrue(
            store.isDirty,
            "the edit made during the save is not on disk, so the vault is still dirty"
        )

        // And the follow-up save clears it, so the flag is not simply stuck on.
        await store.save()
        XCTAssertEqual(try titlesOnDisk(at: url), ["included", "landed-late"])
        XCTAssertFalse(store.isDirty)
    }
}
