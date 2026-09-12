---
name: e2e-selectrow-must-click-the-row-cell
description: "selectRow must click the row cell (own identifier, or innermost containing cell), never an ancestor that merely contains list.entry.<uuid>; custom-drawn rows also need their own onTapGesture to write List(selection:)."
metadata:
  type: project
---

Two facts, established 2026-09-12 when `make e2e` ran for real (Developer Tools TCC now granted) and every test that selects an entry went red. Issue #134.

**1. `.containing(identifier).firstMatch` is the ancestor, not the row.** SwiftUI copies `.accessibilityIdentifier("list.entry.<uuid>")` onto every leaf inside the row, so a parent cell wrapping the whole entry list also matches `cells.containing(identifier == that uuid)`. `.firstMatch` is that parent. Clicking it hits the middle of the column. Gmail Personal sorts near the top; the column's centre is not that row. Sidebar tests still passed — that column has no such wrapping cell.

`selectRow` must prefer a cell whose **own** identifier is the target, otherwise the leaf. Do not use `.containing(identifier).firstMatch` (the ancestor) and do not walk `allElementsBoundByIndex` to pick the smallest containing cell — that query hangs this suite.

**2. Custom-drawn rows do not write `List(selection:)` on a pointer click.** Same class as the sidebar in #129: zero `listRowInsets`, `.listRowBackground(.clear)`, own `entryRowSurface`. `#128`'s `Optional(entry.id)` tag is still required (a `List(data:)` auto-tag is non-optional `UUID` and can never land in a `UUID?` binding) but it is not sufficient. The row needs `.onTapGesture { selectedEntryID = entry.id }`, matching `GroupSidebar`. Double-click-to-edit stays a `.simultaneousGesture` on the inner row so it does not replace that single tap.

#128 was the right diagnosis for the first e2e run and was never verified green on this mini (the suite could not start until the TCC grant). Do not "fix" this by wrapping the row in `.accessibilityElement(children: .combine)` — that was tried under #6 and silently stopped `List(selection:)` selecting at all.
