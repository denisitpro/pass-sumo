# pass-sumo

Native macOS password manager for the KeePass KDBX 4.x format.

Status: **alpha** — the app builds and runs; core vault operations (open/create/edit/save,
search, password generation, TOTP, auto-lock) have unit-test coverage, but the UI has not had its
design pass yet. v1 scope is tracked in issue #1.

The code lives in [`PassSumo/`](./PassSumo), which is meant to stand on its own (its own README,
build instructions, license notices). To build and run it:

```sh
cd PassSumo
xcodegen generate
open PassSumo.xcodeproj   # select the PassSumo scheme, ⌘R
```

or, via the Makefile:

```sh
cd PassSumo
make local   # signed Release build, installed to /Applications and launched
make test    # fast unit-test check
```

See [`PassSumo/README.md`](./PassSumo/README.md) for full build/test requirements and details.

Project conventions, architecture, and key decisions live in [CLAUDE.md](./CLAUDE.md).
