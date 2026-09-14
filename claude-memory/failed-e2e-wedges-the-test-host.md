---
name: failed-e2e-wedges-the-test-host
description: "`make e2e` cannot start unattended on the Mac mini (two gates, the second needs a person), and a failed attempt wedges testmanagerd machine-wide until someone SIGKILLs the host daemon."
metadata:
  type: project
---

Three facts about this Mac mini (`gamma@m4q1`), last re-established 2026-09-14 when a parallel
session's `make e2e` in another repo wedged testing for every session on the machine.

**1. `make e2e` cannot start here unattended, and there are TWO gates, not one.** Read out of
`log show` during a live failure:

```
tccd: AUTHREQ_ATTRIBUTION: accessing={identifier=<app>.uitests.xctrunner, …},
      requesting={identifier=com.apple.syspolicyd, …}
tccd: Service kTCCServiceDeveloperTool does not allow prompting; returning denied.
testmanagerd: Test session with pid … requesting automation mode
testmanagerd: Enabling Automation Mode...
coreautha (com.apple.LocalAuthentication) …
→ Failed to initialize for UI testing … Timed out while enabling automation mode.  (60 s, exit 65)
```

Gate 1 is the TCC Developer Tools grant, and it **cannot prompt** — no dialog ever appears; it has
to be pre-granted in System Settings → Privacy & Security → Developer Tools. Gate 2 is a
LocalAuthentication evaluation behind `testmanagerd`'s automation-mode request. **The gate-1 denial
does not abort the attempt** — the run continues and dies on gate 2, which is what burns the 60
seconds. Do not read the TCC denial as the cause.

`automationmodetool` reports "Automation Mode is disabled. This device requires user authentication
to enable Automation Mode" and `/var/db/com.apple.dt.automationmode/` is empty — so **nothing
durable was granted on 2026-09-12**, and this note's earlier claim that "the suite now actually
runs" was an inference too far. Whatever made that run work (it was launched via `open -a Terminal`
with a `.command` file — see [[e2e-selectrow-must-click-the-row-cell]]) did not persist, and the
two records name different processes in different roles, so they are not one event seen twice.
**Nobody has demonstrated a configuration on this Mac where gate 2 is satisfied without a person
present. Do not invent one.** The only reported durable fix is
`sudo automationmodetool enable-automationmode-without-authentication` — a machine-level security
setting, the owner's decision, never an agent's.

**2. A failed attempt wedges `testmanagerd` for the whole machine.** After one, every hosted
`xcodebuild test` on the Mac executes **zero tests** — signed and unsigned, unit and durability, in
every repo and every session:

```
Timed out after 120.0s while initiating control session with daemon.
<host> encountered an error (The test runner hung before establishing connection.)
** TEST FAILED **      (one observed hang ran 704 s before failing)
```

Confirmed across three repos on 2026-09-14: another session's suite was green minutes before the
e2e attempt and hung afterwards with nothing changed in its tree.

**3. Recovery: SIGKILL the HOST daemon, then prove it with a real run.**

```
pgrep -fl testmanagerd     # there are usually TWO — see the warning below
kill -9 <host pid>         # SIGTERM is ignored; launchd respawns on demand
```

**Never `killall testmanagerd`.** It matches by name, and a running iOS Simulator has its own
daemon (`…/Runtimes/iOS <ver>.simruntime/…/usr/libexec/testmanagerd`); killing that destroys
another session's in-flight suite. Kill the `/usr/libexec/testmanagerd` PID only, and only after
checking with the other live sessions that nothing is mid-run.

Verification is a **real test run**, not the daemon reappearing in `pgrep`:
`Executed N tests, with 0 failures` plus `** TEST SUCCEEDED **`. Two traps when checking that —
`-only-testing:` with a class name that does not exist reports `Executed 0 tests` **and exit 0**,
which looks exactly like the wedge, and `make … ; echo $?` reports the echo's status, not make's.
An iOS Simulator suite was observed running normally while the host daemon was wedged: one
observation, not a proven independence of the two automation paths.

**Why:** attempting this suite opportunistically is not a cheap no-op. It costs every other session
on the machine its test runs until someone kills the daemon, and several sessions normally run
`make test` here — see [[pass-sumo-parallel-sessions-share-a-checkout]].

**How to apply:**

- Never fire `make e2e`, `make test-signed` or `make durability-signed` here unattended, and agree
  it with the other live sessions first. `make test` and `make durability` remain the safe routine
  checks; neither steals focus.
- Recognise the symptom instead of re-diagnosing it: a build that completes, a host that launches,
  and a 120-second daemon timeout with **no `Executed N tests` line** means the host is wedged, not
  that the code is broken. Report it as an environment failure and stop; never retry in a loop, and
  never start rewriting working code to chase it.
- **The build phase still answers build questions.** A run wedged in the test phase has already
  compiled and linked, so `build-for-testing` plus the absence of real `error:` lines proves the
  tree compiles even though no test ran.
- Full details and the original timeline live in issue #6.
