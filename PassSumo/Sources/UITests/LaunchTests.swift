import XCTest

/// Proves the e2e harness: launching with `-ui-testing 1` (see Sources/App/PassSumoApp.swift)
/// produces a window with the vault browser's sidebar, pre-loaded with the deterministic sample
/// vault. Later agents extend this suite; this test exists only to prove `make e2e` actually
/// drives a real window.
final class LaunchTests: XCTestCase {
    func testLaunchShowsSidebar() {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "1"]
        app.launch()
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
    /// "All Entries" carries the vault's total entry count as its trailing digit label (see
    /// `GroupSidebar.swift`) — the simplest single assertion that the sample fixture, specifically,
    /// is what loaded.
    func testLaunchLoadsSampleVault() {
        let app = launchUITestingApp(self)

        XCTAssertTrue(app.byID("sidebar.allEntries").waitForExistence(timeout: 5))
        XCTAssertTrue(app.waitForLabel("\(SampleVault.totalEntryCount)"))
    }
}
