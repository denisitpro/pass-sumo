//
// Copyright (c) 2025, Denis Dzyubenko <denis@ddenis.info>
//
// SPDX-License-Identifier: BSD-2-Clause
//

public extension InnerHeader {
    func validate() -> [ValidationFailure] {
        var results: [ValidationFailure] = []

        // `K` is hashed before use (SHA-512 for ChaCha20, SHA-256 for
        // Salsa20), so any non-empty length is a legal, readable file — see
        // `InnerHeader.CryptorError`. Only an empty key is an error; an
        // unconventional length is worth reporting (it tells you the file
        // was not written by KeePass/KeePassXC) but it is not a fault.
        let conventionalKeyLength: Int
        switch encryptionAlgorithm {
        case .ChaCha20: conventionalKeyLength = 64
        case .Salsa20: conventionalKeyLength = 32
        }
        if encryptionKey.isEmpty {
            results.append(.error("Empty \(encryptionAlgorithm) inner-stream encryption key."))
        } else if encryptionKey.count != conventionalKeyLength {
            results.append(.warning(
                "Unconventional \(encryptionAlgorithm) inner-stream key length: \(encryptionKey.count) "
                    + "bytes (writers conventionally emit \(conventionalKeyLength)). The key is hashed, "
                    + "so the file is still readable."
            ))
        }

        for (index, binaryContent) in binaryContent.enumerated() {
            if binaryContent.data.isEmpty {
                results.append(.warning("Binary content at index \(index) is empty."))
            }
        }

        return results
    }
}
