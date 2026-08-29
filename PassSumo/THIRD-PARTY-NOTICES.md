# Third-Party Notices

Policy: only MIT/BSD/Apache-2.0/CC0/Zlib-licensed dependencies are acceptable — no GPL/AGPL code,
ever, since GPL is incompatible with App Store distribution. Any third-party code added in the
future must be recorded here with its license.

Everything below was verified by reading the license file in the checked-out package on
2026-08-29, not from memory or from a package index's metadata field.

---

## KDBXKit

- Source: <https://github.com/denisitpro/KDBXKit> (fork of <https://github.com/shadone/KDBXKit>)
- Pinned revision: `e9b8839f1226b82665e1e4b7f12f13635d189deb`
- License: **BSD 2-Clause** — `LICENSE`, "BSD 2-Clause License, Copyright (c) 2025-2026,
  Denis Dzyubenko <denis@ddenis.info>"

The KDBX 4.x reader/writer behind `Sources/KDBX`. See `project.yml` for why the dependency is
pinned to an exact commit rather than a released tag.

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
resources (`Tests/KDBXKitTests/Resources/`) at the pinned revision above, and are covered by the
same BSD-2-Clause license reproduced here. They are KeePassXC-written KDBX 4.1 databases with the
published test password `123`; they contain no real secrets. See
`Sources/UnitTests/Fixtures/README.md` for what each one exercises and for why a test that only
reads them proves less than the write-direction interop check does.

### Code vendored inside KDBXKit

These ship inside the KDBXKit source tree rather than as separate packages, so they carry their
own licenses and must be listed separately.

#### P-H-C reference Argon2 (`Sources/CArgon2`)

- License: **CC0-1.0 OR Apache-2.0**, at our option — `Sources/CArgon2/LICENSE`: "Copyright 2015
  Daniel Dinu, Dmitry Khovratovich, Jean-Philippe Aumasson, and Samuel Neves … You may use this
  work under the terms of a Creative Commons CC0 1.0 License/Waiver or the Apache Public License
  2.0, at your option." Full texts are reproduced in that file and in `LICENSES/CC0-1.0.txt` /
  `LICENSES/Apache-2.0.txt`.

#### Salsa20 / ChaCha20 (`Sources/KDBXKit/Crypto/{Salsa20,ChaCha20}.swift`)

- Derived from CryptoSwift. License: **Zlib** — per-file SPDX header
  `SPDX-License-Identifier: Zlib`, "Copyright (C) 2014-2025 Marcin Krzyżanowski
  <marcin@krzyzanowskim.com>, Copyright (C) 2025 Denis Dzyubenko <denis@ddenis.info>". Full text
  in `LICENSES/Zlib.txt`.
- The Zlib license requires that an acknowledgment appear in the product documentation when the
  software is used in a product; this entry is that acknowledgment.

---

## Transitive Swift package dependencies

Resolved by SwiftPM as dependencies of KDBXKit. Versions are what `Package.resolved` pinned on
2026-08-29; the license was read from each package's checkout.

| Package | Version | License | Verified from |
| --- | --- | --- | --- |
| [swift-crypto](https://github.com/apple/swift-crypto) | 3.15.1 | Apache-2.0 | `LICENSE.txt`, `NOTICE.txt` |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.1 | Apache-2.0 | `LICENSE.txt`, `NOTICE.txt` |
| [swift-log](https://github.com/apple/swift-log) | 1.15.0 | Apache-2.0 | `LICENSE.txt`, `NOTICE.txt` |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | `LICENSE.txt` |

`swift-argument-parser` is resolved because KDBXKit's package manifest also declares a `kdbx`
command-line executable. PassSumo depends only on the `KDBXKit` **library** product, so
ArgumentParser is fetched but not linked into the shipped app; it is listed here anyway rather
than omitted, because "fetched but we believe it isn't linked" is not a claim worth leaving
undocumented.

`swift-crypto` vendors a copy of BoringSSL under `Sources/CCryptoBoringSSL`. That copy has no
top-level `LICENSE` file; the notices live in per-file headers, and the files spot-checked
(`crypto/mem.cc`, `crypto/crypto.cc`, `crypto/internal.h`) carry Apache-2.0 headers. This has NOT
been audited file by file — before the first App Store submission, re-derive the vendored
BoringSSL notice set from the upstream `swift-crypto` release being shipped rather than trusting
this paragraph.

KDBXKit also declares a `CZlib` system-library target, which links the zlib already present in
the macOS SDK. No zlib source is vendored or redistributed by this app.
