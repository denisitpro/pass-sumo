import XCTest

/// Proves the e2e harness: launching with `-ui-testing 1` (see Sources/App/PassSumoApp.swift)
/// produces a window with the vault browser's sidebar, pre-loaded with the deterministic sample
/// vault. Later agents extend this suite; this test exists only to prove `make e2e` actually
/// drives a real window.
final class LaunchTests: XCTestCase {
    func testLaunchShowsSidebar() {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "1"]
        if app.state != .notRunning { app.terminate() }
        app.launch()
        app.activate()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        // `.any` rather than a specific element type: SwiftUI's List renders to different
        // underlying AppKit views depending on context, and the identifier is what's stable, not
        // the XCUIElementType it happens to surface as.
        //
        // FIXED: this previously asserted on "root.sidebar", which no view anywhere in the
        // codebase ever sets (grep-confirmed against every `.accessibilityIdentifier(...)` call in
        // Sources/UI) — the sidebar's real identifier is "browser.sidebar" (`VaultBrowserView`),
        // nested under "root.browser" (`RootView`, once the vault is unlocked). The old literal
        // meant this assertion could never have passed.
        XCTAssertTrue(app.descendants(matching: .any)["browser.sidebar"].waitForExistence(timeout: 5))
    }

    /// Beyond "a window exists": the browser must be showing `Vault.sample`, not an empty vault.
    /// "All Entries" carries the vault's total entry count as part of its own row (see
    /// `GroupSidebar.swift`) — checked scoped to that row's OWN identifier
    /// (`waitForElement(identifiedBy:containing:)`), not "this text exists somewhere in the
    /// window", which is what proves the count belongs to this row and not to some unrelated
    /// element that happens to share the digits. Backed up by two known sample entries, from two
    /// different groups, actually appearing as list rows — the count alone can't tell "the sample
    /// vault" apart from "any 20-entry vault".
    func testLaunchLoadsSampleVault() {
        let app = launchUITestingApp(self)

        XCTAssertTrue(app.byID("sidebar.allEntries").waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.waitForElement(identifiedBy: "sidebar.allEntries", containing: "\(SampleVault.totalEntryCount)"),
            "no element of the \"sidebar.allEntries\" row showed the sample vault's total entry " +
            "count (\(SampleVault.totalEntryCount))"
        )

        XCTAssertTrue(app.byID("list.entry.\(SampleVault.gmailPersonalID)").waitForExistence(timeout: 5))
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.payPalID)").waitForExistence(timeout: 5))
    }

    /// Lock sat in the overflow chevron once the search field was centred
    /// (issue #129). `.primaryAction` is the trailing slot that does not overflow;
    /// hittable is the proof, not mere existence.
    func testLockButtonIsHittable() {
        let app = launchUITestingApp(self)
        let lock = app.byID("browser.lock")
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        XCTAssertTrue(lock.isHittable, "Lock overflowed behind the toolbar chevron")
    }
}
