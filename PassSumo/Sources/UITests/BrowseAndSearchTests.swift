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

        app.selectRow(identifiedBy: "sidebar.group.\(SampleVault.groupEmailID)")

        // Email's own entry stays; Finance's own entry is filtered out.
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.gmailPersonalID)").waitForExistence(timeout: 5))
        XCTAssertFalse(app.byID("list.entry.\(SampleVault.payPalID)").waitForExistence(timeout: 2))

        // The reverse path is the owner's #129 bug: after a group is selected (or a new
        // folder is created and left selected), clicking All Entries did nothing, so
        // there was no way back to the unfiltered list.
        app.selectRow(identifiedBy: "sidebar.allEntries")
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.gmailPersonalID)").waitForExistence(timeout: 5))
        XCTAssertTrue(app.byID("list.entry.\(SampleVault.payPalID)").waitForExistence(timeout: 5))
    }

    /// Right-click on a group row must surface the folder actions (issue #129). The
    /// menu used to live only on the row's text/icon content, so a click on the
    /// trailing empty area — or on All Entries, which had no menu at all — did nothing.
    func testGroupRowContextMenuOffersFolderActions() {
        let app = launchUITestingApp(self)

        let identifier = "sidebar.group.\(SampleVault.groupEmailID)"
        // Same cell-not-leaf rule as `selectRow`: SwiftUI copies the identifier onto
        // every Text/Image inside the row, and right-clicking a leaf can miss the
        // view that owns `.contextMenu`.
        let cell = app.descendants(matching: .cell)
            .containing(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
        if cell.waitForExistence(timeout: 5) {
            cell.rightClick()
        } else {
            let leaf = app.byID(identifier)
            XCTAssertTrue(leaf.waitForExistence(timeout: 5), "no row identified by \(identifier)")
            leaf.rightClick()
        }

        // Menu item identifiers often do not surface as XCUIElement.menuItems on macOS;
        // assert by the visible names the group-row menu actually offers.
        XCTAssertTrue(app.menuItems["New Group…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Rename…"].exists)
        XCTAssertTrue(app.menuItems["Change Icon…"].exists)
    }

    func testSelectingAnEntryShowsItsDetail() {
        let app = launchUITestingApp(self)

        app.selectRow(identifiedBy: "list.entry.\(SampleVault.gmailPersonalID)")

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
