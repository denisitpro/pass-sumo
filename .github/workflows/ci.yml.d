name: CI

# Cancel a superseded run for the same branch/PR — macOS runners are the scarcest/most expensive
# GitHub-hosted runner type, no point burning minutes on a build a newer push already obsoletes.
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

on:
  push:
  pull_request:
  # Manual trigger only exists so the e2e job below can be run on demand; it has no effect on the
  # other jobs, which already run on every push/pull_request.
  workflow_dispatch:

# All third-party actions below are pinned to a commit SHA, never a tag. A tag (even `v4`) can be
# force-moved by the action's maintainer (or an attacker who compromises their account) to point at
# malicious code with no changes required on our side — a real supply-chain vector, and one this
# repo can't afford given it builds a password manager. The SHA is immutable; the version tag is
# kept only as a trailing comment for humans.
jobs:
  build-and-test:
    name: Build & unit tests
    # macos-26 (arm64) has been GA since 2026-02-26 and its default Xcode is 26.6 — confirmed
    # against actions/runner-images' macos-26-arm64-Readme.md on 2026-08-29, which lists Xcode 26.6
    # (build 17F113) as the default alongside 26.0.1 through 26.5 as extra installs. This matches
    # the toolchain PassSumo builds with locally.
    #
    # VERIFY ON FIRST RED RUN: if this job fails at the "Select Xcode 26.6" step because
    # /Applications/Xcode_26.6.app doesn't exist, the runner image has moved on — check
    # https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md
    # for the current Xcode paths and update the path below and in the other jobs.
    runs-on: macos-26
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Select Xcode 26.6
        # Pin the toolchain explicitly rather than trusting the image's current default symlink —
        # the default Xcode on a runner-image label can advance to a newer point release at any
        # time, independent of this repo's own version bumps.
        run: sudo xcode-select -s /Applications/Xcode_26.6.app

      - name: Cache SPM checkouts
        # Xcode-integrated SwiftPM (what `xcodebuild`/XcodeGen-generated projects use) keeps its
        # clone/manifest cache under ~/Library/Caches/org.swift.swiftpm and ~/Library/org.swift.swiftpm,
        # shared across projects on the machine. That's cache-friendly, unlike the per-project
        # DerivedData/SourcePackages checkout path, whose directory name is unstable across runs.
        # KDBXKit isn't wired into project.yml yet (checked 2026-08-29) — this step is a no-op
        # until it lands, and then starts paying off immediately with no workflow change needed.
        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: |
            ~/Library/Caches/org.swift.swiftpm
            ~/Library/org.swift.swiftpm
          key: spm-${{ runner.os }}-${{ hashFiles('PassSumo/project.yml') }}
          restore-keys: |
            spm-${{ runner.os }}-

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate Xcode project
        run: make generate

      - name: Build (unsigned Debug)
        run: make debug

      - name: Unit tests
        run: make test

  interop:
    name: Interop (KeePassXC round-trip)
    # The requirement that actually matters for this product (see CLAUDE.md / PassSumo/README.md
    # "Interop"): a database PassSumo writes must open cleanly in KeePassXC. This job is meant to
    # fail loudly, not skip quietly, if either half of that check is missing.
    runs-on: macos-26
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Select Xcode 26.6
        run: sudo xcode-select -s /Applications/Xcode_26.6.app

      - name: Cache SPM checkouts
        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: |
            ~/Library/Caches/org.swift.swiftpm
            ~/Library/org.swift.swiftpm
          key: spm-${{ runner.os }}-${{ hashFiles('PassSumo/project.yml') }}
          restore-keys: |
            spm-${{ runner.os }}-

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Install KeePassXC
        run: brew install --cask keepassxc

      - name: Verify KeePassXC actually installed
        # Guard against the interop check "passing" for the wrong reason (cask install silently
        # failed, or keepassxc-cli isn't the name/path it resolves to on this runner). Without this,
        # a broken install could make the job green while checking nothing.
        run: |
          command -v keepassxc-cli
          keepassxc-cli --version

      - name: Generate Xcode project
        run: make generate

      - name: Build (unsigned Debug)
        run: make debug

      - name: Run interop check
        # PassSumo/scripts/interop-check.sh is owned by another agent working in this repo right
        # now; this job calls it by convention and does not vendor its own copy of that logic.
        # As of 2026-08-29 (when this workflow was written) the script did not exist yet — that is
        # expected to fail this step until it lands, which is the correct behavior: a missing
        # interop check must show up as red CI, not as a silent pass.
        run: PassSumo/scripts/interop-check.sh

  lint:
    name: Lint (tracked TODOs)
    runs-on: macos-26
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: No bare TODO( without an issue reference
        # Flags any "TODO(" under PassSumo/ that isn't annotated with a #<number> issue reference
        # (e.g. TODO(#42)) — a TODO with no reference is one nobody will ever go back and find.
        #
        # A second heuristic (flagging non-English prose, e.g. via a Cyrillic/CJK character-class
        # grep) was drafted but dropped: it depends on git/grep having PCRE Unicode support, which
        # is confirmed on this machine's local git (2.55.0) but not verified against whatever git
        # version the macos-26 hosted runner ships — shipping an unverified check risked either
        # false negatives (silently not running) or false positives on legitimate non-English
        # sample/fixture strings, for a repo where every comment/doc is already reviewed in PRs.
        # Only the TODO check below is implemented, per the "drop what isn't reliable" guidance.
        run: |
          matches="$(git grep -nE 'TODO\(' -- 'PassSumo' | grep -vE 'TODO\([^)]*#[0-9]+' || true)"
          if [ -n "$matches" ]; then
            echo "$matches"
            echo "::error::Found TODO(...) without an issue reference (expected e.g. TODO(#123))."
            exit 1
          fi
          echo "OK: no bare TODO( markers found."

  e2e:
    name: E2E (XCUITest) — manual only, not proven on hosted runners
    # `make e2e` drives XCUITest, which steals real keyboard/mouse focus and needs a live
    # windowserver session with a granted automation permission (see PassSumo/Makefile and
    # PassSumo/README.md's "Tests" section). Whether a GitHub-hosted macOS runner's headless session
    # can satisfy that at all is unverified — this job is opt-in specifically so a hang/failure here
    # never blocks the build-and-test/interop/lint jobs that every push and PR actually needs.
    if: github.event_name == 'workflow_dispatch'
    runs-on: macos-26
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Select Xcode 26.6
        run: sudo xcode-select -s /Applications/Xcode_26.6.app

      - name: Cache SPM checkouts
        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: |
            ~/Library/Caches/org.swift.swiftpm
            ~/Library/org.swift.swiftpm
          key: spm-${{ runner.os }}-${{ hashFiles('PassSumo/project.yml') }}
          restore-keys: |
            spm-${{ runner.os }}-

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: E2E (XCUITest)
        run: make e2e
