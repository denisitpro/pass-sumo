# design/

Single home for everything design-related: the design system, design tokens, UX guidelines,
mockups, competitor reference screenshots, and logo/icon source art. Add subfolders as needed;
this file tracks what exists.

Layout convention follows `~/.claude/playbook/design.md` (this owner's cross-repo method): a
`design/BRAND.md` quick-ref, a `design/design-system.md` full spec (tokens, component contracts,
UX rules), a `design/tokens.json` if/when a second platform needs to consume the tokens, and a
`design/mockups/` of self-contained HTML screens signed off before any SwiftUI is written. Those
files land here once the design pass in issue #3 produces them — this README is the placeholder
for that work, not a promise of a particular file today.

## Subfolders

- `design/logo/` — logo and app-icon source art. Already in use.
- `design/reference/strongbox/` — competitor (Strongbox) reference screenshots, requested in
  issue #3, for information-architecture comparison only — not visual style or scope. Not yet
  populated; the owner captures these by hand (Strongbox is a native app with no UI-automation
  path).

## Boundary with `PassSumo/`

`design/` is a **repo-root** directory — the internal side of the line CLAUDE.md draws around
`PassSumo/` (the load-bearing rule: everything under `PassSumo/` must be publishable on its own).
Source art, working files, and UX/reference notes stay here. Only the assets the app actually
compiles from — e.g. the generated `AppIcon.appiconset` — live under `PassSumo/Resources/`. When
in doubt: if a future open-source consumer of just `PassSumo/` would need the file to build or run
the app, it belongs under `PassSumo/`; if it's source material, planning, or reference for
producing those assets, it belongs under `design/`.
