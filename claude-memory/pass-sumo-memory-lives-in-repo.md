---
name: pass-sumo-memory-lives-in-repo
description: "pass-sumo's AI memory is committed inside the repo so it travels between the owner's two Macs"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3743f4a3-edf2-4c67-9244-5505e180e8bd
  modified: 2026-08-30T08:02:10.303Z
---

Anything worth remembering about pass-sumo goes into `claude-memory/` **inside the repository**, not
into a machine-local Claude store. The owner works on two machines — `beta@m4a4` (MacBook, has Touch
ID, GPG keys, the full `~/git`) and `gamma@m4q1` (Mac mini, pet projects) — and a note that lives
only in one machine's local state is lost the moment work moves to the other.

`~/.claude/projects/<path-slug>/memory` is a symlink to `<repo>/claude-memory/`, maintained
automatically by the SessionStart hook on each machine with that machine's own slug. Never create or
repair that symlink by hand; if the directory is real rather than a symlink, the hook migrates it on
the next session start.

For the memory to actually reach the other machine it has to be **committed and merged** — writing
the file is only half of it. It rides in whatever PR is open; the owner merges.

**Why:** the owner explicitly asked for this so cross-device context is not lost, and it is the
reason issue #21 (Touch ID hardware validation on the MacBook) can be picked up cold.

**How to apply:** when a fact about this project is non-obvious and not derivable from the code or
git history, write it to `claude-memory/` and include it in the current PR.

Related: [[touchid-cross-machine-context]]
