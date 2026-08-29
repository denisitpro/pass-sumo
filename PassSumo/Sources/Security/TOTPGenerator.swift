import CryptoKit
import Foundation

/// RFC 4648 base32, decode only.
///
/// Hand-rolled because Foundation has no base32 at all — `Data(base64Encoded:)` has no base32
/// sibling on any Apple platform — and because pulling a dependency in for 40 lines would mean a
/// THIRD-PARTY-NOTICES entry and a licence review for something this small.
enum Base32 {
    enum DecodeError: Error, Equatable {
        /// A character outside the RFC 4648 alphabet (after case folding) and outside padding.
        case invalidCharacter(Character)
        /// The bit count left over is not a valid base32 remainder — e.g. a single trailing
        /// character, which encodes 5 bits and cannot complete a byte.
        case truncated
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// Decodes `input` into bytes.
    ///
    /// Lenient in exactly the ways real `otpauth://` URLs are sloppy, and no further:
    /// - `=` padding is optional. Google Authenticator, Authy and most issuers strip it; the RFC
    ///   requires it. Both must decode.
    /// - Lowercase is accepted and folded up. The RFC alphabet is uppercase, but lowercase secrets
    ///   are common in hand-written URLs.
    /// - Spaces and dashes are ignored, because that is how secrets are printed for humans to type
    ///   ("JBSW Y3DP EHPK 3PXP").
    ///
    /// Not lenient about anything else: an out-of-alphabet character is an error rather than being
    /// skipped, because silently dropping a character yields a *different secret* that produces
    /// wrong codes forever with no visible failure. Better to reject the URL at import time.
    static func decode(_ input: String) throws -> [UInt8] {
        var output: [UInt8] = []
        var accumulator: UInt32 = 0
        var bitsInAccumulator = 0

        for character in input {
            if character == "=" || character == " " || character == "-" { continue }
            let upper = Character(String(character).uppercased())
            guard let value = alphabet.firstIndex(of: upper) else {
                throw DecodeError.invalidCharacter(character)
            }
            accumulator = (accumulator << 5) | UInt32(value)
            bitsInAccumulator += 5
            if bitsInAccumulator >= 8 {
                bitsInAccumulator -= 8
                output.append(UInt8((accumulator >> UInt32(bitsInAccumulator)) & 0xFF))
            }
        }

        // Leftover bits are legal only if they are the zero-padding the encoder had to add. More
        // than 4 leftover bits means a whole character's worth of data went missing, and non-zero
        // leftover bits mean the input was cut mid-group. Both are corruption, not sloppiness.
        guard bitsInAccumulator < 5 else { throw DecodeError.truncated }
        let leftoverMask = UInt32((1 << bitsInAccumulator) - 1)
        guard accumulator & leftoverMask == 0 else { throw DecodeError.truncated }
        return output
    }
}

/// A parsed TOTP configuration — everything needed to produce codes for one entry.
///
/// This mirrors the `otpauth://` URI the KDBX `otp` string field carries. That field is not part of
/// the KDBX specification; it is a de-facto convention that KeePassXC, Strongbox and KeePassium all
/// read and write, which is why interop demands we be permissive about the shapes it turns up in.
struct TOTPConfig: Sendable, Equatable {
    enum Algorithm: String, Sendable, Equatable, CaseIterable {
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case sha512 = "SHA512"
    }

    /// Decoded shared secret. Held as bytes, not as the base32 text, so the decode failure happens
    /// once at parse time rather than every 30 seconds.
    var secret: [UInt8]
    var algorithm: Algorithm
    var digits: Int
    var period: Int
    /// Purely for display; neither takes part in code generation.
    var issuer: String?
    var account: String?
}

enum TOTPError: Error, Equatable {
    case emptySecret
    case invalidSecret(Base32.DecodeError)
    /// `algorithm=` named something we do not implement. Not silently downgraded to SHA1 — that
    /// would produce plausible-looking codes that never match.
    case unsupportedAlgorithm(String)
    /// RFC 4226 §5.3 defines the truncation for 6..8 digits; outside that the construction is
    /// undefined. Real-world values are 6 and 8, with 7 appearing rarely.
    case unsupportedDigits(Int)
    case invalidPeriod(Int)
    /// The URL had an `otpauth` scheme but was not a `totp` one (almost always `hotp`, which is
    /// counter-based and has no notion of "the code right now").
    case notATOTPURL
}

/// Produces RFC 6238 TOTP codes.
///
/// TOTP is HOTP (RFC 4226) with the counter defined as `floor(unixTime / period)` — that is the
/// entirety of RFC 6238. So the implementation below is HOTP, and the only time-dependent line is
/// the counter computation.
struct TOTPGenerator: Sendable {
    let config: TOTPConfig

    init(config: TOTPConfig) {
        self.config = config
    }

    // MARK: - Parsing

    /// Parses whatever the KDBX `otp` field contained.
    ///
    /// Accepts, in order:
    /// 1. A full `otpauth://totp/…` URI, the normal case.
    /// 2. A bare base32 secret with no URI wrapper, which older KeePass plugins and some manual
    ///    entries use. All other parameters take their RFC defaults.
    ///
    /// The defaults — `SHA1`, `digits=6`, `period=30` — are RFC 6238's own (§4, "Default Value"),
    /// and are what every authenticator assumes when the parameter is absent. Deviating would make
    /// our codes disagree with the site's.
    init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "otpauth" else {
            // Fallback path: treat the whole string as the secret.
            try self.init(config: Self.makeConfig(
                secretText: trimmed, algorithm: nil, digits: nil, period: nil, issuer: nil, account: nil
            ))
            return
        }
        guard components.host?.lowercased() == "totp" else { throw TOTPError.notATOTPURL }

        let items = components.queryItems ?? []
        /// Query parameter names are matched case-insensitively: the spec writes them lowercase but
        /// `?Secret=` and `?Digits=` both appear in the wild.
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }

        // Label is `/issuer:account` or just `/account`; `URLComponents.path` is already
        // percent-decoded, which matters because accounts are email addresses and issuers are
        // often "Example Inc." with a real space in them.
        let label = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        var labelIssuer: String?
        var account: String? = label.isEmpty ? nil : label
        if let separator = label.firstIndex(of: ":") {
            labelIssuer = String(label[label.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            account = String(label[label.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        }

        // The `issuer=` parameter wins over the label prefix: RFC-adjacent guidance (Google's
        // Key-Uri-Format, which every implementation follows) calls the label prefix the legacy
        // form and the parameter authoritative.
        let issuer = value("issuer").flatMap { $0.isEmpty ? nil : $0 } ?? labelIssuer

        try self.init(config: Self.makeConfig(
            secretText: value("secret") ?? "",
            algorithm: value("algorithm"),
            digits: value("digits"),
            period: value("period"),
            issuer: issuer,
            account: account.flatMap { $0.isEmpty ? nil : $0 }
        ))
    }

    private static func makeConfig(
        secretText: String,
        algorithm: String?,
        digits: String?,
        period: String?,
        issuer: String?,
        account: String?
    ) throws -> TOTPConfig {
        guard !secretText.isEmpty else { throw TOTPError.emptySecret }
        let secret: [UInt8]
        do {
            secret = try Base32.decode(secretText)
        } catch let error as Base32.DecodeError {
            throw TOTPError.invalidSecret(error)
        }
        guard !secret.isEmpty else { throw TOTPError.emptySecret }

        let resolvedAlgorithm: TOTPConfig.Algorithm
        if let algorithm, !algorithm.isEmpty {
            // Case-folded because `?algorithm=sha1` and `?algorithm=SHA1` are both common.
            guard let match = TOTPConfig.Algorithm(rawValue: algorithm.uppercased()) else {
                throw TOTPError.unsupportedAlgorithm(algorithm)
            }
            resolvedAlgorithm = match
        } else {
            resolvedAlgorithm = .sha1
        }

        let resolvedDigits = digits.flatMap(Int.init) ?? 6
        guard (6...8).contains(resolvedDigits) else { throw TOTPError.unsupportedDigits(resolvedDigits) }

        let resolvedPeriod = period.flatMap(Int.init) ?? 30
        guard resolvedPeriod > 0 else { throw TOTPError.invalidPeriod(resolvedPeriod) }

        return TOTPConfig(
            secret: secret,
            algorithm: resolvedAlgorithm,
            digits: resolvedDigits,
            period: resolvedPeriod,
            issuer: issuer,
            account: account
        )
    }

    // MARK: - Code generation

    /// The RFC 6238 time counter: `floor(unixTime / period)`, with T0 = 0.
    ///
    /// `floor` and not truncation: `Int(exactly:)`-style truncation rounds *towards zero*, which is
    /// wrong for pre-1970 dates. Those never occur in practice, but a counter that jumps backwards
    /// around the epoch is the kind of thing that only shows up in a test written five years later.
    func counter(at date: Date) -> UInt64 {
        let seconds = floor(date.timeIntervalSince1970 / Double(config.period))
        return UInt64(bitPattern: Int64(seconds))
    }

    /// The current code, zero-padded to `config.digits`.
    ///
    /// Zero-padding is mandatory, not cosmetic: the truncated value is taken modulo `10^digits`, so
    /// roughly one code in ten legitimately starts with a zero, and dropping it produces a
    /// 5-character string the server rejects.
    func code(at date: Date) throws -> String {
        let counterValue = counter(at: date)
        // RFC 4226 §5.1: the counter is an 8-byte big-endian value.
        var message = [UInt8](repeating: 0, count: 8)
        for index in 0..<8 {
            message[7 - index] = UInt8((counterValue >> (8 * UInt64(index))) & 0xFF)
        }

        let key = SymmetricKey(data: Data(config.secret))
        let mac: [UInt8]
        switch config.algorithm {
        case .sha1:
            // `Insecure.SHA1` is the right API here and is *not* a code smell.
            //
            // RFC 4226 §5.1 defines HOTP as `HMAC-SHA-1(K, C)`, and RFC 6238 §1.2 keeps SHA1 as
            // the default for TOTP. CryptoKit files SHA1 under `Insecure` because SHA1's collision
            // resistance is broken (SHAttered, 2017) — and collision resistance is what a
            // *signature* or *certificate* needs. HMAC does not rely on it: HMAC's security proof
            // rests on the compression function being a PRF, a property SHA1 still has, and there
            // is no known attack on HMAC-SHA1. Substituting SHA256 here would simply produce codes
            // that do not match the server's.
            mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: Data(message), using: key))
        case .sha256:
            mac = Array(HMAC<SHA256>.authenticationCode(for: Data(message), using: key))
        case .sha512:
            mac = Array(HMAC<SHA512>.authenticationCode(for: Data(message), using: key))
        }

        // RFC 4226 §5.3 dynamic truncation: the low nibble of the last byte picks a 4-byte window,
        // and the top bit of that window is masked off so the result is a positive 31-bit integer
        // regardless of the host's signed-integer representation.
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let truncated = (UInt32(mac[offset] & 0x7F) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])

        let modulus = UInt32(pow(10.0, Double(config.digits)))
        return String(format: "%0\(config.digits)u", truncated % modulus)
    }

    /// Seconds until the current code expires, in `1...period`.
    ///
    /// Never returns 0: at the exact instant a window closes the *next* code is already valid for a
    /// full period, so a countdown showing "0" would be showing a code that no longer exists.
    func secondsRemaining(at date: Date) -> Int {
        let period = Double(config.period)
        let elapsed = date.timeIntervalSince1970 - floor(date.timeIntervalSince1970 / period) * period
        let remaining = Int(ceil(period - elapsed))
        return remaining <= 0 ? config.period : remaining
    }
}
