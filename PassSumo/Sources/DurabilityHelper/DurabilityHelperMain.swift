import Foundation
import Security

// MARK: - Why this executable exists
//
// The durability suite has to answer one question: what is left on disk when the process dies in
// the middle of a save? Nothing in-process can answer it. A test that crashes its own host takes
// the test runner with it, and XCUITest — the other obvious candidate — cannot `SIGKILL` its
// target at a chosen instant (and has never run on this machine at all, see issue #6).
//
// So the save happens HERE, in a separate process the test owns and can kill at a moment of its
// choosing. This is not a re-implementation of the save path: this target compiles the very same
// `Sources/Model` and `Sources/KDBX` files the app does, and drives them through `VaultStore` —
// the real orchestration, the real `KDBXKitCodec`, the real `SandboxedVaultFileAccess`. The only
// thing added is a `VaultFileAccess` decorator that prints a marker either side of the one call
// that touches the user's file, so the test knows which phase a kill landed in instead of
// guessing from timing.
//
// Everything this process prints on stdout is a marker line, and markers are the suite's evidence:
// a test asserts on the phase the helper actually REACHED, so a kill that arrives too late fails
// loudly rather than passing for the wrong reason.

// MARK: - Markers

/// A point in the save the test can recognise, kill on, or assert was (not) reached.
///
/// Printed as `STAGE:<rawValue>` on its own line, unbuffered — a buffered write would still be
/// sitting in this process's memory when the `SIGKILL` lands, which would destroy exactly the
/// evidence the test needs.
enum Stage: String, Sendable {
    /// Process is up, nothing read or written yet.
    case started
    /// The database is decoded and unlocked in memory (or, for `--mode create`, built in memory).
    /// The KDF for the OPEN has already run by this point; the one for the SAVE has not.
    case opened
    /// The in-memory edit is applied. Still nothing on disk.
    case edited
    /// `VaultStore.save()` is about to be called. Encoding — which begins with an Argon2
    /// derivation taking on the order of a second — starts immediately after this line.
    case saveBegin = "save-begin"
    /// The codec is done: the complete new file's bytes exist in memory, and `VaultFileAccess`
    /// is about to touch the disk. Between `save-begin` and here, NOTHING has been written.
    case writeBegin = "write-begin"
    /// The backup copy and the atomic write both returned successfully.
    case writeEnd = "write-end"
    /// `VaultStore.save()` returned.
    case saveEnd = "save-end"
    /// Clean exit.
    case done
}

/// Marker output. `FileHandle` rather than `print`: stdout to a pipe is fully buffered, so a
/// `print`ed marker can be lost to the kill that the marker itself is meant to trigger.
enum Marker {
    static func emit(_ stage: Stage) {
        write("STAGE:\(stage.rawValue)")
    }

    /// An observation the test wants to assert on — never vault contents. Read back from
    /// `HelperOutcome.info`.
    static func info(_ message: String) {
        write("INFO:\(message)")
    }

    /// Diagnostics for a failure the test needs to see. Never carries vault contents — this
    /// process handles a real (test-owned) master password and real plaintext entries, and a
    /// marker line ends up in a test log.
    static func fail(_ message: String) -> Never {
        write("ERROR:\(message)")
        exit(ExitCode.failed)
    }

    private static func write(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

enum ExitCode {
    /// Anything this process was asked to do and could not: a bad argument, a database that would
    /// not unlock, a save that the filesystem refused. The tests read `ERROR:` lines for the
    /// reason; the status only has to be distinguishable from a clean exit and from a signal.
    static let failed: Int32 = 65
}

// MARK: - Options

struct Options: Sendable {
    enum Mode: String, Sendable {
        /// Create a brand-new database at `--db` and save it. Exercises the first-save path, where
        /// there is no prior file and therefore nothing to back up.
        case create
        /// Open the existing database at `--db`, add an entry, and save over it. This is the path
        /// that matters: it has a real file to destroy.
        case edit
        /// Not a save: rewrite `--db`'s existing bytes over itself with
        /// `Data.write(options: [.atomic])` and report whether the file's inode changed.
        ///
        /// This isolates the ONE primitive the whole no-torn-file guarantee rests on, so it can be
        /// run under a sandbox profile that grants the file and not its directory — the case
        /// `SandboxedVaultFileAccess` has never been exercised in, and the one where `.atomic`'s
        /// sibling temporary file was suspected of being denied. Bypassing `VaultFileAccess` is the
        /// point: the full save path fails EARLIER under such a profile (at the backup copy), which
        /// would mask what the atomic write itself does.
        ///
        /// A changed inode means the bytes arrived via a rename over the destination, i.e. the
        /// write really was atomic and not an in-place rewrite that a crash could tear.
        case probeAtomicWrite = "probe-atomic-write"
    }

    var databaseURL: URL
    var password: String
    var mode: Mode
    /// Title of the entry added before the save. Its presence in the reopened file is how a test
    /// tells the new version from the old one.
    var entryTitle: String
    /// Size of an incompressible attachment added to that entry, in bytes. Padding, and the reason
    /// it exists is timing: a 3 KB vault is written and copied faster than any watcher can react,
    /// so the "killed during the write" and "killed during the backup copy" cases need a file big
    /// enough to have a middle. Random bytes on purpose — gzip must not shrink them back down.
    var attachmentBytes: Int
    /// Print this marker and then block forever, so a test can kill at an exact boundary rather
    /// than racing a timer.
    var hangAt: Stage?

    static func parse(_ arguments: [String]) -> Options {
        var databasePath: String?
        var password: String?
        var mode = Mode.edit
        var title = "durability-probe"
        var attachmentBytes = 0
        var hangAt: Stage?

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            func value() -> String {
                index += 1
                guard index < arguments.endIndex else {
                    Marker.fail("\(flag) needs a value")
                }
                return arguments[index]
            }
            switch flag {
            case "--db": databasePath = value()
            case "--password": password = value()
            case "--mode":
                let raw = value()
                guard let parsed = Mode(rawValue: raw) else { Marker.fail("unknown --mode \(raw)") }
                mode = parsed
            case "--title": title = value()
            case "--attachment-bytes":
                let raw = value()
                guard let parsed = Int(raw), parsed >= 0 else { Marker.fail("bad --attachment-bytes \(raw)") }
                attachmentBytes = parsed
            case "--hang-at":
                let raw = value()
                guard let parsed = Stage(rawValue: raw) else { Marker.fail("unknown --hang-at \(raw)") }
                hangAt = parsed
            default:
                Marker.fail("unknown argument \(flag)")
            }
            index += 1
        }

        guard let databasePath else { Marker.fail("--db is required") }
        guard let password else { Marker.fail("--password is required") }

        return Options(
            databaseURL: URL(fileURLWithPath: databasePath),
            password: password,
            mode: mode,
            entryTitle: title,
            attachmentBytes: attachmentBytes,
            hangAt: hangAt
        )
    }
}

// MARK: - File access decorator

/// Announces the disk-touching window around the REAL `SandboxedVaultFileAccess`, and optionally
/// blocks inside it.
///
/// A decorator rather than a fork of the production type (Open/Closed, and Dependency Inversion —
/// `VaultStore` already takes `any VaultFileAccess`, so nothing about the app has to change to
/// observe it). The backup copy and the atomic write both happen inside the wrapped `write`, so
/// the two markers bracket them jointly; a test that needs to distinguish "during the backup" from
/// "during the write" does it by watching the directory for the backup file and the atomic
/// temporary file, which is finer-grained than any marker could be without cutting the production
/// method open.
final class StageAnnouncingFileAccess: VaultFileAccess {
    private let wrapped: any VaultFileAccess
    private let hangAt: Stage?

    init(wrapping wrapped: any VaultFileAccess, hangAt: Stage?) {
        self.wrapped = wrapped
        self.hangAt = hangAt
    }

    func read(from url: URL) throws -> Data {
        try wrapped.read(from: url)
    }

    func write(_ data: Data, to url: URL) throws -> URL? {
        Marker.emit(.writeBegin)
        hangIfRequested(at: .writeBegin)
        let backupURL = try wrapped.write(data, to: url)
        Marker.emit(.writeEnd)
        hangIfRequested(at: .writeEnd)
        return backupURL
    }

    func bookmark(for url: URL) throws -> Data {
        try wrapped.bookmark(for: url)
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        try wrapped.resolveBookmark(data)
    }

    private func hangIfRequested(at stage: Stage) {
        guard hangAt == stage else { return }
        // Blocks this thread forever and is meant to: the test's `SIGKILL` is what ends this
        // process. `Thread.sleep` rather than a `Task.sleep` so the thread genuinely parks
        // instead of yielding the cooperative pool to something that might make progress.
        while true { Thread.sleep(forTimeInterval: 3600) }
    }
}

// MARK: - Entry point

@main
@MainActor
enum DurabilityHelper {
    static func main() async {
        let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

        Marker.emit(.started)
        hang(options, at: .started)

        if options.mode == .probeAtomicWrite {
            probeAtomicWrite(at: options.databaseURL)
        }

        let credentials = VaultCredentials(password: options.password, keyFile: nil)
        let store = VaultStore(
            codec: KDBXKitCodec(),
            fileAccess: StageAnnouncingFileAccess(
                wrapping: SandboxedVaultFileAccess(),
                hangAt: options.hangAt
            )
        )

        switch options.mode {
        case .create:
            await store.createNew(at: options.databaseURL, credentials: credentials)
        case .edit:
            await store.open(url: options.databaseURL, credentials: credentials)
        case .probeAtomicWrite:
            // Handled above, before the store is built, and it exits — this branch is unreachable
            // and exists only so the switch stays exhaustive without a `default:` that would
            // swallow a future mode.
            Marker.fail("internal error: probe-atomic-write reached the save path")
        }
        guard case .unlocked = store.state else {
            Marker.fail("could not unlock \(options.databaseURL.lastPathComponent): "
                + String(describing: store.lastError))
        }
        Marker.emit(.opened)
        hang(options, at: .opened)

        do {
            try applyEdit(to: store, options: options)
        } catch {
            Marker.fail("could not build the edit: \(error)")
        }
        Marker.emit(.edited)
        hang(options, at: .edited)

        Marker.emit(.saveBegin)
        hang(options, at: .saveBegin)
        await store.save()
        Marker.emit(.saveEnd)
        hang(options, at: .saveEnd)

        if let error = store.lastError {
            Marker.fail("save failed: \(error)")
        }

        Marker.emit(.done)
        hang(options, at: .done)
        exit(0)
    }

    /// Rewrites `url`'s own bytes over itself with `.atomic` and reports what happened. Exits.
    ///
    /// Writing the file's existing bytes back is deliberate: this probe is about the mechanism, and
    /// it must leave a valid database behind whether it succeeds or fails, so the caller can still
    /// open it afterwards.
    private static func probeAtomicWrite(at url: URL) -> Never {
        func inode() -> UInt64 {
            var status = stat()
            guard stat(url.path, &status) == 0 else { return 0 }
            return UInt64(status.st_ino)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Marker.fail("probe could not read \(url.lastPathComponent): \(error)")
        }

        let before = inode()
        Marker.emit(.writeBegin)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            Marker.fail("atomic write refused: \(error)")
        }
        Marker.emit(.writeEnd)
        // A changed inode is the evidence that the bytes arrived by rename rather than by being
        // written over the existing file in place.
        Marker.info("inode-changed=\(before != inode())")
        Marker.emit(.done)
        exit(0)
    }

    /// Adds one recognisable entry, optionally carrying a padding attachment. Goes through
    /// `VaultStore.upsert(_:addingBlobs:)` — the same call `EntryEditView` makes — rather than
    /// mutating a `Vault` directly, so the blob reaches the pool the way it does in the app.
    private static func applyEdit(to store: VaultStore, options: Options) throws {
        var attachments: [VaultAttachment] = []
        var blobs: [VaultBlob] = []

        if options.attachmentBytes > 0 {
            var bytes = Data(count: options.attachmentBytes)
            let filled: Bool = bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return false }
                return SecRandomCopyBytes(kSecRandomDefault, raw.count, base) == errSecSuccess
            }
            guard filled else { Marker.fail("could not generate \(options.attachmentBytes) random bytes") }
            // `isProtected: false`: the padding's only job is to make the file big. Running eight
            // megabytes through the inner stream cipher as well would cost time on both sides of
            // the round trip without testing anything the small protected fields do not already.
            let made = try VaultAttachment.make(name: "padding.bin", bytes: bytes, isProtected: false)
            attachments = [made.attachment]
            blobs = [made.blob]
        }

        let now = Date()
        var entry = VaultEntry(
            id: UUID(),
            groupID: nil,
            title: options.entryTitle,
            username: "durability",
            // Not a secret: this database is created by the test, in the test's own temporary
            // directory, and is deleted with it.
            password: "durability-probe-password",
            url: "",
            notes: "",
            otpAuthURL: nil,
            customFields: [:],
            created: now,
            modified: now
        )
        entry.attachments = attachments
        store.upsert(entry, addingBlobs: blobs)
    }

    private static func hang(_ options: Options, at stage: Stage) {
        guard options.hangAt == stage else { return }
        while true { Thread.sleep(forTimeInterval: 3600) }
    }
}
