import CryptoKit
import Foundation
import KDBXKit
import XCTest
@testable import PassSumo

/// Category 4 — **damaged and hostile files fail in the right way.**
///
/// `KDBXCodecTests.testMalformedHeadersThrowWithoutTrapping` already covers the empty file, the
/// one-byte file, 64 truncation points inside the header, and length fields rewritten to
/// `0xFFFFFFFF` / `0x80000000`. None of that is repeated here. What is added is the part that only
/// becomes visible once the header is *valid*: corruption inside the encrypted body, truncation
/// past the header, and a header that asks for a KDF the machine cannot afford.
///
/// Every test asserts the SPECIFIC failure, not merely that something was thrown. "It threw" would
/// be satisfied by a reader that decrypts attacker-controlled ciphertext first and only then
/// notices, which is the bug this category exists to catch.
final class HostileInputTests: DurabilityTestCase {
    private let codec = KDBXKitCodec()

    /// Published test password for the redistributed KDBXKit fixtures.
    private static let fixturePassword = "123"

    private func credentials() -> VaultCredentials {
        VaultCredentials(password: Self.fixturePassword, keyFile: nil)
    }

    // MARK: - Corruption inside the ciphertext

    /// A flipped bit inside the encrypted body must be caught by the HMAC **before** anything is
    /// decrypted.
    ///
    /// The ordering is the whole point, and it is a security property, not a niceness. KDBX 4
    /// authenticates each block of the encrypted stream with HMAC-SHA256 under a key derived from
    /// the master password. Verifying that first means attacker-modified ciphertext is never fed to
    /// the cipher, the decompressor or the XML parser — three large attack surfaces that would
    /// otherwise be reachable by anyone who can write to the user's synced folder.
    ///
    /// So the assertion is on WHICH error comes back. `.corrupted("…failed its authentication
    /// check…")` is the HMAC rejecting the block. `.corrupted("…decrypted but its contents could
    /// not be parsed…")` would mean decryption ran first, and is failed explicitly below rather
    /// than being quietly accepted as "it threw, good enough".
    func testBitFlipInsideTheEncryptedPayloadFailsTheHMACBeforeAnyDecryption() throws {
        let original = try fixture("simple-argon2id-aes256")
        let headerLength = try XCTUnwrap(
            Self.headerLength(of: original),
            "could not locate the end of the header in the fixture"
        )
        // Everything from here on is HMAC-covered block stream: 32 bytes of header HMAC, then
        // repeating <32-byte block HMAC><Int32 size><block>.
        let payloadStart = headerLength + 32 + 32
        XCTAssertLessThan(payloadStart, original.count, "fixture precondition: there is a body to corrupt")

        // Offsets that land in authenticated bytes — the first block's HMAC, and the ciphertext
        // itself. These must be caught by the HMAC specifically.
        let mustFailTheHMAC = [
            payloadStart,
            payloadStart + 16,
            payloadStart + (original.count - payloadStart) / 2,
        ]
        // The block stream's terminating sentinel is `<32-byte HMAC><Int32 size = 0>`, and the size
        // is read BEFORE the block it describes can be assembled and authenticated. A flip there
        // therefore surfaces as "truncated" rather than as an HMAC failure — a different message
        // for the same refusal, and still nothing decrypted. Kept in the sweep, with the weaker
        // assertion it honestly supports, rather than dropped for being inconvenient.
        let mustAtLeastNotDecrypt = mustFailTheHMAC + [original.count - 1]

        for offset in mustAtLeastNotDecrypt {
            var damaged = original
            damaged[damaged.startIndex + offset] ^= 0x01

            XCTAssertThrowsError(
                try codec.decode(fileData: damaged, credentials: credentials()),
                "a flipped bit at offset \(offset) decoded successfully"
            ) { error in
                guard case let .corrupted(message) = error as? VaultError else {
                    return XCTFail("expected .corrupted at offset \(offset), got \(error)")
                }
                // The signature of decrypt-first: the payload was decrypted, decompressed and
                // handed to the XML parser before anyone checked whether it was authentic.
                XCTAssertFalse(
                    message.contains("decrypted but its contents could not be parsed"),
                    "the flip at offset \(offset) reached the XML parser, so modified ciphertext "
                        + "was decrypted before it was authenticated: \(message)"
                )
                if mustFailTheHMAC.contains(offset) {
                    XCTAssertTrue(
                        message.contains("authentication check"),
                        "the flip at offset \(offset) was not caught by the HMAC — reported as: "
                            + "\(message)"
                    )
                }
            }
        }
    }

    // MARK: - Truncation past the header

    /// A file whose header is intact but whose body was cut short.
    ///
    /// This is the shape of a real accident — an interrupted download, a sync that stopped halfway,
    /// a copy off a disconnected drive — and it is distinct from the header truncations the unit
    /// suite covers: here everything the parser reads before the credentials is valid, so the
    /// failure has to come from the block stream rather than from the header walk.
    ///
    /// Two things are asserted: the header genuinely still parses (otherwise this is just another
    /// header-truncation test wearing a different name), and the file is reported as damaged rather
    /// than as a wrong password. Telling a user their password is wrong for a truncated file sends
    /// them to try passwords instead of to their backup.
    func testTruncatedFileWithAnIntactHeaderIsReportedAsDamagedNotAsAWrongPassword() throws {
        let original = try fixture("simple-argon2id-aes256")
        let headerLength = try XCTUnwrap(Self.headerLength(of: original))

        // Cut points spread through the body, all past the header and its digest.
        let bodyStart = headerLength + 32
        let cuts = [
            bodyStart,                                          // digest kept, nothing else
            bodyStart + 16,                                     // mid header-HMAC
            bodyStart + 32 + 4,                                 // first block HMAC read, size read
            bodyStart + (original.count - bodyStart) / 2,       // mid ciphertext
            original.count - 8,                                 // just short of the end
        ]

        for cut in cuts where cut < original.count {
            let truncated = original.prefix(cut)

            XCTAssertNoThrow(
                try KDBXReader.parseHeader(Data(truncated)),
                "fixture precondition: the header must still parse after cutting at \(cut)"
            )

            XCTAssertThrowsError(
                try codec.decode(fileData: Data(truncated), credentials: credentials()),
                "a file truncated at \(cut) decoded successfully"
            ) { error in
                guard case let .corrupted(message) = error as? VaultError else {
                    return XCTFail(
                        "a file truncated at \(cut) should be reported as damaged, got \(error)"
                    )
                }
                XCTAssertFalse(
                    message.localizedCaseInsensitiveContains("password"),
                    "truncation at \(cut) was blamed on the password: \(message)"
                )
            }
        }
    }

    // MARK: - KDF bombs

    /// A header that demands an absurd amount of memory must be refused **before** the KDF runs.
    ///
    /// The KDF parameters live in the cleartext header, so they are attacker-controlled on any file
    /// the user can be persuaded to open. A header declaring 64 GiB of Argon2 memory, honoured
    /// literally, is a denial of service against the whole machine: not a crash the app can report,
    /// but swapping until something is killed.
    ///
    /// The test is built so it can never allocate that memory itself. The refusal happens in
    /// `KDFParameterLimits.breach(for:)`, which runs before a single byte is allocated — so what is
    /// asserted is both the error and the fact that it came back in well under a second.
    ///
    /// Constructing the file requires re-stamping the header's SHA-256, because that digest is
    /// verified BEFORE the KDF limits are (header parse → digest → KDF → HMAC). Without it the file
    /// would be rejected as corrupt for a reason unrelated to what is under test.
    func testAbsurdKDFMemoryIsRefusedWithoutEverAllocatingIt() throws {
        let original = try fixture("simple-argon2id-aes256")

        // Control: the unmodified fixture opens, so a failure below is about the patch and not
        // about the fixture or the password.
        XCTAssertNoThrow(try codec.decode(fileData: original, credentials: credentials()))

        // 64 GiB, sixty-four times `KDFParameterLimits.default.maxArgon2Memory`.
        let bomb = try XCTUnwrap(
            Self.patchingArgon2Memory(in: original, to: 64 * 1024 * 1024 * 1024),
            "could not find the Argon2 `M` parameter in the fixture header"
        )

        let started = Date()
        XCTAssertThrowsError(
            try codec.decode(fileData: bomb, credentials: credentials())
        ) { error in
            guard case let .unsupportedFeature(message) = error as? VaultError else {
                return XCTFail("expected .unsupportedFeature, got \(error)")
            }
            // The user gets told what is wrong and what to do, not that their file is broken.
            XCTAssertTrue(
                message.contains("key-derivation work"),
                "the refusal did not come from the KDF cost limit: \(message)"
            )
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 1.0,
            "the refusal took long enough that the KDF may have started running"
        )
    }

    /// The same defence on the other KDF: AES-KDF's round count is a pure-CPU bomb rather than a
    /// memory one, and it has its own (higher) ceiling. Covered because the two limits are separate
    /// fields and a regression could remove one without touching the other.
    func testAbsurdAESKDFRoundCountIsRefused() throws {
        let original = try fixture("kdbx3-aeskdf-aes256", subdirectory: "Fixtures")
        // KDBX 3.1 keeps its transform rounds in a fixed header field rather than in a variant
        // dictionary, and the 3.x reader is a separate code path — so rather than hand-patching a
        // format this suite does not otherwise touch, assert the limit itself, which is what the
        // reader consults. It is the same object the 4.x path uses.
        let limits = KDFParameterLimits.default
        XCTAssertNotNil(
            limits.breach(for: .aes(.init(salt: Data(count: 32), rounds: 1 << 60), additional: [:])),
            "an absurd AES-KDF round count is not refused by the default limits"
        )
        XCTAssertNil(
            limits.breach(for: .aes(.init(salt: Data(count: 32), rounds: 60_000), additional: [:])),
            "a realistic AES-KDF round count must not be refused"
        )
        XCTAssertNoThrow(
            try codec.decode(
                fileData: original,
                credentials: VaultCredentials(password: "correct horse battery staple", keyFile: nil)
            ),
            "control: the unmodified AES-KDF fixture must still open"
        )
    }

    // MARK: - Helpers

    private func fixture(_ name: String, subdirectory: String = "Fixtures/kdbxkit") throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "kdbx", subdirectory: subdirectory),
            "fixture \(subdirectory)/\(name).kdbx is not in the test bundle"
        )
        return try Data(contentsOf: url)
    }

    /// Where the cleartext header ends, found by looking for the offset whose SHA-256 prefix
    /// matches the 32 bytes stored immediately after it.
    ///
    /// Derived rather than parsed on purpose: walking the header fields here would mean
    /// reimplementing the parser under test, and a test that agrees with the code it is checking
    /// because it shares its bugs is not evidence.
    private static func headerLength(of data: Data) -> Int? {
        let limit = min(4096, data.count - 32)
        guard limit > 12 else { return nil }
        for length in 12 ... limit {
            let digest = Data(SHA256.hash(data: data.prefix(length)))
            let stored = data.subdata(in: data.startIndex + length ..< data.startIndex + length + 32)
            if digest == stored { return length }
        }
        return nil
    }

    /// Rewrites the Argon2 `M` (memory, in bytes) parameter in the cleartext header and re-stamps
    /// the header's SHA-256 so the file stays structurally valid up to the KDF.
    ///
    /// The record is a KDBX VariantDictionary entry: `<0x05 = UInt64><Int32 nameLen = 1>"M"`
    /// `<Int32 valueLen = 8><memory, UInt64 LE>`.
    private static func patchingArgon2Memory(in data: Data, to memory: UInt64) -> Data? {
        let prefix: [UInt8] = [
            0x05,                       // value type: UInt64
            0x01, 0x00, 0x00, 0x00,     // name length (Int32 LE) = 1
            0x4D,                       // "M"
            0x08, 0x00, 0x00, 0x00,     // value length (Int32 LE) = 8
        ]
        guard let headerLength = headerLength(of: data) else { return nil }
        let header = Array(data.prefix(headerLength))
        guard header.count > prefix.count + 8 else { return nil }

        for start in 0 ... (header.count - prefix.count - 8)
            where Array(header[start ..< start + prefix.count]) == prefix
        {
            var patched = data
            let valueStart = data.startIndex + start + prefix.count
            for byte in 0 ..< 8 {
                patched[valueStart + byte] = UInt8(truncatingIfNeeded: memory >> (8 * UInt64(byte)))
            }
            // Re-stamp the digest the parser checks before it ever looks at the KDF.
            let digest = Data(SHA256.hash(data: patched.prefix(headerLength)))
            patched.replaceSubrange(
                (patched.startIndex + headerLength) ..< (patched.startIndex + headerLength + 32),
                with: digest
            )
            return patched
        }
        return nil
    }
}
