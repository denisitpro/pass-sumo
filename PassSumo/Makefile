# Convenience wrappers around the commands documented in README.md's "Build" section. These do
# not replace that documentation — see it for the full explanation of when to use each.

.DEFAULT_GOAL := help

# Derived data for `local`, kept OUTSIDE the repo so a build never puts hundreds of MB into the
# source tree (`release`/`debug` pass no -derivedDataPath, so Xcode's own default — also outside
# the repo — applies). ~/Library/Caches survives reboots unlike $(TMPDIR). Override: `make local DERIVED_DIR=...`.
DERIVED_DIR ?= $(HOME)/Library/Caches/PassSumo/DerivedData

# Used by `remove-app` to drop the stale Launch Services entry for a deleted .app — otherwise
# Spotlight/Launch Services can keep offering a "PassSumo" that no longer exists until the
# database happens to rebuild on its own schedule.
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: help generate debug release local remove-app remove run test test-signed durability durability-signed e2e

help:
	@echo "Targets:"
	@echo "  generate   - regenerate PassSumo.xcodeproj from project.yml (xcodegen generate)"
	@echo "  debug      - unsigned Debug build; fast compile check only (agents), not the human workflow"
	@echo "  release    - signed Release build (leaves the .app in DerivedData; does not install)"
	@echo "  local      - signed Release build, installed to /Applications and launched (one-step test)"
	@echo "  remove-app - quit PassSumo and delete /Applications/PassSumo.app only; what 'local' uses to reinstall"
	@echo "  remove     - full uninstall: remove-app plus all persisted user state,"
	@echo "               so the app can be tested as a first-time install (App Review's view) would see it"
	@echo "  run        - open the project in Xcode; day-to-day dev workflow is Run (Debug) via ⌘R"
	@echo "  test       - fast unit suite (PassSumoUnitTests), signing off; no automation grant, no focus steal — run this"
	@echo "  test-signed- same unit suite WITH signing; needed only for Keychain/Touch ID behaviour"
	@echo "  durability - crash-safety suite: SIGKILLs a real save mid-flight and checks the file survives."
	@echo "               Deliberately NOT part of 'test'. See Sources/DurabilityTests/README.md"
	@echo "  durability-signed - same suite WITH signing, so its App Sandbox checks stop skipping"
	@echo "  e2e        - regenerate + run the XCUITest UI suite; steals focus/mouse, run only when asked"

generate:
	xcodegen generate

debug:
	xcodebuild -project PassSumo.xcodeproj -scheme PassSumo -configuration Debug \
	  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

# Signed targets below pass -allowProvisioningUpdates: Automatic signing can need to mint or
# renew a certificate. The flag lets Xcode do that in place instead of failing the build.
release:
	xcodebuild -project PassSumo.xcodeproj -scheme PassSumo -configuration Release -allowProvisioningUpdates build

# One-step "build it and let me test it": signed Release build into DERIVED_DIR, then installed
# to /Applications and launched. Regenerates the project first to pick up newly added source
# files. Any already-running instance is replaced.
#
# Deliberately calls remove-app, NOT remove: a rebuild only needs the stale .app out of the way,
# not a full wipe of saved user state on every rebuild.
local: generate
	mkdir -p $(DERIVED_DIR)
	xcodebuild -project PassSumo.xcodeproj -scheme PassSumo -configuration Release \
	  -derivedDataPath $(DERIVED_DIR) -allowProvisioningUpdates build
	$(MAKE) remove-app
	cp -R $(DERIVED_DIR)/Build/Products/Release/PassSumo.app /Applications/
	open /Applications/PassSumo.app

# App-only uninstall: quit + delete the installed copy, nothing else. This is the first half of
# `local` above and exists as its own target specifically so `local` can call it without pulling
# in the full wipe that `remove` does below.
remove-app:
	killall PassSumo 2>/dev/null || true
	@if [ -x "$(LSREGISTER)" ] && [ -d /Applications/PassSumo.app ]; then \
	  "$(LSREGISTER)" -u /Applications/PassSumo.app; \
	fi
	rm -rf /Applications/PassSumo.app
	@echo "removed /Applications/PassSumo.app"

# Full uninstall: remove-app plus every piece of persisted user state, so the app can be
# exercised exactly as a first-time install would look to an App Review auditor. Every step below
# tolerates the thing already being gone — running this twice in a row must succeed silently, not
# fail partway through — and only ever touches user-visible install state, never build artifacts
# (~/Library/Caches/PassSumo, DerivedData).
remove: remove-app
	@# The App Sandbox container is where a sandboxed app's real state lives: Preferences, the
	@# Keychain-adjacent bookmark data, Application Support, Caches, Saved Application State and
	@# HTTPStorages are all *inside* it, not at their traditional top-level paths. Deleting the
	@# container is most of the wipe in one step.
	@if [ -d "$(HOME)/Library/Containers/app.passsumo" ]; then \
	  rm -rf "$(HOME)/Library/Containers/app.passsumo"; \
	  echo "removed ~/Library/Containers/app.passsumo"; \
	fi
	@# The XCUITest runner gets its own container under a distinct bundle id
	@# (app.passsumo.uitests.xctrunner) — wipe it too so `make e2e` also starts from a clean slate
	@# instead of inheriting whatever the previous UI run left behind.
	@if [ -d "$(HOME)/Library/Containers/app.passsumo.uitests.xctrunner" ]; then \
	  rm -rf "$(HOME)/Library/Containers/app.passsumo.uitests.xctrunner"; \
	  echo "removed ~/Library/Containers/app.passsumo.uitests.xctrunner"; \
	fi
	@# No App Group is configured today, but a group container is keyed by group id, not bundle
	@# id, so an app-only container wipe wouldn't catch one if a future version added it. Sweep
	@# for it defensively; the glob is quoted only around the space in "Group Containers" so it
	@# still expands, and a no-match leaves the literal pattern, which `-e` then correctly treats
	@# as absent.
	@for d in "$(HOME)/Library/Group Containers/"*app.passsumo*; do \
	  [ -e "$$d" ] && rm -rf "$$d" && echo "removed $$d"; \
	done; true
	@# Legacy/non-sandboxed leftover safety net: a pre-sandbox or ad-hoc-signed build could still
	@# write a top-level plist instead of a container one.
	@if [ -f "$(HOME)/Library/Preferences/app.passsumo.plist" ]; then \
	  rm -f "$(HOME)/Library/Preferences/app.passsumo.plist"; \
	  echo "removed ~/Library/Preferences/app.passsumo.plist"; \
	fi
	@# cfprefsd caches preferences in memory keyed by bundle id and can flush that cache straight
	@# back to disk on the app's next read — deleting only the plist file above is not enough to
	@# make the deletion stick. `defaults delete` clears the cached copy too.
	@defaults delete app.passsumo >/dev/null 2>&1 || true
	@# Saved window state, Caches and HTTPStorages for a *sandboxed* app all live inside the
	@# container already removed above; these top-level locations are only the pre-sandbox
	@# fallback, kept as a safety net for a non-sandboxed build.
	@if [ -e "$(HOME)/Library/Saved Application State/app.passsumo.savedState" ]; then \
	  rm -rf "$(HOME)/Library/Saved Application State/app.passsumo.savedState"; \
	  echo "removed ~/Library/Saved Application State/app.passsumo.savedState"; \
	fi
	@if [ -e "$(HOME)/Library/Caches/app.passsumo" ]; then \
	  rm -rf "$(HOME)/Library/Caches/app.passsumo"; \
	  echo "removed ~/Library/Caches/app.passsumo"; \
	fi
	@if [ -e "$(HOME)/Library/HTTPStorages/app.passsumo" ]; then \
	  rm -rf "$(HOME)/Library/HTTPStorages/app.passsumo"; \
	  echo "removed ~/Library/HTTPStorages/app.passsumo"; \
	fi
	@echo "wiped user state for app.passsumo"

run:
	# Day-to-day human workflow: open in Xcode, select the PassSumo scheme, then Run (⌘R).
	open PassSumo.xcodeproj

# In-process unit suite — the routine check. Hosted by the app itself, so it needs no system
# automation grant and never touches the keyboard or the mouse; run it on every change.
# `-only-testing` is not optional: the scheme's test action carries BOTH suites, so a bare
# `xcodebuild test` would drag the XCUITest one in behind it.
#
# Signing is DISABLED here on purpose. This is the fast everyday check — the one every agent and
# every contributor runs on every change — so it must work on any machine, including one with no
# Apple Developer account, no team membership and no registered device. With Automatic signing
# left on, `xcodebuild test` fails before compiling a single line with "No profiles for
# 'app.passsumo' were found … Device isn't registered in your developer account", which has
# nothing to do with the code under test: the unit bundle is loaded into the host app in-process
# and none of these tests assert anything about entitlements, the sandbox container or the
# Keychain. Anything that genuinely needs a real signed host goes through `test-signed` below.
test: generate
	xcodebuild -project PassSumo.xcodeproj -scheme PassSumo -configuration Debug \
	  -destination 'platform=macOS' -only-testing:PassSumoUnitTests test \
	  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

# Same suite, but with signing on — for the cases `test` deliberately cannot cover. An unsigned
# host has no entitlements, so it gets no App Sandbox container, no keychain-access-groups and no
# Touch ID / LocalAuthentication identity; anything asserting on Keychain items, biometric
# prompts or sandbox-relative paths only means something here. Needs a configured Apple Developer
# account and this machine registered on the team — `-allowProvisioningUpdates` lets Xcode mint or
# renew the profile in place rather than failing, exactly as `release`/`local` do above.
test-signed: generate
	xcodebuild -project PassSumo.xcodeproj -scheme PassSumo -configuration Debug \
	  -destination 'platform=macOS' -only-testing:PassSumoUnitTests test \
	  -allowProvisioningUpdates

# Durability / crash-safety suite: what the database file looks like when the process dies in the
# middle of a save. It spawns PassSumoDurabilityHelper — a separate executable that drives the real
# VaultStore/codec/file-access stack — and SIGKILLs it at controlled points, then reopens whatever
# is on disk with the real codec.
#
# NOT part of `make test`, on purpose — and not mainly because of the ~26s it adds (the unit suite
# is ~24s), but because it is a different kind of test: it spawns subprocesses and SIGKILLs them,
# writes and copies 8 MB files, and two cases depend on tools that may be absent (keepassxc-cli) or
# disallowed (sandbox-exec). None of that belongs in the check run on every edit. Run this one on
# any change to the save path, the codec, or SandboxedVaultFileAccess.
#
# Signing off, like `test`: an unsigned host runs anywhere, and — importantly — an unsigned host is
# NOT sandboxed, which is what lets these tests spawn a subprocess at all. The cost is that the
# App Sandbox assertions skip; `durability-signed` below is the run that exercises those.
durability: generate
	xcodebuild -project PassSumo.xcodeproj -scheme PassSumo -configuration Debug \
	  -destination 'platform=macOS' -only-testing:PassSumoDurabilityTests test \
	  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

# Same suite, signed, so the test host really is sandboxed and
# testAtomicWriteWorksInsideTheRealAppSandboxContainer stops skipping. Most kill tests still work —
# the helper deliberately has no entitlements file, so it stays unsandboxed and can still reach the
# host's temporary directory — but four cases skip here, because a sandboxed host cannot launch
# sandbox-exec (no nesting) and cannot poll a directory fast enough to catch the atomic write's
# temporary file. Measured: 22 tests, 4 skipped. Run BOTH; neither is a superset of the other.
durability-signed: generate
	xcodebuild -project PassSumo.xcodeproj -scheme PassSumo -configuration Debug \
	  -destination 'platform=macOS' -only-testing:PassSumoDurabilityTests test \
	  -allowProvisioningUpdates

# The XCUITest suite steals focus/mouse and needs a system automation grant a human has to give —
# run only when explicitly requested, not as part of routine builds. Use `make test` for that.
e2e: generate
	xcodebuild -project PassSumo.xcodeproj -scheme PassSumo -configuration Debug \
	  -destination 'platform=macOS' -only-testing:PassSumoUITests test
