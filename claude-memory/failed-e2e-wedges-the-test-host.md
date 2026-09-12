---
name: failed-e2e-wedges-the-test-host
description: "`make e2e` cannot start on the Mac mini (no Developer Tools TCC grant) and a failed attempt wedges testmanagerd machine-wide, so no session can run any xcodebuild test until the owner resets the host."
metadata:
  type: project
---

Two facts about this Mac mini (`gamma@m4q1`), established 2026-09-10. Point 1 is **partially
stale as of 2026-09-12**: the owner granted Developer Tools TCC and `make e2e` now actually
runs (and fails on real assertions — see [[e2e-selectrow-must-click-the-row-cell]]). The wedge
in point 2 still applies if a run cannot *start*.

**1. Without the Developer Tools TCC grant, `make e2e` cannot start at all.** It fails with
`The test runner failed to initialize for UI testing. (Underlying Error: Timed out while
enabling automation mode.)`, and `com.apple.TCC` logs `Service kTCCServiceDeveloperTool does
not allow prompting; returning denied` (responsible: the terminal binary, e.g. iTerm2). That
service forbids a runtime consent dialog, so **no permission prompt ever appears** — it has to
be pre-granted by a human in System Settings → Privacy & Security → Developer Tools. Do not
wait for a dialog and do not try to work around TCC. Granted on this mini as of 2026-09-12.

**2. A failed attempt wedges `testmanagerd` for the whole machine, and it does not self-heal.** After
one failed attempt at 16:20, every hosted `xcodebuild test` on the machine executed **zero tests** —
signed and unsigned, unit and durability, in this repo and in an unrelated one belonging to another
session:

```
Timed out after 120.0s while initiating control session with daemon.   (or: while initializing logarchive)
<host> encountered an error (The test runner hung before establishing connection.)
** TEST FAILED **      make: *** [test] Error 65
```

The control: the same unsigned `make test` passed four times that afternoon before 16:20 (377 / 363 /
362 / 357 tests), and another session's runs passed at 16:02 and 16:13. A clean attempt at 17:19, with
`pgrep -fl xcodebuild` empty beforehand, still ran zero tests — so **waiting for processes to exit does
not fix it**. Recovery needs a `testmanagerd` restart or a re-login, which an agent session is not
permitted to do.

An early symptom line, `Accessibility: Not vending elements because elementWindow(25) is lower than
shield(2001)`, is a downstream effect, not the cause — later failures carry no shield line at all.

**Why:** attempting this suite opportunistically is not a cheap no-op. It costs every other session on
the machine its test runs until a human resets the host, and several sessions normally run `make test`
here — see [[pass-sumo-parallel-sessions-share-a-checkout]].

**How to apply:**

- Never fire `make e2e`, `make test-signed` or `make durability-signed` here without the Developer
  Tools grant in place and agreement from the other live sessions. `make test` and `make durability`
  remain the safe routine checks.
- Recognise the symptom instead of re-diagnosing it: a build that completes, a host that launches, and
  a 120-second daemon timeout with no `Executed N tests` line means the host is wedged, not that the
  code is broken. Report it as an environment failure and stop; do not retry in a loop.
- **The build phase still answers build questions.** A run wedged in the test phase has already
  finished compiling and linking, so `Ld` lines plus the absence of real `error:` lines prove the tree
  compiles even though no test ran. Filter this app's harmless `com.apple.linkd.autoShortcut` console
  noise before concluding anything about `error:` lines.
- Full details and the timeline live in issue #6.
