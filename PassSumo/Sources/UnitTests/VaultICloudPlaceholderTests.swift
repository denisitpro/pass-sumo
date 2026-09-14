import XCTest
@testable import PassSumo

/// Issue #177 — an iCloud Drive database that has not finished downloading must say so, instead
/// of failing as a generic I/O error on a file the user can see in Finder.
///
/// The decision is tested directly rather than through a ubiquitous file, and that is the design
/// and not a shortcut: `make test` has no iCloud account and cannot make one, so a branch
/// reachable only on a real placeholder would be a branch nothing ever checks.
/// `SandboxedVaultFileAccess.read` reads the two resource values and hands them to
/// `UbiquitousDownloadCheck`; these tests hand the same pairs in themselves.
@MainActor
final class VaultICloudPlaceholderTests: XCTestCase {
    func testANotDownloadedUbiquitousItemIsBlockedWithItsOwnError() {
        XCTAssertEqual(
            UbiquitousDownloadCheck.blockingError(isUbiquitous: true, downloadingStatus: .notDownloaded),
            .iCloudNotDownloaded
        )
    }

    func testADownloadedUbiquitousItemIsReadable() {
        // `.downloaded` means a local copy exists and a newer one is in the cloud. Refusing here
        // would lock the user out of a database that is sitting right there on the disk.
        XCTAssertNil(
            UbiquitousDownloadCheck.blockingError(isUbiquitous: true, downloadingStatus: .downloaded)
        )
    }

    func testACurrentUbiquitousItemIsReadable() {
        XCTAssertNil(
            UbiquitousDownloadCheck.blockingError(isUbiquitous: true, downloadingStatus: .current)
        )
    }

    func testAUbiquitousItemOfUnknownStatusIsNotBlocked() {
        // The resource value could not be read. That is not evidence the file is a placeholder,
        // and attempting the read is a better answer than a guess.
        XCTAssertNil(
            UbiquitousDownloadCheck.blockingError(isUbiquitous: true, downloadingStatus: nil)
        )
    }

    func testALocalFileIsNeverBlockedWhateverTheStatusSays() {
        // The `isUbiquitous` guard has to come first: a non-ubiquitous file has no download state,
        // and a stray status value must not be able to block an ordinary local database.
        XCTAssertNil(
            UbiquitousDownloadCheck.blockingError(isUbiquitous: false, downloadingStatus: .notDownloaded)
        )
        XCTAssertNil(
            UbiquitousDownloadCheck.blockingError(isUbiquitous: false, downloadingStatus: nil)
        )
    }

    func testTheMessageNamesICloudAndTellsTheUserWhatToDo() {
        // Both halves matter. Without "iCloud" the user has no way to tell this apart from a
        // damaged database; without "try again" they have no next step.
        let message = VaultError.iCloudNotDownloaded.displayMessage
        XCTAssertTrue(message.contains("iCloud"), message)
        XCTAssertTrue(message.lowercased().contains("try again"), message)
        XCTAssertNil(VaultError.iCloudNotDownloaded.diagnosticDetail)
    }

    /// The other acceptance criterion: an ordinary local file still reads. Goes through the real
    /// `SandboxedVaultFileAccess`, because the new check lives in its `read` and the risk being
    /// covered is that it blocks something it should not.
    func testAnOrdinaryLocalFileStillReadsThroughTheRealFileAccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassSumoICloudTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("Vault.kdbx")
        let contents = Data("not in the cloud".utf8)
        try contents.write(to: url, options: [.atomic])

        var policy = VaultBackupPolicy.default
        let root = directory.appendingPathComponent("Backups", isDirectory: true)
        policy.root = { root }

        XCTAssertEqual(try SandboxedVaultFileAccess(backupPolicy: policy).read(from: url), contents)
    }
}
