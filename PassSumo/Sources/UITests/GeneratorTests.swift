import XCTest

/// `GeneratorSheet`, reached through `EntryEditView`'s "Generate…" button (`edit.generate`) rather
/// than `VaultBrowserView`'s standalone toolbar "Generator" button — that toolbar button has no
/// `.accessibilityIdentifier` (see this suite's own README for the full list of such gaps), only a
/// ⌘⇧G shortcut, so it can't be targeted directly by id. The sheet itself is identical either way
/// (`VaultBrowserView` opens the very same `GeneratorSheet`), so this is not a narrower test of the
/// generator's own behavior — only of a different entry point into it.
final class GeneratorTests: XCTestCase {
    private func entropyBits(from label: String) -> Int? {
        // "Entropy: 131 bits" -> 131. Deliberately just the digits rather than a stricter regex:
        // the label has exactly one run of digits, so this is unambiguous.
        Int(label.filter(\.isNumber))
    }

    func testChangingLengthRegeneratesWithMatchingLengthAndEntropy() throws {
        let app = launchUITestingApp(self)
        app.byID("browser.newEntry").click()
        app.byID("edit.generate").click()

        let resultField = app.byID("generator.result")
        let entropyField = app.byID("generator.entropy")
        let lengthSlider = app.byID("generator.length")
        XCTAssertTrue(resultField.waitForExistence(timeout: 5))
        XCTAssertTrue(entropyField.waitForExistence(timeout: 5))
        XCTAssertTrue(lengthSlider.waitForExistence(timeout: 5))

        let lengthBefore = resultField.label.count
        let entropyBefore = try XCTUnwrap(
            entropyBits(from: entropyField.label), "couldn't parse a bit count out of \(entropyField.label)"
        )

        // Drag to the slider's maximum (64 characters, per `GeneratorSheet`'s `4...64` range) —
        // as far as possible from the 20-character default, so a flaky few-character wobble in
        // `adjust(toNormalizedSliderPosition:)`'s precision can't be mistaken for "didn't change".
        lengthSlider.adjust(toNormalizedSliderPosition: 1.0)
        // `GeneratorSheet.onChange(of: recipe, regenerate)` already regenerates on the slider
        // drag alone; clicking Regenerate too exercises that control explicitly, per the brief.
        app.byID("generator.regenerate").click()

        let lengthAfter = resultField.label.count
        let entropyAfter = try XCTUnwrap(
            entropyBits(from: entropyField.label), "couldn't parse a bit count out of \(entropyField.label)"
        )

        XCTAssertGreaterThan(lengthAfter, lengthBefore, "moving the slider to its maximum should have produced a longer password")
        XCTAssertGreaterThan(entropyAfter, entropyBefore, "a longer password from the same alphabet is never lower-entropy")
    }

    func testUsePutsTheGeneratedValueIntoTheEditFormsPasswordField() {
        let app = launchUITestingApp(self)
        app.byID("browser.newEntry").click()
        app.byID("edit.generate").click()

        let resultField = app.byID("generator.result")
        XCTAssertTrue(resultField.waitForExistence(timeout: 5))
        let generated = resultField.label
        XCTAssertFalse(generated.isEmpty)

        app.byID("generator.use").click()

        // "Use" dismisses the generator sheet (`GeneratorSheet`'s own `onUse` + `dismiss()`),
        // returning focus to the edit form underneath with the password field now filled.
        let passwordField = app.byID("edit.password")
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        XCTAssertEqual(passwordField.value as? String, generated)

        app.byID("edit.cancel").click()
    }
}
