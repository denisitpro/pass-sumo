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

One injected seam, and it is not optional: backups go to `<Application Support>/PassSumo/Backups`
(see `VaultBackupStore`), which for an unsigned, unsandboxed run is the developer's own shared
Application Support. Every `SandboxedVaultFileAccess` this suite builds is therefore pointed at a
per-test scratch root — `DurabilityTestCase.backupRoot()`, passed to the helper as
`--backup-root` — so a run cannot litter or prune a directory it does not own. The per-database
subdirectory *inside* that root is still derived by the production code
(`VaultBackupStore.directoryName(for:)`), so a change to how backups are named cannot leave these
tests looking in a stale place and calling it "no backup".

The kill point is chosen by evidence, not by sleeping and hoping:

| Trigger | Fires on | Lands in |
|---|---|---|
| `.marker(save-begin)` | a line on the helper's stdout | the Argon2 derivation, before anything is written |
| `.backupAppears` | a file appearing in the backup directory | the backup copy |
| `.backupReaches(bytes:)` | the backup reaching full size | after the backup, before the write |
| `.atomicTemporaryAppears` | a sibling of the vault existing | inside `Data.write(options: [.atomic])` |
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

In-process, because the question is about the app's own orchestration. **This one found a real
defect, and now guards its fix** (issue #27 — see "Findings" below).

### `AtomicWriteTests.swift` — the atomic-write path under a sandbox

Establishes that `.atomic` replaces the file by `rename(2)` (the file's inode changes), that it
still does so when only the file — not its directory — is writable, and that the production save
path now completes under that same restriction, backup included. **This one found the other real
defect, and now guards its fix** (issue #26 — see "Findings" below).

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

Two real defects, both now fixed (issues #27 and #26), and these tests guard both fixes.

### 1. `VaultStore.save()` had no mutual exclusion
### *(found here, fixed in issue #27)*

`save()` was `@MainActor`, but its body was an awaited `Task.detached`. A second `save()` entering
during that suspension encoded and wrote alongside the first: measured peak overlap was 2. Two
backups were taken of the same pre-save file, and two atomic writes raced for the same path — the
loser's edits were silently discarded even though its `save()` reported success. The *file* was
never torn (each write is atomic, so one rename simply wins), so this was a lost-update bug, not a
corruption bug.

**What changed.** Saves are now chained: each `save()` appends a task that awaits the previous
one's completion before touching the vault, and the read-modify-write of that chain's tail happens
on the main actor with no suspension point in between, so it cannot race. The expensive work still
runs in a detached task, so a queued save waits off the main actor. A save asked for during another
one waits and then encodes the state as of when it **runs** — never coalesced into the in-flight
save, which has already taken its snapshot and provably does not contain the later edits. And the
honesty half: a save clears `isDirty` only if nothing was edited after the snapshot it wrote, so an
edit that landed during the KDF is no longer reported as being on disk.

`testTwoConcurrentSavesDoNotOverlap` asserts peak overlap is 1 through the real stack; its
`XCTExpectFailure` is gone. The lost update itself, and the dirty-flag half, are pinned
deterministically in `UnitTests/VaultStoreSaveSerializationTests` — that suite can hold a fake
codec *inside* the critical section instead of racing a real Argon2 derivation, so all three
assertions fail on the old code for the right reason rather than by timing luck.

### 2. Under a file-scoped sandbox grant, the save failed — at the BACKUP, not the atomic write
### *(found here, fixed in issue #26)*

This was the open question issue #22 raised, and the answer was the opposite of the hypothesis.

- `Data.write(options: [.atomic])` is **fine**. Watching the directory during a 300 MB atomic write
  shows a `v.kdbx.sb-<hex>-<rand>` sibling appear when the process is unrestricted and **no sibling
  at all** when the same write runs under a grant covering only the file — yet the inode still
  changes both times. Foundation falls back to a temporary file the sandbox permits and renames from
  there.
- The backup was **not** fine. `SandboxedVaultFileAccess` copied the vault to
  `<name>.kdbx.bak-<stamp>` *next to the vault*, which means creating a new file in a directory the
  app was never granted. Under a file-only grant the save failed with
  `io("failed to back up …: you don't have permission to access …")` — and since the backup runs
  before the write it protects, the user could not save at all.

**What changed.** Backups moved into the app's own container, at
`<Application Support>/PassSumo/Backups/<database name>-<hash of its path>/`, obtained from
`FileManager` — no entitlement, and none to be added: a file-access entitlement claimed to make a
write the user never chose is what got the sibling app ShotSumo rejected under App Review Guideline
2.4.5(i). And the behavioural half: a backup that fails no longer aborts the save. `write` returns
a `VaultBackupOutcome`, `VaultStore` keeps the reason in `lastBackupError`, and `StatusBar` shows
it — the save proceeds and the user is told it went to disk unprotected. See `VaultBackupStore` for
the destination, the per-database identity and the retention caps.

`testProductionSavePathSucceedsUnderAFileOnlyGrantBecauseBackupsLiveInTheContainer` is the
regression test. It is the same case that used to assert the failure, and it now requires four
things: the save completes, a backup was actually made (a "fix" that stopped taking one would pass
the first assertion alone), the backup is the *pre-save* version, and **nothing at all** was
written beside the vault — a fallback that tried the sibling "just in case" would reintroduce the
whole defect.

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

  Since issue #26 this caveat matters less than it did, and it is worth being precise about why.
  The fix does not depend on knowing a powerbox grant's exact scope: the app no longer writes
  **anything** into the vault's directory, so the only write left there is the atomic replacement
  of a file the user explicitly picked — which is the narrowest thing any grant for that file can
  possibly permit. What is still unverified is the interactive path end to end: nobody has yet
  opened a database through `NSOpenPanel` in a signed build, saved, and watched the backup land.
  That needs a human at the keyboard.
- **The real container IS covered, and only under `make durability-signed`.**
  `testAtomicWriteWorksInsideTheRealAppSandboxContainer` is the one test that writes through the
  PRODUCTION backup policy — no injected root — and asserts the resulting file is under
  `Library/Application Support/PassSumo/Backups`. That is the premise the whole of issue #26's fix
  rests on (the app can always write its own container, with no file-access entitlement), so it is
  checked against a genuine App Sandbox rather than modelled. It skips under `make durability`,
  where there is no container to check.
- **`make durability` runs unsigned, so the host has no sandbox at all.** An unsigned build gets no
  entitlements and therefore no container. `testAtomicWriteWorksInsideTheRealAppSandboxContainer`
  skips there with that message and only runs under `make durability-signed`. Even then it covers
  the app's own container, which the app owns outright — not a file-scoped grant. That is not a
  weakness any more, it is the point: the container is where backups go, so that test is the one
  real-sandbox evidence the fix has (see the bullet on it above).
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
  exFAT stick, a disk image) a kill mid-copy **would** leave a truncated backup that retention
  counts as one. This suite cannot reach such a volume; the tests state where the guarantee comes
  from so nobody mistakes it for ours. Note that the destination is now the app's container, so in
  practice this is the container's filesystem — APFS on any Mac that ships today, but a guarantee
  of the volume's, still not ours.
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

Measured: **22 tests, ~27 s** of test time, against `make test`'s 233 tests in ~24 s. So it roughly
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
