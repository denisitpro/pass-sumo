import Foundation
import XCTest

@testable import PassSumo

final class SecurityPasswordGeneratorTests: XCTestCase {
    private let generator = PasswordGenerator()

    private func recipe(
        length: Int = 20,
        lowercase: Bool = true,
        uppercase: Bool = true,
        digits: Bool = true,
        symbols: Bool = true,
        excludeAmbiguous: Bool = true,
        customSymbols: String? = nil
    ) -> PasswordGenerator.Recipe {
        PasswordGenerator.Recipe(
            length: length,
            lowercase: lowercase,
            uppercase: uppercase,
            digits: digits,
            symbols: symbols,
            excludeAmbiguous: excludeAmbiguous,
            customSymbols: customSymbols
        )
    }

    // MARK: - Unsatisfiable recipes

    func testThrowsWhenNoClassIsEnabled() {
        let empty = recipe(lowercase: false, uppercase: false, digits: false, symbols: false)
        XCTAssertThrowsError(try generator.generate(empty)) {
            XCTAssertEqual($0 as? PasswordGenerator.GeneratorError, .noCharacterClassEnabled)
        }
    }

    /// Four classes cannot all appear in a three-character password. The minimum is reported so the
    /// UI can say what to change rather than just refusing.
    func testThrowsWhenLengthIsBelowTheNumberOfEnabledClasses() {
        XCTAssertThrowsError(try generator.generate(recipe(length: 3))) {
            XCTAssertEqual($0 as? PasswordGenerator.GeneratorError, .lengthTooShort(minimum: 4))
        }
        XCTAssertThrowsError(try generator.generate(recipe(length: 1, digits: false, symbols: false))) {
            XCTAssertEqual($0 as? PasswordGenerator.GeneratorError, .lengthTooShort(minimum: 2))
        }
    }

    /// A custom symbol set that filters down to nothing must not count as an enabled class — and
    /// when it is the only class, the recipe is unsatisfiable rather than silently falling back to
    /// the built-in symbols.
    func testCustomSymbolSetThatFiltersToNothingIsNotAClass() {
        let onlyAmbiguousSymbols = recipe(
            length: 8, lowercase: false, uppercase: false, digits: false, customSymbols: "0O1lI"
        )
        XCTAssertThrowsError(try generator.generate(onlyAmbiguousSymbols)) {
            XCTAssertEqual($0 as? PasswordGenerator.GeneratorError, .noCharacterClassEnabled)
        }
    }

    func testLengthExactlyEqualToClassCountIsSatisfiable() throws {
        let password = try generator.generate(recipe(length: 4))
        XCTAssertEqual(password.count, 4)
    }

    // MARK: - Output shape

    func testProducesRequestedLength() throws {
        for length in [4, 8, 20, 64, 128] {
            XCTAssertEqual(try generator.generate(recipe(length: length)).count, length)
        }
    }

    /// The "at least one of every enabled class" guarantee. Run many times because a guarantee that
    /// holds only *usually* is not a guarantee, and at length 4 with four classes there is exactly
    /// one arrangement per draw — the tightest case.
    func testGuaranteesAtLeastOneCharacterFromEveryEnabledClass() throws {
        for _ in 0..<300 {
            let password = try generator.generate(recipe(length: 4))
            XCTAssertTrue(password.contains { $0.isLowercase }, "no lowercase in \(password)")
            XCTAssertTrue(password.contains { $0.isUppercase }, "no uppercase in \(password)")
            XCTAssertTrue(password.contains { $0.isNumber }, "no digit in \(password)")
            XCTAssertTrue(password.contains { !$0.isLetter && !$0.isNumber }, "no symbol in \(password)")
        }
    }

    func testDisabledClassesNeverAppear() throws {
        let lettersOnly = recipe(length: 40, digits: false, symbols: false)
        for _ in 0..<50 {
            let password = try generator.generate(lettersOnly)
            XCTAssertFalse(password.contains { $0.isNumber }, "digit leaked into \(password)")
            XCTAssertFalse(password.contains { !$0.isLetter }, "symbol leaked into \(password)")
        }
    }

    func testExcludeAmbiguousRemovesExactlyTheFiveConfusableGlyphs() throws {
        let ambiguous: Set<Character> = ["0", "O", "1", "l", "I"]
        for _ in 0..<200 {
            let password = try generator.generate(recipe(length: 60))
            XCTAssertTrue(password.allSatisfy { !ambiguous.contains($0) }, "ambiguous glyph in \(password)")
        }
    }

    /// With the filter off, the excluded glyphs must be reachable again — otherwise the toggle is
    /// doing nothing and the user is quietly losing entropy.
    func testAmbiguousGlyphsAreReachableWhenTheFilterIsOff() throws {
        let permissive = recipe(length: 80, excludeAmbiguous: false)
        var seen: Set<Character> = []
        for _ in 0..<200 {
            seen.formUnion(try generator.generate(permissive))
        }
        for glyph: Character in ["0", "O", "1", "l", "I"] {
            XCTAssertTrue(seen.contains(glyph), "never produced \(glyph)")
        }
    }

    func testCustomSymbolSetReplacesTheBuiltInOne() throws {
        let restricted = recipe(length: 40, customSymbols: "@#")
        for _ in 0..<50 {
            let password = try generator.generate(restricted)
            let symbols = password.filter { !$0.isLetter && !$0.isNumber }
            XCTAssertFalse(symbols.isEmpty)
            XCTAssertTrue(symbols.allSatisfy { $0 == "@" || $0 == "#" }, "unexpected symbol in \(password)")
        }
    }

    // MARK: - Randomness

    /// The class guarantee draws one character per class *in a fixed order*, so without the
    /// CSPRNG-backed shuffle position 0 would always be lowercase, position 1 always uppercase, and
    /// so on — an attacker would get the class layout of the first four characters for free.
    ///
    /// 400 draws: if the shuffle were absent, every single first character would be lowercase. The
    /// probability of this test failing spuriously is the probability that 400 independent shuffles
    /// all put a lowercase character first, which is roughly `0.25^400`.
    func testShuffleRemovesThePositionalBiasOfTheClassGuarantee() throws {
        var firstCharacterClasses: Set<String> = []
        for _ in 0..<400 {
            let first = try XCTUnwrap(generator.generate(recipe(length: 4)).first)
            if first.isLowercase { firstCharacterClasses.insert("lower") }
            else if first.isUppercase { firstCharacterClasses.insert("upper") }
            else if first.isNumber { firstCharacterClasses.insert("digit") }
            else { firstCharacterClasses.insert("symbol") }
        }
        XCTAssertEqual(firstCharacterClasses.count, 4, "first character never varied across all four classes")
    }

    /// Not a randomness proof — no unit test is one — but it catches the failures that actually
    /// happen: a generator that returns a constant, or one seeded identically every call.
    func testConsecutiveGenerationsDiffer() throws {
        var seen: Set<String> = []
        for _ in 0..<200 {
            seen.insert(try generator.generate(recipe(length: 20)))
        }
        XCTAssertEqual(seen.count, 200, "generator repeated a 20-character password within 200 draws")
    }

    /// `CSPRNG.uniform` uses rejection sampling to avoid modulo bias. A bias small enough to matter
    /// cryptographically is far too small for a test to see, so this asserts the coarse property a
    /// broken implementation would violate outright: every residue occurs, and none dominates. The
    /// bound is deliberately loose (±25 % of the expected 3000) so it cannot flake.
    func testUniformCoversEveryResidueWithoutGrossSkew() throws {
        let buckets = 7
        let draws = buckets * 3000
        var counts = [Int](repeating: 0, count: buckets)
        for _ in 0..<draws {
            let value = try CSPRNG.uniform(upperBound: buckets)
            XCTAssertTrue((0..<buckets).contains(value))
            counts[value] += 1
        }
        let expected = Double(draws / buckets)
        for (index, count) in counts.enumerated() {
            XCTAssertGreaterThan(Double(count), expected * 0.75, "bucket \(index) underrepresented: \(counts)")
            XCTAssertLessThan(Double(count), expected * 1.25, "bucket \(index) overrepresented: \(counts)")
        }
    }

    func testUniformWithUpperBoundOneAlwaysReturnsZero() throws {
        for _ in 0..<10 {
            XCTAssertEqual(try CSPRNG.uniform(upperBound: 1), 0)
        }
    }

    func testShuffledKeepsEveryElementExactlyOnce() throws {
        let input = Array(0..<50)
        for _ in 0..<50 {
            XCTAssertEqual(try CSPRNG.shuffled(input).sorted(), input)
        }
        XCTAssertEqual(try CSPRNG.shuffled([Int]()), [])
        XCTAssertEqual(try CSPRNG.shuffled([7]), [7])
    }

    func testRandomBytesReturnsRequestedCount() throws {
        XCTAssertEqual(try CSPRNG.bytes(count: 0).count, 0)
        XCTAssertEqual(try CSPRNG.bytes(count: 32).count, 32)
    }

    // MARK: - Strength

    /// `length * log2(poolSize)`, with the pool being every enabled, ambiguity-filtered class.
    /// The default recipe drops `l` from lowercase (25), `O` and `I` from uppercase (24), `0` and
    /// `1` from digits (8), and keeps all 28 symbols: 85 in total.
    func testStrengthBitsMatchesTheAlphabetItActuallyDrawsFrom() {
        let defaultRecipe = recipe()
        XCTAssertEqual(generator.strengthBits(for: defaultRecipe), 20 * log2(85), accuracy: 0.0001)

        // Ambiguity filter off: 26 + 26 + 10 + 28 = 90.
        XCTAssertEqual(generator.strengthBits(for: recipe(excludeAmbiguous: false)), 20 * log2(90), accuracy: 0.0001)

        // Lowercase only, filter off: the classic 26-letter alphabet.
        let lowerOnly = recipe(length: 10, uppercase: false, digits: false, symbols: false, excludeAmbiguous: false)
        XCTAssertEqual(generator.strengthBits(for: lowerOnly), 10 * log2(26), accuracy: 0.0001)
    }

    func testStrengthBitsIsZeroForAnUnsatisfiableRecipe() {
        XCTAssertEqual(generator.strengthBits(for: recipe(lowercase: false, uppercase: false, digits: false, symbols: false)), 0)
        XCTAssertEqual(generator.strengthBits(for: recipe(length: 0)), 0)
    }

    /// The typed-password estimate is character-class arithmetic and nothing more — see the doc
    /// comment on `strength(of:)`. These assertions pin the arithmetic, not any claim about how
    /// hard the password is to guess.
    func testStrengthOfTypedPasswordIsCharacterClassArithmetic() {
        XCTAssertEqual(generator.strength(of: ""), 0)
        XCTAssertEqual(generator.strength(of: "abcdefgh"), 8 * log2(26), accuracy: 0.0001)
        XCTAssertEqual(generator.strength(of: "abcdEFGH"), 8 * log2(52), accuracy: 0.0001)
        XCTAssertEqual(generator.strength(of: "abcdEF12"), 8 * log2(62), accuracy: 0.0001)
        XCTAssertEqual(generator.strength(of: "abcdEF1!"), 8 * log2(90), accuracy: 0.0001)
        XCTAssertEqual(generator.strength(of: "12345678"), 8 * log2(10), accuracy: 0.0001)
    }

    /// Documents the estimator's known blind spot rather than papering over it: `Password1!` is a
    /// dictionary word with the two most predictable suffixes on earth, and this estimator — having
    /// no dictionary — scores it as if it were random. Anyone who later mistakes this function for
    /// a real strength meter should trip over this test.
    func testStrengthOfTypedPasswordOverstatesDictionaryPasswords() {
        XCTAssertGreaterThan(generator.strength(of: "Password1!"), 60)
    }

    /// Longer is never weaker, and a broader alphabet is never weaker at equal length. Anything
    /// else would make a strength bar that moves the wrong way as the user types.
    func testStrengthIsMonotonic() {
        XCTAssertGreaterThan(generator.strength(of: "abcdefghi"), generator.strength(of: "abcdefgh"))
        XCTAssertGreaterThan(generator.strength(of: "abcdefgH"), generator.strength(of: "abcdefgh"))
        XCTAssertGreaterThan(generator.strengthBits(for: recipe(length: 21)), generator.strengthBits(for: recipe(length: 20)))
    }
}
