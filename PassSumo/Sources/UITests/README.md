# PassSumoUITests

XCUITest end-to-end suite for the PassSumo macOS app. Every test drives a REAL app window against
the `-ui-testing 1` fixture (`InMemoryVaultCodec` + `InMemoryVaultFileAccess`, pre-loaded with
`Vault.sample` — see `Sources/App/AppEnvironment.swift`'s `uiTesting()`), never a real `.kdbx` file
or real crypto.

## Running

    make e2e

This regenerates the Xcode project and runs the whole `PassSumoUITests` target. To run one file
(or one test method) only, call `xcodebuild` directly with `-only-testing:`:

    xcodebuild -project PassSumo.xcodeproj -scheme PassSumo -configuration Debug \
      -destination 'platform=macOS' \
      -only-testing:PassSumoUITests/BrowseAndSearchTests test

Swap the class name for `LaunchTests`, `EntryEditTests`, `SecretHandlingTests`, or
`GeneratorTests`; add `/testMethodName` after the class name to run a single test.

## Before you run it

- **This suite steals keyboard and mouse focus.** It drives a real window with real clicks and
  keystrokes — don't touch the keyboard or mouse on this Mac while it runs, and don't run it
  unattended on a machine you're also using for something else.
- **It needs a real windowserver session** — a logged-in GUI session, not a headless SSH/CI
  runner — and, the first time, a macOS Accessibility/Automation permission grant for whatever
  process invokes `xcodebuild` (Terminal, Xcode, or an agent's own shell). Without that grant the
  run fails outright rather than degrading silently.
- It is deliberately **not** part of `make test` or the routine CI path — see the `Makefile`'s own
  comments on `test` vs `e2e`. Run it explicitly when you specifically want to verify UI behavior
  end-to-end.

## What each file covers

- `LaunchTests.swift` — the app launches, the window exists, the sample vault is loaded.
- `BrowseAndSearchTests.swift` — sidebar groups, group filtering, entry selection/detail, search
  (including the password-field search differentiator), an empty search result.
- `EntryEditTests.swift` — edit / create / cancel / delete an entry, and the list's own Return-to-
  edit keyboard wiring.
- `SecretHandlingTests.swift` — password concealment/reveal, Copy Password → pasteboard, locking.
  The suite's most important file: a regression here is a real secret showing up somewhere it
  shouldn't, not just a broken UI flow.
- `GeneratorTests.swift` — the password generator sheet: length/entropy, "Use" fills the edit
  form's password field.
- `UITestSupport.swift` — shared launch helper, element lookup helpers, and `SampleVault` (hand-
  copied `Vault.sample` values these tests assert against — see its own doc comment on why this
  can't just `@testable import PassSumo` and reuse the real fixture).

## Conventions

- Every test launches its own `XCUIApplication` (`launchUITestingApp(self)`) and registers a
  teardown that terminates it. The in-memory fakes reset per launch (architecture contract,
  "Testing" section), and that guarantee only holds if no test's assertions run against a process
  a previous test left behind — tests never chain off each other's state.
- No `sleep`, anywhere. Waits are `waitForExistence(timeout:)` for anything in the view hierarchy,
  or `XCTNSPredicateExpectation` for the one case that isn't (`SecretHandlingTests`' pasteboard
  check — a view-hierarchy wait can't express "wait for a value on a resource outside the window").
- Elements are looked up by accessibility identifier or, where none exists, by accessibility label
  (`XCUIApplication.byID`/`.waitForLabel`/`.fieldRowValue` in `UITestSupport.swift`) — never by
  screen position, and never by matching a localized string that isn't also the identifier.
- **A plain SwiftUI `Text` puts its string in the accessibility VALUE, not the LABEL, on macOS.**
  Confirmed against the real AX tree captured from this suite's first run on actual hardware
  (issue #6) — every `StaticText` in the dump had an empty `label` and the string in `value`.
  `waitForLabel(_:)` matches label OR value for exactly this reason; `XCUIElement.textValue` (also
  in `UITestSupport.swift`) is the direct way to read a bare `Text`-backed element
  (`generator.result`, `generator.entropy`, …) — reading `.label` on one of those is always "".
- **A dense row's `.accessibilityIdentifier(...)` (`list.entry.<uuid>`, `sidebar.group.<uuid>`)
  lands on EVERY leaf Text/Image inside it, not just one element** — SwiftUI propagates an
  identifier to all of a view's accessibility children, confirmed against the real AX tree from
  issue #6's first run on actual hardware. `byID(_:)` resolves this with `.firstMatch` rather than
  requiring uniqueness, deliberately — see its own doc comment in `UITestSupport.swift`. **Wrapping
  each row in `.accessibilityElement(children: .combine)` was tried first and reverted**: it made
  the identifier unique again, but it also silently broke `List(selection:)`'s click-to-select —
  clicking a row stopped selecting it at all, which is a worse failure than an ambiguous id.
  `waitForElement(identifiedBy:containing:)` / `waitForEntryListRow(containing:)` read such a row's
  text by matching CONTAINS against whichever leaf carries it, scoped by the row's own identifier
  (or its prefix, for a row whose exact identifier isn't known ahead of time) — stronger than
  `waitForLabel(_:)` for list/row content: it proves the match belongs to that specific row, not
  merely to some text elsewhere on screen.

## Known accessibility-identifier gaps (as of this suite's writing)

These elements have no `.accessibilityIdentifier`, so nothing in this suite can target them
directly by id. Flagged for whoever owns `Sources/UI` next — not something this directory should
work around by adding identifiers itself:

- `VaultBrowserView`'s standalone toolbar "Generator" button — only reachable by its ⌘⇧G keyboard
  shortcut in a test, not by id. `GeneratorTests` sidesteps this by opening the (identical)
  generator sheet through `EntryEditView`'s "Generate…" button (`edit.generate`) instead.

**Closed since this list was written:**

- `EntryEditView.passwordField`'s reveal/hide eye button now carries `edit.revealPassword`,
  mirroring `detail.revealPassword` in `EntryDetailView`. Closed by issue #6: `edit.password`'s
  accessibility value is a run of bullet characters while concealed (a `SecureField`), so reading
  the REAL generated value back — what
  `GeneratorTests.testUsePutsTheGeneratedValueIntoTheEditFormsPasswordField` needs — requires
  revealing it first, and there was previously no id to click to do that.
- The search field. It used to be `.searchable`'s, whose toolbar item did not inherit the
  `"browser.search"` identifier set on the content column, so tests reached it through
  `app.searchFields.firstMatch`. Issue #87 replaced it with a field of this app's own in a centred
  toolbar item, which carries the identifier directly — the tests here look it up by id like
  everything else, and there is no longer an `XCUIElement` of type `searchField` to match.
