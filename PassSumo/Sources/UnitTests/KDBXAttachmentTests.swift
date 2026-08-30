import KDBXKit
import XCTest
@testable import PassSumo

/// Attachment tests, at the level that matters: real `.kdbx` bytes in, real `.kdbx` bytes out.
///
/// Every assertion here goes through `KDBXKitCodec.encode` / `.decode` rather than poking at
/// `KDBXAttachments` directly. The bug class this feature can produce — a payload that decodes
/// fine in memory but is dropped, duplicated, or repointed at the wrong pool slot on the way to
/// disk — is only visible after a full round trip, so that is what is tested.
///
/// Lives in its own file, in the existing `Sources/UnitTests` directory, so no `project.yml` edit
/// is needed (a new test DIRECTORY would need one; a new file in an existing one does not).
final class KDBXAttachmentTests: XCTestCase {
    private let codec = KDBXKitCodec()

    /// Published test password for the redistributed KDBXKit fixtures — these files ship in the
    /// repo and contain no real secrets.
    private static let kdbxKitPassword = "123"

    private func credentials() -> VaultCredentials {
        VaultCredentials(password: Self.kdbxKitPassword, keyFile: nil)
    }

    private func fixture(_ name: String, subdirectory: String = "Fixtures/kdbxkit") throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "kdbx", subdirectory: subdirectory),
            "fixture \(subdirectory)/\(name).kdbx is not in the test bundle — check the "
                + "PassSumoUnitTests `sources` folder reference in project.yml"
        )
        return try Data(contentsOf: url)
    }

    private static func kdbxContent(of decoded: DecodedVault) -> KDBXContent? {
        (decoded.opaque as? KDBXOrigin)?.content
    }

    /// Deterministic, recognisable payload — not random bytes, so a failure message showing the
    /// wrong data is readable rather than a hex dump.
    private static func payload(_ marker: UInt8, count: Int = 4096) -> Data {
        Data(repeating: marker, count: count)
    }

    // MARK: - Reading what other clients wrote

    /// The read direction against a file this project did not write: KeePassXC put an attachment
    /// on the `GitHub` entry of `kpxc-rich`, and it has to reach the domain model with its bytes
    /// resolvable — not merely survive as opaque state the UI cannot show.
    func testExistingExternalAttachmentIsProjectedIntoTheModel() throws {
        let decoded = try codec.decode(fileData: try fixture("kpxc-rich"), credentials: credentials())
        let vault = decoded.vault

        let github = try XCTUnwrap(vault.entries.first { $0.title == "GitHub" })
        XCTAssertFalse(github.attachments.isEmpty, "fixture precondition: GitHub has an attachment")

        for attachment in github.attachments {
            let bytes = try XCTUnwrap(
                vault.bytes(for: attachment),
                "attachment '\(attachment.name)' has no resolvable payload in the blob pool"
            )
            XCTAssertEqual(bytes.count, attachment.byteCount, "declared size disagrees with the payload")
            XCTAssertEqual(
                VaultBlobID(hashing: bytes), attachment.blobID,
                "the blob id must be the content hash of the payload it names"
            )
        }
    }

    /// A decode/encode of an untouched database with an attachment must leave the binary pool and
    /// every entry's `<Binary>` list exactly as they were — no duplicated payload, no dropped one,
    /// no ref repointed. This is the invariant the whole design is built around.
    func testUneditedDatabaseRoundTripsWithAnIdenticalBinaryPool() throws {
        let creds = credentials()
        let decoded = try codec.decode(fileData: try fixture("kpxc-rich"), credentials: creds)
        let before = try XCTUnwrap(Self.kdbxContent(of: decoded))

        let saved = try codec.encode(decoded.vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: saved, credentials: creds)
        let after = try XCTUnwrap(Self.kdbxContent(of: reopened))

        XCTAssertEqual(
            after.innerHeader.binaryContent, before.innerHeader.binaryContent,
            "the binary pool changed on a save that edited nothing"
        )
        XCTAssertEqual(
            Self.binaries(in: after), Self.binaries(in: before),
            "an entry's <Binary> elements changed on a save that edited nothing"
        )
    }

    // MARK: - Adding

    /// Add an attachment, save, reload: the payload comes back byte-identical.
    func testAddedAttachmentSurvivesASaveByteIdentical() throws {
        let creds = credentials()
        let decoded = try codec.decode(
            fileData: try fixture("simple-argon2id-aes256"),
            credentials: creds
        )

        var vault = decoded.vault
        let index = try XCTUnwrap(vault.entries.indices.first, "fixture precondition: has an entry")
        let bytes = Self.payload(0xAB)
        let made = try VaultAttachment.make(name: "receipt.bin", bytes: bytes)
        vault.blobs[made.blob.id] = made.blob
        vault.entries[index].attachments = [made.attachment]

        let saved = try codec.encode(vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: saved, credentials: creds)

        let entry = try XCTUnwrap(reopened.vault.entries.first { $0.id == vault.entries[index].id })
        let attachment = try XCTUnwrap(entry.attachments.first)
        XCTAssertEqual(attachment.name, "receipt.bin")
        XCTAssertEqual(attachment.byteCount, bytes.count)
        XCTAssertEqual(
            reopened.vault.bytes(for: attachment), bytes,
            "the payload that came back is not the payload that went in"
        )

        // New attachments are written inner-stream protected — see `VaultAttachment.make`.
        let content = try XCTUnwrap(Self.kdbxContent(of: reopened))
        XCTAssertTrue(
            content.innerHeader.binaryContent.contains { $0.data == bytes && $0.shouldBeProtected },
            "a newly added attachment must land in the pool marked protected"
        )
    }

    /// Two entries carrying the same bytes must cost ONE pool slot, not two. This is the reason
    /// the model addresses payloads by content hash instead of giving each entry its own copy.
    func testTheSamePayloadOnTwoEntriesSharesOnePoolSlot() throws {
        let creds = credentials()
        let decoded = try codec.decode(fileData: try fixture("kpxc-rich"), credentials: creds)
        let before = try XCTUnwrap(Self.kdbxContent(of: decoded))
        let poolCountBefore = before.innerHeader.binaryContent.count

        var vault = decoded.vault
        XCTAssertGreaterThanOrEqual(vault.entries.count, 2, "fixture precondition: 2+ entries")
        let bytes = Self.payload(0x5A)
        let made = try VaultAttachment.make(name: "shared.bin", bytes: bytes)
        vault.blobs[made.blob.id] = made.blob
        vault.entries[0].attachments.append(made.attachment)
        vault.entries[1].attachments.append(made.attachment)

        let saved = try codec.encode(vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: saved, credentials: creds)
        let after = try XCTUnwrap(Self.kdbxContent(of: reopened))

        XCTAssertEqual(
            after.innerHeader.binaryContent.count, poolCountBefore + 1,
            "one payload attached twice must add exactly one pool slot"
        )
        // And both entries must still resolve to it.
        for id in [vault.entries[0].id, vault.entries[1].id] {
            let entry = try XCTUnwrap(reopened.vault.entries.first { $0.id == id })
            let attachment = try XCTUnwrap(entry.attachments.first { $0.name == "shared.bin" })
            XCTAssertEqual(reopened.vault.bytes(for: attachment), bytes)
        }
    }

    // MARK: - Removing

    /// Remove an attachment, save, reload: it is gone from the entry.
    ///
    /// The payload is asserted to still be IN THE POOL, orphaned. That is deliberate behaviour,
    /// not a leak the test forgot to catch — history snapshots reference pool slots positionally
    /// and are never rewritten, so compacting the pool would repoint them at the wrong payload.
    /// `KDBXBinaryPool`'s doc comment has the full argument; this assertion is what pins the
    /// decision down so a later "tidy up the pool" change has to confront it.
    func testRemovedAttachmentIsGoneFromTheEntryAndItsPayloadIsLeftOrphaned() throws {
        let creds = credentials()
        let decoded = try codec.decode(fileData: try fixture("kpxc-rich"), credentials: creds)
        let before = try XCTUnwrap(Self.kdbxContent(of: decoded))

        var vault = decoded.vault
        let index = try XCTUnwrap(vault.entries.firstIndex { !$0.attachments.isEmpty })
        let removed = vault.entries[index].attachments
        XCTAssertFalse(removed.isEmpty, "fixture precondition: an entry with an attachment")
        let removedBytes = try XCTUnwrap(vault.bytes(for: removed[0]))
        vault.entries[index].attachments = []

        let saved = try codec.encode(vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: saved, credentials: creds)

        let entry = try XCTUnwrap(reopened.vault.entries.first { $0.id == vault.entries[index].id })
        XCTAssertTrue(entry.attachments.isEmpty, "the removed attachment is still on the entry")

        let after = try XCTUnwrap(Self.kdbxContent(of: reopened))
        XCTAssertEqual(
            after.innerHeader.binaryContent.count, before.innerHeader.binaryContent.count,
            "the pool must be appended to, never compacted — see KDBXBinaryPool"
        )
        XCTAssertTrue(
            after.innerHeader.binaryContent.contains { $0.data == removedBytes },
            "the orphaned payload is expected to stay in the pool"
        )
    }

    /// Removing one of two attachments leaves the other intact and still resolvable — the rebuild
    /// path (which re-emits the whole `<Binary>` list) must not disturb what it kept.
    func testRemovingOneAttachmentLeavesTheOtherIntact() throws {
        let creds = credentials()
        let decoded = try codec.decode(
            fileData: try fixture("simple-argon2id-aes256"),
            credentials: creds
        )

        var vault = decoded.vault
        let index = try XCTUnwrap(vault.entries.indices.first)
        let keptBytes = Self.payload(0x11)
        let goneBytes = Self.payload(0x22)
        let kept = try VaultAttachment.make(name: "kept.bin", bytes: keptBytes)
        let gone = try VaultAttachment.make(name: "gone.bin", bytes: goneBytes)
        vault.blobs[kept.blob.id] = kept.blob
        vault.blobs[gone.blob.id] = gone.blob
        vault.entries[index].attachments = [kept.attachment, gone.attachment]

        let withBoth = try codec.encode(vault, credentials: creds, origin: decoded)
        let reopened = try codec.decode(fileData: withBoth, credentials: creds)

        var pruned = reopened.vault
        let prunedIndex = try XCTUnwrap(pruned.entries.firstIndex { $0.id == vault.entries[index].id })
        pruned.entries[prunedIndex].attachments.removeAll { $0.name == "gone.bin" }

        let savedAgain = try codec.encode(pruned, credentials: creds, origin: reopened)
        let reopenedAgain = try codec.decode(fileData: savedAgain, credentials: creds)

        let entry = try XCTUnwrap(reopenedAgain.vault.entries.first { $0.id == vault.entries[index].id })
        XCTAssertEqual(entry.attachments.map(\.name), ["kept.bin"])
        XCTAssertEqual(
            reopenedAgain.vault.bytes(for: try XCTUnwrap(entry.attachments.first)),
            keptBytes
        )
    }

    // MARK: - The size guard

    func testAttachmentOverTheLimitIsRefused() {
        let oversized = Data(count: VaultAttachment.maximumByteCount + 1)
        XCTAssertThrowsError(try VaultAttachment.make(name: "huge.bin", bytes: oversized)) { error in
            XCTAssertEqual(
                error as? VaultAttachmentError,
                .tooLarge(
                    name: "huge.bin",
                    byteCount: VaultAttachment.maximumByteCount + 1,
                    limit: VaultAttachment.maximumByteCount
                )
            )
        }
    }

    func testAttachmentExactlyAtTheLimitIsAccepted() throws {
        // The boundary is inclusive; an off-by-one here would refuse a file the message says fits.
        let atLimit = Data(count: VaultAttachment.maximumByteCount)
        let made = try VaultAttachment.make(name: "exact.bin", bytes: atLimit)
        XCTAssertEqual(made.attachment.byteCount, VaultAttachment.maximumByteCount)
    }

    // MARK: - Helpers

    /// Every entry's `<Binary>` list in the file, keyed by entry UUID, so two files can be compared
    /// without depending on tree order.
    private static func binaries(in content: KDBXContent) -> [UUID: [KDBX.ProtectedBinary]] {
        var result: [UUID: [KDBX.ProtectedBinary]] = [:]
        content.database.visitEntries(in: content.database.root.group) { entry in
            result[entry.uuid] = entry.binaries
        }
        return result
    }
}
