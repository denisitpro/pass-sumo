import Foundation
import XCTest
@testable import PassSumo

// MARK: - Stage names
//
// These MUST match `Stage`'s raw values in Sources/DurabilityHelper/DurabilityHelperMain.swift.
// They are duplicated rather than shared because the helper is a separate executable module: the
// alternative — compiling its source into this bundle too — would drag an `@main` entry point into
// a test bundle. A mismatch cannot fail silently: `HelperOutcome.assertReached` fails the test with
// the markers it actually saw.

enum HelperStage {
    static let started = "started"
    static let opened = "opened"
    static let edited = "edited"
    static let saveBegin = "save-begin"
    static let writeBegin = "write-begin"
    static let writeEnd = "write-end"
    static let saveEnd = "save-end"
    static let done = "done"
}

// MARK: - Helper outcome

/// What one helper run did: the stages it reached, and how it ended.
///
/// The stage list is the evidence a kill test rests on. "The file survived a kill during the KDF"
/// only means something if the kill DID land during the KDF, and the only honest way to know that
/// is that the helper announced `save-begin` and never announced `write-begin`. Timing alone would
/// make every one of these tests a coin flip that happens to be weighted in our favour.
struct HelperOutcome {
    let markers: [String]
    /// `INFO:` lines — observations the helper made about itself, e.g. whether an atomic write
    /// changed the file's inode.
    let info: [String]
    let errors: [String]
    let terminationStatus: Int32
    /// `true` when the process died from a signal (i.e. our `SIGKILL`) rather than exiting.
    let terminatedBySignal: Bool
    /// Whether the harness actually delivered the kill. `false` means the run completed before the
    /// kill condition was ever satisfied.
    let wasKilled: Bool
    /// What the filesystem looked like at the instant the trigger fired — e.g. how many bytes of
    /// the backup or of the atomic temporary file existed when it was first seen.
    ///
    /// Recorded because it is the difference between "we caught the copy mid-flight and it was
    /// still valid" and "the copy was never observable in a partial state at all". The second is
    /// what actually happens on APFS, and a test that could not tell them apart would be claiming
    /// credit for a guarantee the filesystem is providing.
    let killObservation: String?

    func reached(_ stage: String) -> Bool { markers.contains(stage) }

    /// Asserts the kill landed in the intended window: `stage` announced, `notPast` never was.
    func assertKilled(
        after stage: String,
        before notPast: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            terminatedBySignal,
            "helper was expected to die from SIGKILL, exited \(terminationStatus) instead; "
                + "markers: \(markers), errors: \(errors)",
            file: file, line: line
        )
        XCTAssertTrue(
            reached(stage),
            "helper never reached '\(stage)'; markers: \(markers), errors: \(errors)",
            file: file, line: line
        )
        XCTAssertFalse(
            reached(notPast),
            "the kill arrived too late — helper got past '\(notPast)', so this run proves nothing "
                + "about the window it was aiming at; markers: \(markers)",
            file: file, line: line
        )
    }
}

// MARK: - Kill conditions

/// When the harness pulls the trigger.
///
/// Two families, and the distinction matters. `marker` fires on something the helper *said*, which
/// makes it exact at a phase boundary. The file-watching cases fire on something the filesystem
/// *did*, which is the only way to reach inside `SandboxedVaultFileAccess.write` — the backup copy
/// and the atomic write happen inside one production call, and cutting that call open to announce
/// its own halfway point would mean testing modified code.
enum KillCondition {
    /// Let the helper finish.
    case never
    /// Kill the instant this stage marker appears on stdout.
    case marker(String)
    /// Kill the instant a `<name>.kdbx.bak-*` file appears, i.e. mid-`copyItem`.
    case backupAppears
    /// Kill once the backup's size has reached `bytes`, i.e. the copy is done but the atomic write
    /// has not replaced anything yet.
    case backupReaches(bytes: Int)
    /// Kill the instant a sibling file appears that is neither the database nor a backup — which is
    /// what `Data.write(options: [.atomic])`'s temporary file looks like from outside.
    case atomicTemporaryAppears
    /// Kill this long after the helper announced `save-begin`. The shotgun: no phase is claimed, so
    /// the assertion has to hold for whatever phase it hits.
    case delayAfterSaveBegin(TimeInterval)
}

// MARK: - Marker log

/// Thread-safe sink for the helper's stdout. `@unchecked Sendable`: every stored property is only
/// read or written under `lock`, which the compiler cannot see through an `NSLock`.
private final class MarkerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var atEOF = false

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
    }

    func markEOF() {
        lock.lock(); defer { lock.unlock() }
        atEOF = true
    }

    var isAtEOF: Bool {
        lock.lock(); defer { lock.unlock() }
        return atEOF
    }

    /// Complete lines only. A partially-written marker must never be treated as having arrived —
    /// that is exactly the false "the helper got past this stage" a kill test must not make.
    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: buffer, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        if !text.hasSuffix("\n") { lines.removeLast() }
        return lines.filter { !$0.isEmpty }
    }
}

// MARK: - Test case base

/// Shared machinery for the durability suite: scratch directories, spawning and killing the helper,
/// and reading a database back with the real codec.
class DurabilityTestCase: XCTestCase {
    /// The master password for every database this suite creates. Not a secret: each database is
    /// built from scratch in a per-test temporary directory that `tearDown` deletes, and holds only
    /// entries this suite invented. It is a literal rather than a random string so a failing run
    /// leaves a database the owner can open by hand while investigating.
    static let password = "durability-suite-password"

    /// Padding size for databases whose write has to be caught in the act. A vault with no
    /// attachment is ~3 KB — written and copied in well under the time any watcher can react in, so
    /// "kill during the write" would silently degrade into "kill before or after the write".
    /// 8 MB of incompressible bytes gives the write and the backup copy a middle to be interrupted
    /// in, while staying under the 25 MB per-attachment ceiling and keeping a full round trip fast.
    static let paddingBytes = 8 * 1024 * 1024

    private var scratchDirectories: [URL] = []

    override func tearDown() {
        for directory in scratchDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        scratchDirectories = []
        super.tearDown()
    }

    // MARK: Scratch space

    /// A fresh directory that `tearDown` removes. Every database this suite writes lives in one, so
    /// no plaintext this suite creates outlives the test that created it.
    func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("passsumo-durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectories.append(directory)
        return directory
    }

    // MARK: Host capabilities

    /// Whether this test bundle's host process is inside an App Sandbox container, i.e. whether the
    /// run is `make durability-signed` rather than `make durability`.
    static var hostIsSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Skips when the host is sandboxed, for the two things a sandboxed host demonstrably cannot do
    /// — measured, not assumed, by running the whole suite under `make durability-signed`:
    ///
    /// - **Launch `sandbox-exec`.** A sandboxed process cannot put a child into a second sandbox;
    ///   the child produces no output at all.
    /// - **Watch a directory closely enough to catch the atomic write's temporary file.** Every
    ///   filesystem call goes through the sandbox's MAC checks, and the poll loop stops being fast
    ///   enough to see a file that exists for a few milliseconds. The kill then lands after the
    ///   save, which the marker assertions correctly refuse to accept as proof of anything.
    ///
    /// Skipping rather than quietly weakening the assertion: these tests mean what they say under
    /// `make durability`, and under `make durability-signed` they mean nothing, so they must not
    /// report a result there at all.
    func skipIfHostIsSandboxed(_ what: String) throws {
        guard Self.hostIsSandboxed else { return }
        throw XCTSkip(
            "\(what) does not work from a sandboxed test host — run this under `make durability` "
                + "(unsigned, unsandboxed). `make durability-signed` exists for the App Sandbox "
                + "assertions, which are the ones that need a real container."
        )
    }

    // MARK: The helper

    /// The helper executable, built alongside this bundle.
    func helperExecutable() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PASSSUMO_DURABILITY_HELPER"] {
            return URL(fileURLWithPath: override)
        }
        let name = "PassSumoDurabilityHelper"
        var candidates: [URL] = []
        // Depending on how the bundle is hosted, the test bundle sits either directly in
        // BUILT_PRODUCTS_DIR next to the tool or inside the host app's PlugIns directory. Walk up
        // rather than hard-coding either shape.
        var directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        for _ in 0 ..< 5 {
            candidates.append(directory.appendingPathComponent(name))
            directory = directory.deletingLastPathComponent()
        }
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(name))

        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip(
                "PassSumoDurabilityHelper was not found next to the test bundle. It is built by the "
                    + "PassSumoDurabilityHelper target — run `make durability`, or set "
                    + "PASSSUMO_DURABILITY_HELPER to its path. Looked in: "
                    + candidates.map(\.path).joined(separator: ", ")
            )
        }
        return found
    }

    /// Runs the helper against `database`, killing it when `killWhen` says so.
    ///
    /// Blocks until the process is gone and its output has been drained — a marker still sitting in
    /// the pipe when the assertions run would look exactly like a stage that never happened.
    @discardableResult
    func runHelper(
        database: URL,
        mode: String = "edit",
        title: String = "durability-probe",
        attachmentBytes: Int = 0,
        hangAt: String? = nil,
        killWhen: KillCondition = .never,
        /// Prefix command that launches the helper, e.g. `["/usr/bin/sandbox-exec", "-f", profile]`.
        /// Empty means run it directly.
        launcher: [String] = [],
        timeout: TimeInterval = 120,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HelperOutcome {
        var arguments = [
            "--db", database.path,
            "--password", Self.password,
            "--mode", mode,
            "--title", title,
        ]
        if attachmentBytes > 0 {
            arguments += ["--attachment-bytes", String(attachmentBytes)]
        }
        if let hangAt {
            arguments += ["--hang-at", hangAt]
        }

        let helper = try helperExecutable()
        let process = Process()
        if launcher.isEmpty {
            process.executableURL = helper
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: launcher[0])
            process.arguments = Array(launcher.dropFirst()) + [helper.path] + arguments
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let log = MarkerLog()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                log.markEOF()
                return
            }
            log.append(chunk)
        }

        try process.run()
        let pid = process.processIdentifier

        var killed = false
        var observation: String?
        var saveBeganAt: Date?
        let deadline = Date().addingTimeInterval(timeout)

        while process.isRunning {
            let markers = log.lines
            if saveBeganAt == nil, markers.contains(marker: HelperStage.saveBegin) {
                saveBeganAt = Date()
            }
            if !killed,
               let reason = Self.killObservation(
                   killWhen, markers: markers, database: database, saveBeganAt: saveBeganAt
               ) {
                kill(pid, SIGKILL)
                killed = true
                observation = reason
            }
            if Date() > deadline {
                kill(pid, SIGKILL)
                XCTFail(
                    "helper did not finish within \(timeout)s; markers: \(markers)",
                    file: file, line: line
                )
                break
            }
            // 0.2 ms. Tight enough to catch an 8 MB atomic write's temporary file, which exists for
            // tens of milliseconds, without spinning a core flat out.
            usleep(200)
        }
        process.waitUntilExit()

        // Drain: the helper's last markers are written before it dies but read after.
        let drainDeadline = Date().addingTimeInterval(5)
        while !log.isAtEOF, Date() < drainDeadline {
            usleep(1000)
        }
        pipe.fileHandleForReading.readabilityHandler = nil

        let lines = log.lines
        return HelperOutcome(
            markers: lines.compactMap { $0.hasPrefix("STAGE:") ? String($0.dropFirst("STAGE:".count)) : nil },
            info: lines.compactMap { $0.hasPrefix("INFO:") ? String($0.dropFirst("INFO:".count)) : nil },
            errors: lines.compactMap { $0.hasPrefix("ERROR:") ? String($0.dropFirst("ERROR:".count)) : nil },
            terminationStatus: process.terminationStatus,
            terminatedBySignal: process.terminationReason == .uncaughtSignal,
            wasKilled: killed,
            killObservation: observation
        )
    }

    /// `nil` while the trigger has not fired; otherwise a description of what was observed at the
    /// instant it did, which becomes `HelperOutcome.killObservation`.
    private static func killObservation(
        _ condition: KillCondition,
        markers: [String],
        database: URL,
        saveBeganAt: Date?
    ) -> String? {
        switch condition {
        case .never:
            return nil
        case let .marker(stage):
            return markers.contains(marker: stage) ? "marker \(stage)" : nil
        case .backupAppears:
            guard let backup = backupURLs(besides: database).first else { return nil }
            return "backup was \(size(of: backup)) bytes when first seen"
        case let .backupReaches(bytes):
            guard let backup = backupURLs(besides: database).first(where: { size(of: $0) >= bytes })
            else { return nil }
            return "backup reached \(size(of: backup)) of \(bytes) bytes"
        case .atomicTemporaryAppears:
            guard let temporary = temporaryURLs(besides: database).first else { return nil }
            return "temporary file '\(temporary.lastPathComponent)' was \(size(of: temporary)) "
                + "bytes when first seen, database was \(size(of: database))"
        case let .delayAfterSaveBegin(delay):
            guard let saveBeganAt, Date().timeIntervalSince(saveBeganAt) >= delay else { return nil }
            return "\(delay)s after save-begin"
        }
    }

    // MARK: Looking at the directory

    /// Backups of `database` sitting next to it — the `<name>.kdbx.bak-<stamp>` files
    /// `SandboxedVaultFileAccess` rotates.
    static func backupURLs(besides database: URL) -> [URL] {
        contents(of: database.deletingLastPathComponent())
            .filter { $0.lastPathComponent.hasPrefix(database.lastPathComponent + ".bak-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Anything in the directory that is neither the database nor one of its backups. During a save
    /// that is `Data.write(options: [.atomic])`'s temporary file; at rest there should be nothing.
    static func temporaryURLs(besides database: URL) -> [URL] {
        contents(of: database.deletingLastPathComponent()).filter {
            $0.lastPathComponent != database.lastPathComponent
                && !$0.lastPathComponent.hasPrefix(database.lastPathComponent + ".bak-")
        }
    }

    private static func contents(of directory: URL) -> [URL] {
        // `.skipsHiddenFiles` is deliberately NOT passed: Foundation's atomic temporary file is a
        // dot-file, and it is the thing we are looking for.
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
    }

    static func size(of url: URL) -> Int {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return 0 }
        return values.fileSize ?? 0
    }

    func backups(of database: URL) -> [URL] { Self.backupURLs(besides: database) }

    // MARK: Databases

    /// Creates a database through the helper — i.e. through the real `VaultStore.createNew` +
    /// `SandboxedVaultFileAccess.write` path, not by hand — and returns its URL.
    func createDatabase(
        in directory: URL,
        named name: String = "vault.kdbx",
        title: String = "original",
        attachmentBytes: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let outcome = try runHelper(
            database: url,
            mode: "create",
            title: title,
            attachmentBytes: attachmentBytes,
            file: file, line: line
        )
        XCTAssertTrue(
            outcome.reached(HelperStage.done),
            "could not create the test database: markers \(outcome.markers), errors \(outcome.errors)",
            file: file, line: line
        )
        return url
    }

    /// Decodes `url` with the real codec. Throws whatever the codec throws, so a test can assert on
    /// the failure as readily as on the contents.
    func decode(_ url: URL) throws -> Vault {
        let data = try Data(contentsOf: url)
        let decoded = try KDBXKitCodec().decode(
            fileData: data,
            credentials: VaultCredentials(password: Self.password, keyFile: nil)
        )
        return decoded.vault
    }

    /// The whole point of the suite, in one assertion: whatever is at `url` is a complete, openable
    /// database — not a zero-byte file, not a truncated one, not one that decodes to nonsense.
    /// Returns the titles it found so a caller can decide which version it is looking at.
    @discardableResult
    func assertOpens(
        _ url: URL,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Set<String> {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "\(message): the file is gone entirely",
            file: file, line: line
        )
        XCTAssertGreaterThan(
            Self.size(of: url), 0,
            "\(message): the file is zero bytes",
            file: file, line: line
        )
        do {
            let vault = try decode(url)
            return Set(vault.entries.map(\.title))
        } catch {
            XCTFail("\(message): it does not open — \(error)", file: file, line: line)
            return []
        }
    }
}

private extension [String] {
    /// Marker lines arrive prefixed; comparing the prefixed form keeps a stage name from matching
    /// an `ERROR:` line that happens to mention it.
    func contains(marker: String) -> Bool {
        contains("STAGE:" + marker)
    }
}
