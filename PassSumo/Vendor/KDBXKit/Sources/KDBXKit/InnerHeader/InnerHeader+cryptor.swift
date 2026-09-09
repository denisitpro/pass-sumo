//
// Copyright (c) 2025, Denis Dzyubenko <denis@ddenis.info>
//
// SPDX-License-Identifier: BSD-2-Clause
//

import Foundation

extension InnerHeader {
    /// Inner-stream cipher construction failure surface.
    ///
    /// `K` — the inner random-stream key as it appears in the inner header —
    /// is **hashed** before it is used: `SHA-512(K)` for ChaCha20,
    /// `SHA-256(K)` for Salsa20. Any non-empty `K`, of any length,
    /// therefore yields a valid fixed-size cipher key. The 64 bytes
    /// (ChaCha20) / 32 bytes (Salsa20) named in the KDBX documentation are
    /// what a *writer* is expected to emit by convention — KeePass 2.x and
    /// KeePassXC both do, and so does this library's writer — and **not** a
    /// constraint a reader may enforce. A file carrying a shorter `K` is a
    /// legal file, and rejecting it locks the user out of an intact
    /// database.
    ///
    /// The one genuinely broken case is an empty `K`: there is no key
    /// material at all, so the inner header cannot be what it claims to be.
    ///
    /// Untyped `throws` because `SecureBytes.withUnsafeBytes` is declared
    /// `rethrows` over an untyped closure and won't propagate a typed error
    /// out unchanged; callers re-wrap as
    /// `KDBXReader.Error.corruptedInnerHeader` / equivalent.
    enum CryptorError: Swift.Error, Equatable, Sendable {
        /// The inner header declared an inner-stream cipher but carried a
        /// zero-length key, leaving nothing to derive from.
        case emptyKey(algorithm: EncryptionAlgorithm)
    }

    private func makeCryptor() throws -> any Encryptable & Decryptable {
        try encryptionKey.withUnsafeBytes { keyPtr -> any Encryptable & Decryptable in
            var rawKey = Data(keyPtr.bindMemory(to: UInt8.self))
            defer {
                rawKey.withUnsafeMutableBytes { ptr in
                    _ = ptr.initializeMemory(as: UInt8.self, repeating: 0)
                }
            }

            switch encryptionAlgorithm {
            case .ChaCha20:
                /// `K` is 64 bytes by convention, but it is hashed — any
                /// non-empty length derives a valid key. See `CryptorError`.
                guard !rawKey.isEmpty else {
                    throw CryptorError.emptyKey(algorithm: .ChaCha20)
                }

                /// Compute `H := SHA-512(K)`.
                let hash = rawKey.sha512()

                /// The key for ChaCha20 is `H[0], ..., H[31]`
                let key = hash.subdata(in: 0..<32)

                /// and the nonce is `H[32], ..., H[43]`.
                let nonce = hash.subdata(in: 32..<44)

                // ChaCha20 init only fails on key/iv length mismatch.
                // SHA-512 returns 64 bytes whatever the length of `K`, so
                // the 32-byte key + 12-byte nonce slices are infallible.
                return try! ChaCha20(key: key, iv: nonce)

            case .Salsa20:
                /// `K` is 32 bytes by convention, but it is hashed — any
                /// non-empty length derives a valid key. See `CryptorError`.
                guard !rawKey.isEmpty else {
                    throw CryptorError.emptyKey(algorithm: .Salsa20)
                }

                /// The key for Salsa20 is SHA-256(K)
                let key = rawKey.sha256()

                /// and the nonce is `0xE8, 0x30, 0x09, 0x4B, 0x97, 0x20, 0x5D, 0x2A`
                let nonce = Data([0xE8, 0x30, 0x09, 0x4B, 0x97, 0x20, 0x5D, 0x2A])

                // Salsa20 init only fails on key/iv length mismatch.
                // SHA-256 returns 32 bytes whatever the length of `K`, and
                // the nonce is a literal, so both sides are length-fixed.
                return try! Salsa20(key: key, iv: nonce)
            }
        }
    }

    func makeDecryptor() throws -> any Decryptable {
        try makeCryptor()
    }

    func makeEncryptor() throws -> any Encryptable {
        try makeCryptor()
    }

    /// Produce a `KeystreamSource` carrying the inner-cipher key and
    /// nonce. Used by the reader to emit `.lazyInnerCipher`
    /// `ProtectedString.Value`s — same key derivation as
    /// `makeCryptor()`, but value-typed and Sendable so it can be
    /// embedded in entries without keeping a stateful cipher alive.
    func makeKeystreamSource() throws -> KeystreamSource {
        try encryptionKey.withUnsafeBytes { keyPtr -> KeystreamSource in
            var rawKey = Data(keyPtr.bindMemory(to: UInt8.self))
            defer {
                rawKey.withUnsafeMutableBytes { ptr in
                    _ = ptr.initializeMemory(as: UInt8.self, repeating: 0)
                }
            }

            switch encryptionAlgorithm {
            case .ChaCha20:
                // K is any non-empty length (64 bytes by convention).
                // The inner cipher derives:
                //   H := SHA-512(K)
                //   key   = H[0..32]
                //   nonce = H[32..44]
                guard !rawKey.isEmpty else {
                    throw CryptorError.emptyKey(algorithm: .ChaCha20)
                }
                let hash = rawKey.sha512()
                let key = hash.subdata(in: 0..<32)
                let nonce = hash.subdata(in: 32..<44)
                return KeystreamSource(
                    algorithm: .chacha20,
                    key: SecureBytes(key),
                    nonce: nonce
                )

            case .Salsa20:
                // K is any non-empty length (32 bytes by convention);
                // key = SHA-256(K). Nonce is a fixed constant from the
                // KDBX spec.
                guard !rawKey.isEmpty else {
                    throw CryptorError.emptyKey(algorithm: .Salsa20)
                }
                let key = rawKey.sha256()
                let nonce = Data([0xE8, 0x30, 0x09, 0x4B, 0x97, 0x20, 0x5D, 0x2A])
                return KeystreamSource(
                    algorithm: .salsa20,
                    key: SecureBytes(key),
                    nonce: nonce
                )
            }
        }
    }
}
