import XCTest

/// `GeneratorSheet`, reached through `EntryEditView`'s "Generate…" button (`edit.generate`) rather
/// than `VaultBrowserView`'s standalone toolbar "Generator" button — that toolbar button has no
/// `.accessibilityIdentifier` (see this suite's own README for the full list of such gaps), only a
/// ⌘⇧G shortcut, so it can't be targeted directly by id. The sheet itself is identical either way
/// (`VaultBrowserView` opens the very same `GeneratorSheet`), so this is not a narrower test of the
/// generator's own behavior — only of a different entry point into it.
final class GeneratorTests: XCTestCase {
    private func entropyBits(from text: String) -> Int? {
        // "Entropy: 131 bits" -> 131. Deliberately just the digits rather than a stricter regex:
        // the text has exactly one run of digits, so this is unambiguous.
        Int(text.filter(\.isNumber))
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

        // `.textValue`, not `.label`: both fields are plain SwiftUI `Text`, and on macOS a `Text`
        // puts its string in the accessibility VALUE, never the LABEL (see `UITestSupport.swift`'s
        // `waitForLabel` doc comment) — reading `.label` here always returned an empty string.
        let lengthBefore = resultField.textValue.count
        let entropyBefore = try XCTUnwrap(
            entropyBits(from: entropyField.textValue),
            "couldn't parse a bit count out of \(entropyField.textValue)"
        )

        // Drag to the slider's maximum (64 characters, per `GeneratorSheet`'s `4...64` range) —
        // as far as possible from the 20-character default, so a flaky few-character wobble in
        // `adjust(toNormalizedSliderPosition:)`'s precision can't be mistaken for "didn't change".
        lengthSlider.adjust(toNormalizedSliderPosition: 1.0)
        // `GeneratorSheet.onChange(of: recipe, regenerate)` already regenerates on the slider
        // drag alone; clicking Regenerate too exercises that control explicitly, per the brief.
        app.byID("generator.regenerate").click()

        let lengthAfter = resultField.textValue.count
        let entropyAfter = try XCTUnwrap(
            entropyBits(from: entropyField.textValue),
            "couldn't parse a bit count out of \(entropyField.textValue)"
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
        // `.textValue`, not `.label` — `generator.result` is a plain `Text`, whose string lands in
        // the accessibility VALUE on macOS (see `GeneratorSheet.swift:151`, `UITestSupport.swift`'s
        // `waitForLabel` doc comment). Reading `.label` here always returned "", which is why
        // `generated` used to be empty and the field-value comparison below trivially passed.
        let generated = resultField.textValue
        XCTAssertFalse(generated.isEmpty)

        app.byID("generator.use").click()

        // "Use" dismisses the generator sheet (`GeneratorSheet`'s own `onUse` + `dismiss()`),
        // returning focus to the edit form underneath with the password field now filled.
        let passwordField = app.byID("edit.password")
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))

        // The field renders concealed by default (`EntryEditView.isPasswordVisible` starts
        // `false`), so its accessibility value right now is a run of bullet characters, never the
        // real password — a security-relevant fact worth asserting on its own, not just a nuisance
        // in the way of the real check below.
        XCTAssertNotEqual(
            passwordField.value as? String, generated,
            "a concealed password field must not expose the real password as its accessibility value"
        )

        // Reveal it — the only way to read the REAL text back, concealed or not, and the same
        // thing a real user has to do to verify "Use" actually worked (issue #6: this button had no
        // identifier until now; see `EntryEditView.swift`'s `edit.revealPassword`).
        app.byID("edit.revealPassword").click()
        XCTAssertEqual(passwordField.value as? String, generated)

        app.byID("edit.cancel").click()
    }
}
