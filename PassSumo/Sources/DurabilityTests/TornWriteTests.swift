import Foundation
import XCTest
@testable import PassSumo

/// Category 1 — **the file is never left torn.**
///
/// Every test here kills a real save in a real process at a known point and then asks the real
/// codec to open what is on disk. The invariant under test is the one a password manager cannot
/// negotiate: after a crash, a force quit or a power cut, the database file is either the complete
/// old version or the complete new version. Never a prefix of either.
///
/// The kill is a `SIGKILL`, which no process can catch, defer or clean up after — the closest a
/// test can get to the plug coming out of the wall. What it does NOT reproduce is the layer below:
/// `SIGKILL` leaves the filesystem intact, so page-cache contents already handed to the kernel are
/// still written out. A genuine power loss can also lose an un-`fsync`ed rename. See README.md.
final class TornWriteTests: DurabilityTestCase {
    // MARK: - The control

    /// Establishes the baseline the kill tests are read against: an uninterrupted save produces the
    /// new version, leaves exactly one backup, and that backup is the complete old version.
    func testUninterruptedSaveWritesTheNewVersionAndLeavesACompleteBackup() throws {
        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1")
        let before = try Data(contentsOf: database)

        let outcome = try runHelper(database: database, title: "v2")
        XCTAssertTrue(outcome.reached(HelperStage.done), "markers: \(outcome.markers), errors: \(outcome.errors)")

        let titles = try assertOpens(database, "after a clean save")
        XCTAssertTrue(titles.contains("v2"), "the new entry is missing: \(titles)")
        XCTAssertTrue(titles.contains("v1"), "the old entry was lost: \(titles)")

        let backups = backups(of: database)
        XCTAssertEqual(backups.count, 1, "exactly one backup should have been rotated in")
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(
            try Data(contentsOf: backup), before,
            "the backup must be a byte-exact copy of the file as it was before the save"
        )
        XCTAssertEqual(
            Self.temporaryURLs(besides: database), [],
            "the atomic write left its temporary file behind instead of renaming it into place"
        )
    }

    // MARK: - Killed before anything is written

    /// Killed while the key derivation for the save is running.
    ///
    /// A KDBX save begins with Argon2, which is deliberately expensive — around a second — so this
    /// is the single widest window in which a user can quit, lose power, or force-kill the app. At
    /// that point the codec has not produced a single byte, so the correct outcome is that the file
    /// is not merely openable but bit-for-bit what it was.
    ///
    /// The kill is fired on the `save-begin` marker and the assertion that it landed in the KDF is
    /// that `write-begin` never arrived — evidence, not a timing assumption.
    func testKillDuringKeyDerivationLeavesTheDatabaseByteIdentical() throws {
        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1")
        let before = try Data(contentsOf: database)

        let outcome = try runHelper(
            database: database,
            title: "v2",
            killWhen: .marker(HelperStage.saveBegin)
        )
        outcome.assertKilled(after: HelperStage.saveBegin, before: HelperStage.writeBegin)

        XCTAssertEqual(
            try Data(contentsOf: database), before,
            "nothing had been written yet, so the file must be untouched"
        )
        XCTAssertEqual(
            backups(of: database), [],
            "the backup is taken inside the write — a kill before it must not have produced one"
        )
        let titles = try assertOpens(database, "after a kill during the KDF")
        XCTAssertEqual(titles, ["v1"], "the file must still be the old version: \(titles)")
    }

    /// Killed at the exact boundary between "the new file's bytes exist in memory" and "the disk is
    /// touched" — the one case in this file with no race in it at all.
    ///
    /// The kills elsewhere fire on an event and win by a margin (a millisecond against a hundred),
    /// and prove they won by which markers arrived. Here the helper is told to *park* at
    /// `write-begin` and block forever, so the window is unbounded and the kill cannot land
    /// anywhere else. What that isolates is the encoder's own contract: encoding a vault must have
    /// no side effects on disk, so a process that dies with a fully-encoded database in hand leaves
    /// the file exactly as it found it — and, since the backup is taken inside the write, without
    /// even a backup to clean up.
    func testKillAfterEncodingButBeforeAnyDiskWriteLeavesTheFileByteIdentical() throws {
        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1")
        let before = try Data(contentsOf: database)

        let outcome = try runHelper(
            database: database,
            title: "v2",
            hangAt: HelperStage.writeBegin,
            killWhen: .marker(HelperStage.writeBegin)
        )
        outcome.assertKilled(after: HelperStage.writeBegin, before: HelperStage.writeEnd)

        XCTAssertEqual(
            try Data(contentsOf: database), before,
            "encoding is not supposed to touch the disk at all"
        )
        XCTAssertEqual(
            backups(of: database), [],
            "the backup is taken inside the write, which had not started"
        )
        XCTAssertEqual(
            Self.temporaryURLs(besides: database), [],
            "nothing at all should have been created yet"
        )
    }

    // MARK: - Killed during the backup

    /// Killed while the pre-save backup copy is in flight.
    ///
    /// Two things must hold. The database itself is untouched — the backup is taken before the
    /// write, so nothing has replaced it yet. And any backup file left behind must be a complete,
    /// openable database: a backup is only worth having if it can be trusted unconditionally, and a
    /// half-copied one that still looks like a backup is worse than no backup at all, because it is
    /// what someone reaches for after losing the original.
    ///
    /// **Why this passes, precisely.** Not because the copy is fast enough to win a race:
    /// `FileManager.copyItem` on APFS issues `clonefile(2)`, which shares the source's blocks
    /// instead of reading and rewriting them, so the destination is complete the moment it exists —
    /// measured here at 1 GiB in ~2 ms. The backup is therefore never observable in a partial
    /// state at all, which is why `killObservation` below shows it already at full size the first
    /// time the watcher sees it. That guarantee is the FILESYSTEM's, not this code's: on a volume
    /// where `copyfile` has to fall back to a byte-by-byte copy (a network share, an exFAT stick,
    /// a disk image) a kill mid-copy would leave exactly the truncated backup this test is looking
    /// for. See README.md.
    func testKillWhileTheBackupIsBeingCopiedLeavesNoUnopenableBackup() throws {
        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1", attachmentBytes: Self.paddingBytes)
        let before = try Data(contentsOf: database)

        let outcome = try runHelper(
            database: database,
            title: "v2",
            killWhen: .backupAppears
        )
        outcome.assertKilled(after: HelperStage.writeBegin, before: HelperStage.writeEnd)

        XCTAssertEqual(
            try Data(contentsOf: database), before,
            "the backup runs before the write — the database itself must be untouched"
        )

        XCTAssertFalse(backups(of: database).isEmpty, "the trigger fired, so a backup must exist")
        for backup in backups(of: database) {
            let titles = try assertOpens(
                backup,
                "a backup left behind by a kill during the copy — \(Self.size(of: backup)) of "
                    + "\(before.count) bytes; at the kill: \(outcome.killObservation ?? "n/a")"
            )
            XCTAssertEqual(titles, ["v1"], "the backup must be the pre-save version")
        }
    }

    /// Killed after the backup is complete but before the atomic write replaces anything.
    ///
    /// The narrow window the backup exists for: this is the moment where a user has both the
    /// original and its copy and nothing has been overwritten.
    func testKillBetweenTheBackupAndTheWriteLeavesTheOldFileAndACompleteBackup() throws {
        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1", attachmentBytes: Self.paddingBytes)
        let before = try Data(contentsOf: database)

        let outcome = try runHelper(
            database: database,
            title: "v2",
            killWhen: .backupReaches(bytes: before.count)
        )
        outcome.assertKilled(after: HelperStage.writeBegin, before: HelperStage.writeEnd)

        XCTAssertEqual(
            try Data(contentsOf: database), before,
            "the write had not replaced anything yet"
        )
        let backup = try XCTUnwrap(backups(of: database).first, "the backup should exist by now")
        XCTAssertEqual(
            try Data(contentsOf: backup), before,
            "a backup that reached full size must also be byte-identical, not merely the right length"
        )
    }

    // MARK: - Killed during the write itself

    /// Killed with the atomic write in progress — the case the whole `.atomic` option exists for.
    ///
    /// `Data.write(options: [.atomic])` writes a temporary file next to the destination and renames
    /// it over the top, and `rename(2)` is atomic within a filesystem, so a reader can only ever see
    /// one file or the other. The kill fires the instant that temporary file appears, which is as
    /// close to "mid-write" as an outside observer can aim.
    ///
    /// The assertion is deliberately "old OR new": which one survives is genuinely
    /// non-deterministic, and demanding a particular one would be testing the scheduler.
    func testKillDuringTheAtomicWriteLeavesEitherTheCompleteOldOrTheCompleteNewFile() throws {
        try skipIfHostIsSandboxed("watching a directory closely enough to catch the atomic write's "
            + "temporary file")
        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1", attachmentBytes: Self.paddingBytes)

        let outcome = try runHelper(
            database: database,
            title: "v2",
            killWhen: .atomicTemporaryAppears
        )
        XCTAssertTrue(
            outcome.wasKilled,
            "no sibling temporary file was ever observed, so this run did not exercise a mid-write "
                + "kill; markers: \(outcome.markers)"
        )
        outcome.assertKilled(after: HelperStage.writeBegin, before: HelperStage.writeEnd)

        let titles = try assertOpens(
            database,
            "after a kill during the atomic write (at the kill: \(outcome.killObservation ?? "n/a"))"
        )
        XCTAssertTrue(
            titles == ["v1"] || titles == ["v1", "v2"],
            "the file is neither the complete old version nor the complete new one: \(titles); "
                + "at the kill: \(outcome.killObservation ?? "n/a")"
        )
        // A kill mid-write leaves Foundation's temporary file orphaned next to the database — there
        // is no one left to rename or delete it. That is tolerable, but only as long as it cannot be
        // mistaken for the vault or for one of its backups: the rotation in
        // `SandboxedVaultFileAccess` selects backups by filename prefix, and a stray file matching
        // that prefix would be counted as a backup and eventually presented as one.
        for orphan in Self.temporaryURLs(besides: database) {
            XCTAssertFalse(
                orphan.pathExtension == "kdbx",
                "a torn write left '\(orphan.lastPathComponent)' looking like a database"
            )
        }
    }

    /// The shotgun: kills spread across the whole save, claiming no particular phase.
    ///
    /// The targeted tests above each prove one window. This one covers the gaps between them —
    /// including the instants inside `rename(2)` and inside `copyItem` that no marker can name — by
    /// killing at a spread of offsets after the save starts and asserting the same invariant every
    /// time. Any offset that lands after the save completed is not a wasted run: it still asserts
    /// the file opens.
    func testKillsSpreadAcrossTheSaveNeverLeaveATornFile() throws {
        let offsets: [TimeInterval] = [0.05, 0.2, 0.4, 0.6, 0.8, 1.0, 1.3, 1.6]

        for offset in offsets {
            let directory = try makeScratchDirectory()
            let database = try createDatabase(
                in: directory, title: "v1", attachmentBytes: Self.paddingBytes
            )

            let outcome = try runHelper(
                database: database,
                title: "v2",
                killWhen: .delayAfterSaveBegin(offset)
            )

            let titles = try assertOpens(database, "after a kill \(offset)s into the save")
            XCTAssertTrue(
                titles == ["v1"] || titles == ["v1", "v2"],
                "kill at +\(offset)s left a file that is neither version: \(titles); "
                    + "markers: \(outcome.markers)"
            )
            for backup in backups(of: database) {
                try assertOpens(backup, "a backup left by a kill at +\(offset)s")
            }
        }
    }
}
