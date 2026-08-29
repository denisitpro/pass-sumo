import Foundation

/// Detects, from the cleartext KDBX 4 header alone, a database whose KDF is **Argon2 version 1.0**
/// (`0x10`) rather than the current 1.3 (`0x13`).
///
/// ## Why this exists
///
/// KDBXKit's Argon2 binding hands the P-H-C reference implementation no version argument:
/// `argon2{i,d}_hash_raw` hard-code `ARGON2_VERSION_NUMBER` (0x13). A v1.0 database therefore
/// derives a DIFFERENT key from the correct password. Depending on where the library rejects it,
/// the user is told either that their password is wrong or that their file is corrupt — both are
/// lies, and the first is the worse one: it sends someone hunting for a password they already have.
///
/// At the pinned revision the library never gets that far — `KDFParameters.init(from:)` refuses to
/// build a v1.0 parameter set, so the file surfaces as `corruptedHeader(reason:)` during the header
/// walk. That is not a message anyone can act on, which is what this probe fixes: it lets the codec
/// turn that specific case into `VaultError.unsupportedFeature` with instructions.
///
/// ## Why it re-reads the header instead of asking the library
///
/// Precisely because the library's parse fails first, there is no parsed `Header` to inspect. The
/// walk below is read-only, bounded, and can only ever change which error message the user sees —
/// it never feeds a decode.
///
/// ## Why it does not look at the KDF UUID
///
/// It would be the obvious check and it is the easy thing to get wrong: KDBX stores those UUIDs in
/// a mixed-endian layout, so a literal copied from a spec page matches nothing. Instead the probe
/// keys off the parameter names, which are unambiguous — `V`, `M` and `P` (version, memory,
/// parallelism) appear together only in an Argon2 parameter dictionary; AES-KDF uses `S` and `R`.
enum KDBXArgon2VersionProbe {
    /// KDBX 4 headers are a few hundred bytes. Reading a bounded prefix keeps the probe O(1) in the
    /// size of the vault and means a hostile file cannot make it walk a gigabyte.
    private static let maxHeaderBytes = 64 * 1024

    private static let signature1: UInt32 = 0x9AA2_D903
    private static let signature2: UInt32 = 0xB54B_FB67
    private static let kdfParametersFieldID: UInt8 = 11
    private static let variantTypeUInt32: UInt8 = 0x04
    private static let argon2Version1_0: UInt32 = 0x10

    /// `true` only when the file is a KDBX 4 container whose KDF parameters say Argon2 v1.0.
    /// Every ambiguity — truncation, an unexpected length, a version this codec does not model —
    /// answers `false`, because the caller's fallback is the library's own error, and a
    /// false positive here would mislabel a genuinely corrupt file as merely unsupported.
    static func detectsArgon2Version1_0(in fileData: Data) -> Bool {
        var cursor = ByteCursor(Array(fileData.prefix(maxHeaderBytes)))

        guard
            cursor.readUInt32() == signature1,
            cursor.readUInt32() == signature2,
            let rawVersion = cursor.readUInt32()
        else { return false }

        // Major 4 only. KDBX 3.1 frames header fields with UInt16 lengths and has no KDF-parameter
        // field at all (its KDF is always AES-KDF), so walking it with this reader would be
        // nonsense rather than merely unproductive.
        guard UInt16(truncatingIfNeeded: rawVersion >> 16) == 4 else { return false }

        // A well-formed header has under a dozen fields; the bound stops a crafted file from
        // spinning here on zero-length records.
        for _ in 0 ..< 64 {
            guard
                let fieldID = cursor.readUInt8(),
                let length = cursor.readUInt32(),
                let payload = cursor.read(count: Int(length))
            else { return false }

            if fieldID == 0 { return false }           // EndOfHeader, and no KDF field was found.
            if fieldID == kdfParametersFieldID {
                return isArgon2Version1_0(variantDictionary: payload)
            }
        }
        return false
    }

    /// Walks a KDBX VariantDictionary (`<UInt16 version>` then `<UInt8 type><Int32 nameLen><name>`
    /// `<Int32 valueLen><value>` records, terminated by a zero type byte) looking only for the
    /// Argon2 fingerprint.
    private static func isArgon2Version1_0(variantDictionary bytes: [UInt8]) -> Bool {
        var cursor = ByteCursor(bytes)
        guard cursor.readUInt16() != nil else { return false }

        var version: UInt32?
        var hasMemory = false
        var hasParallelism = false

        for _ in 0 ..< 256 {
            guard let type = cursor.readUInt8() else { return false }
            if type == 0 { break }

            // Both lengths are SIGNED 32-bit in the format. Reading them as unsigned is how a
            // negative length becomes a gigantic allocation or a trap — the exact defect class the
            // pinned revision exists to avoid, so this reader will not reintroduce it.
            guard
                let nameLength = cursor.readInt32(), nameLength > 0,
                let nameBytes = cursor.read(count: Int(nameLength)),
                let valueLength = cursor.readInt32(), valueLength > 0,
                let valueBytes = cursor.read(count: Int(valueLength))
            else { return false }

            let name = String(decoding: nameBytes, as: UTF8.self)
            switch name {
            case "V" where type == variantTypeUInt32 && valueBytes.count == 4:
                version = UInt32(littleEndian: valueBytes)
            case "M": hasMemory = true
            case "P": hasParallelism = true
            default: break
            }
        }

        return version == argon2Version1_0 && hasMemory && hasParallelism
    }
}

// MARK: - Bounded cursor

/// Minimal bounds-checked reader. Every accessor returns `nil` past the end rather than trapping —
/// this walks attacker-controlled bytes, so a range check that crashes is not a range check.
private struct ByteCursor {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(count: Int) -> [UInt8]? {
        guard count >= 0, position <= bytes.count - count else { return nil }
        defer { position += count }
        return Array(bytes[position ..< position + count])
    }

    mutating func readUInt8() -> UInt8? {
        guard let slice = read(count: 1) else { return nil }
        return slice[0]
    }

    mutating func readUInt16() -> UInt16? {
        guard let slice = read(count: 2) else { return nil }
        return UInt16(littleEndian: slice)
    }

    mutating func readUInt32() -> UInt32? {
        guard let slice = read(count: 4) else { return nil }
        return UInt32(littleEndian: slice)
    }

    mutating func readInt32() -> Int32? {
        guard let value = readUInt32() else { return nil }
        return Int32(bitPattern: value)
    }
}

private extension UInt16 {
    init(littleEndian bytes: [UInt8]) {
        self = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }
}

private extension UInt32 {
    init(littleEndian bytes: [UInt8]) {
        self = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }
}
