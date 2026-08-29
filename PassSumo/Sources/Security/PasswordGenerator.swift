import Foundation
import Security

/// The one source of randomness in pass-sumo.
///
/// **Why `SecRandomCopyBytes` and not `SystemRandomNumberGenerator`.** The Swift standard library
/// documents `SystemRandomNumberGenerator` as using "a cryptographically secure algorithm whenever
/// possible", and on Darwin it is implemented on top of `arc4random_buf(3)`, whose man page on this
/// machine (macOS 26.6) states it "use[s] a cryptographic pseudo-random number generator" backed by
/// AES since OS X 10.12. That would be good enough — except the standard library's guarantee is
/// hedged ("whenever possible") and its implementation is not part of the stable, checkable
/// surface: it is compiled into the shipped stdlib binary, with no `.swiftinterface` in the
/// toolchain to read. I could not verify the claim from a first-party artefact on this machine,
/// only recall it, so per the "never rely on an unverified value" rule we do not rely on it.
///
/// `SecRandomCopyBytes` is verifiable right here: `SecRandom.h` in the macOS 26.5 SDK says of
/// `kSecRandomDefault` — "This refers to a cryptographically secure random number generator." That
/// is a documented, unhedged, first-party guarantee from a header we can read, so it is what the
/// password generator uses. The cost is one extra failure path (the call can fail), which we
/// surface as a thrown error rather than silently degrading.
enum CSPRNG {
    enum Failure: Error, Equatable {
        /// `SecRandomCopyBytes` returned non-zero. Documented as "critical to check"; there is no
        /// safe fallback, so this propagates rather than quietly reaching for a weaker source.
        case randomSourceUnavailable(OSStatus)
    }

    static func bytes(count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        let status = buffer.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.randomSourceUnavailable(OSStatus(status)) }
        return buffer
    }

    /// A uniform integer in `0..<upperBound`, **free of modulo bias by rejection sampling**.
    ///
    /// The naive `random % n` is biased whenever `n` does not divide the generator's range: the
    /// first `range % n` values occur one extra time each, so low indices come up slightly more
    /// often. For an alphabet of 94 symbols against a 2^32 range the skew is tiny, but "tiny and
    /// systematic" is exactly the shape of bias that erodes real entropy, and there is no reason
    /// to accept it when the fix costs one loop.
    ///
    /// So: draw a 32-bit value, and *reject and redraw* anything landing in the short final
    /// partial block `[limit, 2^32)`. Every accepted value maps to exactly one residue, so the
    /// result is exactly uniform. Expected redraws for any `n <= 94` are well under one in a
    /// million; the loop is unbounded on purpose because a bounded one would have to fall back to
    /// a biased answer, which is the bug.
    static func uniform(upperBound: Int) throws -> Int {
        precondition(upperBound > 0, "upperBound must be positive")
        let n = UInt64(upperBound)
        let range = UInt64(1) << 32                 // number of distinct values a UInt32 can take
        let limit = range - (range % n)             // largest multiple of n that fits in the range
        while true {
            let raw = try bytes(count: 4)
            let value = UInt64(raw[0]) << 24 | UInt64(raw[1]) << 16 | UInt64(raw[2]) << 8 | UInt64(raw[3])
            if value < limit { return Int(value % n) }
        }
    }

    /// Fisher–Yates driven by `uniform(upperBound:)`, i.e. by the same CSPRNG and the same
    /// rejection sampling. `Array.shuffle()` would use `SystemRandomNumberGenerator`, which is the
    /// source this file deliberately declined to depend on.
    static func shuffled<T>(_ elements: [T]) throws -> [T] {
        var result = elements
        guard result.count > 1 else { return result }
        for i in stride(from: result.count - 1, to: 0, by: -1) {
            let j = try uniform(upperBound: i + 1)
            result.swapAt(i, j)
        }
        return result
    }
}

/// Generates passwords, and rates them.
///
/// Stateless on purpose — a `Recipe` in, a password out — so it is trivially `Sendable` and can be
/// called from wherever the UI happens to be.
struct PasswordGenerator: Sendable {
    /// What the user asked for. Defaults are the ones the "generate" button starts from: 20
    /// characters of everything, ambiguous glyphs excluded, because the overwhelmingly common case
    /// for this app is a password the user will never read out loud but might have to re-type once
    /// from a phone screen.
    struct Recipe: Sendable, Equatable {
        var length: Int = 20
        var lowercase: Bool = true
        var uppercase: Bool = true
        var digits: Bool = true
        var symbols: Bool = true
        /// Drops `0 O 1 l I` — the five glyphs that are genuinely indistinguishable in most UI
        /// fonts. Deliberately not a longer "looks confusing" list: every extra exclusion is real
        /// entropy given away, and the rest (`5`/`S`, `2`/`Z`) are separable in the fonts macOS
        /// actually renders passwords in.
        var excludeAmbiguous: Bool = true
        /// Replaces the built-in symbol set when non-empty. Sites with idiosyncratic "special
        /// characters allowed" rules are the reason this exists; without it the user's only
        /// recourse is to turn symbols off entirely and lose ~6 bits per character.
        var customSymbols: String?
    }

    enum GeneratorError: Error, Equatable {
        /// Every toggle is off (or a custom symbol set was supplied that is empty after
        /// de-duplication and ambiguity filtering) — there is no alphabet to draw from.
        case noCharacterClassEnabled
        /// `length` is smaller than the number of enabled classes, so the "at least one of each"
        /// guarantee is arithmetically impossible. Reported with the minimum so the UI can say
        /// what to do instead of just refusing.
        case lengthTooShort(minimum: Int)
        /// The CSPRNG failed. Surfaced rather than swallowed — see `CSPRNG`.
        case randomSourceUnavailable(OSStatus)
    }

    /// The four alphabets, before ambiguity filtering.
    ///
    /// The symbol set is the printable ASCII punctuation minus space, backslash, backtick, quote
    /// and double-quote. Those five are excluded not for looks but because they are the characters
    /// most likely to be mangled in transit — shell copy-paste, CSV round-trips, and the "escape
    /// the string" bugs in other people's password fields.
    private static let lowercaseAlphabet = "abcdefghijklmnopqrstuvwxyz"
    private static let uppercaseAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let digitAlphabet = "0123456789"
    private static let symbolAlphabet = "!#$%&()*+,-./:;<=>?@[]^_{|}~"

    /// Exactly the five listed in `Recipe.excludeAmbiguous`, no more.
    private static let ambiguousCharacters: Set<Character> = ["0", "O", "1", "l", "I"]

    init() {}

    // MARK: - Alphabets

    /// The enabled classes, each already ambiguity-filtered and de-duplicated, in a fixed order.
    /// Returned as separate arrays rather than one flat pool because the "at least one of each"
    /// guarantee needs to draw from each class individually.
    private func alphabets(for recipe: Recipe) -> [[Character]] {
        var result: [[Character]] = []
        if recipe.lowercase { result.append(filtered(Self.lowercaseAlphabet, recipe)) }
        if recipe.uppercase { result.append(filtered(Self.uppercaseAlphabet, recipe)) }
        if recipe.digits { result.append(filtered(Self.digitAlphabet, recipe)) }
        if recipe.symbols {
            let source = recipe.customSymbols.flatMap { $0.isEmpty ? nil : $0 } ?? Self.symbolAlphabet
            result.append(filtered(source, recipe))
        }
        // A class can filter down to nothing — a custom symbol set of "0O1lI" with
        // `excludeAmbiguous` on, say. Dropping it here rather than earlier keeps the
        // "unsatisfiable recipe" check in one place.
        return result.filter { !$0.isEmpty }
    }

    /// De-duplicates as well as filtering: a repeated character in a custom symbol set would
    /// otherwise be drawn twice as often, which is a bias the user did not ask for.
    private func filtered(_ source: String, _ recipe: Recipe) -> [Character] {
        var seen: Set<Character> = []
        return source.filter { character in
            if recipe.excludeAmbiguous && Self.ambiguousCharacters.contains(character) { return false }
            return seen.insert(character).inserted
        }
    }

    // MARK: - Generation

    /// Builds one password satisfying `recipe`, or throws if the recipe cannot be satisfied.
    ///
    /// The shape is: one character drawn from each enabled class (that is the guarantee), the
    /// remaining `length - classCount` drawn from the union of all classes, then the whole thing
    /// **shuffled with the CSPRNG-backed Fisher–Yates above**. The shuffle is not cosmetic: without
    /// it the guaranteed characters would sit at fixed positions in class order, so position 0
    /// would always be lowercase and an attacker would get the first few characters' classes for
    /// free.
    ///
    /// Note on what the guarantee costs, stated plainly because `strengthBits(for:)` reports the
    /// unconditional figure: constraining the output to strings containing at least one of each
    /// class removes some strings from the sample space, so the true entropy is a *fraction of a
    /// bit* below `length * log2(poolSize)`. For a 20-character password over a 90-odd character
    /// pool the gap is far under one bit — the constraint excludes a vanishing share of the space.
    /// It is not worth modelling exactly, but it is worth not pretending it is zero.
    func generate(_ recipe: Recipe) throws -> String {
        let classes = alphabets(for: recipe)
        guard !classes.isEmpty else { throw GeneratorError.noCharacterClassEnabled }
        guard recipe.length >= classes.count else {
            throw GeneratorError.lengthTooShort(minimum: classes.count)
        }

        let pool = classes.flatMap { $0 }
        do {
            var characters: [Character] = []
            characters.reserveCapacity(recipe.length)
            for alphabet in classes {
                characters.append(alphabet[try CSPRNG.uniform(upperBound: alphabet.count)])
            }
            for _ in classes.count..<recipe.length {
                characters.append(pool[try CSPRNG.uniform(upperBound: pool.count)])
            }
            return String(try CSPRNG.shuffled(characters))
        } catch let failure as CSPRNG.Failure {
            guard case .randomSourceUnavailable(let status) = failure else { throw failure }
            throw GeneratorError.randomSourceUnavailable(status)
        }
    }

    // MARK: - Strength

    /// Entropy of a password *this generator would produce* for `recipe`, in bits.
    ///
    /// This one is exact-by-construction (modulo the fraction-of-a-bit noted on `generate`),
    /// because we know the alphabet and we know every character was drawn uniformly and
    /// independently from it: `length * log2(poolSize)`. That is the honest figure for a generated
    /// password and it is the number the generator UI should show. `0` for an unsatisfiable recipe.
    func strengthBits(for recipe: Recipe) -> Double {
        let pool = alphabets(for: recipe).flatMap { $0 }
        guard !pool.isEmpty, recipe.length > 0 else { return 0 }
        return Double(recipe.length) * log2(Double(pool.count))
    }

    /// A rating for a password the **user typed**, in bits.
    ///
    /// Read this as "how big is the alphabet you appear to have drawn from, times how long it is"
    /// — it counts which character classes occur and multiplies. That is all it is.
    ///
    /// **It is not a strength estimate in the zxcvbn sense and must not be presented as one.** It
    /// has no dictionary, no leaked-password list, no keyboard-walk detection, no leet-speak
    /// normalisation, no repeat or sequence detection. `Password1!` scores ~65 bits here and would
    /// score roughly 10 in zxcvbn, because zxcvbn knows it is a dictionary word plus the two most
    /// predictable suffixes on earth. So this number is a strict **upper bound** on strength: it
    /// can only overstate, never understate.
    ///
    /// Why ship it anyway: it correctly catches the failure modes that actually dominate a KDBX
    /// import — passwords that are simply too short, or drawn from one class. Anything better means
    /// bundling a dictionary, which is a real feature with a real size cost, not a tweak. The UI
    /// must therefore label this as a rough guide, not as a verdict.
    func strength(of password: String) -> Double {
        guard !password.isEmpty else { return 0 }
        var pool = 0
        if password.contains(where: { $0.isLowercase && $0.isASCII }) { pool += 26 }
        if password.contains(where: { $0.isUppercase && $0.isASCII }) { pool += 26 }
        if password.contains(where: { $0.isNumber && $0.isASCII }) { pool += 10 }
        // Everything that is not an ASCII letter or digit is lumped together and credited with the
        // size of our own symbol alphabet. Crediting the true Unicode range would be absurd — a
        // user who typed one emoji did not thereby gain 20 bits per character.
        if password.contains(where: { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }) {
            pool += Self.symbolAlphabet.count
        }
        guard pool > 0 else { return 0 }
        return Double(password.count) * log2(Double(pool))
    }
}
