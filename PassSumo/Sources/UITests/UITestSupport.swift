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
    static let gmailPersonalUsername = "den.larkin@gmail.com"
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
    func byID(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }

    /// True once some element with accessibility LABEL `text` exists anywhere in the app — the
    /// generic way to check for a plain `Text`/`Label` that has no identifier of its own
    /// (`ContentUnavailableView`'s title, a row's title text, an inline error message, …).
    func waitForLabel(_ text: String, timeout: TimeInterval = 5) -> Bool {
        descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", text))
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
