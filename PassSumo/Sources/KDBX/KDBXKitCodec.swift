import Foundation
import KDBXKit
import Security

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
/// Stateless apart from its KDF policy, and therefore trivially `Sendable`; `VaultStore` runs
/// `decode`/`encode` off the main actor because Argon2 takes roughly a second by design.
struct KDBXKitCodec: VaultCodec {
    /// `Meta/CustomData` key under which the vault's stable identity lives. See
    /// `databaseID(of:)`.
    static let databaseIDKey = "PassSumo/DatabaseID"

    /// Written into `Meta/Generator` for databases we create, so another client (and a support
    /// request) can tell which app produced the file.
    private static let generator = "PassSumo"

    /// How a database **we** create gets its key-derivation parameters.
    ///
    /// A closure rather than a stored `KDFParameters` because the salt has to be fresh per
    /// database: a stored value would hand the same salt to every vault this codec ever creates,
    /// which is the one thing a salt exists to prevent.
    ///
    /// Injected, with the production tuple as the default, for the reason the rest of this app
    /// injects its collaborators: the cost that makes ``productionKDF`` worth having is exactly
    /// what makes it unaffordable in a test suite. A unit suite that creates a few dozen databases
    /// would spend a minute proving nothing about the KDF — and a dev loop that slow is what
    /// eventually tempts someone to weaken the real tuple for the wrong reason. Defaulting to
    /// production means nothing can get the cheap one without asking for it by name.
    let newDatabaseKDF: @Sendable () throws -> KDFParameters

    init(newDatabaseKDF: @escaping @Sendable () throws -> KDFParameters = KDBXKitCodec.productionKDF) {
        self.newDatabaseKDF = newDatabaseKDF
    }

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
        let base = try (origin?.opaque as? KDBXOrigin)?.content
            ?? KDBXContent.makeEmpty(
                databaseName: vault.name,
                kdf: newDatabaseKDF(),
                generator: Self.generator
            )

        let content = KDBXContentMerge.apply(vault, to: base)
        return try Self.serialize(content, credentials: credentials)
    }

    // MARK: Create

    func makeEmpty(name: String, credentials: VaultCredentials) throws -> DecodedVault {
        // Validate the credentials here rather than at the first save: a key file that cannot be
        // read should fail while the user is still in the "create database" flow, not later when
        // they think their vault already exists.
        _ = try Self.unlockData(for: credentials)

        let content = KDBXContent.makeEmpty(
            databaseName: name,
            kdf: try newDatabaseKDF(),
            generator: Self.generator
        )
        return DecodedVault(
            vault: KDBXVaultProjection.vault(from: content),
            opaque: KDBXOrigin(content: content)
        )
    }

    // MARK: Shared

    /// The key-derivation parameters for a database **we** create: Argon2id v1.3,
    /// t = 120 passes, m = 64 MiB, p = 4 lanes, with a fresh 32-byte random salt per database.
    ///
    /// Written out here rather than left to `KDFParameters.argon2idDefault()`. The library's
    /// default is a portable, hardware-neutral value it is explicitly free to re-tune, so
    /// inheriting it means the strength of every vault we create is a number nobody in this repo
    /// chose and nobody would notice changing. That is not hypothetical: the default is RFC 9106
    /// §4's memory-constrained option (t=3, m=64 MiB, p=4), which measured **20 ms** here, while
    /// three comments in this app described the KDF as "~1 s" of deliberate work — off by a factor
    /// of forty, and unnoticed until the 2026-09-13 audit (issue #178).
    ///
    /// **Measured, not assumed:** median **856 ms** (min 841, max 912 over 9 runs, machine
    /// otherwise idle) on an Apple Silicon Mac mini — a Release build of a standalone executable
    /// calling `UnlockData.computeUnlockKey`, which is the same derivation a real unlock and a real
    /// save perform. The same binary measured the old default at 20 ms on the same run. Under load
    /// the same tuple medians ~935 ms with a much wider spread, and KDF time is hardware-dependent
    /// besides, so read this as the order of magnitude the tuple was chosen for rather than a
    /// wall-clock guarantee.
    ///
    /// **The 856 ms is Release only.** Argon2 is C, and an unoptimised build of it measures ~8.7 s
    /// for this tuple — ~10x the shipped cost. Both test suites build Debug, and it shows: holding
    /// everything else fixed, `make durability` runs in 28 s at `iterations: 3` and 438 s at
    /// `iterations: 120`, a delta that divides out to ~7 s per derivation. A "the KDF feels slow"
    /// report from a Debug build is therefore not a measurement of what users get. `TestKDF` keeps
    /// the unit suite off this path, and the durability tests that are not about key derivation
    /// create their fixtures with a cheap KDF — which is what matters, because a save pays the KDF
    /// recorded in the file's header, not one chosen by whoever is saving. That takes the suite from
    /// 438 s to 186 s; the rest is the tests that must keep the real derivation.
    ///
    /// `t = 120` sits well inside `KDFParameterLimits.default` (max 1000 iterations, max 1 GiB
    /// memory), which is what our own reader checks a file's declared parameters against before
    /// running the KDF — a production tuple our own limit check would reject would be a
    /// self-inflicted unopenable file.
    ///
    /// **Why the second is bought with `t` and not with `m`.** More memory is the better lever in
    /// the abstract — it is what defeats the wide parallelism a GPU or ASIC guessing rig is built
    /// on, where extra passes only cost an attacker time it already has. It is not the better lever
    /// *here*, because these parameters live in the file and every client that opens the vault has
    /// to allocate them too. On iOS the AutoFill Credential Provider extension runs under a hard
    /// memory cap far below the host app's, so a header declaring a large Argon2 memory cost is
    /// what makes a database unlock in KeePassium's or Strongbox's main app and fail inside the
    /// same vendor's AutoFill extension — a file *we* wrote refusing to open on a client the repo
    /// promises compatibility with (CLAUDE.md: "databases must open in KeePassium/Strongbox and
    /// vice versa"), and unfixable for the user without re-keying the database. 64 MiB is the
    /// interoperable ceiling, which is also why KeePassXC's own default stays there and buys its
    /// ~1 s with iterations. So `m` is pinned, not tuned — and **never lowered**: dropping it is a
    /// straight cut in brute-force cost per guess, not a performance tweak.
    ///
    /// Applies to **new** databases only. A file we open keeps whatever KDF it arrived with; a save
    /// is not the moment to re-tune somebody else's database for them.
    static func productionKDF() throws -> KDFParameters {
        .argon2id(
            .init(
                version: .v1_3,
                salt: try newKDFSalt(),
                iterations: 120,
                memory: 64 * 1024 * 1024,
                parallelism: 4
            ),
            additional: [:]
        )
    }

    /// A fresh 32-byte Argon2 salt.
    ///
    /// `SecRandomCopyBytes` directly rather than `CSPRNG` (`Sources/Security`) — not a second
    /// opinion about randomness, a target boundary: `Sources/KDBX` is compiled into the durability
    /// helper too, which builds `Sources/Model` + `Sources/KDBX` and no more (see `project.yml`).
    /// `Sources/DurabilityHelper` reaches for the same call for the same reason. The rationale for
    /// preferring `SecRandomCopyBytes` over the stdlib generator is written out once, in `CSPRNG`.
    private static func newKDFSalt() throws -> Data {
        var salt = Data(count: 32)
        let status: Int32 = salt.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, raw.count, base)
        }
        // No fallback to a weaker source: a predictable salt lets one precomputed Argon2 run cover
        // every vault created on this machine, which is the whole point of having a salt.
        guard status == errSecSuccess else {
            throw VaultError.io("Could not generate a key-derivation salt (SecRandomCopyBytes \(status))")
        }
        return salt
    }

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
            // revision instead of a tag (see project.yml). The flag exists only so tests can
            // control the exact bytes on disk — byte-equality round-trips, and the
            // inner-stream-key fixtures in `KDBXCodecTests`. Production code has no legitimate
            // use for it.
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
