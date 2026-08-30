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

## Known accessibility-identifier gaps (as of this suite's writing)

These elements have no `.accessibilityIdentifier`, so nothing in this suite can target them
directly by id. Flagged for whoever owns `Sources/UI` next — not something this directory should
work around by adding identifiers itself:

- `VaultBrowserView`'s standalone toolbar "Generator" button — only reachable by its ⌘⇧G keyboard
  shortcut in a test, not by id. `GeneratorTests` sidesteps this by opening the (identical)
  generator sheet through `EntryEditView`'s "Generate…" button (`edit.generate`) instead.
- `EntryEditView.passwordField`'s reveal/hide eye button — no id, unlike its read-only counterpart
  `detail.revealPassword` in `EntryDetailView`. Not currently a blocker for any test in this suite,
  since `edit.password`'s accessibility VALUE is read directly regardless of which mode
  (`SecureField`/`TextField`) it's rendered in.
- `VaultBrowserView`'s `.searchable` search field: the `"browser.search"` identifier is set on the
  content column (`EntryListView` + the `.searchable` modifier), not on the resulting toolbar
  search control itself — SwiftUI's `.searchable` toolbar item doesn't appear to inherit it. Tests
  here use `app.searchFields.firstMatch` instead, which works but means `"browser.search"` isn't
  actually reachable as documented.
