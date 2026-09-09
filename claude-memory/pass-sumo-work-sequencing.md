---
name: pass-sumo-work-sequencing
description: Why localization, multi-database support and the UI rewrite all wait on the design-system decision, and what gates autosave.
metadata:
  type: project
---

Ordering constraints settled 2026-09-09. None of them is visible from the code or from the issue
bodies on their own, and each concerns an issue that *looks* independent but is not.

- **Localization (#46) waits for the design pass (#3).** It has to route every user-visible string
  in `Sources/UI` through a String Catalog, and the design pass rewrites those same views. Landing
  it first means doing the extraction twice and reviewing a conflict in fourteen files. Order:
  palette approved → design system written → SwiftUI rewritten → strings extracted.
- **Autosave (#12) is gated on #27 merging**, not on its own open design questions. `VaultStore.save()`
  had no mutual exclusion, so building autosave on top of it would have automated the silent loss of
  edits. The fix is PR #53 (a chain of tasks). Start autosave only once that is in `main` — do not
  stack it on the unmerged branch.
- **Several open databases (#47) waits for #3 as well**, because choosing between one window per
  database and an in-window switcher is a window-chrome decision the design system owns.

**Why:** the owner asked for the design system first and for parallel work to be limited to what is
genuinely design-independent. These three are the ones that fail that test despite looking safe.

**How to apply:** before picking up #46, #47 or #12, check the gate above rather than starting from
the issue's own acceptance criteria. See also [[pass-sumo-memory-lives-in-repo]].
