import XCTest

/// Creating a folder from the browser toolbar (issue #129). Lives in its own file rather than
/// folding into `BrowseAndSearchTests` because that file is the everyday look-up flow and this
/// one writes to the sidebar.
final class GroupSidebarTests: XCTestCase {
    func testCreatingAGroupFromTheToolbarAddsItToTheSidebar() {
        let app = launchUITestingApp(self)
        let name = "Brand New Folder (e2e)"

        XCTAssertTrue(app.byID("browser.newGroup").waitForExistence(timeout: 5))
        app.byID("browser.newGroup").click()

        let nameField = app.byID("browser.groupName")
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.replaceText(name)
        app.byID("browser.confirmGroupName").click()

        // The new folder's UUID is minted at create time, so the row identifier
        // (`sidebar.group.<uuid>`) is not known ahead of time. Prefix-match plus the name is the
        // same shape as `waitForEntryListRow` for a freshly created entry.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'sidebar.group.' AND (label CONTAINS %@ OR value CONTAINS %@)",
                name, name
            ))
            .firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 5),
            "no sidebar group row carried the new folder's name \"\(name)\" after creating it"
        )
    }

    /// Cancel on the New Group sheet must not create a folder (issue #129). The
    /// sheet used to be a name-only alert; a live Cancel that still called
    /// `addGroup` would look like the button did nothing useful.
    func testCancelingNewGroupSheetCreatesNothing() {
        let app = launchUITestingApp(self)
        let name = "Cancelled Folder (e2e)"

        app.byID("browser.newGroup").click()
        let nameField = app.byID("browser.groupName")
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.replaceText(name)
        app.byID("browser.cancelGroupName").click()

        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(NSPredicate(
                    format: "identifier BEGINSWITH 'sidebar.group.' AND (label CONTAINS %@ OR value CONTAINS %@)",
                    name, name
                ))
                .firstMatch
                .waitForExistence(timeout: 2),
            "cancelling New Group still created a folder named \"\(name)\""
        )
    }

    /// The reason create is a sheet instead of an alert: an icon picker. Opening
    /// it and cancelling must leave the New Group sheet up, not create a folder.
    func testNewGroupSheetOffersAnIconPicker() {
        let app = launchUITestingApp(self)

        app.byID("browser.newGroup").click()
        XCTAssertTrue(app.byID("browser.groupName").waitForExistence(timeout: 5))
        app.byID("browser.newGroup.icon").click()

        XCTAssertTrue(app.byID("iconPicker").waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(app.byID("browser.groupName").waitForExistence(timeout: 5))
        app.byID("browser.cancelGroupName").click()
    }
}
