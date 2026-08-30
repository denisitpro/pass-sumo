import Foundation
import KDBXKit

// MARK: - Round-trip state

/// Everything the codec needs to write a file back without losing what `Vault` cannot represent.
///
/// It carries the ORIGINAL `KDBXContent` — header, inner header, `Meta`, the whole group tree with
/// its attachments, history and custom data. `encode` starts from this and applies deltas; it never
/// rebuilds a database out of `Vault`. `KDBXContent` is `Sendable`, so this crosses actor
/// boundaries with the rest of `DecodedVault`.
struct KDBXOrigin: VaultCodecState {
    var content: KDBXContent
}

// MARK: - Codec

/// The real KDBX 4.x codec, implemented on top of KDBXKit (BSD-2-Clause; see
/// `THIRD-PARTY-NOTICES.md` and the pinning rationale in `project.yml`).
///
/// Reads KDBX 3.1, 4.0 and 4.1. **Always writes KDBX 4.1** — KDBXKit's writer only emits the 4.x
/// on-disk shape, so saving a 3.1 file upgrades it in place. That is the right default (4.x is the
/// format with per-block authentication and Argon2) but it is a one-way change for a file another
/// tool may still be reading, which is why the repo requires a backup before the first save to an
/// existing database.
///
/// Stateless and therefore trivially `Sendable`; `VaultStore` runs `decode`/`encode` off the main
/// actor because Argon2 takes roughly a second by design.
struct KDBXKitCodec: VaultCodec {
    /// `Meta/CustomData` key under which the vault's stable identity lives. See
    /// `databaseID(of:)`.
    static let databaseIDKey = "PassSumo/DatabaseID"

    /// Written into `Meta/Generator` for databases we create, so another client (and a support
    /// request) can tell which app produced the file.
    private static let generator = "PassSumo"

    init() {}

    // MARK: Decode

    func decode(fileData: Data, credentials: VaultCredentials) throws -> DecodedVault {
        // Header first, WITHOUT credentials. It costs nothing (the KDF has not run yet) and it is
        // the only place a feature we cannot support can be reported honestly: once `parse` starts
        // deriving a key, an unsupported KDF variant comes back as a failed unlock, which reads to
        // the user as "wrong password".
        let header: Header
        do {
            header = try KDBXReader.parseHeader(fileData)
        } catch {
            throw KDBXErrorMapping.vaultError(from: error, fileData: fileData)
        }

        try Self.rejectUnsupportedKDF(header)

        let unlockData = try Self.unlockData(for: credentials)

        let content: KDBXContent
        do {
            content = try KDBXReader.parse(fileData, unlockData: unlockData)
        } catch {
            throw KDBXErrorMapping.vaultError(from: error, fileData: fileData)
        }

        return DecodedVault(
            vault: KDBXVaultProjection.vault(from: content),
            opaque: KDBXOrigin(content: content)
        )
    }

    /// Rejects KDF configurations that would otherwise fail in a way that misinforms the user.
    ///
    /// Argon2 **v1.0** is the important one. KDBXKit passes no version to the P-H-C hasher, which
    /// hard-codes 0x13, so a v1.0 database derives the wrong key from the right password. At the
    /// pinned revision the header parse rejects v1.0 outright and this check cannot fire — it is
    /// here so that if a future KDBXKit starts *accepting* v1.0 headers while still hashing them as
    /// 1.3, the failure mode is an accurate message instead of a silent regression to
    /// "wrong password". `KDBXArgon2VersionProbe` covers the case as things actually stand today.
    private static func rejectUnsupportedKDF(_ header: Header) throws {
        switch header.kdfParameters {
        case let .argon2d(params, _), let .argon2id(params, _):
            guard params.version != .v1_0 else {
                throw VaultError.unsupportedFeature(
                    "This database uses Argon2 version 1.0, which PassSumo cannot open yet. "
                        + "Your file is fine — open it in KeePassXC and save it (KeePassXC writes "
                        + "Argon2 version 1.3), then reopen it here."
                )
            }
        case .aes:
            break
        case let .unknown(uuid):
            throw VaultError.unsupportedFeature(
                "This database derives its key with a function PassSumo does not support (KDF \(uuid)). "
                    + "Re-save it in KeePassXC using Argon2id or AES-KDF."
            )
        }
    }

    // MARK: Encode

    func encode(_ vault: Vault, credentials: VaultCredentials, origin: DecodedVault?) throws -> Data {
        // Falling back to an empty database when `origin` is missing is required by the protocol,
        // but it means a save with no origin CANNOT preserve anything — it has nothing to preserve
        // from. `VaultStore` always passes what `decode` returned; anything else is a caller bug,
        // and the empty base keeps that bug from also being a crash.
        let base = (origin?.opaque as? KDBXOrigin)?.content
            ?? KDBXContent.makeEmpty(databaseName: vault.name, generator: Self.generator)

        let content = KDBXContentMerge.apply(vault, to: base)
        return try Self.serialize(content, credentials: credentials)
    }

    // MARK: Create

    func makeEmpty(name: String, credentials: VaultCredentials) throws -> DecodedVault {
        // Validate the credentials here rather than at the first save: a key file that cannot be
        // read should fail while the user is still in the "create database" flow, not later when
        // they think their vault already exists.
        _ = try Self.unlockData(for: credentials)

        let content = KDBXContent.makeEmpty(databaseName: name, generator: Self.generator)
        return DecodedVault(
            vault: KDBXVaultProjection.vault(from: content),
            opaque: KDBXOrigin(content: content)
        )
    }

    // MARK: Shared

    private static func unlockData(for credentials: VaultCredentials) throws -> UnlockData {
        guard let keyFile = credentials.keyFile else {
            return UnlockData(masterPassword: credentials.password)
        }
        do {
            return try UnlockData(masterPassword: credentials.password, keyFile: keyFile)
        } catch {
            // KeyFileError's cases are about the file's shape, not the user's password — surfacing
            // them as `.wrongCredentials` would send the user to re-type a password that is fine.
            throw VaultError.io("The key file could not be used: \(error)")
        }
    }

    private static func serialize(_ content: KDBXContent, credentials: VaultCredentials) throws -> Data {
        let unlockData = try unlockData(for: credentials)

        let stream = OutputStream(toMemory: ())
        stream.open()
        defer { stream.close() }

        do {
            // `regenerateSalts` is left at its default of `true` and MUST NEVER be set to `false`
            // for a real save. It regenerates the master salt, the encryption nonce, the KDF salt
            // AND the inner random-stream key on every write. Reusing the inner key is not a
            // theoretical weakness: the inner stream is a keystream XOR, so two saves of the same
            // vault under the same key would encrypt the passwords with the SAME keystream, and
            // anyone holding both files recovers the plaintext by XORing them together — no
            // password needed. That defect is precisely why this project pins an unreleased KDBXKit
            // revision instead of a tag (see project.yml). The flag exists only so KDBXKit's own
            // tests can assert byte-equality; production code has no legitimate use for it.
            try KDBXWriter(to: stream).write(content, unlockData: unlockData)
        } catch {
            throw KDBXErrorMapping.vaultError(from: error)
        }

        guard let data = stream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data else {
            throw VaultError.io("The database was encoded but its bytes could not be read back.")
        }
        return data
    }
}

// MARK: - Stable per-database identity

extension KDBXKitCodec {
    /// The vault's stable identifier, or `nil` if it has never been assigned one.
    ///
    /// This is what the Keychain/Touch ID layer keys its stored secret on (`VaultKeyIdentifier`).
    /// It is a random UUID kept in `Meta/CustomData` under `PassSumo/DatabaseID`, because that is
    /// the only place in the format that satisfies all four requirements at once: it survives the
    /// file being moved or renamed, it survives iCloud relocation, other clients round-trip it
    /// untouched (`CustomData` is KDBX's sanctioned extension point, and KDBXKit preserves keys it
    /// does not understand), and — critically — it does not change when the file is saved.
    ///
    /// The tempting alternative, hashing the header's master seed, is broken: KDBX 4 regenerates
    /// that seed on **every** save by design (see `serialize`), so the identifier would change the
    /// first time the user edited an entry and orphan the Keychain item behind it.
    func databaseID(of decoded: DecodedVault) -> UUID? {
        guard let origin = decoded.opaque as? KDBXOrigin else { return nil }
        guard let raw = origin.content.database.meta.customData
            .first(where: { $0.key == Self.databaseIDKey })?.value
        else { return nil }
        return UUID(uuidString: raw)
    }

    /// Returns `decoded` with a freshly generated database ID, or unchanged if it already has one.
    ///
    /// Assignment is an explicit call rather than a side effect of `decode` **because it is a
    /// mutation, and a mutation only reaches disk through a save.** Making it implicit would mean
    /// merely opening a vault marked it dirty and rewrote the user's file — a read must never do
    /// that, least of all to a file that lives in a synced folder or that the user opened read-only
    /// from a backup. The caller decides when the write is warranted (in practice: when the user
    /// opts into Touch ID unlock) and saves deliberately.
    ///
    /// Returns `nil` if `decoded` carries no KDBX origin, which can only happen for a
    /// `DecodedVault` this codec did not produce.
    func assigningDatabaseID(to decoded: DecodedVault) -> (vault: DecodedVault, id: UUID)? {
        guard var origin = decoded.opaque as? KDBXOrigin else { return nil }
        if let existing = databaseID(of: decoded) { return (decoded, existing) }

        let id = UUID()
        origin.content.database.meta.customData.append(
            KDBX.CustomDataWithTimes(
                key: Self.databaseIDKey,
                value: id.uuidString,
                lastModificationTime: Date()
            )
        )

        var updated = decoded
        updated.opaque = origin
        return (updated, id)
    }
}
