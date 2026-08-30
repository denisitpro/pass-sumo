import KDBXKit
import XCTest
@testable import PassSumo

/// Category 3 — **what we write is a standards-conformant KDBX 4.1 file, and it is safe.**
///
/// Two of these overlap with `KDBXCodecTests` in subject but not in evidence, and the difference is
/// the point of this suite: there, a file is encoded in memory and handed straight back to our own
/// reader; here, a file that has been through the real save path on disk — in one case through a
/// kill and a recovery — is handed to KeePassXC.
///
/// The inner-random-stream test has no counterpart at all. `KDBXCodecTests` asserts that two saves
/// differ byte-for-byte, which two freshly generated master seeds guarantee on their own; it would
/// stay green with the inner keystream reused. This one looks at the protected ciphertext itself.
final class FormatConformanceTests: DurabilityTestCase {
    private let codec = KDBXKitCodec()

    /// Published test password for the redistributed KDBXKit fixtures — they ship in the repo and
    /// contain no real secrets.
    private static let fixturePassword = "123"

    // MARK: - Header

    /// Every file we write declares KDBX 4.1.
    ///
    /// The version is the first thing another implementation reads, and getting it wrong is the one
    /// error that makes a perfectly good file unopenable everywhere. Checked on the bytes rather
    /// than on a parsed `Header` so the assertion does not depend on our own reader agreeing with
    /// our own writer.
    func testWrittenFileDeclaresKDBX4_1InItsHeaderBytes() throws {
        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1")
        _ = try runHelper(database: database, title: "v2")

        let bytes = try Data(contentsOf: database)
        XCTAssertGreaterThan(bytes.count, 12, "the file is too short to carry a version field")

        // Layout: signature1 (UInt32 LE), signature2 (UInt32 LE), version (UInt32 LE, low 16 =
        // minor, high 16 = major).
        let signature1 = bytes.uint32LE(at: 0)
        let signature2 = bytes.uint32LE(at: 4)
        let version = bytes.uint32LE(at: 8)

        XCTAssertEqual(signature1, 0x9AA2_D903, "wrong KDBX signature")
        XCTAssertEqual(signature2, 0xB54B_FB67, "wrong KDBX signature")
        XCTAssertEqual(UInt16(truncatingIfNeeded: version >> 16), 4, "major version must be 4")
        XCTAssertEqual(UInt16(truncatingIfNeeded: version & 0xFFFF), 1, "minor version must be 1")
    }

    // MARK: - The inner random stream

    /// **The highest-stakes assertion in the suite.** Two saves of the same vault must not encrypt
    /// their protected fields with the same keystream.
    ///
    /// KDBX protects passwords twice: the whole payload under the main cipher, and each protected
    /// string under an inner stream cipher (ChaCha20 here) whose key lives in the inner header. The
    /// inner cipher is a keystream XOR. If the key is not regenerated on save, two saves of the same
    /// vault XOR the same plaintext with the same keystream, and anyone holding both files recovers
    /// the passwords by XORing the two ciphertexts together — no password, no key, no cryptanalysis.
    ///
    /// This is not hypothetical: it is the defect every released KDBXKit tag carries, and the reason
    /// `project.yml` pins an unreleased revision. So it needs an assertion that would actually catch
    /// it. Comparing whole files would not — the master seed, the KDF salt and the nonce are all
    /// regenerated regardless, so two files differ even with the keystream reused. The only test
    /// that bites is the one below: pull the base64 of the protected values straight out of the
    /// decrypted XML, BEFORE the inner stream is applied, and require that the same plaintext
    /// produced different ciphertext.
    func testInnerRandomStreamKeyIsRegeneratedOnEverySave() throws {
        let credentials = VaultCredentials(password: Self.fixturePassword, keyFile: nil)
        let original = try fixture("simple-argon2id-aes256", subdirectory: "Fixtures/kdbxkit")
        let decoded = try codec.decode(fileData: original, credentials: credentials)

        // The same vault, encoded twice, with nothing changed in between.
        let first = try codec.encode(decoded.vault, credentials: credentials, origin: decoded)
        let second = try codec.encode(decoded.vault, credentials: credentials, origin: decoded)

        let firstCiphertexts = try Self.protectedCiphertexts(in: first, password: Self.fixturePassword)
        let secondCiphertexts = try Self.protectedCiphertexts(in: second, password: Self.fixturePassword)

        XCTAssertFalse(
            firstCiphertexts.isEmpty,
            "the fixture has no protected fields, so this test would pass vacuously"
        )
        XCTAssertEqual(
            firstCiphertexts.count, secondCiphertexts.count,
            "the two saves do not even carry the same number of protected fields"
        )

        // Identical plaintext, identical field order, two saves. Any ciphertext repeated between
        // them is a reused keystream at that offset.
        let repeated = Set(firstCiphertexts).intersection(secondCiphertexts)
        XCTAssertTrue(
            repeated.isEmpty,
            "\(repeated.count) protected field(s) came out byte-identical across two saves — the "
                + "inner random-stream key was REUSED, so XORing the two files recovers the "
                + "plaintext passwords. This is the defect the KDBXKit pin exists to avoid; check "
                + "project.yml's revision before anything else."
        )

        // …and the difference must be fresh randomness, not damage: both files still decode to the
        // same vault.
        XCTAssertEqual(try codec.decode(fileData: first, credentials: credentials).vault, decoded.vault)
        XCTAssertEqual(try codec.decode(fileData: second, credentials: credentials).vault, decoded.vault)
    }

    /// The negative control for the test above — proof that it can fail.
    ///
    /// An assertion that two sets of ciphertext do not intersect is worthless if the extraction
    /// silently returns nothing useful, or if protected values happen never to repeat for some
    /// unrelated reason. So: write the same content twice with `regenerateSalts: false` — the
    /// KDBXKit flag that exists precisely to reproduce the defective behaviour — and require that
    /// the same comparison DOES find repeated ciphertext. If this test ever stops failing to find
    /// repeats, the detector above has gone blind and its green result means nothing.
    ///
    /// `regenerateSalts: false` appears here and nowhere else in this repository. It must never be
    /// used on a real save; see `KDBXKitCodec.serialize`.
    func testTheInnerStreamCheckWouldActuallyCatchAReusedKey() throws {
        let credentials = VaultCredentials(password: Self.fixturePassword, keyFile: nil)
        let original = try fixture("simple-argon2id-aes256", subdirectory: "Fixtures/kdbxkit")
        let decoded = try codec.decode(fileData: original, credentials: credentials)
        let content = try XCTUnwrap(
            (decoded.opaque as? KDBXOrigin)?.content,
            "the codec did not hand back its KDBX round-trip state"
        )

        func serializeWithoutRegeneratingSalts() throws -> Data {
            let stream = OutputStream(toMemory: ())
            stream.open()
            defer { stream.close() }
            try KDBXWriter(to: stream).write(
                content,
                unlockData: UnlockData(masterPassword: Self.fixturePassword),
                regenerateSalts: false
            )
            return try XCTUnwrap(
                stream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data,
                "the writer produced no bytes"
            )
        }

        let first = try Self.protectedCiphertexts(
            in: try serializeWithoutRegeneratingSalts(), password: Self.fixturePassword
        )
        let second = try Self.protectedCiphertexts(
            in: try serializeWithoutRegeneratingSalts(), password: Self.fixturePassword
        )

        XCTAssertFalse(first.isEmpty, "no protected fields were extracted at all")
        XCTAssertFalse(
            Set(first).intersection(second).isEmpty,
            "with the inner key deliberately reused, the check found no repeated ciphertext — so "
                + "it cannot detect the real defect either"
        )
    }

    // MARK: - External verification

    /// The strong evidence, on a file that has been through a crash: KeePassXC opens it.
    ///
    /// The sequence is deliberately not a clean save. The database is created, a save is killed
    /// mid-write, and only then is it saved again — which is the recovery path a user actually
    /// walks after a force quit. What KeePassXC opens at the end is the file that survived that.
    ///
    /// `keepassxc-cli` is an independent implementation that reads KDBX 4 perfectly well (it cannot
    /// *create* one — see the repo CLAUDE.md — which is why it is a read-direction oracle only).
    func testFileThatSurvivedAKillStillOpensInKeePassXC() throws {
        try skipIfHostIsSandboxed("watching a directory closely enough to catch the atomic write's "
            + "temporary file")
        let cli = try Self.keePassXCCLIOrSkip()

        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1", attachmentBytes: Self.paddingBytes)

        // Crash mid-save…
        let killed = try runHelper(database: database, title: "v2", killWhen: .atomicTemporaryAppears)
        XCTAssertTrue(killed.terminatedBySignal, "the run under test was supposed to be killed")

        // …then reopen and save again, exactly as the user would after relaunching.
        let recovered = try runHelper(database: database, title: "v3")
        XCTAssertTrue(
            recovered.reached(HelperStage.done),
            "the database could not be saved again after the crash: \(recovered.errors)"
        )

        let listing = try Self.run(cli, ["ls", "-R", database.path], stdin: Self.password + "\n")
        XCTAssertEqual(
            listing.status, 0,
            "keepassxc-cli could not open the file that survived a crash:\n\(listing.output)"
        )
        XCTAssertTrue(listing.output.contains("v1"), "the original entry is missing:\n\(listing.output)")
        XCTAssertTrue(listing.output.contains("v3"), "the post-crash entry is missing:\n\(listing.output)")
    }

    /// Backups have to be openable by other tools too. A backup is the thing a user reaches for
    /// when everything else has gone wrong, quite possibly from a different application, and one
    /// that only our own reader can open is a promise we have not actually kept.
    func testBackupsOpenInKeePassXCToo() throws {
        let cli = try Self.keePassXCCLIOrSkip()

        let directory = try makeScratchDirectory()
        let database = try createDatabase(in: directory, title: "v1")
        _ = try runHelper(database: database, title: "v2")

        let backup = try XCTUnwrap(backups(of: database).first, "the save should have left a backup")
        let listing = try Self.run(cli, ["ls", "-R", backup.path], stdin: Self.password + "\n")
        XCTAssertEqual(
            listing.status, 0,
            "keepassxc-cli could not open our backup:\n\(listing.output)"
        )
        XCTAssertTrue(listing.output.contains("v1"), "the backup lost its content:\n\(listing.output)")
    }

    // MARK: - Helpers

    /// The base64 payloads of every `Protected="True"` value in `file`'s decrypted XML, **before**
    /// the inner stream cipher is applied to them.
    ///
    /// `retainsXMLForDiagnostics: true` is what makes this possible: the reader normally clears
    /// `xmlDocument` on a successful parse (it holds the vault's unprotected fields in a Swift
    /// `String` that cannot be zeroed), and that flag keeps it. Nothing here is logged or written
    /// anywhere — the values are compared and dropped.
    private static func protectedCiphertexts(in file: Data, password: String) throws -> [String] {
        var reader = KDBXReader(file)
        _ = try reader.parse(
            unlockData: UnlockData(masterPassword: password),
            retainsXMLForDiagnostics: true
        )
        let xml = try XCTUnwrap(reader.xmlDocument, "the reader did not retain the XML document")

        let pattern = try NSRegularExpression(pattern: "Protected=\"True\"\\s*>([^<]*)<")
        let range = NSRange(xml.startIndex ..< xml.endIndex, in: xml)
        return pattern.matches(in: xml, range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: xml) else { return nil }
            let value = String(xml[captured])
            // An empty protected value carries no keystream bytes and would compare equal across
            // saves for a reason that has nothing to do with key reuse.
            return value.isEmpty ? nil : value
        }
    }

    private func fixture(_ name: String, subdirectory: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "kdbx", subdirectory: subdirectory),
            "fixture \(subdirectory)/\(name).kdbx is not in the test bundle — check the "
                + "PassSumoDurabilityTests `sources` folder reference in project.yml"
        )
        return try Data(contentsOf: url)
    }

    private static func keePassXCCLIOrSkip() throws -> String {
        let candidates = [
            "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli",
            "/opt/homebrew/bin/keepassxc-cli",
            "/usr/local/bin/keepassxc-cli",
        ]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("keepassxc-cli is not installed — skipping the external interop check")
        }
        do {
            _ = try run(cli, ["--version"])
        } catch {
            throw XCTSkip("cannot launch a subprocess from this test host (sandboxed?): \(error)")
        }
        return cli
    }

    private static func run(
        _ launchPath: String,
        _ arguments: [String],
        stdin: String? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        if stdin != nil {
            process.standardInput = Pipe()
        }

        try process.run()
        if let stdin, let input = process.standardInput as? Pipe {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        // Read before waiting: a full pipe buffer would otherwise deadlock the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private extension Data {
    /// Little-endian `UInt32` at a byte offset from the start of the data.
    func uint32LE(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start ..< start + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
