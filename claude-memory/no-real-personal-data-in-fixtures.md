---
name: no-real-personal-data-in-fixtures
description: "Never put the owner's real personal data in test databases, sample data, fixtures or mockups — it leaks into screenshots and the App Store."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4a02d8bb-f54e-4faf-abc4-30e592260ef0
  modified: 2026-09-10T11:35:22.937Z
---

Never write the owner's real personal data — surname, given name, real email addresses, real
account names — into a test database, sample/preview data, a test fixture, or a design mockup.
Use obviously synthetic values only (`Sample`, `user@example.com`, `example.com`).

**Why:** anything in a fixture surfaces in screenshots, in PR attachments, in SwiftUI previews and
in the App Store screenshot set (#76) — so personal data placed there leaks publicly. The owner
stated this forcefully on 2026-09-10 and forbade it outright.

**How to apply:** when seeding or opening a database for verification, invent the data. Never open
one of the owner's own databases (`test1-db.kdbx`, `testDB.kdbx` and friends in `~/Downloads` are
HIS) for a screenshot. Before attaching any screenshot to a PR, look at what is actually in the
frame.

Already-committed violations found on 2026-09-10, pre-dating this rule (reported to the owner, left
untouched pending his decision): `PassSumo/Sources/Model/Domain.swift` sample entries,
`PassSumo/Sources/UITests/UITestSupport.swift`, `design/mockups/palette-variants.html`. Note that
`Sources/Model` is the shipping app target, not a test target — see
[[pass-sumo-work-sequencing]] and [[pass-sumo-strongbox-is-the-reference]].
