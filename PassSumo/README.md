# PassSumo

A native macOS password manager for the KeePass KDBX 4.x database format. The `.kdbx` file is the
single source of truth — there is no proprietary cloud sync; the file lives wherever you put it
(iCloud Drive, a local disk, a third-party sync tool), the same way KeePassXC, KeePassium, and
Strongbox already work with it.

**Status: alpha.** This is early scaffolding: a placeholder window, no real vault yet. App icon
artwork is also pending — `Resources/Assets.xcassets/AppIcon.appiconset` currently declares the
icon slots with no images, so the build produces a blank icon.

## Build

Requirements:

- macOS 26.
- Xcode 26.6, Swift 6 language mode (Swift 6.3.3 toolchain).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

The code lives in this folder; run every command below from inside it (`cd PassSumo` if you're
not already there). The Xcode project is generated from `project.yml` — the `.xcodeproj` is not
committed, so generate it before a first build and regenerate it whenever source files are added,
removed, or renamed:

```sh
xcodegen generate
```

`project.yml` pins a `DEVELOPMENT_TEAM` for automatic signing. Replace it with your own team ID
before building: sign into an Apple ID under Xcode › Settings › Accounts, and let Xcode fill in
the ID, or copy it from there into `project.yml`.

Day-to-day development: open the project in Xcode and run the `PassSumo` scheme (Debug, ⌘R).

```sh
open PassSumo.xcodeproj
# select the PassSumo scheme → Run
```

A `Makefile` wraps the common commands; run `make help` to see all targets:

```sh
make local       # regenerate, signed Release build, install into /Applications and launch
make remove-app  # quit PassSumo and delete /Applications/PassSumo.app — what `local` uses to reinstall
```

`make remove` goes further: a full uninstall that also clears saved preferences and the sandbox
container, so the next launch behaves like a fresh install.

### Tests

There are two suites, and the difference between them is what they cost to run — not what they
cover.

```sh
make test     # unit suite (PassSumoUnitTests) — run this on every change
make e2e      # UI suite (PassSumoUITests) — on demand only, see the warning below
```

`make test` is the routine check. It is a **hosted** unit target: the test bundle is loaded into a
real PassSumo process, so it runs with the app's identity, entitlements, and container, and drives
the production types directly. It needs no special permission and never touches your keyboard or
mouse.

`make e2e` is different in kind. XCUITest drives another process's UI, which macOS gates behind a
**system automation grant only a human can give** — expect a permission prompt the first time —
and it **takes over the keyboard and mouse** for the length of the run. Run it deliberately, not
as part of a normal edit-build loop.

Both are attached to the same scheme's test action, so a bare `xcodebuild test` runs *both* —
including the one that steals your input. `make test` and `make e2e` each pass `-only-testing:`
for exactly that reason; prefer them over calling `xcodebuild` directly.

### Versioning

`CFBundleShortVersionString`, `CFBundleVersion`, and the custom `GitRevision` key are stamped from
git at build time (a pre-build script copies `Resources/Info.plist` — the template, with
placeholder `0.0.0` / `1` / `dev` values — into the derived-data build products and rewrites those
three keys from `git describe`, `git rev-list --count HEAD`, and the short commit SHA,
`-dirty`-suffixed for an uncommitted tree). `Resources/Info.plist` itself never changes as part of
a build; only the derived copy does.

## Interop

Interoperability with the wider KeePass ecosystem is a hard requirement, not an aspiration:
databases must round-trip losslessly against `keepassxc-cli`, and open correctly in
KeePassium/Strongbox and vice versa.

## License

No license has been chosen for this code yet.

Third-party components (none at the time of writing) are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Policy: no GPL/AGPL-licensed code, ever — only
MIT/BSD/Apache-2.0/CC0 dependencies are acceptable, since GPL is incompatible with App Store
distribution.

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to contribute.
