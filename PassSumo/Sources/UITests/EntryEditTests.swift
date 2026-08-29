import XCTest

/// The edit/create/cancel/delete flows around `EntryEditView` and `VaultBrowserView`'s toolbar.
final class EntryEditTests: XCTestCase {
    func testEditingTitleUpdatesListAndDetail() {
        let app = launchUITestingApp(self)
        let newTitle = "iCloud (Renamed for e2e)"

        app.byID("list.entry.\(SampleVault.iCloudID)").click()
        app.byID("detail.edit").click()

        let titleField = app.byID("edit.title")
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.replaceText(newTitle)
        app.byID("edit.save").click()

        // The list row (a plain `Text(entry.title)`, no identifier of its own) shows the new title…
        XCTAssertTrue(app.waitForLabel(newTitle))
        // …and so does the detail column, read the same way every other detail assertion in this
        // suite is: through `FieldRow`'s combined label+value element, not screen text.
        XCTAssertEqual(app.fieldRowValue("Title"), newTitle)
    }

    func testCreatingNewEntryAppearsInTheList() {
        let app = launchUITestingApp(self)
        let title = "Brand New Service (e2e)"

        app.byID("browser.newEntry").click()

        let titleField = app.byID("edit.title")
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.replaceText(title)
        app.byID("edit.username").replaceText("new-service-user")
        app.byID("edit.password").replaceText("Sup3r-Fresh-Passw0rd!")

        app.byID("edit.save").click()

        XCTAssertTrue(app.waitForLabel(title))
    }

    func testCancelingAnEditLeavesTheEntryUnchanged() {
        let app = launchUITestingApp(self)
        let attemptedTitle = "This Edit Should Never Stick"

        app.byID("list.entry.\(SampleVault.outlookID)").click()
        app.byID("detail.edit").click()

        let titleField = app.byID("edit.title")
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.replaceText(attemptedTitle)
        app.byID("edit.cancel").click()

        XCTAssertEqual(app.fieldRowValue("Title"), SampleVault.outlookTitle)
        XCTAssertFalse(app.waitForLabel(attemptedTitle, timeout: 2))
    }

    func testDeletingAnEntryRemovesItFromTheList() {
        let app = launchUITestingApp(self)

        app.byID("list.entry.\(SampleVault.yahooMailID)").click()
        app.byID("browser.deleteEntry").click()

        XCTAssertFalse(app.byID("list.entry.\(SampleVault.yahooMailID)").waitForExistence(timeout: 3))
    }

    /// Exercises `EntryListView`'s own `.onKeyPress(.return)` wiring — direct, per-view state
    /// (`selectedEntryID`/`onOpenEntry`), NOT routed through `AppCommands`/
    /// `AppEnvironment.selectedEntryID` (see that property's own doc comment on the integration
    /// still pending there) — so unlike a menu-shortcut-driven test, this one is not expected to be
    /// red on that account.
    func testReturnKeyOnASelectedEntryOpensTheEditSheet() {
        let app = launchUITestingApp(self)

        app.byID("list.entry.\(SampleVault.gmailPersonalID)").click()
        app.typeText("\r")

        XCTAssertTrue(app.byID("edit.save").waitForExistence(timeout: 5))
        app.byID("edit.cancel").click()
    }
}
