---
name: e2e-selectrow-must-click-the-row-cell
description: "selectRow must click the row cell (own identifier, or innermost containing cell), never an ancestor that merely contains list.entry.<uuid>; custom-drawn rows also need their own onTapGesture to write List(selection:)."
metadata:
  type: project
---

Two facts, established 2026-09-12 when `make e2e` ran for real (Developer Tools TCC now granted) and every test that selects an entry went red. Issue #134.

**1. `.containing(identifier).firstMatch` is the ancestor, not the row.** SwiftUI copies `.accessibilityIdentifier("list.entry.<uuid>")` onto every leaf inside the row, so a parent cell wrapping the whole entry list also matches `cells.containing(identifier == that uuid)`. `.firstMatch` is that parent. Clicking it hits the middle of the column. Gmail Personal sorts near the top; the column's centre is not that row. Sidebar tests still passed — that column has no such wrapping cell.

`selectRow` / `rightClickRow` go through `rowElement`: a cell whose **own** identifier is the target; else a containing cell no taller than two entry rows (a wrapping ancestor is hundreds of points tall); else the leaf. Do not walk `allElementsBoundByIndex` — that query hangs this suite.

**This agent session cannot `make e2e` directly.** `xcodebuild` from the grok shell loops on `DebuggerLLDB.DebuggerVersionStore.StoreError` and never launches a test (Developer Tools TCC is on Terminal.app, not on the agent). Launch via a `.command` file opened in Terminal (`open -a Terminal /tmp/pass-sumo-e2e.command`) and read `/tmp/pass-sumo-e2e.log`. Kill leftover `PassSumo -ui-testing` processes first — `killall xcodebuild` leaves the app under test running, and the next run then hangs.

**2. Custom-drawn rows do not write `List(selection:)` on a pointer click.** Same class as the sidebar in #129: zero `listRowInsets`, `.listRowBackground(.clear)`, own `entryRowSurface`. `#128`'s `Optional(entry.id)` tag is still required (a `List(data:)` auto-tag is non-optional `UUID` and can never land in a `UUID?` binding) but it is not sufficient. The row uses `.highPriorityGesture(TapGesture)` so List's own (no-op) click recogniser cannot swallow it. Double-click-to-edit stays a `.simultaneousGesture`.

**3. The AX cell is as wide as the list column, and `.inspector` covers the trailing end.** A centre-click lands in the inspector. `selectRow` clicks ~40pt from the leading edge.

**4. Do not read `FieldRow` through `XCUIElement.value`.** SwiftUI's `.accessibilityValue` comes back empty. Detail assertions use `waitForDetailContaining` (descendants of `browser.detail`).

#128 was the right diagnosis for the first e2e run and was never verified green on this mini (the suite could not start until the TCC grant). Do not "fix" this by wrapping the row in `.accessibilityElement(children: .combine)` — that was tried under #6 and silently stopped `List(selection:)` selecting at all.
