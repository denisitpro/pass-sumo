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

        // Nothing is selected in the sidebar yet, so "All Entries" is implicitly in effect
        // (`VaultBrowserView`'s `selectedGroupID` starts `nil`) — both Email's own entry and
        // Finance's own entry are visible up front.
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.gmailPersonalID)").waitForExistence(timeout: 5))
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.payPalID)").waitForExistence(timeout: 5))

        app.byID("sidebar.group.\(SampleVault.groupEmailID)").click()

        // Email's own entry stays; Finance's own entry is filtered out.
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.gmailPersonalID)").waitForExistence(timeout: 5))
        XCTAssertFalse(app.byID("list.entry.\(SampleVault.payPalID)").waitForExistence(timeout: 2))
    }

    func testSelectingAnEntryShowsItsDetail() {
        let app = launchUITestingApp(self)

        app.byID("list.entry.\(SampleVault.gmailPersonalID)").click()

        XCTAssertEqual(app.fieldRowValue("Title"), SampleVault.gmailPersonalTitle)
        XCTAssertEqual(app.fieldRowValue("Username"), SampleVault.gmailPersonalUsername)
        XCTAssertEqual(app.fieldRowValue("URL"), SampleVault.gmailPersonalURL)
    }

    func testSearchNarrowsTheListAndClearingRestoresIt() {
        let app = launchUITestingApp(self)
        let searchField = app.searchFields.firstMatch
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
        let searchField = app.searchFields.firstMatch
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
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        searchField.replaceText(SampleVault.searchWithNoMatches)

        XCTAssertTrue(app.waitForLabel("No Results"))
        XCTAssertFalse(app.byID("list.entry.\(SampleVault.gmailPersonalID)").waitForExistence(timeout: 2))
        // Still responsive — a crash on an empty result set would make this fail instead.
        XCTAssertTrue(app.windows.firstMatch.exists)
    }
}
