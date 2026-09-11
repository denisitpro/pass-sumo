import XCTest

/// Sidebar, entry list, detail, and search — the everyday "look something up" flow through
/// `VaultBrowserView`. See `UITestSupport.swift` for `SampleVault` (the fixed `Vault.sample`
/// values these tests assert against) and the shared launch/lookup helpers.
final class BrowseAndSearchTests: XCTestCase {
    func testSidebarListsSampleGroupsAndAllEntries() {
        let app = launchUITestingApp(self)

        XCTAssertTrue(app.byID("sidebar.allEntries").waitForExistence(timeout: 5))
        XCTAssertTrue(app.byID("sidebar.group.\(SampleVault.groupEmailID)").waitForExistence(timeout: 5))
        XCTAssertTrue(app.byID("sidebar.group.\(SampleVault.groupWorkID)").waitForExistence(timeout: 5))
        XCTAssertTrue(app.byID("sidebar.group.\(SampleVault.groupFinanceID)").waitForExistence(timeout: 5))
    }

    func testSelectingAGroupFiltersTheList() {
        let app = launchUITestingApp(self)

        // The sidebar opens on "All Entries" (`VaultBrowserView`'s `selectedGroup` starts at
        // `.allEntries` — issue #85), so both Email's own entry and Finance's own entry are
        // visible up front.
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.gmailPersonalID)").waitForExistence(timeout: 5))
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.payPalID)").waitForExistence(timeout: 5))

        app.byID("sidebar.group.\(SampleVault.groupEmailID)").click()

        // Email's own entry stays; Finance's own entry is filtered out.
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.gmailPersonalID)").waitForExistence(timeout: 5))
        XCTAssertFalse(app.byID("list.entry.\(SampleVault.payPalID)").waitForExistence(timeout: 2))
    }

    func testSelectingAnEntryShowsItsDetail() {
        let app = launchUITestingApp(self)

        // TEMP DIAGNOSTIC (issue #6, to be removed before this task is done): H-A (focus) is
        // already disproven (app.activate() changed nothing). Three probes to separate H-C
        // (click never reaches List's selection machinery) from H-D (selection is set then
        // immediately cleared) from "double-click's own gesture doesn't fire either".
        let identifier = "list.entry.\(SampleVault.gmailPersonalID)"

        func detailState() -> String {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'browser.detail'"))
                .allElementsBoundByIndex
                .map { "\($0.label)|\($0.value ?? "nil")" }
                .joined(separator: " // ")
        }

        // Probe 1: keyboard-only selection, no mouse involved at all yet.
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        print("DIAG P1 keyboard-only: detail.edit exists = \(app.byID("detail.edit").exists), detail = \(detailState())")

        // Probe 2: single click, then check the CELL's own AX-reported selection state directly,
        // to see whether the click reached List's selection machinery at all (isSelected true)
        // even if the detail pane doesn't reflect it (which would point at H-D).
        let cell = app.descendants(matching: .cell)
            .containing(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
        cell.click()
        Thread.sleep(forTimeInterval: 1.0)
        print("DIAG P2 after single click: cell.isSelected = \(cell.isSelected), detail.edit exists = \(app.byID("detail.edit").exists), detail = \(detailState())")

        // Probe 3: double-click — EntryListView wires this to `onOpenEntry` (opens the edit
        // sheet) independently of List's own selection. If this fires, the row's own gesture
        // recognizer works even though single-click selection doesn't.
        cell.doubleClick()
        Thread.sleep(forTimeInterval: 1.0)
        let editSheetAppeared = app.byID("edit.save").exists
        print("DIAG P3 after double-click: edit.save exists = \(editSheetAppeared), detail = \(detailState())")
        if editSheetAppeared {
            app.byID("edit.cancel").click()
        }

        XCTAssertEqual(app.fieldRowValue("Title"), SampleVault.gmailPersonalTitle)
        XCTAssertEqual(app.fieldRowValue("Username"), SampleVault.gmailPersonalUsername)
        XCTAssertEqual(app.fieldRowValue("URL"), SampleVault.gmailPersonalURL)
    }

    func testSearchNarrowsTheListAndClearingRestoresIt() {
        let app = launchUITestingApp(self)
        let searchField = app.byID("browser.search")
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        searchField.replaceText(SampleVault.gmailPersonalTitle)
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.gmailPersonalID)").waitForExistence(timeout: 5))
        XCTAssertFalse(app.byID("list.entry.\(SampleVault.payPalID)").waitForExistence(timeout: 2))

        searchField.replaceText("")
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.payPalID)").waitForExistence(timeout: 5))
    }

    /// The product's stated differentiator over KeePassium (see `Vault.search`'s doc comment in
    /// `Domain.swift`): search reaches into the PASSWORD field, not just title/username/url/notes.
    /// `SampleVault.passwordOnlySearchSubstring` ("Cinder") occurs nowhere in `Vault.sample` except
    /// inside PayPal's password — so finding PayPal (and only PayPal) by this query is a true e2e
    /// check of that specific behavior, not just of substring search in general.
    func testSearchFindsEntryBySubstringThatOnlyAppearsInItsPassword() {
        let app = launchUITestingApp(self)
        let searchField = app.byID("browser.search")
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        searchField.replaceText(SampleVault.passwordOnlySearchSubstring)

        XCTAssertTrue(app.byID("list.entry.\(SampleVault.payPalID)").waitForExistence(timeout: 5))
        // Gmail Personal's title/username/url/notes don't contain the needle either — a plain
        // "did something match" check wouldn't distinguish "found via the password field" from a
        // bug that matched every entry.
        XCTAssertFalse(app.byID("list.entry.\(SampleVault.gmailPersonalID)").waitForExistence(timeout: 2))
    }

    func testSearchWithNoMatchesShowsEmptyStateAndDoesNotCrash() {
        let app = launchUITestingApp(self)
        let searchField = app.byID("browser.search")
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        searchField.replaceText(SampleVault.searchWithNoMatches)

        XCTAssertTrue(app.waitForLabel("No Results"))
        XCTAssertFalse(app.byID("list.entry.\(SampleVault.gmailPersonalID)").waitForExistence(timeout: 2))
        // Still responsive — a crash on an empty result set would make this fail instead.
        XCTAssertTrue(app.windows.firstMatch.exists)
    }
}
