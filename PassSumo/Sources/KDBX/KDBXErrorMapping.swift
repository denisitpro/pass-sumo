import Foundation
import KDBXKit

/// Translates KDBXKit's errors into the flat `VaultError` the store and the UI understand.
///
/// Both switches below are deliberately written with **no `default:` case**. A KDBXKit upgrade that
/// adds an error case must then fail the build here rather than silently falling into whichever
/// bucket the `default` happened to name — which, for a password manager, means the difference
/// between telling a user their file is damaged and telling them their password is wrong.
enum KDBXErrorMapping {
    /// `fileData` is only used to run the Argon2-v1.0 probe on the one error that needs it; nothing
    /// here reads or retains the file's contents otherwise.
    static func vaultError(from error: KDBXReader.Error, fileData: Data) -> VaultError {
        switch error {
        case .wrongCredentials:
            return .wrongCredentials

        case .invalidFileSignature:
            return .notAKDBXFile

        case let .unsupportedFormatVersion(major, minor):
            return .unsupportedVersion(
                "This file is KDBX \(major).\(minor). PassSumo reads KDBX 3.1, 4.0 and 4.1. "
                    + "Open it in KeePassXC and save it as KDBX 4 to use it here."
            )

        case let .unsupportedEncryption(uuid):
            // KDBXKit implements AES-256-CBC and ChaCha20. Twofish is the only other cipher any
            // KeePass distribution offers, so it is by far the likeliest cause — but it is named
            // here as the likely cause rather than asserted, because the cipher UUID is not
            // verified against a Twofish constant anywhere in this codebase.
            return .unsupportedFeature(
                "This database uses an encryption algorithm PassSumo does not support (cipher \(uuid)). "
                    + "Twofish is the usual reason. Re-encrypt the database with AES-256 or ChaCha20 "
                    + "in KeePassXC's Database Security settings."
            )

        case let .unsupportedKDF(uuid):
            return .unsupportedFeature(
                "This database derives its key with a function PassSumo does not support (KDF \(uuid)). "
                    + "Re-save it in KeePassXC using Argon2id or AES-KDF."
            )

        case let .unsupportedCompression(code):
            return .unsupportedFeature(
                "This database uses compression method \(code), which PassSumo does not support. "
                    + "Re-save it in KeePassXC with the default (gzip) compression."
            )

        case let .kdfParametersOutOfRange(reason):
            // A ceiling on KDF cost, checked BEFORE the KDF runs — the defence against a file
            // crafted to make us allocate gigabytes. Not corruption, and not something the user did
            // wrong, so it gets its own actionable message.
            return .unsupportedFeature(
                "This database asks for more key-derivation work than PassSumo will do in one go "
                    + "(\(reason)). Lower the KDF settings in KeePassXC and save again."
            )

        case let .corruptedHeader(reason):
            // The one place the Argon2-v1.0 probe pays off: at the pinned revision a v1.0 database
            // fails here, and "your file header is corrupt" would send the user to a backup they do
            // not need. See KDBXArgon2VersionProbe for the whole story.
            if KDBXArgon2VersionProbe.detectsArgon2Version1_0(in: fileData) {
                return .unsupportedFeature(
                    "This database uses Argon2 version 1.0, which PassSumo cannot open yet. "
                        + "Your file is fine — open it in KeePassXC and save it (KeePassXC writes "
                        + "Argon2 version 1.3), then reopen it here."
                )
            }
            return .corrupted("The database header is damaged: \(reason)")

        case .corruptedHeaderDigest:
            return .corrupted(
                "The database header failed its checksum — the file was modified or truncated in transit."
            )

        case let .corruptedHMAC(reason):
            return .corrupted(
                "The database failed its authentication check, so its contents cannot be trusted: \(reason)"
            )

        case let .corruptedInnerHeader(reason):
            return .corrupted("The database's attachment table is damaged: \(reason)")

        case let .corruptedXML(reason):
            return .corrupted("The database decrypted but its contents could not be parsed: \(reason)")

        case let .decompressedPayloadTooLarge(limit):
            return .corrupted(
                "The database expands to more than \(limit / 1_048_576) MB when decompressed, "
                    + "which means it is damaged or deliberately malformed."
            )

        case .unexpectedEOF:
            return .corrupted("The file ends earlier than its header says it should — it is truncated.")

        case .unlockDataRequired:
            // Unreachable from this codec: `decode` always passes credentials, and the header peek
            // goes through `parseHeader`, which handles this case internally. Reported as an
            // internal error rather than mapped to something user-facing that would be a lie.
            return .io("Internal error: the KDBX reader was called without credentials.")
        }
    }

    static func vaultError(from error: KDBXWriter.Error) -> VaultError {
        switch error {
        case let .streamWriteFailed(underlying):
            return .io("Could not write the database: \(underlying.localizedDescription)")

        case .streamNotOpen:
            return .io("Internal error: the KDBX writer's output stream was not open.")

        case .unexpectedEOF:
            return .io("The database could not be written completely.")

        case let .headerSerializationFailed(reason):
            return .io("Could not write the database header: \(reason)")

        case let .innerHeaderSerializationFailed(reason):
            return .io("Could not write the database's attachment table: \(reason)")

        case let .xmlSerializationFailed(reason):
            return .io("Could not write the database's contents: \(reason)")

        case let .unsupportedKDF(uuid):
            return .unsupportedFeature(
                "PassSumo cannot save a database that derives its key with KDF \(uuid)."
            )

        case let .encryptionFailed(reason):
            return .io("Could not encrypt the database: \(reason)")

        case let .compressionFailed(reason):
            return .io("Could not compress the database: \(reason)")

        // The two save-time integrity checks below are the writer refusing to produce a file that
        // would lose attachment data. `.corrupted` rather than `.io` on purpose: the problem is the
        // in-memory database, not the disk, and the user must not be told to just retry the save.
        case let .danglingBinaryRef(entryUUID, ref, poolCount):
            return .corrupted(
                "Refusing to save: entry \(entryUUID) references attachment \(ref), but the "
                    + "database only holds \(poolCount). Saving would lose the attachment."
            )

        case let .binarySourceCountMismatch(sources, poolEntries):
            return .corrupted(
                "Refusing to save: \(sources) attachment sources for \(poolEntries) attachment "
                    + "records. Saving would lose data."
            )
        }
    }
}
