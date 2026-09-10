---
name: pass-sumo-design-system-docs
description: Where the design system lives after issue #3 — an index plus focused siblings under design/, what each owns, and the two things the approved mockup must NOT be read as.
metadata:
  type: project
---

Written 2026-09-09 with issue #3. The shape here is not guessable from the file names.

- **The spec is not one file.** `design/design-system.md` is an **index**; the substance lives in
  `components-controls.md`, `components-data.md`, `components-chrome.md`, `screens.md`,
  `ux-rules.md`, `keyboard-map.md`, `accessibility.md` and `tone-of-voice.md`, all in `design/`.
  One document would have been several times the docs convention's 200-line cap. The cut follows
  who edits what: a new button role touches only the controls file, a shortcut audit only the
  keyboard map. `design/README.md` lists every file; the divergence from the playbook's single
  `design-system.md` is recorded there under its non-blocking clause.
- **No design document restates a token value.** `design/BRAND.md` owns every hex, size and
  measured contrast ratio; the spec names tokens (`accent-600`, `space-5`, `field-height`) and even
  states the contrast *rule* without repeating the figures. If you catch yourself writing a number
  into one of these files, it belongs in BRAND.md instead — or it is already there.
- **The approved mockup is a PALETTE reference and nothing more.** Two traps:
  1. **It is not a keyboard specification.** `palette-variants.html` annotates its buttons with ⌘N,
     ⌘G, ⌘B, ⌘C, ⌘⌫, ⌘⇧R, ⌘U and ⌘T. Only ⌘F matches the shipped app; the rest are bound to
     something else or to nothing. Read bindings off `AppCommands.swift`, never off the mockup.
     Settling the real set is issue #16 and needs the owner's go-ahead.
  2. **It is not a component specification either.** Where the code and the mockup disagree, the
     disagreement is *recorded* in the spec (strength meter, toolbar grouping, the TOTP meta line,
     the unlock screen showing both Touch ID affordances at once) rather than silently resolved.
     Do not "fix" the code to match the mockup without a decision.
- **The undecided parts are issues, not gaps in the prose:** #60 disabled-control appearance
  (`control-disabled-opacity` is the one invented token), #61 strength meter and its two threshold
  sets, #62 the unlock screen never says why the vault locked, #63 no mockup for Welcome / edit
  sheet / Settings, #64 no focus indicator on custom buttons, #65 custom fields have no protected
  flag, #66 the two unverified rendering assumptions from PR #59.

**How to apply:** for a UI task, read `design/design-system.md` and follow its table to the one file
that answers the question — not the whole tree. Read `BRAND.md` only when you need a value. See also
[[pass-sumo-palette-decision]].
