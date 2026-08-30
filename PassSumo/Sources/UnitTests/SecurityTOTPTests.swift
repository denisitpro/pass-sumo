import Foundation
import XCTest

@testable import PassSumo

/// Base32 is hand-rolled (Foundation has none), so it is tested against the RFC 4648 §10 vectors
/// rather than against itself.
final class SecurityBase32Tests: XCTestCase {
    /// RFC 4648 §10, the canonical padded encodings of "f", "fo", "foo", "foob", "fooba", "foobar".
    private let rfc4648: [(encoded: String, decoded: String)] = [
        ("MY======", "f"),
        ("MZXQ====", "fo"),
        ("MZXW6===", "foo"),
        ("MZXW6YQ=", "foob"),
        ("MZXW6YTB", "fooba"),
        ("MZXW6YTBOI======", "foobar")
    ]

    func testDecodesRFC4648PaddedVectors() throws {
        for vector in rfc4648 {
            let bytes = try Base32.decode(vector.encoded)
            XCTAssertEqual(String(bytes: bytes, encoding: .utf8), vector.decoded, "for \(vector.encoded)")
        }
    }

    /// The padding-stripped form is what Google Authenticator, Authy and most issuers actually put
    /// in `otpauth://` URLs, so it has to decode identically.
    func testDecodesUnpaddedVectors() throws {
        for vector in rfc4648 {
            let stripped = vector.encoded.replacingOccurrences(of: "=", with: "")
            let bytes = try Base32.decode(stripped)
            XCTAssertEqual(String(bytes: bytes, encoding: .utf8), vector.decoded, "for \(stripped)")
        }
    }

    func testDecodesLowercase() throws {
        let upper = try Base32.decode("MZXW6YTBOI======")
        let lower = try Base32.decode("mzxw6ytboi")
        XCTAssertEqual(upper, lower)
    }

    /// Secrets are printed in groups for humans to retype; the separators must not become part of
    /// the secret.
    func testIgnoresSpacesAndDashes() throws {
        XCTAssertEqual(try Base32.decode("MZXW 6YTB-OI"), try Base32.decode("MZXW6YTBOI"))
    }

    /// An out-of-alphabet character is rejected rather than skipped. Skipping would produce a
    /// *different secret* that generates wrong codes forever with no visible error — far worse
    /// than refusing the import.
    func testRejectsInvalidCharacters() {
        for input in ["MZXW6YTB1I", "MZXW6YTB0I", "MZXW6YTB!I", "héllo"] {
            XCTAssertThrowsError(try Base32.decode(input), "should reject \(input)") { error in
                guard case .invalidCharacter = error as? Base32.DecodeError else {
                    return XCTFail("expected .invalidCharacter for \(input), got \(error)")
                }
            }
        }
    }

    /// A single trailing character carries 5 bits — not enough to finish a byte — and a group cut
    /// mid-stream leaves non-zero padding bits. Both are corruption.
    func testRejectsTruncatedInput() {
        XCTAssertThrowsError(try Base32.decode("M")) { XCTAssertEqual($0 as? Base32.DecodeError, .truncated) }
        XCTAssertThrowsError(try Base32.decode("MZXW6YTBOB")) { XCTAssertEqual($0 as? Base32.DecodeError, .truncated) }
    }

    func testDecodesEmptyToEmpty() throws {
        XCTAssertEqual(try Base32.decode(""), [])
        XCTAssertEqual(try Base32.decode("===="), [])
    }
}

/// The official RFC 6238 Appendix B test vectors.
///
/// These are the reason this file exists. A TOTP implementation that is subtly wrong still produces
/// six plausible digits that change every thirty seconds, so nothing short of the published vectors
/// distinguishes "correct" from "confidently wrong". The expected values below are transcribed from
/// RFC 6238 Appendix B and **must never be edited to match the implementation** — if one fails, the
/// implementation is what changes.
final class SecurityTOTPVectorTests: XCTestCase {
    /// Appendix B specifies the seed as ASCII "12345678901234567890" for SHA1, and — per the
    /// errata that every implementation follows — the same digit pattern extended to the hash's
    /// block-appropriate length for SHA256 (32 bytes) and SHA512 (64 bytes). Using the 20-byte
    /// seed for all three is the single most common way to "fail" these vectors.
    private static let sha1Seed = Array("12345678901234567890".utf8)
    private static let sha256Seed = Array("12345678901234567890123456789012".utf8)
    private static let sha512Seed = Array("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    /// Appendix B's test times, in seconds since the epoch, with T0 = 0 and X = 30.
    private static let times: [TimeInterval] = [59, 1_111_111_109, 1_111_111_111, 1_234_567_890, 2_000_000_000, 20_000_000_000]

    private func assertVectors(
        algorithm: TOTPConfig.Algorithm,
        seed: [UInt8],
        expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // Appendix B uses 8 digits throughout.
        let generator = TOTPGenerator(config: TOTPConfig(
            secret: seed, algorithm: algorithm, digits: 8, period: 30, issuer: nil, account: nil
        ))
        for (index, time) in Self.times.enumerated() {
            let code = try generator.code(at: Date(timeIntervalSince1970: time))
            XCTAssertEqual(code, expected[index], "\(algorithm.rawValue) at T=\(time)", file: file, line: line)
        }
    }

    func testRFC6238AppendixBSHA1() throws {
        try assertVectors(
            algorithm: .sha1,
            seed: Self.sha1Seed,
            expected: ["94287082", "07081804", "14050471", "89005924", "69279037", "65353130"]
        )
    }

    func testRFC6238AppendixBSHA256() throws {
        try assertVectors(
            algorithm: .sha256,
            seed: Self.sha256Seed,
            expected: ["46119246", "68084774", "67062674", "91819424", "90698825", "77737706"]
        )
    }

    func testRFC6238AppendixBSHA512() throws {
        try assertVectors(
            algorithm: .sha512,
            seed: Self.sha512Seed,
            expected: ["90693936", "25091201", "99943326", "93441116", "38618901", "47863826"]
        )
    }

    /// The counter, isolated. RFC 6238 §4: `T = floor((unixTime - T0) / X)` with T0 = 0.
    func testCounterMatchesAppendixB() {
        let generator = TOTPGenerator(config: TOTPConfig(
            secret: Self.sha1Seed, algorithm: .sha1, digits: 8, period: 30, issuer: nil, account: nil
        ))
        XCTAssertEqual(generator.counter(at: Date(timeIntervalSince1970: 59)), 0x0000000000000001)
        XCTAssertEqual(generator.counter(at: Date(timeIntervalSince1970: 1_111_111_109)), 0x00000000023523EC)
        XCTAssertEqual(generator.counter(at: Date(timeIntervalSince1970: 1_111_111_111)), 0x00000000023523ED)
        XCTAssertEqual(generator.counter(at: Date(timeIntervalSince1970: 1_234_567_890)), 0x000000000273EF07)
        XCTAssertEqual(generator.counter(at: Date(timeIntervalSince1970: 2_000_000_000)), 0x0000000003F940AA)
        XCTAssertEqual(generator.counter(at: Date(timeIntervalSince1970: 20_000_000_000)), 0x0000000027BC86AA)
    }

    /// Roughly one code in ten is numerically shorter than `digits`; dropping the leading zero
    /// gives the server a 5-character string it rejects. T=1111111109/SHA1 is an Appendix B vector
    /// that happens to have one, which is why it is worth asserting separately.
    func testCodesAreZeroPaddedToDigits() throws {
        let generator = TOTPGenerator(config: TOTPConfig(
            secret: Self.sha1Seed, algorithm: .sha1, digits: 8, period: 30, issuer: nil, account: nil
        ))
        let code = try generator.code(at: Date(timeIntervalSince1970: 1_111_111_109))
        XCTAssertEqual(code, "07081804")
        XCTAssertEqual(code.count, 8)
    }

    /// The six-digit truncation of the same vector, i.e. the everyday case.
    func testSixDigitsIsTheLowSixOfTheEightDigitValue() throws {
        let generator = TOTPGenerator(config: TOTPConfig(
            secret: Self.sha1Seed, algorithm: .sha1, digits: 6, period: 30, issuer: nil, account: nil
        ))
        // 94287082 mod 10^6 == 287082
        XCTAssertEqual(try generator.code(at: Date(timeIntervalSince1970: 59)), "287082")
    }
}

/// Parsing the `otpauth://` URI out of the KDBX `otp` string field. Not a KDBX feature — a
/// convention KeePassXC, Strongbox and KeePassium share — so the shapes below are the ones those
/// clients and the common authenticator apps actually emit.
final class SecurityTOTPParsingTests: XCTestCase {
    func testParsesFullURL() throws {
        let generator = try TOTPGenerator(
            parsing: "otpauth://totp/ACME%20Co:john.doe@email.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co&algorithm=SHA256&digits=8&period=60"
        )
        XCTAssertEqual(generator.config.issuer, "ACME Co")
        XCTAssertEqual(generator.config.account, "john.doe@email.com")
        XCTAssertEqual(generator.config.algorithm, .sha256)
        XCTAssertEqual(generator.config.digits, 8)
        XCTAssertEqual(generator.config.period, 60)
        XCTAssertEqual(generator.config.secret, try Base32.decode("JBSWY3DPEHPK3PXP"))
    }

    /// RFC 6238 §4 defaults: SHA1, 6 digits, 30 seconds. Getting any of these wrong produces codes
    /// that disagree with the server for every entry that omits the parameter — which is most.
    func testAppliesRFCDefaultsWhenParametersAreAbsent() throws {
        let generator = try TOTPGenerator(parsing: "otpauth://totp/alice@example.com?secret=JBSWY3DPEHPK3PXP")
        XCTAssertEqual(generator.config.algorithm, .sha1)
        XCTAssertEqual(generator.config.digits, 6)
        XCTAssertEqual(generator.config.period, 30)
        XCTAssertNil(generator.config.issuer)
        XCTAssertEqual(generator.config.account, "alice@example.com")
    }

    func testAcceptsLowercaseAndUnpaddedSecret() throws {
        let padded = try TOTPGenerator(parsing: "otpauth://totp/a?secret=MZXW6YTBOI======")
        let sloppy = try TOTPGenerator(parsing: "otpauth://totp/a?secret=mzxw6ytboi")
        XCTAssertEqual(padded.config.secret, sloppy.config.secret)
    }

    func testAcceptsMixedCaseSchemeAndParameterNames() throws {
        let generator = try TOTPGenerator(parsing: "OTPAUTH://TOTP/a?Secret=JBSWY3DPEHPK3PXP&Digits=8&Algorithm=sha512")
        XCTAssertEqual(generator.config.digits, 8)
        XCTAssertEqual(generator.config.algorithm, .sha512)
    }

    /// The `issuer=` parameter is authoritative over the `Issuer:` label prefix — the label form is
    /// the legacy one and the two disagree in real databases after a rename.
    func testIssuerParameterWinsOverLabelPrefix() throws {
        let generator = try TOTPGenerator(parsing: "otpauth://totp/Old%20Name:bob?secret=JBSWY3DPEHPK3PXP&issuer=New%20Name")
        XCTAssertEqual(generator.config.issuer, "New Name")
        XCTAssertEqual(generator.config.account, "bob")
    }

    func testFallsBackToLabelPrefixWhenNoIssuerParameter() throws {
        let generator = try TOTPGenerator(parsing: "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP")
        XCTAssertEqual(generator.config.issuer, "GitHub")
        XCTAssertEqual(generator.config.account, "octocat")
    }

    /// Older KeePass plugins and hand-made entries store just the secret. Treating that as an
    /// unparseable URL would silently drop the user's 2FA.
    func testAcceptsBareBase32SecretWithNoURL() throws {
        let generator = try TOTPGenerator(parsing: "  JBSW Y3DP EHPK 3PXP  ")
        XCTAssertEqual(generator.config.secret, try Base32.decode("JBSWY3DPEHPK3PXP"))
        XCTAssertEqual(generator.config.algorithm, .sha1)
        XCTAssertEqual(generator.config.digits, 6)
        XCTAssertEqual(generator.config.period, 30)
    }

    /// HOTP is counter-based; "the code right now" is not a question it can answer, so it is
    /// rejected rather than quietly treated as TOTP.
    func testRejectsHOTPURL() {
        XCTAssertThrowsError(try TOTPGenerator(parsing: "otpauth://hotp/a?secret=JBSWY3DPEHPK3PXP&counter=1")) {
            XCTAssertEqual($0 as? TOTPError, .notATOTPURL)
        }
    }

    func testRejectsMissingSecret() {
        XCTAssertThrowsError(try TOTPGenerator(parsing: "otpauth://totp/a?digits=6")) {
            XCTAssertEqual($0 as? TOTPError, .emptySecret)
        }
    }

    /// An unknown algorithm is not downgraded to the SHA1 default: that would generate wrong codes
    /// indefinitely with nothing to indicate why.
    func testRejectsUnsupportedAlgorithm() {
        XCTAssertThrowsError(try TOTPGenerator(parsing: "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP&algorithm=MD5")) {
            XCTAssertEqual($0 as? TOTPError, .unsupportedAlgorithm("MD5"))
        }
    }

    func testRejectsUnsupportedDigits() {
        XCTAssertThrowsError(try TOTPGenerator(parsing: "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP&digits=4")) {
            XCTAssertEqual($0 as? TOTPError, .unsupportedDigits(4))
        }
    }

    func testRejectsNonPositivePeriod() {
        XCTAssertThrowsError(try TOTPGenerator(parsing: "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP&period=0")) {
            XCTAssertEqual($0 as? TOTPError, .invalidPeriod(0))
        }
    }

    func testRejectsInvalidBase32Secret() {
        XCTAssertThrowsError(try TOTPGenerator(parsing: "otpauth://totp/a?secret=NOT!VALID")) {
            guard case .invalidSecret = $0 as? TOTPError else { return XCTFail("expected .invalidSecret, got \($0)") }
        }
    }

    // MARK: - Countdown

    /// `secondsRemaining` drives the UI ring, so its edges matter more than its middle.
    func testSecondsRemainingSpansTheWholePeriodAndNeverReturnsZero() throws {
        let generator = try TOTPGenerator(parsing: "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP")
        // Exactly on a window boundary the *next* code is valid for a full 30 s.
        XCTAssertEqual(generator.secondsRemaining(at: Date(timeIntervalSince1970: 0)), 30)
        XCTAssertEqual(generator.secondsRemaining(at: Date(timeIntervalSince1970: 30)), 30)
        XCTAssertEqual(generator.secondsRemaining(at: Date(timeIntervalSince1970: 1)), 29)
        XCTAssertEqual(generator.secondsRemaining(at: Date(timeIntervalSince1970: 29)), 1)
        for second in 0..<120 {
            let remaining = generator.secondsRemaining(at: Date(timeIntervalSince1970: TimeInterval(second)))
            XCTAssertTrue((1...30).contains(remaining), "remaining \(remaining) at t=\(second)")
        }
    }

    func testCodeIsStableWithinAWindowAndChangesAcrossIt() throws {
        let generator = try TOTPGenerator(parsing: "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP")
        let first = try generator.code(at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(first, try generator.code(at: Date(timeIntervalSince1970: 59)))
        XCTAssertNotEqual(first, try generator.code(at: Date(timeIntervalSince1970: 60)))
    }
}
