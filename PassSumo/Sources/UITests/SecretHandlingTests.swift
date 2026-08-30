import AppKit
import XCTest

/// The security-behavior tests: password concealment, reveal, copy-to-pasteboard, and locking.
/// These matter more than any other file in this suite — a regression here is a real secret
/// showing up somewhere it shouldn't, not just a broken UI flow.
final class SecretHandlingTests: XCTestCase {
    func testPasswordIsConcealedByDefault() {
        let app = launchUITestingApp(self)

        app.byID("list.entry.\(SampleVault.gmailPersonalID)").click()

        // `FieldRow` reports the literal VoiceOver value "hidden" for a concealed secret (never
        // the real value, never even its length — see that file's own doc comment on why), so
        // "hidden" IS the concealed value, and it must not equal the real plaintext either way.
        XCTAssertEqual(app.fieldRowValue("Password"), "hidden")
        XCTAssertNotEqual(app.fieldRowValue("Password"), SampleVault.gmailPersonalPassword)
    }

    func testRevealingShowsThePasswordAndSelectionChangeResetsConcealment() {
        let app = launchUITestingApp(self)

        app.byID("list.entry.\(SampleVault.gmailPersonalID)").click()
        app.byID("detail.revealPassword").click()
        XCTAssertEqual(app.fieldRowValue("Password"), SampleVault.gmailPersonalPassword)

        // `RevealPolicy.revealAfterSelectionChange` (EntryDetailView.swift): a reveal never
        // survives a selection change, so a different entry's password must come up concealed
        // again with no re-toggle needed — this is the one guarantee a shoulder-surfer scenario
        // actually depends on.
        app.byID("list.entry.\(SampleVault.iCloudID)").click()
        XCTAssertEqual(app.fieldRowValue("Password"), "hidden")
    }

    /// **Saves and restores `NSPasteboard.general`'s real contents around this test** — see the
    /// `defer` below — so running the suite never costs whoever runs `make e2e` their actual
    /// clipboard.
    ///
    /// `PassSumoUITests` runs as its own separate, separately-sandboxed process
    /// (`PassSumoUITests-Runner.app`, distinct container from `PassSumo.app` — see the
    /// architecture contract and `Resources/PassSumoUITests.entitlements`), so "does this test
    /// process see what the app process copied" is a genuine empirical question, not a given.
    /// **Verified empirically, not assumed**, by actually running this test (see this suite's
    /// final report): App Sandbox gates *named/custom* pasteboards behind an entitlement, but does
    /// NOT gate the plain GENERAL pasteboard (`NSPasteboard.general`) — it is one systemwide
    /// service (`pboard`), not a per-container resource — so this test's own process reads it
    /// directly, no bridge through the UI needed. If that assumption is ever wrong (a stricter
    /// future sandbox profile, say), the `XCTWaiter` below times out and this test FAILS LOUDLY
    /// rather than silently reporting success on a value it never actually checked.
    func testCopyPasswordPutsTheRightValueOnThePasteboard() {
        // `savedItems` is a plain `Sendable` value ([String-keyed-`Data`] dictionaries) — captured
        // by `addTeardownBlock`'s `@Sendable` closure below, unlike `NSPasteboard` itself (an
        // AppKit reference type). Re-fetching `.general` fresh INSIDE the closure, rather than
        // capturing today's `pasteboard` local across that boundary, is what keeps this compiling
        // under Swift 6 strict concurrency without sending a non-`Sendable` reference across it.
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = NSPasteboard.general.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
        addTeardownBlock {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            for itemData in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in itemData { item.setData(data, forType: type) }
                pasteboard.writeObjects([item])
            }
        }

        let pasteboard = NSPasteboard.general
        let app = launchUITestingApp(self)
        app.byID("list.entry.\(SampleVault.gmailPersonalID)").click()
        // A known baseline distinguishable from the real password, so a false pass can't be
        // explained by "the pasteboard already happened to hold that string."
        pasteboard.clearContents()

        app.byID("detail.copyPassword").click()

        // `ClipboardService.copy` writes synchronously in the APP process; this test reads a
        // separate live view of the same systemwide pasteboard from the TEST process, so this
        // waits for that write to become observable here rather than asserting on a stale read.
        let sawExpectedValue = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in pasteboard.string(forType: .string) == SampleVault.gmailPersonalPassword },
            object: nil
        )
        let result = XCTWaiter().wait(for: [sawExpectedValue], timeout: 5)
        XCTAssertEqual(
            result, .completed,
            "the UI-test runner process never observed PassSumo's copy on NSPasteboard.general " +
            "within 5s — either Copy Password didn't fire, or (see this test's own doc comment) " +
            "the two sandboxed processes do NOT share the general pasteboard the way assumed"
        )
    }

    func testLockingReturnsToUnlockScreenAndTheEntryListIsGone() {
        let app = launchUITestingApp(self)
        XCTAssertTrue(app.byID("browser.list").waitForExistence(timeout: 5))

        app.byID("browser.lock").click()

        XCTAssertTrue(app.byID("root.unlock").waitForExistence(timeout: 5))
        XCTAssertFalse(app.byID("browser.list").exists)
        XCTAssertFalse(app.byID("list.entry.\(SampleVault.gmailPersonalID)").exists)
    }
}
