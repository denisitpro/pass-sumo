# Tone of voice

> Status: living · Last verified: 2026-09-09 · [AI - claude-opus-5]

Derived from the strings the app already ships and from the positioning in `CLAUDE.md`: privacy
focused, anti-bloat, "what Strongbox was before the feature creep".

## The register

**Plain, technical, unexcited.** The user chose a KDBX manager on purpose and wants to know what
happened, not to be reassured. No exclamation marks, no "Oops", no "Great!", no emoji anywhere in
the UI. Nothing is congratulated and nothing is apologised for.

**Say the thing, then stop.** One sentence per state is the norm: "This group has no entries yet."
"Wrong password. Try again." "Open a database to set up Touch ID unlock." A second sentence appears
only when the first leaves the user unable to act.

**Name the machinery.** Paths, byte counts, bit counts, KDBX terms and UUIDs are shown in the words a
technical user already uses — the attachment-size refusal explains its limit by naming the mechanism
("the whole database is held in memory while unlocked and rewritten on every save") rather than by
calling it a policy.

**Nothing is sold.** No purchase prompts, no rating prompts, no banners, no "Pro" language, and no
label promising a feature the app does not have.

## Wording rules

- **Sentence case, and a full stop on a sentence.** Buttons and labels are title case ("Copy
  Password", "Empty Recycle Bin…"), messages are sentences with terminal punctuation.
- **A trailing ellipsis means "this opens something first".** "Open Database…", "Add File…",
  "Choose Location & Create…", "Generate…", "Empty Recycle Bin…" all lead to a panel, a sheet or a
  confirmation. A button that acts immediately has none: "Unlock", "Save", "Copy", "Regenerate".
- **Buttons are verbs; a destructive one repeats the verb.** The confirmation for a permanent delete
  is "Delete Permanently", not "OK" — the button says what it will do, so the dialog's message does
  not have to be re-read.
- **State the consequence, not the risk.** "Deleting it now removes it from this database for good —
  there is no undo." Never "Are you sure?".
- **Never claim protection the app does not provide.** The pasteboard sensitivity markers are a
  request to other software and to the OS, honoured by convention and nothing else; they must never
  be described to a user as protection. The same restraint applies to the strength meter, which is
  always qualified as a "rough guide" because it is a generous upper bound with no dictionary behind
  it.
- **Both halves of a partial success.** "Saved, but no backup: …" — the data is safe *and* the copy
  was not made. A message that reports only one half of a two-part outcome is wrong even when every
  word in it is true.

## Error messages

The hard-won rule, from issue #30, and it is the one to read before writing any new error string:

> **A `VaultError` message must not name a cause the error does not carry.**

`corruptedInnerHeader` was once mapped to "the database's attachment table is damaged", and it told
the owner his attachments were broken when the file was fine — the KDBX 4 inner header holds the
attachment pool *and* the inner random-stream parameters, so the error identified a stage, not a
cause. So:

- **Report the stage that failed, never a guessed why.** No verdict prefix like "looks corrupted" on
  a case that has several non-corruption causes.
- **Two payloads, two lines.** The human sentence is what the screen leads with; the library's own
  raw text goes in a separate `diagnostic:` slot, rendered quieter, monospaced and **selectable** so
  it can be pasted into a bug report. Library enum text never goes in the first line.
- **The wording lives in the presentation layer**, not on the error type: `VaultError` stays flat and
  directly displayable, and one `displayMessage` switch serves every screen so two screens cannot
  drift apart.
- **A different situation gets its own sentence, not a reused one.** A failed backup does not borrow
  "Couldn't read the file" — for that case it would say the opposite of what happened.
- **Name the file, never the payload.** An attachment error names the filename and the system's own
  reason; nothing about the bytes is shown or logged.
- **Never swallow a failure, and never block on one.** If something is silently ignorable it gets no
  message; if it is not, it gets a visible one that persists as long as the condition does.
