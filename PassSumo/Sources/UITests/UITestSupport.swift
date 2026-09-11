import AppKit
import XCTest

/// Copies of `Vault.sample`'s fixed fixture values (`Sources/Model/Domain.swift`), for tests that
/// need to assert on specific entries/groups without inventing data.
///
/// `PassSumoUITests` is a black-box UI-test target — `project.yml`'s own comment is explicit that
/// it "must not link the data layer at all" — so it cannot `@testable import PassSumo` and reuse
/// `Vault.sample` directly. These constants are hand-copied instead; keep them in sync by hand if
/// that fixture ever changes.
enum SampleVault {
    static let groupEmailID = "10000000-0000-0000-0000-000000000001"
    static let groupWorkID = "10000000-0000-0000-0000-000000000002"
    static let groupFinanceID = "10000000-0000-0000-0000-000000000003"

    static let totalEntryCount = 20
    static let emailEntryCount = 7
    static let workEntryCount = 7
    static let financeEntryCount = 6

    // Every entry chosen below has a purely-numeric UUID (no hex letters) ON PURPOSE: `UUID`'s
    // own `description`/`uuidString` always renders hex letters UPPERCASE, and `EntryListView`
    // interpolates `entry.id` directly into `"list.entry.\(entry.id)"` — a lowercase literal here
    // (e.g. for the Slack or AWS Console entries, whose fixed UUIDs contain "a".."f") would
    // silently never match. Sticking to all-digit UUIDs sidesteps that footgun entirely.
    static let gmailPersonalID = "20000000-0000-0000-0000-000000000001"
    static let gmailPersonalTitle = "Gmail Personal"
    static let gmailPersonalUsername = "sample.user@example.com"
    static let gmailPersonalURL = "https://accounts.google.com"
    static let gmailPersonalPassword = "Tr0ub4dor&3-gmail"

    static let iCloudID = "20000000-0000-0000-0000-000000000002"
    static let iCloudTitle = "iCloud"

    static let outlookID = "20000000-0000-0000-0000-000000000004"
    static let outlookTitle = "Outlook"

    static let yahooMailID = "20000000-0000-0000-0000-000000000006"
    static let yahooMailTitle = "Yahoo Mail"

    static let payPalID = "20000012-0000-0000-0000-000000000012"
    static let payPalTitle = "PayPal"

    /// Occurs ONLY inside PayPal's password field ("P4yPal-Cinder-19") — nowhere else in
    /// `Vault.sample`'s title/username/url/notes/customFields, across all 20 entries. Hand-
    /// verified by grepping `Domain.swift` for this literal when this file was written (it must
    /// match exactly once, on the `password:` line). Exercises `Vault.search`'s documented
    /// differentiator over KeePassium: search reaches into the password field itself.
    static let passwordOnlySearchSubstring = "Cinder"

    static let searchWithNoMatches = "xyzzy-does-not-exist-in-any-field-of-any-entry"
}

extension XCUIApplication {
    /// Every stable identifier in this app is looked up this way, matching `LaunchTests`'
    /// originally-established pattern: SwiftUI's List/OutlineGroup/toolbar content renders to
    /// different underlying AppKit element types depending on context, so `.any` is what stays
    /// stable across that, not a specific `XCUIElementType`.
    ///
    /// `.firstMatch`, not the ambiguity-sensitive `[identifier]` subscript — deliberately (issue
    /// #6). SwiftUI propagates `.accessibilityIdentifier(...)` down to EVERY leaf accessibility
    /// element inside the view it's attached to, not just the view itself: a sidebar/list row built
    /// from an icon `Image` plus one or two `Text`s ends up with several elements that all carry
    /// the SAME identifier (verified against the real AX tree from this suite's first run on actual
    /// hardware). `[identifier]` requires the match to be unique and throws "Find single matching
    /// element. Multiple matching elements found" the moment you `.click()` one of these; `.firstMatch`
    /// resolves the ambiguity deterministically instead.
    ///
    /// Wrapping each row in `.accessibilityElement(children: .combine)` to make the identifier
    /// unique again was tried first and reverted: it silently broke `List(selection:)`'s own
    /// click-to-select handling (`testSelectingAnEntryShowsItsDetail`,
    /// `testSelectingAGroupFiltersTheList` both regressed to the row never getting selected at
    /// all), which is a MUCH worse failure mode than an ambiguous id. `.firstMatch` still resolves
    /// to one of the row's own leaves — every leaf's frame sits inside the row's clickable area
    /// (the row's `.contentShape(Rectangle())`/List's own row hit-test), so clicking it still hits
    /// the row.
    func byID(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }

    /// True once some element with accessibility LABEL *or* VALUE `text` exists anywhere in the
    /// app — the generic way to check for a plain `Text`/`Label` that has no identifier of its own
    /// (`ContentUnavailableView`'s title, an inline error message, …).
    ///
    /// Matches VALUE as well as LABEL because a plain SwiftUI `Text` puts its string into the
    /// accessibility VALUE on macOS, never the LABEL — confirmed against the real AX tree captured
    /// from this suite's first run against actual hardware (issue #6): every `StaticText` in the
    /// dump had an empty `label` and the string in `value`. A predicate on `label` alone can never
    /// match one, which is why this originally matched nothing for "20", "No Results", or a freshly
    /// created entry's title.
    func waitForLabel(_ text: String, timeout: TimeInterval = 5) -> Bool {
        descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", text, text))
            .firstMatch
            .waitForExistence(timeout: timeout)
    }

    /// True once some element identified by `identifier` carries `text` in its accessibility label
    /// or value. Scoped by the row/element's OWN identifier — stronger than `waitForLabel(_:)` for
    /// proving a specific piece of UI shows specific text: that helper matches ANY element in the
    /// whole window, so it can't tell "this specific row/field shows the text" apart from "this
    /// text appears somewhere else on screen entirely" (a different view showing the same string).
    ///
    /// `CONTAINS`, not `==`: a row built from more than one `Text` (a title plus a username, or a
    /// label plus a trailing count) has several leaf elements sharing one identifier (see `byID`'s
    /// doc comment on why), each carrying only ITS OWN piece of the row's text — matching CONTAINS
    /// against any of them is what proves "the count/title is somewhere in this row" without
    /// requiring a single element that holds the row's whole text at once.
    func waitForElement(identifiedBy identifier: String, containing text: String, timeout: TimeInterval = 5) -> Bool {
        descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
                identifier, text, text
            ))
            .firstMatch
            .waitForExistence(timeout: timeout)
    }

    /// True once a row in the entry list (identifier `BEGINSWITH "list.entry."`) carries `text` in
    /// its accessibility label or value. The prefix-matching sibling of `waitForElement(identifiedBy:
    /// containing:)` above, for exactly the case where the row's own identifier (a per-entry UUID)
    /// isn't known ahead of time — a freshly created entry, say.
    func waitForEntryListRow(containing text: String, timeout: TimeInterval = 5) -> Bool {
        descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'list.entry.' AND (label CONTAINS %@ OR value CONTAINS %@)",
                text, text
            ))
            .firstMatch
            .waitForExistence(timeout: timeout)
    }

    /// Reads the accessibility VALUE of the one `FieldRow` labeled `label` in `EntryDetailView`
    /// ("Title"/"Username"/"Password"/"URL"/"Notes"/…). See `FieldRow.swift`'s own doc comment:
    /// label and value are deliberately ONE combined accessibility element, with the copy/reveal
    /// buttons kept outside it — this is how that combined element's value is read without
    /// depending on screen text or position. `nil` if no such row exists (wrong screen, typo'd
    /// label) or it hasn't appeared within `timeout`.
    func fieldRowValue(_ label: String, timeout: TimeInterval = 5) -> String? {
        let element = descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        guard element.waitForExistence(timeout: timeout) else { return nil }
        return element.value as? String
    }
}

extension XCUIElement {
    /// The string a plain SwiftUI `Text`-backed element carries — in its accessibility VALUE on
    /// macOS, never the LABEL (see `waitForLabel(_:)`'s doc comment for the same fact, confirmed
    /// against a real AX tree in issue #6). `generator.result`/`generator.entropy` are both bare
    /// `Text`, so `.label` on them is always empty; this is the correct way to read either one.
    var textValue: String {
        (value as? String) ?? ""
    }

    /// Clicks into the field, selects everything already there and deletes it, then types `text`
    /// — the reliable way to REPLACE a text/search field's contents rather than append to
    /// whatever a previous interaction in the same launch left in it.
    func replaceText(_ text: String) {
        click()
        if let current = value as? String, !current.isEmpty {
            typeKey("a", modifierFlags: .command)
            typeKey(.delete, modifierFlags: [])
        }
        typeText(text)
    }
}

/// Launches `PassSumo` against the deterministic `-ui-testing 1` fixture (see
/// `Sources/App/AppEnvironment.swift`'s `uiTesting()`) and waits for the vault browser to appear —
/// i.e. for `loadUITestingFixture()` to have finished unlocking `Vault.sample`.
///
/// Registers a teardown that terminates the app, so every test starts a FRESH process rather than
/// reusing one left over from a previous test: the in-memory fakes reset per launch (architecture
/// contract, "Testing" section), and that guarantee only holds if nothing chains off a previous
/// test's still-running app.
@discardableResult
func launchUITestingApp(
    _ testCase: XCTestCase,
    file: StaticString = #filePath,
    line: UInt = #line
) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-ui-testing", "1"]
    app.launch()
    testCase.addTeardownBlock { app.terminate() }

    XCTAssertTrue(
        app.byID("root.browser").waitForExistence(timeout: 10),
        "vault browser did not appear after launch with -ui-testing 1",
        file: file, line: line
    )
    return app
}
