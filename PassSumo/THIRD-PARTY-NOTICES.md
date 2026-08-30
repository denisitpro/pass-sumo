# Third-Party Notices

Policy: only MIT/BSD/Apache-2.0/CC0/Zlib-licensed dependencies are acceptable — no GPL/AGPL code,
ever, since GPL is incompatible with App Store distribution. Any third-party code added in the
future must be recorded here with its license.

Everything below was verified by reading the license file in the actual source tree on
2026-08-30, not from memory or from a package index's metadata field. For KDBXKit that tree is
`Vendor/KDBXKit/`, which is committed into this repository (see below); for the transitive Swift
packages it is the SwiftPM checkout SwiftPM resolved for the build.

---

## KDBXKit

- Upstream source: <https://github.com/shadone/KDBXKit>
- Vendored revision: `e9b8839f1226b82665e1e4b7f12f13635d189deb`
- **Redistributed in this repository** as a `git subtree` copy at `Vendor/KDBXKit/`, byte-for-byte
  identical to that upstream revision. It is consumed as a local SwiftPM package
  (`packages: KDBXKit: path: Vendor/KDBXKit` in `project.yml`), not fetched from a remote.
- License: **BSD 2-Clause** — `Vendor/KDBXKit/LICENSE`, "BSD 2-Clause License, Copyright (c)
  2025-2026, Denis Dzyubenko <denis@ddenis.info>". Per-file SPDX headers and
  `Vendor/KDBXKit/REUSE.toml` cover the rest of that tree.

The KDBX 4.x reader/writer behind `Sources/KDBX`. Because the source is redistributed here rather
than merely depended on, the BSD-2-Clause copyright notice and disclaimer below apply to this
repository's source distribution as well as to the shipped binary. See
`Vendor/KDBXKit-VENDORING.md` for why it is vendored, how to pull upstream changes in, and how to
split the tree back out; see `project.yml` for why the revision is a `develop` commit rather than a
released tag.

```
BSD 2-Clause License

Copyright (c) 2025-2026, Denis Dzyubenko <denis@ddenis.info>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Test fixtures redistributed from KDBXKit

`Sources/UnitTests/Fixtures/kdbxkit/simple-argon2id-aes256.kdbx` and
`Sources/UnitTests/Fixtures/kdbxkit/kpxc-rich.kdbx` are copied verbatim from KDBXKit's own test
resources (`Vendor/KDBXKit/Tests/KDBXKitTests/Resources/`) at the vendored revision above, and are covered by the
same BSD-2-Clause license reproduced here. They are KeePassXC-written KDBX 4.1 databases with the
published test password `123`; they contain no real secrets. See
`Sources/UnitTests/Fixtures/README.md` for what each one exercises and for why a test that only
reads them proves less than the write-direction interop check does.

### Code vendored inside KDBXKit

These ship inside the KDBXKit source tree rather than as separate packages, so they carry their
own licenses and must be listed separately.

#### P-H-C reference Argon2 (`Vendor/KDBXKit/Sources/CArgon2`)

- License: **CC0-1.0 OR Apache-2.0**, at our option — `Vendor/KDBXKit/Sources/CArgon2/LICENSE`: "Copyright 2015
  Daniel Dinu, Dmitry Khovratovich, Jean-Philippe Aumasson, and Samuel Neves … You may use this
  work under the terms of a Creative Commons CC0 1.0 License/Waiver or the Apache Public License
  2.0, at your option." Full texts are reproduced in that file and in
  `Vendor/KDBXKit/LICENSES/CC0-1.0.txt` / `Vendor/KDBXKit/LICENSES/Apache-2.0.txt`.

#### Salsa20 / ChaCha20 (`Vendor/KDBXKit/Sources/KDBXKit/Crypto/{Salsa20,ChaCha20}.swift`)

- Derived from CryptoSwift. License: **Zlib** — per-file SPDX header
  `SPDX-License-Identifier: Zlib`, "Copyright (C) 2014-2025 Marcin Krzyżanowski
  <marcin@krzyzanowskim.com>, Copyright (C) 2025 Denis Dzyubenko <denis@ddenis.info>". Full text
  in `Vendor/KDBXKit/LICENSES/Zlib.txt`.
- The Zlib license requires that an acknowledgment appear in the product documentation when the
  software is used in a product; this entry is that acknowledgment.

---

## Transitive Swift package dependencies

Resolved by SwiftPM as dependencies of KDBXKit. These are **not** redistributed in this
repository — only KDBXKit itself is vendored; SwiftPM still fetches everything below. Versions are
what the build resolved on 2026-08-30 (they match `Vendor/KDBXKit/Package.resolved`, which SwiftPM
now honours because KDBXKit is a local package rather than a remote pin); the license was read from
each package's checkout.

| Package | Version | License | Verified from |
| --- | --- | --- | --- |
| [swift-crypto](https://github.com/apple/swift-crypto) | 3.15.1 | Apache-2.0 | `LICENSE.txt`, `NOTICE.txt` |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.0 | Apache-2.0 | `LICENSE.txt`, `NOTICE.txt` |
| [swift-log](https://github.com/apple/swift-log) | 1.12.0 | Apache-2.0 | `LICENSE.txt`, `NOTICE.txt` |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.5.0 | Apache-2.0 | `LICENSE.txt` |
| [swift-docc-plugin](https://github.com/apple/swift-docc-plugin) | 1.5.0 | Apache-2.0 | `LICENSE.txt` |
| [swift-docc-symbolkit](https://github.com/swiftlang/swift-docc-symbolkit) | 1.0.0 | Apache-2.0 | `LICENSE.txt` |

`swift-argument-parser` is resolved because KDBXKit's package manifest also declares a `kdbx`
command-line executable. `swift-docc-plugin` (and its own dependency `swift-docc-symbolkit`) is
resolved because that manifest declares a documentation build plugin. PassSumo depends only on the
`KDBXKit` **library** product, so none of these three is linked into the shipped app — the two DocC
packages are build-time tooling that produces no runtime code at all. They are listed here anyway
rather than omitted, because "fetched but we believe it isn't linked" is not a claim worth leaving
undocumented.

`swift-crypto` vendors a copy of BoringSSL under `Sources/CCryptoBoringSSL`. That copy has no
top-level `LICENSE` file; the notices live in per-file headers, and the files spot-checked
(`crypto/mem.cc`, `crypto/crypto.cc`, `crypto/internal.h`) carry Apache-2.0 headers. This has NOT
been audited file by file — before the first App Store submission, re-derive the vendored
BoringSSL notice set from the upstream `swift-crypto` release being shipped rather than trusting
this paragraph.

KDBXKit also declares a `CZlib` system-library target, which links the zlib already present in
the macOS SDK. No zlib source is vendored or redistributed by this app.
