# Durability / crash-safety suite

> Issue [#22](https://github.com/denisitpro/pass-sumo/issues/22). Run it with `cd PassSumo && make durability`.

The other suites test *logic*. This one tests what the `.kdbx` file on disk looks like when the
process dies in the middle of a save — the failure that loses a user's entire password database,
and the one nothing else here covers.

## How it works

`XCUITest` is not used, deliberately. It cannot `SIGKILL` its target at a chosen instant, which is
the entire point, and that suite has never successfully run on this machine anyway (issue #6).

Instead:

- **`Sources/DurabilityHelper`** — a small command-line executable that opens, edits and saves a
  database. It compiles `Sources/Model` and `Sources/KDBX` — the same files the app builds, not a
  copy — and drives them through the real `VaultStore` → `KDBXKitCodec` → `SandboxedVaultFileAccess`
  path. The only addition is a `VaultFileAccess` decorator that prints a stage marker either side of
  the one call that touches the user's file.
- **`Sources/DurabilityTests`** — spawns that helper and kills it at a controlled point, then
  reopens whatever is on disk with the real codec.

The kill point is chosen by evidence, not by sleeping and hoping:

| Trigger | Fires on | Lands in |
|---|---|---|
| `.marker(save-begin)` | a line on the helper's stdout | the Argon2 derivation, before anything is written |
| `.backupAppears` | the `.bak-` file existing | the backup copy |
| `.backupReaches(bytes:)` | the backup reaching full size | after the backup, before the write |
| `.atomicTemporaryAppears` | a sibling temp file existing | inside `Data.write(options: [.atomic])` |
| `.delayAfterSaveBegin(_:)` | a stopwatch | anywhere — the shotgun sweep |

Every kill test then asserts which stages the helper *actually reached*, so a kill that arrives too
late fails loudly instead of passing for the wrong reason.

One case has no race in it at all: `--hang-at write-begin` tells the helper to park forever at a
stage boundary, so the kill window is unbounded. That is what
`testKillAfterEncodingButBeforeAnyDiskWriteLeavesTheFileByteIdentical` uses. The other triggers win
their races by a wide margin (a millisecond against a hundred) and prove it by which markers
arrived; this one cannot lose.

## What each file proves

### `TornWriteTests.swift` — the file is never left torn

Kills a real save at each of the points above and asserts the database is either the complete old
version or the complete new version: it exists, it is non-empty, and the real codec decodes it to a
vault whose entries are one of the two expected sets. Also asserts that a kill during the KDF leaves
the file *byte-identical* (nothing has been written yet), and that every backup left behind is
itself complete and openable.

### `ConcurrentSaveTests.swift` — two saves must not overlap

In-process, because the question is about the app's own orchestration. **This one records a real
defect** — see "Findings" below.

### `AtomicWriteTests.swift` — the atomic-write path under a sandbox

Establishes that `.atomic` replaces the file by `rename(2)` (the file's inode changes), that it
still does so when only the file — not its directory — is writable, and what the production save
path does under that same restriction. **This one records the other real defect.**

### `FormatConformanceTests.swift` — what we write is conformant, and safe

Header bytes declare KDBX 4.1; a file that survived a kill still opens in `keepassxc-cli`; backups
open in `keepassxc-cli`; and — the highest-stakes assertion in the suite — **the inner random-stream
key is regenerated on every save**, checked on the protected fields' ciphertext taken straight out
of the decrypted XML before the inner stream is applied. That test carries its own negative control
(`testTheInnerStreamCheckWouldActuallyCatchAReusedKey`), which reproduces the defect on purpose with
`regenerateSalts: false` and requires the check to detect it.

### `HostileInputTests.swift` — damaged and hostile files

Bit-flips inside the encrypted body (must fail the HMAC *before* any decryption), truncation past an
intact header, and a header demanding 64 GiB of Argon2 memory (must be refused before the KDF runs,
without allocating anything). Deliberately does not repeat what
`UnitTests/KDBXCodecTests.testMalformedHeadersThrowWithoutTrapping` already covers.

## Findings

Two real defects, both reported rather than fixed — fixing either is a separate decision.

### 1. `VaultStore.save()` has no mutual exclusion

`save()` is `@MainActor`, but its body is an awaited `Task.detached`. A second `save()` entering
during that suspension encodes and writes alongside the first: measured peak overlap is 2. Two
backups are taken of the same pre-save file, and two atomic writes race for the same path — the
loser's edits are silently discarded even though its `save()` reported success. The *file* is never
torn (each write is atomic, so one rename simply wins), so this is a lost-update bug, not a
corruption bug.

Recorded as a strict `XCTExpectFailure` in `testTwoConcurrentSavesDoNotOverlap`, so the suite stays
usable as a gate and the moment `save()` starts serialising, that test fails and forces the note to
be removed.

### 2. Under a file-scoped sandbox grant, the save fails — at the BACKUP, not the atomic write

This was the open question issue #22 raised, and the answer is the opposite of the hypothesis.

- `Data.write(options: [.atomic])` is **fine**. Watching the directory during a 300 MB atomic write
  shows a `v.kdbx.sb-<hex>-<rand>` sibling appear when the process is unrestricted and **no sibling
  at all** when the same write runs under a grant covering only the file — yet the inode still
  changes both times. Foundation falls back to a temporary file the sandbox permits and renames from
  there.
- `SandboxedVaultFileAccess.makeBackupIfNeeded` is **not** fine. It copies the vault to
  `<name>.kdbx.bak-<stamp>` *next to the vault*, which means creating a new file in a directory the
  app was never granted. Under a file-only grant the save fails with
  `io("failed to back up …: you don't have permission to access …")`.

The failure is safe — the database is left byte-identical, and `VaultStore` leaves `isDirty` set so
the user is not told their edits are saved — but the user cannot save at all. If a real
powerbox grant for a user-picked file is file-scoped (see the caveat below), this is a shipping
blocker. The fix would be to put backups somewhere the app can always write (its container) or to
ask for a directory grant; neither is done here.

## What this suite does **not** prove

Read this before treating a green run as an all-clear.

- **It is not a power-loss test.** `SIGKILL` kills the process; it does not stop the kernel.
  Anything already handed to the page cache is still written out, and nothing here calls `fsync`,
  so a real power cut can still lose a rename that this suite would see as durable. Testing that
  needs a VM whose virtual disk can be cut, or a kernel fault injector.
- **The App Sandbox tests use a Seatbelt model, not a powerbox grant.** The App Sandbox cannot be
  entered on demand: a grant for a user-picked file comes from `NSOpenPanel`, which needs a human.
  `AtomicWriteTests` reproduces the filesystem restriction with `sandbox-exec` and a profile that
  permits writing one file and forbids creating anything in its directory — the same kernel MAC
  layer the App Sandbox is built on, applied by hand. It does **not** prove that a
  powerbox-issued extension has exactly that scope. The profile self-checks that it actually bites
  before any assertion relies on it.
- **`make durability` runs unsigned, so the host has no sandbox at all.** An unsigned build gets no
  entitlements and therefore no container. `testAtomicWriteWorksInsideTheRealAppSandboxContainer`
  skips there with that message and only runs under `make durability-signed`. Even then it covers
  the app's own container, which the app owns outright — not a file-scoped grant.
- **The two runs cover different things, and neither covers everything.** Measured:
  `make durability` = 22 tests, 1 skipped (the real-container one), 0 failures.
  `make durability-signed` = 22 tests, 4 skipped, 0 failures — the container test runs and passes,
  and four others skip because a sandboxed host cannot do what they need: it cannot launch
  `sandbox-exec` (no nesting a Seatbelt sandbox inside the App Sandbox — the child produces no
  output at all), and its filesystem calls are slow enough through the sandbox's MAC checks that the
  directory watcher stops catching the atomic write's temporary file. Those skip loudly rather than
  degrading into an assertion that would pass without testing anything.
- **APFS is doing some of the work.** `FileManager.copyItem` on APFS issues `clonefile(2)` — 1 GiB
  cloned in ~2 ms, measured — so the backup is complete the instant it exists and can never be
  observed half-written. On a volume where `copyfile` falls back to a byte copy (a network share, an
  exFAT stick, a disk image) a kill mid-copy **would** leave a truncated `.bak-` file that the
  rotation counts as a backup. This suite cannot reach such a volume; the tests state where the
  guarantee comes from so nobody mistakes it for ours.
- **Removable / external volumes are not covered.** Issue #22 asks for the kill tests to be repeated
  on one, since `rename(2)`'s atomicity is a filesystem guarantee. That needs a volume that is not
  present on a CI machine or reliably on the owner's.
- **Autosave is not covered** — it does not exist yet (issue #12). When it does, it multiplies the
  number of writes and therefore the exposure to everything above, and these tests should be
  repeated against it.
- **Relaunch behaviour after a force quit is not covered.** Issue #22 asks that the app not present
  stale state or silently discard edits on relaunch. The data-layer half is covered here (what is on
  disk after a kill is always a complete previous or new version, never stale or partial), but
  "tells the user their unsaved edits were lost" is UI behaviour that does not exist yet — there is
  no crash-recovery or unsaved-state persistence in the app to test.
- **It does not test the UI at all.** Nothing here drives a window, a menu or a save command.

## Cost, and why it is not in `make test`

Measured: **22 tests, ~28 s** of test time, against `make test`'s 217 tests in ~24 s. So it roughly
doubles the routine check — real, but not the main reason it is separate.

The reason it is separate is that it is a different kind of test. It spawns subprocesses and
`SIGKILL`s them, it writes and copies 8 MB files, and two of its cases depend on tools that may not
be installed (`keepassxc-cli`) or permitted (`sandbox-exec`) — none of which belongs in the check
every contributor runs on every edit. Run it on any change to the save path, the codec, or
`SandboxedVaultFileAccess`.

## Secrets

Every database this suite creates lives in a per-test temporary directory that `tearDown` deletes.
The master password is a literal in the test source (`durability-suite-password`) — not a secret,
since the databases contain only entries this suite invented, and a literal rather than a random
string so a failing run leaves something the owner can open by hand. No plaintext is ever printed:
the helper's markers carry stage names and file sizes, never vault contents.
