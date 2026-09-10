---
name: pass-sumo-parallel-builds-share-log-paths
description: Why a subagent's `make test` count can belong to a different agent's build, and the capture pattern that prevents it.
metadata:
  type: feedback
---

When several agents build this repo at once, a brief that says `make test > /tmp/run.log 2>&1`
hands every one of them **the same file**. Two concurrent `xcodebuild` runs then interleave into one
log, and an agent reads a total that is not its own — verified 2026-09-10, when one agent's capture
contained 210 path references to a *different* agent's worktree and zero to its own, and a later
capture held two totals (283 and 290) from two builds.

`make test` passes no `-derivedDataPath`, so Xcode's per-project-path default keeps the *build*
products separate. The collision is only in the log file, which makes it worse, not better: the
builds are genuinely independent and only the reported number is wrong.

**Why:** a test count is the main evidence a delegated change is safe, and this failure mode
produces a plausible wrong number rather than an error.

**How to apply:** in every brief, give the agent a capture path unique to it and tell it to prove
the log is its own. `rtk proxy make -C /abs/path/to/its/worktree/PassSumo test > /tmp/<tag>-$$.log 2>&1`,
then grep the log for its own worktree path and for the names of the tests it added. Invoke make with
`-C <absolute path>` rather than relying on `cd`. Related: [[pass-sumo-parallel-sessions-share-a-checkout]].
