import Foundation
import XCTest
@testable import PassSumo

/// Records how many saves are inside their critical section at once, and the widest overlap seen.
///
/// A "save" here spans from the codec starting to encode to the file access finishing the write —
/// i.e. `VaultStore.save()`'s entire detached body. `@unchecked Sendable`: every property is
/// touched only under `lock`.
private final class OverlapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var highWaterMark = 0

    func enter() {
        lock.lock(); defer { lock.unlock() }
        inFlight += 1
        highWaterMark = max(highWaterMark, inFlight)
    }

    func leave() {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
    }

    var maximumOverlap: Int {
        lock.lock(); defer { lock.unlock() }
        return highWaterMark
    }
}

/// Marks the START of a save: `VaultStore.save()` calls `encode` first, before it touches disk.
private struct OverlapObservingCodec: VaultCodec {
    let wrapped: any VaultCodec
    let recorder: OverlapRecorder

    func decode(fileData: Data, credentials: VaultCredentials) throws -> DecodedVault {
        try wrapped.decode(fileData: fileData, credentials: credentials)
    }

    func encode(_ vault: Vault, credentials: VaultCredentials, origin: DecodedVault?) throws -> Data {
        recorder.enter()
        return try wrapped.encode(vault, credentials: credentials, origin: origin)
    }

    func makeEmpty(name: String, credentials: VaultCredentials) throws -> DecodedVault {
        try wrapped.makeEmpty(name: name, credentials: credentials)
    }
}

/// Marks the END of a save: the write is the last thing `VaultStore.save()`'s detached body does.
private final class OverlapObservingFileAccess: VaultFileAccess {
    let wrapped: any VaultFileAccess
    let recorder: OverlapRecorder

    init(wrapped: any VaultFileAccess, recorder: OverlapRecorder) {
        self.wrapped = wrapped
        self.recorder = recorder
    }

    func read(from url: URL) throws -> Data { try wrapped.read(from: url) }

    func write(_ data: Data, to url: URL) throws -> URL? {
        defer { recorder.leave() }
        return try wrapped.write(data, to: url)
    }

    func bookmark(for url: URL) throws -> Data { try wrapped.bookmark(for: url) }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        try wrapped.resolveBookmark(data)
    }
}

/// Category 1, the concurrency half — **two saves must never be in flight at once.**
///
/// This one runs in-process rather than through the helper: the question is not what a kill does,
/// it is whether the app's own orchestration lets two writes to the same file overlap. That is
/// visible only from inside, by instrumenting the codec and the file access `VaultStore` was handed.
///
/// Everything below uses the REAL `KDBXKitCodec` and the REAL `SandboxedVaultFileAccess`, wrapped
/// in recorders that only observe. The vault, its password and its file live in a per-test
/// temporary directory that `tearDown` deletes.
final class ConcurrentSaveTests: DurabilityTestCase {
    /// Two `save()` calls issued without awaiting the first.
    ///
    /// `VaultStore.save()` is `@MainActor`, but its body is a `Task.detached` that it awaits — so
    /// the main actor is released the moment the first save starts encoding, and a second `save()`
    /// entering at that point runs its own detached encode-and-write alongside the first. Nothing
    /// in `VaultStore` holds a lock, a flag or a serial executor across that suspension.
    ///
    /// Two assertions, and they are deliberately different in kind:
    ///
    /// 1. **The file must survive.** Whatever the ordering, what is left on disk is a complete,
    ///    openable database. This holds because each write is `.atomic`: two renames onto the same
    ///    path cannot interleave, one simply wins.
    /// 2. **The saves must not overlap.** They do. This is a real finding, not a test artefact —
    ///    see README.md and the note below.
    ///
    /// `XCTExpectFailure(strict:)` is how the second assertion is recorded without leaving the
    /// suite red, and it is not a way of looking away: it is strict, so the moment `VaultStore`
    /// grows the serialisation it needs, this test fails for saying the defect is still there and
    /// forces someone to come back and delete this block.
    @MainActor
    func testTwoConcurrentSavesDoNotOverlap() async throws {
        let directory = try makeScratchDirectory()
        let url = directory.appendingPathComponent("racing.kdbx")
        let credentials = VaultCredentials(password: Self.password, keyFile: nil)

        let recorder = OverlapRecorder()
        let store = VaultStore(
            codec: OverlapObservingCodec(wrapped: KDBXKitCodec(), recorder: recorder),
            fileAccess: OverlapObservingFileAccess(
                wrapped: SandboxedVaultFileAccess(), recorder: recorder
            )
        )

        await store.createNew(at: url, credentials: credentials)
        await store.save()
        XCTAssertNil(store.lastError, "the initial save must succeed before the race is set up")

        let now = Date()
        store.upsert(VaultEntry(
            id: UUID(), groupID: nil, title: "raced", username: "u",
            password: "durability-probe-password", url: "", notes: "", otpAuthURL: nil,
            customFields: [:], created: now, modified: now
        ))

        // Both child tasks hop onto the main actor to call `save()`; each releases it at the
        // `Task.detached` suspension inside, which is where the second one gets in.
        async let first: Void = store.save()
        async let second: Void = store.save()
        _ = await (first, second)

        XCTAssertNil(store.lastError, "neither save should have failed: \(String(describing: store.lastError))")

        let titles = try assertOpens(url, "after two concurrent saves")
        XCTAssertTrue(titles.contains("raced"), "the edit was lost entirely: \(titles)")

        XCTExpectFailure(
            "KNOWN DEFECT (durability suite finding): VaultStore.save() has no mutual exclusion. "
                + "It is @MainActor, but its body is an awaited Task.detached, so a second save() "
                + "entering during that suspension encodes and writes alongside the first. Two "
                + "backups are taken of the same pre-save file and two atomic writes race for the "
                + "same path; the loser's edits are silently discarded even though its save() "
                + "reported success. Delete this XCTExpectFailure once save() serialises.",
            strict: true
        ) {
            XCTAssertEqual(
                recorder.maximumOverlap, 1,
                "two saves were in flight at once (peak overlap \(recorder.maximumOverlap))"
            )
        }
    }
}
