import Foundation
import XCTest
@testable import PassSumo

/// Category 2 — **does the atomic-write path actually work where it has to?**
///
/// `SandboxedVaultFileAccess.write` rests on `Data.write(options: [.atomic])`, whose documented
/// behaviour is to write a temporary file *next to* the destination and rename it over the top.
/// Under the App Sandbox, a user-picked `.kdbx` is granted as a SINGLE FILE, not as its directory —
/// so "write a sibling" was a suspected failure that had never been exercised against anything.
///
/// ## What these tests establish, and what they do not
///
/// The App Sandbox cannot be entered on demand from a test: a sandbox grant for a user-picked file
/// comes from the powerbox (`NSOpenPanel`), which needs a human. What CAN be done is to reproduce
/// the exact filesystem restriction with the same kernel enforcement mechanism, via `sandbox-exec`
/// and a Seatbelt profile that permits writing one file and forbids creating anything in its
/// directory. That is the same MAC layer the App Sandbox is built on, applied by hand rather than
/// by the powerbox.
///
/// So: these tests establish what the kernel does when only the file is writable. They do NOT
/// establish that a powerbox-issued extension for a user-picked file has exactly the same scope —
/// see README.md, "What this suite does not prove".
final class AtomicWriteTests: DurabilityTestCase {
    private static let sandboxExec = "/usr/bin/sandbox-exec"

    // MARK: - The mechanism, unrestricted

    /// The baseline: an atomic write replaces the file by rename, not by rewriting it in place.
    ///
    /// This is the whole basis of the no-torn-file guarantee, so it is worth asserting directly
    /// rather than inferring from the kill tests. A changed inode can only mean the bytes arrived
    /// under a different file that was then renamed over the destination — and `rename(2)` within a
    /// filesystem is atomic, which is why a reader can never see a half-written vault.
    func testAtomicWriteReplacesTheFileByRenameRatherThanInPlace() throws {
        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1")

        let outcome = try runHelper(database: database, mode: "probe-atomic-write")
        XCTAssertTrue(
            outcome.reached(HelperStage.done),
            "the probe did not complete: \(outcome.markers) \(outcome.errors)"
        )
        XCTAssertTrue(
            outcome.info.contains("inode-changed=true"),
            "the atomic write did not replace the file by rename — it wrote in place, which a "
                + "crash can tear; info: \(outcome.info)"
        )
        try assertOpens(database, "after an atomic rewrite")
    }

    // MARK: - The mechanism under a single-file grant

    /// **The answer to the open question.** With write access to the database file and none to its
    /// directory, `Data.write(options: [.atomic])` still succeeds, and still replaces the file by
    /// rename.
    ///
    /// Foundation does not blindly create the sibling: watching the directory during a 300 MB
    /// atomic write shows a `v.kdbx.sb-<hex>-<rand>` sibling appear when the process is
    /// unrestricted, and NO sibling at all when the same write runs under a file-only grant — yet
    /// the inode still changes either way. It falls back to a temporary file the sandbox does
    /// permit and renames from there.
    ///
    /// The practical consequence: `.atomic` is not the thing that breaks in the sandbox. The backup
    /// is — see the next test.
    func testAtomicWriteSucceedsWhenTheSandboxGrantsTheFileButNotItsDirectory() throws {
        let (database, profile) = try makeSingleFileGrant()

        let outcome = try runHelper(
            database: database,
            mode: "probe-atomic-write",
            launcher: [Self.sandboxExec, "-f", profile.path]
        )

        XCTAssertTrue(
            outcome.reached(HelperStage.done),
            "the atomic write was refused under a file-only grant: \(outcome.errors)"
        )
        XCTAssertTrue(
            outcome.info.contains("inode-changed=true"),
            "it succeeded but stopped being atomic — the bytes went in place rather than through a "
                + "rename; info: \(outcome.info)"
        )
        try assertOpens(database, "after an atomic write under a file-only grant")
    }

    /// **A real defect, found by this suite.** Under a file-only grant the production save path
    /// fails — and not at the atomic write, which the test above shows is fine, but at the pre-save
    /// backup: `SandboxedVaultFileAccess` copies the vault to `<name>.kdbx.bak-<stamp>` NEXT TO
    /// the vault, which means creating a new file in a directory the app was never granted.
    ///
    /// The failure is at least a safe one — the save reports `VaultError.io`, the database is left
    /// byte-for-byte intact, and `VaultStore` leaves `isDirty` set so the user is not told their
    /// edits are on disk. But the user simply cannot save, which for a password manager whose
    /// entire sandbox story is "the user picks a `.kdbx` with `NSOpenPanel`" is a shipping blocker,
    /// not a rough edge.
    ///
    /// This test asserts the CURRENT behaviour, including the failure, because pretending it does
    /// not happen would remove the only signal anyone has. When the backup moves somewhere the app
    /// can always write (its container) or the app starts asking for a directory grant, this test
    /// is the one that has to be rewritten — deliberately, with the fix.
    func testProductionSavePathIsBlockedByAFileOnlyGrantBecauseTheBACKUPNeedsTheDirectory() throws {
        let (database, profile) = try makeSingleFileGrant()
        let before = try Data(contentsOf: database)

        let outcome = try runHelper(
            database: database,
            title: "v2",
            launcher: [Self.sandboxExec, "-f", profile.path]
        )

        XCTAssertFalse(
            outcome.reached(HelperStage.done),
            "the save unexpectedly SUCCEEDED under a file-only grant. That is good news and this "
                + "test is now wrong — check whether the backup moved out of the vault's directory, "
                + "and rewrite this test around the new behaviour rather than deleting it."
        )
        XCTAssertTrue(
            outcome.errors.contains { $0.contains("failed to back up") },
            "the save failed for some other reason than the backup: \(outcome.errors)"
        )

        // The one thing that must never be negotiable: a save that cannot proceed leaves the
        // existing database exactly as it was.
        XCTAssertEqual(
            try Data(contentsOf: database), before,
            "a refused save damaged the database it could not replace"
        )
        XCTAssertEqual(
            Self.temporaryURLs(besides: database), [],
            "a refused save left debris next to the database"
        )
        try assertOpens(database, "after a save refused by the sandbox")
    }

    // MARK: - The mechanism on a directory that cannot be written at all

    /// A different restriction with a different answer: a directory made unwritable by plain POSIX
    /// permissions — a vault on a read-only mount, a wrongly-`chmod`ed folder, a synced folder gone
    /// read-only. Unlike the Seatbelt case, there is no fallback here: even a rename from elsewhere
    /// needs write permission on the destination directory, so the atomic write itself cannot land.
    ///
    /// Included because the outcome is the one that matters for data safety: everything FAILS, and
    /// failing is correct. What must not happen is a partial write, a zero-byte file, or a save
    /// that reports success without having replaced anything.
    func testSaveFailsCleanlyWhenTheDirectoryIsUnwritable() throws {
        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1")
        let before = try Data(contentsOf: database)

        let fileAccess = SandboxedVaultFileAccess()
        // r-x: the directory can be listed and traversed, but nothing can be created or renamed
        // into it. The database file itself stays writable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
        }

        // The primitive first: `.atomic` cannot complete, because there is nowhere in this
        // directory for the replacement to be renamed from.
        XCTAssertThrowsError(
            try Data("not a database".utf8).write(to: database, options: [.atomic]),
            "an atomic write into an unwritable directory unexpectedly succeeded"
        )

        // Then the whole save path. It fails earlier still — at the backup copy — but the property
        // under test is the same: a refused save is refused as a whole.
        XCTAssertThrowsError(
            try fileAccess.write(Data("not a database".utf8), to: database)
        ) { error in
            guard case .io = error as? VaultError else {
                return XCTFail("expected VaultError.io, got \(error)")
            }
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(
            try Data(contentsOf: database), before,
            "the refused write must not have touched the database"
        )
        try assertOpens(database, "after a write refused by directory permissions")
    }

    // MARK: - The real App Sandbox

    /// The real thing, as far as it can be reached automatically: when the test host is genuinely
    /// sandboxed, an atomic write still works.
    ///
    /// Skips under `make durability`, whose host is unsigned and therefore has no entitlements and
    /// no sandbox at all — a pass there would prove nothing about the sandbox, so it must not be
    /// allowed to look like one. Run `make durability-signed` for this.
    ///
    /// Even then, it covers the container, not a powerbox grant: the app owns its container
    /// directory outright, so a sibling temporary file is permitted there. The file-only case is
    /// what the Seatbelt tests above are for.
    func testAtomicWriteWorksInsideTheRealAppSandboxContainer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["APP_SANDBOX_CONTAINER_ID"] != nil else {
            throw XCTSkip(
                "this host is not sandboxed — an unsigned build gets no entitlements and therefore "
                    + "no App Sandbox, so this test would pass without testing anything. Run "
                    + "`make durability-signed`."
            )
        }

        let directory = try makeScratchDirectory()
        let url = directory.appendingPathComponent("container.kdbx")
        let codec = KDBXKitCodec()
        let credentials = VaultCredentials(password: Self.password, keyFile: nil)
        let created = try codec.makeEmpty(name: "container", credentials: credentials)
        let bytes = try codec.encode(created.vault, credentials: credentials, origin: created)

        try bytes.write(to: url, options: [.atomic])
        XCTAssertNoThrow(
            try codec.decode(fileData: try Data(contentsOf: url), credentials: credentials),
            "an atomic write inside the app's own sandbox container did not produce a readable file"
        )

        // And the full path, backup included — inside the container the app owns the directory, so
        // this is expected to succeed. It is the contrast with the file-only grant above.
        let fileAccess = SandboxedVaultFileAccess()
        XCTAssertNoThrow(try fileAccess.write(bytes, to: url))
    }

    // MARK: - Helpers

    /// A scratch database plus a Seatbelt profile that grants write access to that one file and
    /// denies it for everything else in the directory — the filesystem shape of a powerbox grant
    /// for a user-picked file.
    private func makeSingleFileGrant() throws -> (database: URL, profile: URL) {
        try skipIfHostIsSandboxed("nesting a Seatbelt sandbox inside the App Sandbox")
        guard FileManager.default.isExecutableFile(atPath: Self.sandboxExec) else {
            throw XCTSkip("\(Self.sandboxExec) is not available on this system")
        }
        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1")

        // Seatbelt matches on RESOLVED paths: the test host's temporary directory is reached
        // through /var -> /private/var, and a profile written with the unresolved path silently
        // matches nothing — which looks exactly like "the sandbox allowed it", and did, until the
        // self-check below caught it. `realpath(3)` rather than `URL.resolvingSymlinksInPath()`,
        // which normalises /private/var back DOWN to /var for temporary directories and so produces
        // precisely the path that does not match.
        let resolvedDirectory = Self.realPath(of: directory)
        let resolvedDatabase = Self.realPath(of: database)

        // The profile lives in a directory of its own, not beside the database: tests here assert
        // that a refused save leaves NO debris next to the vault, and a stray `.sb` file would be
        // indistinguishable from debris.
        let profile = try makeScratchDirectory().appendingPathComponent("single-file-grant.sb")
        try """
        (version 1)
        ;; Everything the process would ordinarily be allowed, minus one directory: this models the
        ;; App Sandbox's FILE-scoped grant, not a whole app sandbox. What is under test is the
        ;; filesystem restriction, so restricting anything else would only add noise.
        (allow default)
        (deny file-write* (subpath "\(resolvedDirectory)"))
        ;; ...except the database itself, which is what the user picked.
        (allow file-write* (literal "\(resolvedDatabase)"))
        """.write(to: profile, atomically: true, encoding: .utf8)

        // A profile that does not actually restrict anything would make every test below pass for
        // the wrong reason. Prove it bites before relying on it.
        let probe = directory.appendingPathComponent("sandbox-self-check")
        let denied = Self.run(Self.sandboxExec, ["-f", profile.path, "/usr/bin/touch", probe.path])
        XCTAssertNotEqual(
            denied, 0,
            "the Seatbelt profile did not deny creating a sibling file, so it is not restricting "
                + "anything and none of the sandbox tests in this file would mean what they claim"
        )
        try? FileManager.default.removeItem(at: probe)

        return (database, profile)
    }

    /// The path with every symlink resolved, as the kernel sees it.
    private static func realPath(of url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Runs a command to completion and returns its exit status. Output is discarded — the callers
    /// here only need pass/fail.
    private static func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        do {
            try process.run()
        } catch {
            return -1
        }
        _ = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
